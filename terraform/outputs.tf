# ============================================================
# outputs.tf
# ============================================================

output "public_ip" {
  description = "Public IP address of the VPS"
  value       = var.vps_ip
}

output "domain" {
  description = "Fully qualified domain name for this deployment"
  value       = local.fqdn
}

output "final_url" {
  description = "Final URL of the deployed application"
  value       = var.enable_ssl ? "https://${local.fqdn}" : "http://${local.fqdn}"
}

output "features_enabled" {
  description = "Summary of which features were enabled in this run"
  value = {
    nginx      = var.enable_nginx
    ssl        = var.enable_ssl && var.enable_nginx
    monitoring = var.enable_monitoring
  }
}
