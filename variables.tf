variable "location" {
  description = "Azure region"
  type        = string
  default     = "UK South"
}

variable "vm_size" {
  description = "Azure VM size"
  type        = string
  default     = "Standard_B2s"
}

variable "github_repo" {
  description = "GitHub repo URL to clone the app from"
  type        = string
  default     = "https://github.com/my-claude-code/a11-Quiz-App-PostgreSQL.git"
}

variable "domain" {
  description = "Domain name for the app"
  type        = string
  default     = "aztest.dnsabr.com"
}
