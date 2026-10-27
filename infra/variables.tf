variable "region" {
  description = "AWS region in which all resources will be created."
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster."
  type        = string
  default     = "eks-lab"
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster. Defaults to the latest Auto Mode-supported version at authoring time."
  type        = string
  default     = "1.36"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of availability zones to use. Must be empty (auto-selected via data source) or exactly two."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.availability_zones) == 0 || length(var.availability_zones) == 2
    error_message = "availability_zones must be an empty list (to trigger data source fallback) or contain exactly 2 zones."
  }
}

variable "api_allowed_cidrs" {
  description = "CIDR ranges permitted to reach the EKS API server endpoint. Must not contain 0.0.0.0/0."
  type        = list(string)

  validation {
    condition     = !contains(var.api_allowed_cidrs, "0.0.0.0/0")
    error_message = "api_allowed_cidrs must not contain 0.0.0.0/0; supply one or more specific CIDR ranges instead."
  }
}

variable "budget_limit_amount" {
  description = "Monthly budget limit amount (as a string) in the currency specified by budget_currency."
  type        = string
  default     = "30"
}

variable "budget_currency" {
  description = "ISO 4217 currency code for the monthly budget (e.g. USD)."
  type        = string
  default     = "USD"
}

variable "budget_notification_emails" {
  description = "Email addresses that receive budget alert notifications. Must contain between 1 and 10 addresses."
  type        = list(string)

  validation {
    condition     = length(var.budget_notification_emails) >= 1 && length(var.budget_notification_emails) <= 10
    error_message = "budget_notification_emails must contain between 1 and 10 email addresses."
  }
}
