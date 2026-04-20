variable "api_allowed_cidrs" {
  description = "CIDRs allowed to reach the EKS public API endpoint (owner's home IP)"
  type        = list(string)
  default     = ["71.11.152.159/32"]
}
