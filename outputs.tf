output "app_public_ip" {
  description = "Public IP of the app VM"
  value       = azurerm_public_ip.app.ip_address
}

output "app_url" {
  description = "Quiz app URL"
  value       = "https://${var.domain}"
}

output "ssh_app" {
  description = "SSH command for the app VM"
  value       = "ssh ${data.azurerm_key_vault_secret.admin_username.value}@${azurerm_public_ip.app.ip_address}"
}

output "entra_redirect_uri" {
  description = "Add this to your Entra app registration under Authentication > Redirect URIs"
  value       = "https://${var.domain}/auth/callback"
}

output "dns_instruction" {
  description = "Point your domain to this IP"
  value       = "Create an A record: ${var.domain} → ${azurerm_public_ip.app.ip_address}"
}

output "setup_log" {
  description = "Monitor VM setup progress"
  value       = "ssh ${data.azurerm_key_vault_secret.admin_username.value}@${azurerm_public_ip.app.ip_address} 'tail -f /var/log/app-setup.log'"
}

output "ACTION_REQUIRED" {
  description = "Steps after deployment"
  value       = <<-EOT
    1. Point DNS: create A record ${var.domain} → ${azurerm_public_ip.app.ip_address}

    2. Add redirect URI to Entra app registration:
       https://${var.domain}/auth/callback

    3. Monitor VM setup (~5-10 min):
       ssh ${data.azurerm_key_vault_secret.admin_username.value}@${azurerm_public_ip.app.ip_address} 'tail -f /var/log/app-setup.log'

    4. Import question data (after setup complete):
       ssh ${data.azurerm_key_vault_secret.admin_username.value}@${azurerm_public_ip.app.ip_address}
       cd /opt/quiz-app && source venv/bin/activate
       for f in data/english/*.json data/french/*.json data/defender_pam/*.json; do
           python utils/import_questions.py "$f"
       done
  EOT
}
