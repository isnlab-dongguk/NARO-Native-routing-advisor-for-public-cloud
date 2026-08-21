terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 6.0.0, < 8.0.0"
    }
  }
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}
