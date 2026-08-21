variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "region" {
  description = "GCP region for the compact placement policy and subnet lookup."
  type        = string
  default     = "asia-northeast3"
}

variable "zone" {
  description = "Single GCP zone for the zonal GKE cluster, its node pools, and the ops VM."
  type        = string
  default     = "asia-northeast3-a"
}

variable "experiment_name" {
  description = "Short experiment family name. N-Cloud on GKE keeps the 'cloud' token; only the CSV label says GKE."
  type        = string
  default     = "cloud"

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]{0,30}[a-z0-9])?$", var.experiment_name))
    error_message = "experiment_name must be lowercase RFC1035-compatible."
  }
}

variable "prefix" {
  description = "Optional name prefix for all experiment resources, including the cluster name. Null uses experiment_name as is."
  type        = string
  default     = null

  validation {
    condition     = var.prefix == null || can(regex("^[a-z]([-a-z0-9]{0,30}[a-z0-9])?$", var.prefix))
    error_message = "prefix must be RFC1035-compatible and short."
  }
}

variable "worker_count" {
  description = "Worker node pool size: 2 for the label-4-node experiment, 6 for the label-8-node one. Raising it and applying on the same state resizes only the worker pool and keeps the existing nodes."
  type        = number
  default     = 2

  validation {
    condition     = var.worker_count >= 2
    error_message = "worker_count must be at least 2 so the first and last worker can run the connectivity test."
  }
}

variable "gke_version" {
  description = "Exact GKE master/node pool creation version: the REGULAR-channel build offered in the zone whose minor.patch matches the kubeadm pin (1.35.6). Node pool auto-upgrade is disabled during experiments; the managed control plane remains subject to GKE upgrade policy."
  type        = string
  default     = "1.35.6-gke.1641000"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+-gke\\.[0-9]+$", var.gke_version))
    error_message = "gke_version must be an exact GKE version such as 1.35.6-gke.1641000."
  }
}

variable "network_name" {
  description = "Existing VPC network name. This module only reads it as a data source."
  type        = string
}

variable "subnetwork_name" {
  description = "Existing subnet name in var.region. This module only reads it as a data source."
  type        = string
}

variable "expected_subnet_cidr" {
  description = "Expected internal IP range of the existing subnet (for example 10.0.0.0/16). null skips the check."
  type        = string
  default     = null
}

variable "pod_cidr" {
  description = "GKE VPC-native cluster secondary range for pods: 10.244.0.0/16, the same as the kubeadm experiments. GKE creates and deletes the subnet secondary range itself."
  type        = string
  default     = "10.244.0.0/16"
}

variable "services_cidr" {
  description = "GKE services secondary range: a /20 from the kubeadm default service CIDR family (10.96.0.0/12)."
  type        = string
  default     = "10.96.0.0/20"
}

variable "machine_type" {
  description = "Node pool machine type for every experiment node."
  type        = string
  default     = "c2-standard-4"
}

variable "min_cpu_platform" {
  description = "Minimum CPU platform requested for deterministic CPU checks."
  type        = string
  default     = "Intel Cascade Lake"
}

variable "disk_size_gb" {
  description = "Balanced persistent disk size in GB per node (25GB, the shared control variable)."
  type        = number
  default     = 25
}

variable "max_pods_per_node" {
  description = "Maximum pods per node. 110 makes GKE assign a /24 Pod CIDR per node, matching the kubeadm experiments."
  type        = number
  default     = 110
}

variable "create_ops_vm" {
  description = "Whether to create the ops VM (cloud-ops-0). Measured T3 convergence and post-measurement T5 run there, so it is part of the measured apply. depends_on makes it created after the GKE nodes fixed their sub-blocks, so it cannot take a placement slot first, and creating a VM (~40s) is short next to cluster creation (~6min), so its effect on T0~T1 is small. Its bootstrap runs asynchronously and overlaps the T3~T4 convergence wait. Pass true on destroy as well, so the instance in the state is definitely removed."
  type        = bool
  default     = true
}

variable "ops_machine_type" {
  description = "ops VM machine type. e2 does not support placement policies, and mixing machine families under COLLOCATED max_distance=1 risks a placement failure, so it uses the same minimum C2 type as the nodes (the CP VM spec)."
  type        = string
  default     = "c2-standard-4"
}

variable "ops_disk_size_gb" {
  description = "ops VM pd-balanced disk size in GB."
  type        = number
  default     = 25
}

variable "source_image_project" {
  description = "GCP public image project for the ops VM."
  type        = string
  default     = "ubuntu-os-cloud"
}

variable "source_image_family" {
  description = "Ubuntu image family for the ops VM."
  type        = string
  default     = "ubuntu-2204-lts"
}

variable "source_image" {
  description = "Exact source image name/self-link for the ops VM. null resolves the newest of the family. (Not applicable to GKE nodes: their image is decided by the GKE version.)"
  type        = string
  default     = null

  validation {
    condition     = var.source_image == null || trimspace(var.source_image) != ""
    error_message = "source_image must be null or a non-empty image name/self-link."
  }
}

variable "ssh_source_ranges" {
  description = "Source CIDRs allowed for SSH (tcp/22) ingress."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ssh_user" {
  description = "Linux user for the ops VM metadata SSH key injection."
  type        = string
}

variable "ssh_public_key_path" {
  description = "Path of the SSH public key injected into the ops VM metadata."
  type        = string
}

variable "ssh_private_key_path" {
  description = "Optional matching OpenSSH private key path. Null derives it by removing a trailing '.pub'."
  type        = string
  default     = null

  validation {
    condition     = var.ssh_private_key_path == null || trimspace(var.ssh_private_key_path) != ""
    error_message = "ssh_private_key_path must be null or a non-empty path."
  }
}

variable "service_account_email" {
  description = "Service account attached to the node pools and the ops VM. Null uses the Compute Engine default. The experiment 3 hybrid measurement uses the default compute SA with the cloud-platform scope, the same as every other method."
  type        = string
  default     = null
}

variable "service_account_scopes" {
  description = "OAuth scopes for the node pool / ops VM service account."
  type        = list(string)
  default     = ["https://www.googleapis.com/auth/cloud-platform"]
}

variable "kubernetes_minor_version" {
  description = "pkgs.k8s.io minor repository for the ops VM kubectl: the same minor as the GKE version (1.35.x)."
  type        = string
  default     = "v1.35"
}

variable "kubernetes_apt_version" {
  description = "Exact apt version of the ops VM kubectl: the same pin as the kubeadm experiments."
  type        = string
  default     = "1.35.6-1.1"
}

variable "cilium_cli_version" {
  description = "Exact Cilium CLI version expected on the ops VM. The T5 preflight compares the installed copy against it."
  type        = string
  default     = "v0.19.5"

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.cilium_cli_version))
    error_message = "cilium_cli_version must be an exact release such as v0.19.5."
  }
}

variable "labels" {
  description = "Additional labels applied to all resources that support labels."
  type        = map(string)
  default     = {}
}
