# ============================================================
# main.tf
# ============================================================

terraform {
  required_version = ">= 1.6"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

locals {
  # e.g. staging-a1b2.terraform.domain.com
  fqdn       = "${var.subdomain}.${var.domain}"
  deploy_dir = "/opt/app/${var.subdomain}"

  # Wildcard cert covers *.terraform.domain.com — no per-deploy cert needed
  wildcard_domain = "*.${var.domain}"
}

# ---------- Upload files to VPS ----------
# DNS record is not managed here — the wildcard *.terraform.domain.com
# record already exists in Cloudflare and covers all subdomains.
resource "null_resource" "upload_files" {
  triggers = {
    vps_ip    = var.vps_ip
    app_image = var.app_image
    subdomain = var.subdomain
  }

  connection {
    type        = "ssh"
    host        = var.vps_ip
    user        = var.ssh_user
    port        = var.ssh_port
    private_key = var.ssh_private_key
    timeout     = "5m"
  }

  # Create per-deployment directory structure on VPS
  provisioner "remote-exec" {
    inline = [
      "mkdir -p ${local.deploy_dir}/nginx/conf.d",
      "mkdir -p ${local.deploy_dir}/nginx/ssl",
    ]
  }

  provisioner "file" {
    source      = "${path.module}/../docker-compose.yml"
    destination = "${local.deploy_dir}/docker-compose.yml"
  }

  # Upload nginx config then replace ${DOMAIN} placeholder
  provisioner "file" {
    source      = "${path.module}/../nginx/conf.d/app.conf"
    destination = "${local.deploy_dir}/nginx/conf.d/app.conf.tmpl"
  }

  provisioner "remote-exec" {
    inline = [
      "sed 's/$${DOMAIN}/${local.fqdn}/g' ${local.deploy_dir}/nginx/conf.d/app.conf.tmpl > ${local.deploy_dir}/nginx/conf.d/app.conf",
      "rm ${local.deploy_dir}/nginx/conf.d/app.conf.tmpl",
    ]
  }
}

# ---------- VPS provisioning ----------
resource "null_resource" "vps_provision" {
  triggers = {
    upload_id         = null_resource.upload_files.id
    enable_nginx      = tostring(var.enable_nginx)
    enable_ssl        = tostring(var.enable_ssl)
    enable_monitoring = tostring(var.enable_monitoring)
  }

  depends_on = [null_resource.upload_files]

  connection {
    type        = "ssh"
    host        = var.vps_ip
    user        = var.ssh_user
    port        = var.ssh_port
    private_key = var.ssh_private_key
    timeout     = "10m"
  }

  provisioner "remote-exec" {
    inline = [
      "set -e",

      # Install Docker if not present
      "if ! command -v docker &>/dev/null; then",
      "  curl -fsSL https://get.docker.com | sh",
      "  sudo usermod -aG docker ${var.ssh_user}",
      "fi",

      "docker compose version",

      # Write .env for docker-compose
      "cat > ${local.deploy_dir}/.env <<EOF",
      "APP_IMAGE=${var.app_image}",
      "DOMAIN=${local.fqdn}",
      "EOF",

      # Start the stack (nginx + app)
      var.enable_nginx ? "cd ${local.deploy_dir} && docker compose pull && docker compose up -d --remove-orphans" : "echo '==> Docker stack skipped'",

      # Issue wildcard cert via DNS challenge (covers all *.terraform.domain.com)
      # Requires certbot-dns-cloudflare plugin and CF credentials
      var.enable_ssl && var.enable_nginx ? join("\n", [
        "echo '==> Issuing wildcard SSL cert via Cloudflare DNS challenge'",
        "docker compose -f ${local.deploy_dir}/docker-compose.yml run --rm certbot certonly",
        "  --dns-cloudflare",
        "  --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini",
        "  --email ${var.ssl_email}",
        "  --agree-tos --no-eff-email",
        "  -d ${local.wildcard_domain}",
        "docker compose -f ${local.deploy_dir}/docker-compose.yml restart nginx",
      ]) : "echo '==> SSL skipped'",

      # Beszel agent runs on the host (not in a container) to access Docker socket and host metrics
      var.enable_monitoring ? join("\n", [
        "echo '==> Installing Beszel agent on host'",
        "curl -fsSL https://raw.githubusercontent.com/henrygd/beszel/main/supplemental/scripts/install-agent.sh -o /tmp/install-agent.sh",
        "chmod +x /tmp/install-agent.sh",
        "sudo bash /tmp/install-agent.sh",
      ]) : "echo '==> Monitoring skipped'",

      "echo '==> Provisioning complete'",
    ]
  }
}
