# ============================================================
# variables.tf
# ============================================================

# ---------- VPS connection ----------
variable "vps_ip" {
  description = "Public IP address of the target VPS"
  type        = string
}

variable "ssh_private_key" {
  description = "Private SSH key content for connecting to VPS"
  type        = string
  sensitive   = true
}

variable "ssh_user" {
  description = "SSH user on the VPS"
  type        = string
  default     = "ubuntu"
}

variable "ssh_port" {
  description = "SSH port on the VPS"
  type        = number
  default     = 22
}

# ---------- Domain & DNS ----------
variable "domain" {
  description = "Root domain managed in Cloudflare (e.g. example.com)"
  type        = string
}

variable "subdomain" {
  description = "Subdomain prefix for this deployment (e.g. staging-a1b2 or prod-x9y8). Combined with domain to form the FQDN."
  type        = string
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token with Zone:Edit permission"
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Cloudflare Zone ID for the domain"
  type        = string
}

# ---------- Feature flags ----------
variable "enable_nginx" {
  description = "Deploy Nginx container as reverse proxy"
  type        = bool
  default     = true
}

variable "enable_ssl" {
  description = "Request SSL certificate via Certbot"
  type        = bool
  default     = true
}

variable "enable_monitoring" {
  description = "Install Beszel agent on the host (not container)"
  type        = bool
  default     = false
}

variable "ssl_email" {
  description = "Email for Let's Encrypt certificate registration"
  type        = string
  default     = ""
}

# ---------- App ----------
variable "app_image" {
  description = "Docker image for the app service (e.g. ghcr.io/user/myapp:latest)"
  type        = string
}
