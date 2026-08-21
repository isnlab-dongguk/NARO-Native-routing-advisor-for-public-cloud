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
  description = "Single GCP zone for all experiment VMs."
  type        = string
  default     = "asia-northeast3-a"
}

variable "experiment_name" {
  description = "Short experiment family name used for labels, resource prefix and firewall names. The same module is reused per method by changing this value (vxlan/host/static/dynamic)."
  type        = string
  default     = "dynamic"

  validation {
    condition     = can(regex("^[a-z]([-a-z0-9]{0,30}[a-z0-9])?$", var.experiment_name))
    error_message = "experiment_name must be lowercase RFC1035-compatible, for example vxlan, host, nstatic, ndynamic, or ncloud."
  }
}

variable "prefix" {
  description = "Optional name prefix for all experiment resources. Null uses experiment_name as is. Never put the node count in the prefix: renaming resources during the 4->8 expansion would destroy and recreate the existing VMs."
  type        = string
  default     = null

  validation {
    condition     = var.prefix == null || can(regex("^[a-z]([-a-z0-9]{0,51}[a-z0-9])?$", var.prefix))
    error_message = "prefix must be RFC1035-compatible and short enough to leave room for node suffixes."
  }
}

variable "worker_count" {
  description = "Number of worker VMs. 2 for the 4-node experiment, 6 for the 8-node one. Raising it and applying again on the same state keeps the existing nodes (control plane, benchmark, existing workers) and only creates the new workers."
  type        = number
  default     = 2

  validation {
    condition     = var.worker_count >= 2
    error_message = "worker_count must be at least 2 so worker-0 and the last worker can run the Cilium connectivity test."
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

variable "expected_network_mtu" {
  description = "Expected MTU of the existing VPC; the experiment plan requires 1500. GCP supports 1300~8896 so 1500 is fine, but the default is 1460, so set it beforehand with 'gcloud compute networks update <vpc> --mtu 1500'. This is verified by the provisioning preflight with gcloud, not by Terraform, because the provider data source does not expose mtu. null in tfvars skips the check."
  type        = number
  default     = 1500
}

variable "expected_subnet_cidr" {
  description = "Expected internal IP range of the existing subnet (for example 10.0.0.0/16). Set it when the range has to be validated against the VM/pod count before any VM is created. null skips the check."
  type        = string
  default     = null
}

variable "pod_cidr" {
  description = "Cluster Pod CIDR. It is both the kubeadm --pod-network-cidr value and the pod traffic source range of the internal firewall, allowed up front because the native routing methods (Host/N-Static/N-Dynamic) expose the pod IP as the source."
  type        = string
  default     = "10.244.0.0/16"
}

variable "ssh_source_ranges" {
  description = "Source CIDRs allowed for SSH (tcp/22) ingress. The default allows everything, so narrowing it to the public IP/32 of your workstation is recommended."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ssh_user" {
  description = "Linux user for gcloud compute ssh and metadata SSH key injection."
  type        = string
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key to inject into all VM metadata."
  type        = string
}

variable "ssh_private_key_path" {
  description = "Optional path to the matching OpenSSH private key for native ssh/scp. Null derives it by removing a trailing '.pub' from ssh_public_key_path."
  type        = string
  default     = null

  validation {
    condition     = var.ssh_private_key_path == null || trimspace(var.ssh_private_key_path) != ""
    error_message = "ssh_private_key_path must be null or a non-empty path."
  }
}

variable "machine_type" {
  description = "VM machine type for every experiment node."
  type        = string
  default     = "c2-standard-4"
}

variable "min_cpu_platform" {
  description = "Minimum CPU platform requested for deterministic CPU checks."
  type        = string
  default     = "Intel Cascade Lake"
}

variable "disk_size_gb" {
  description = "Balanced persistent disk size in GB. pd-balanced consumes the SSD_TOTAL_GB quota. 25GB is the shared control variable across every method (8 nodes x 25GB = 200GB, inside the default 250GB SSD quota)."
  type        = number
  default     = 25
}

variable "source_image_project" {
  description = "GCP public image project for Ubuntu."
  type        = string
  default     = "ubuntu-os-cloud"
}

variable "source_image_family" {
  description = "Ubuntu image family."
  type        = string
  default     = "ubuntu-2204-lts"
}

variable "source_image" {
  description = "Optional exact source image name or self-link. Set this to pin every experiment node to one immutable image; null resolves the latest source_image_family image."
  type        = string
  default     = null

  validation {
    condition     = var.source_image == null || trimspace(var.source_image) != ""
    error_message = "source_image must be null or a non-empty image name/self-link."
  }
}

variable "allow_external_ip" {
  description = "Attach ephemeral external IPs so gcloud compute ssh works without a bastion."
  type        = bool
  default     = true
}

variable "network_tags" {
  description = "Extra network tags. The '<prefix>-node' tag used by the experiment firewall is applied by the module itself, so this is normally left empty."
  type        = list(string)
  default     = []
}

variable "service_account_email" {
  description = "Optional service account email for the VMs. Null uses the Compute Engine default."
  type        = string
  default     = null
}

variable "service_account_scopes" {
  description = "OAuth scopes for the optional VM service account."
  type        = list(string)
  default     = ["cloud-platform"]
}

variable "block_project_ssh_keys" {
  description = "Whether VM metadata should block project-level SSH keys."
  type        = bool
  default     = false
}

variable "kubernetes_minor_version" {
  description = "Kubernetes apt repository minor version. The default v1.35 is the newest version inside the 1.32~1.35 range the Cilium 1.19 documentation guarantees e2e compatibility for."
  type        = string
  default     = "v1.35"
}

variable "kubernetes_apt_version" {
  description = "Exact kubelet/kubeadm/kubectl apt package version. Empty string installs latest from kubernetes_minor_version repo."
  type        = string
  default     = "1.35.6-1.1"
}

variable "cilium_cli_version" {
  description = "Exact Cilium CLI release installed on the control-plane. Pinned so repeated runs use the same connectivity-test implementation."
  type        = string
  default     = "v0.19.5"

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.cilium_cli_version))
    error_message = "cilium_cli_version must be an exact release such as v0.19.5; auto is intentionally not allowed for experiment reproducibility."
  }
}

variable "cilium_version" {
  description = "Exact Cilium Helm chart/dataplane version used by the provisioning workflow. The default 1.19.5 is the newest stable patch, and Cilium 1.19 guarantees e2e compatibility with Kubernetes 1.32~1.35 (it pairs with the default kubernetes_apt_version 1.35.x)."
  type        = string
  default     = "1.19.5"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z.-]+)?$", var.cilium_version))
    error_message = "cilium_version must be an exact semantic version, for example 1.19.5."
  }
}

variable "labels" {
  description = "Additional labels applied to all resources that support labels."
  type        = map(string)
  default     = {}
}
