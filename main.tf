### Terraform Resources

# Setting local variables for the sake of reusability of resouces described below

locals {
  instance-ip = "${cidrhost(data.google_compute_subnetwork.jenkins-cidr-range.ip_cidr_range, 100)}"
}



### Resource Collection

data "google_compute_zones" "available" {
  depends_on = [
    google_project_service.compute
  ]

  region = var.google_region["single"]
}


# Collect Latest Jenkins Master Compute Image
data "google_compute_image" "jenkins_image" {
  depends_on = [
    google_project_service.compute,
    google_project_iam_member.cross-project-role-source-image-project
  ]

  project = var.shared_image_project
  family  = "jenkins-master"
}


data "google_compute_subnetwork" "jenkins-cidr-range" {
  depends_on = [
    google_project_service.compute
  ]

  name   = google_compute_subnetwork.jenkins.name
  region = var.google_region["single"]
}




### Create Jenkins Master Resources

resource "google_project_service" "compute" {
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_compute_disk" "jenkins-master-data-disk" {
  depends_on = [
    google_project_iam_member.cross-project-role-source-image-project,
    google_project_iam_member.jenkins-master-service-account-editor,
    google_service_account.jenkins-master-service-account,
    google_compute_subnetwork.jenkins
  ]
  name = "jenkins-master-data-disk"
  type = "pd-standard"
  size = var.jenkins_data_disk_size
  zone = data.google_compute_zones.available.names[0]

  labels = {
    app       = "jenkins",
    role      = "master"
    component = "data-disk"
  }

  lifecycle {
    ignore_changes = [zone]
  }

}


resource "google_compute_instance_template" "jenkins-master" {
  depends_on = [
    data.google_compute_zones.available
  ]
  provider = google-beta

  name                 = "jenkins-master"
  description          = "Jenkins Master Instance Template"
  instance_description = "Jenkins Master Instance"

  tags = [
    "jenkins-master"
  ]

  labels = {
    app  = "jenkins",
    role = "master"
  }

  region         = var.google_region["single"]
  machine_type   = var.jenkins_instance_type
  can_ip_forward = false

  scheduling {
    automatic_restart   = false
    on_host_maintenance = "TERMINATE"
    preemptible         = true
  }

  disk {
    disk_name    = "jenkins-master-boot-disk"
    source_image = data.google_compute_image.jenkins_image.self_link
    auto_delete  = true
    boot         = true
    disk_type    = "pd-standard"
    type         = "PERSISTENT"
  }

  disk {
    source      = google_compute_disk.jenkins-master-data-disk.name
    auto_delete = false
    boot        = false
    device_name = "sdb"
    mode        = "READ_WRITE"
  }

  network_interface {
    network    = var.google_compute_network
    subnetwork = google_compute_subnetwork.jenkins.name
    network_ip = local.instance-ip

    access_config {
      nat_ip       = ""
      network_tier = "PREMIUM"
    }
  }

  service_account {
    email = google_service_account.jenkins-master-service-account.email
    scopes = [
      "cloud-platform"
    ]
  }

  metadata_startup_script = <<EOM
#!/bin/bash

if sudo blkid /dev/sdb
then 
        sudo mkdir -p /mnt/disks/data
        sudo mount -o discard,defaults /dev/sdb /mnt/disks/data
        sudo mkdir -p /mnt/disks/data/jenkins_home
        sudo chown 1000:1000 /mnt/disks/data/jenkins_home
else 
        sudo mkfs.ext4 -m 0 -F -E lazy_itable_init=0,lazy_journal_init=0,discard /dev/sdb; \
        sudo mkdir -p /mnt/disks/data
        sudo mount -o discard,defaults /dev/sdb /mnt/disks/data
        sudo mkdir -p /mnt/disks/data/jenkins_home
        sudo chown 1000:1000 /mnt/disks/data/jenkins_home
fi
EOM

  lifecycle {
    create_before_destroy = true

    ignore_changes = [
      disk,
      network_interface[0].network_ip
    ]
  }
}


resource "google_compute_instance_group_manager" "jenkins-master" {
  depends_on = [
    google_project_iam_member.cross-project-role-source-image-project,
    google_project_iam_member.jenkins-master-service-account-editor
  ]

  name        = "jenkins-master"
  description = "Jenkins Master Instance Group"

  base_instance_name = "jenkins-master"
  instance_template  = google_compute_instance_template.jenkins-master.self_link
  zone               = data.google_compute_zones.available.names[0]
  update_strategy    = "NONE"
  target_size        = 1

  named_port {
    name = "http"
    port = 8080
  }

  lifecycle {
    ignore_changes = [
      zone
    ]
  }
}


data "google_compute_instance_group" "jenkins-master" {
  name = google_compute_instance_group_manager.jenkins-master.name
  zone = data.google_compute_zones.available.names[0]
}


resource "google_compute_health_check" "jenkins-master-tcp" {
  depends_on = [
    google_compute_instance_group_manager.jenkins-master
  ]

  name                = "jenkins-master-tcp-8080-healthcheck"
  timeout_sec         = 5
  check_interval_sec  = 10
  healthy_threshold   = 2
  unhealthy_threshold = 6

  tcp_health_check {
    port               = "8080"
    port_specification = "USE_FIXED_PORT"
    proxy_header       = "NONE"
  }
}


resource "google_compute_backend_service" "jenkins-master" {
  provider = google-beta

  name                  = "jenkins-master-backend"
  health_checks         = [google_compute_health_check.jenkins-master-tcp.self_link]
  protocol              = "HTTP"
  port_name             = data.google_compute_instance_group.jenkins-master.named_port[0].name
  timeout_sec           = 10
  load_balancing_scheme = "EXTERNAL"

  backend {
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1
    max_utilization = 0.8
    group           = google_compute_instance_group_manager.jenkins-master.instance_group
  }

  lifecycle {
    ignore_changes = [
      port_name
    ]
  }
}


resource "google_compute_url_map" "jenkins-master" {
  name            = "jenkins-master-loadbalancer"
  default_service = google_compute_backend_service.jenkins-master.self_link
}


resource "google_compute_target_http_proxy" "jenkins-master" {
  provider = google-beta

  name    = "jenkins-master-target-http-proxy"
  url_map = google_compute_url_map.jenkins-master.self_link
}


resource "google_compute_global_forwarding_rule" "jenkins-master" {
  provider = google-beta

  name                  = "jenkins-master-global-forwading-rule"
  target                = google_compute_target_http_proxy.jenkins-master.self_link
  port_range            = "80"
  load_balancing_scheme = "EXTERNAL"
}



resource "google_service_account" "jenkins-master-service-account" {
  account_id   = "jenkins-master-service-account"
  display_name = "Jenkins Master Service Account"
}



resource "google_project_iam_member" "jenkins-master-service-account-editor" {
  role   = "roles/editor"
  member = "serviceAccount:${google_service_account.jenkins-master-service-account.email}"
}



resource "google_project_iam_member" "cross-project-role-source-image-project" {
  project = var.shared_image_project
  role    = "roles/compute.imageUser"
  member  = "serviceAccount:${var.google_project_number}@cloudservices.gserviceaccount.com"
}




resource "google_compute_firewall" "allow-ssh-jenkins-master" {
  name    = "allow-ssh-jenkins-master"
  network = var.google_compute_network

  allow {
    protocol = "icmp"
  }

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = [var.local_public_ip]
  target_tags   = ["jenkins-master"]
}


resource "google_compute_firewall" "allow-http-jenkins-master" {
  name    = "allow-http-jenkins-master"
  network = var.google_compute_network

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }

  source_ranges = [var.local_public_ip]
  target_tags   = ["jenkins-master"]
}


resource "google_compute_firewall" "allow-jnlp-jenkins-master" {
  name    = "allow-jnlp-jenkins-master"
  network = var.google_compute_network

  allow {
    protocol = "tcp"
    ports    = ["50000"]
  }

  source_tags = ["jenkins-slave"]
  target_tags = ["jenkins-master"]
}


resource "google_compute_firewall" "allow-lb-healthcheck-jenkins-master" {
  name    = "allow-lb-healthcheck-jenkins-master"
  network = var.google_compute_network

  allow {
    protocol = "tcp"
    ports    = ["8080"]
  }

  source_ranges = ["35.191.0.0/16", "130.211.0.0/22"]
  target_tags   = ["jenkins-master"]
}


resource "google_compute_subnetwork" "jenkins" {
  depends_on = [
    google_project_service.compute
  ]

  name          = "jenkins"
  network       = var.google_compute_network
  region        = var.google_region["single"]
  ip_cidr_range = "10.0.0.0/24"

  private_ip_google_access = true
}