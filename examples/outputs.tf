# Output Variables

output "google_project_name" {
  description = "Google Project Name"
  value       = module.project.google_project_name
}

output "google_project_id" {
  description = "Google Project ID"
  value       = module.project.google_project_id
}

output "google_project_number" {
  description = "Google Project Number"
  value       = module.project.google_project_number
}

output "google_billing_account" {
  description = "Google Billing Account ID"
  value       = module.project.google_billing_account
}

output "google_org_id" {
  description = "Google Organization ID number"
  value       = module.project.google_org_id
}

output "google_compute_network_name" {
  description = "Google VPC Network Name"
  value       = module.vpc-networking.google_compute_network_name
}

output "local_public_ip" {
  description = "Public IP Address"
  value       = module.public_ip.public_ip
}
