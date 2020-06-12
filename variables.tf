# Input Variables

variable "google_project_name" {
  description = "Google Project Name. Must be less than 30 alpha-numberic characters. (Example: tf-gcp-test-project)"
}

variable "google_project_number" {
  description = "Google Project Number"
}

variable "google_region" {
  description = "Google Cloud Region"
  type        = map
}

variable "google_compute_network" {
  description = "Google Compute VPC Network Name"
}

variable "local_public_ip" {
  description = "Public IP Address"
}

variable "shared_image_project" {
  description = "Google Project where GCE Image resides"
}

variable "jenkins_instance_type" {
  description = "Jenkins Master Instance Type"
}
