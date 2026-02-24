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

# ---------- DNS A Record ----------
resource "cloudflare_record" "vps_a_record" {
  zone_id = var.cloudflare_zone_id
  name    = var.subdomain
  value   = var.vps_ip
  type    = "A"
  ttl     = 1
  proxied = false
  comment = "Managed by Terraform"
}

# ---------- Upload files to VPS ----------
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

  depends_on = [
    cloudflare_record.vps_a_record,
    null_resource.upload_files,
  ]

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

      "if ! command -v docker &>/dev/null; then curl -fsSL https://get.docker.com | sh && sudo usermod -aG docker ${var.ssh_user}; fi",

      "docker compose version",

      # Write .env for docker-compose
      "cat > ${local.deploy_dir}/.env <<EOF",
      "APP_IMAGE=${var.app_image}",
      "DOMAIN=${local.fqdn}",
      "EOF",

      # Start the stack (nginx + app)
      var.enable_nginx ? "cd ${local.deploy_dir} && docker compose pull && docker compose up -d --remove-orphans" : "echo '==> Docker stack skipped'",

      # Issue wildcard cert via DNS challenge, then write HTTPS nginx config and reload
      var.enable_ssl && var.enable_nginx ? join(" && ", [
        "echo '==> Issuing wildcard SSL cert via Cloudflare DNS challenge'",
        "docker compose -f ${local.deploy_dir}/docker-compose.yml run --rm certbot certonly --dns-cloudflare --dns-cloudflare-credentials /etc/letsencrypt/cloudflare.ini --email ${var.ssl_email} --agree-tos --no-eff-email -d ${local.wildcard_domain}",
        "cat > ${local.deploy_dir}/nginx/conf.d/app.conf <<'NGINXCONF'\nserver {\n    listen 80;\n    server_name ${local.fqdn};\n    location /.well-known/acme-challenge/ { root /var/www/certbot; }\n    location / { return 301 https://$host$request_uri; }\n}\nserver {\n    listen 443 ssl;\n    server_name ${local.fqdn};\n    ssl_certificate /etc/letsencrypt/live/${local.wildcard_domain}/fullchain.pem;\n    ssl_certificate_key /etc/letsencrypt/live/${local.wildcard_domain}/privkey.pem;\n    ssl_protocols TLSv1.2 TLSv1.3;\n    location / {\n        proxy_pass http://app:3000;\n        proxy_http_version 1.1;\n        proxy_set_header Upgrade $http_upgrade;\n        proxy_set_header Connection upgrade;\n        proxy_set_header Host $host;\n        proxy_set_header X-Real-IP $remote_addr;\n        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;\n        proxy_set_header X-Forwarded-Proto $scheme;\n    }\n}\nNGINXCONF",
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
