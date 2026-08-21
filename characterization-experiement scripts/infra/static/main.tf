locals {
  bootstrap_template_path = "${path.module}/templates/bootstrap-node.sh.tftpl"
  # The fingerprint covers the template body and every version value that
  # changes the node bootstrap result. If a value differs between the 4- and
  # 8-node runs the existing marker and the new worker marker disagree, which
  # stops the experiment from continuing on a hidden configuration mismatch.
  bootstrap_revision = sha256(join("|", [
    filesha256(local.bootstrap_template_path),
    var.kubernetes_minor_version,
    var.kubernetes_apt_version,
    var.cilium_cli_version,
    var.cilium_version,
  ]))

  # Compatible with a tfvars that only sets ssh_public_key_path: without an
  # explicit private key path it is derived from the usual '<private>.pub' pair.
  ssh_private_key_path = coalesce(
    var.ssh_private_key_path,
    trimsuffix(var.ssh_public_key_path, ".pub"),
  )

  # An explicit source_image makes every iteration use exactly the same image.
  # null keeps the old behaviour and resolves the latest source_image_family.
  resolved_source_image = var.source_image != null ? var.source_image : data.google_compute_image.ubuntu[0].self_link

  # Single source of truth for the apt package version, so the PowerShell
  # provisioning layer reads the same Kubernetes version as Terraform.
  kubernetes_version = var.kubernetes_apt_version != "" ? split("-", var.kubernetes_apt_version)[0] : trimprefix(var.kubernetes_minor_version, "v")

  # The control plane and benchmark nodes are fixed; workers come from
  # worker_count. Going from 4 nodes (worker_count=2) to 8 (worker_count=6) does
  # not build a new cluster: the same Terraform state is applied again with a
  # higher worker_count. The resource addresses of existing nodes
  # (google_compute_instance.node["worker-0"], ...) do not change, so existing
  # VMs stay and only the new workers are created.
  fixed_nodes = {
    cp-0 = {
      role       = "control-plane"
      role_index = 0
    }
    bench-0 = {
      role       = "benchmark"
      role_index = 0
    }
  }

  worker_nodes = {
    for i in range(var.worker_count) : "worker-${i}" => {
      role       = "worker"
      role_index = i
    }
  }

  nodes      = merge(local.fixed_nodes, local.worker_nodes)
  node_count = length(local.nodes)

  # The node count is deliberately not part of the prefix: a prefix like
  # "vxlan4" would rename every resource during the 8-node expansion and force
  # the existing VMs to be destroyed and recreated. The Host/N-Static/N-Dynamic
  # experiments reuse this module by changing experiment_name only
  # (host-cp-0, static-worker-0, ...).
  resource_prefix = coalesce(var.prefix, var.experiment_name)

  # Target tag of the firewall rules this module creates; every VM gets it.
  node_tag = "${local.resource_prefix}-node"

  # A topology (node count) label is deliberately omitted: during an expansion
  # apply it would make the existing VMs targets of an in-place label update and
  # mix an unrelated change into the "pure worker creation" measurement.
  common_labels = merge(var.labels, {
    experiment = var.experiment_name
    managed-by = "terraform"
  })

  # The internal firewall allows node traffic (the subnet range) and pod traffic
  # (the Pod CIDR). VXLAN encapsulates into the node IP (UDP 8472), so the subnet
  # range alone would do, but with native routing (Host/N-Static/N-Dynamic) the
  # pod IP appears as the source, so allowing the Pod CIDR is mandatory. It is
  # included up front to keep the conditions identical across methods.
  internal_source_ranges = concat(
    [data.google_compute_subnetwork.subnet.ip_cidr_range],
    [var.pod_cidr],
  )
}

data "google_compute_network" "vpc" {
  provider = google-beta
  name     = var.network_name
  project  = var.project_id
}

data "google_compute_subnetwork" "subnet" {
  provider = google-beta
  name     = var.subnetwork_name
  project  = var.project_id
  region   = var.region
}

data "google_compute_image" "ubuntu" {
  provider = google-beta
  count    = var.source_image == null ? 1 : 0
  family   = var.source_image_family
  project  = var.source_image_project
}

resource "google_compute_resource_policy" "compact" {
  provider    = google-beta
  name        = "${local.resource_prefix}-compact"
  project     = var.project_id
  region      = var.region
  description = "Compact placement policy for the ${upper(var.experiment_name)} experiment."

  group_placement_policy {
    # vm_count is deliberately not set: pinning it would force a policy
    # replacement during the 4->8 expansion and break node retention.
    #
    # max_distance = 1 asks for "same sub-block" (same rack) placement, the
    # lowest network latency option offered. Supported on C2, up to 22 VMs (8
    # nodes fit), and it requires host maintenance TERMINATE (satisfied by the
    # instance scheduling block). Whether the nodes really landed on one rack is
    # verified afterwards by check-control-vars.ps1, comparing the first two
    # segments of resourceStatus.physicalHost.
    collocation  = "COLLOCATED"
    max_distance = 1
  }

  lifecycle {
    # The MTU 1500 check is not done here but in the provisioning preflight,
    # with gcloud: the google_compute_network data source of the google-beta
    # provider does not expose the mtu attribute (as of v7.x). The expected
    # value is var.expected_network_mtu.

    # Set expected_subnet_cidr when the subnet IP range has to be validated
    # against the experiment premise (for example /16 or larger). null skips it.
    precondition {
      condition     = var.expected_subnet_cidr == null || data.google_compute_subnetwork.subnet.ip_cidr_range == var.expected_subnet_cidr
      error_message = "Subnet CIDR mismatch: subnet '${var.subnetwork_name}' is ${data.google_compute_subnetwork.subnet.ip_cidr_range}, expected ${coalesce(var.expected_subnet_cidr, "null")}. Fix the subnet or expected_subnet_cidr, or set it to null to skip this check."
    }
  }
}

# -- Firewall -----------------------------------------------------------------
# This module creates the firewall rules the experiment needs, instead of relying
# on existing VPC rules. It still creates no VPC route, Cloud Router, NCC or
# Alias IP.

# Allows SSH (tcp/22) from the local workstation.
resource "google_compute_firewall" "ssh" {
  provider  = google-beta
  name      = "${local.resource_prefix}-allow-ssh"
  project   = var.project_id
  network   = data.google_compute_network.vpc.self_link
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = var.ssh_source_ranges
  target_tags   = [local.node_tag]
}

# Allows all internal node/pod traffic, which covers:
# - tcp/6443       : kubeadm join, Cilium agent -> kube-apiserver
# - tcp/10250      : kubelet API
# - udp/8472       : VXLAN tunnel (Cilium tunnelPort)
# - tcp/4240, icmp : Cilium health check
# - Pod CIDR source: needed by the native routing methods (Host/N-Static/N-Dynamic)
resource "google_compute_firewall" "internal" {
  provider  = google-beta
  name      = "${local.resource_prefix}-allow-internal"
  project   = var.project_id
  network   = data.google_compute_network.vpc.self_link
  direction = "INGRESS"

  allow {
    protocol = "tcp"
  }

  allow {
    protocol = "udp"
  }

  allow {
    protocol = "icmp"
  }

  source_ranges = local.internal_source_ranges
  target_tags   = [local.node_tag]
}

resource "google_compute_instance" "node" {
  provider = google-beta
  for_each = local.nodes

  name             = "${local.resource_prefix}-${each.key}"
  project          = var.project_id
  zone             = var.zone
  machine_type     = var.machine_type
  can_ip_forward   = true
  min_cpu_platform = var.min_cpu_platform

  resource_policies = [
    google_compute_resource_policy.compact.self_link
  ]

  # The module assigns the firewall target tag; use network_tags for extras.
  tags = distinct(concat([local.node_tag], var.network_tags))

  labels = merge(local.common_labels, {
    role       = each.value.role
    role-index = tostring(each.value.role_index)
  })

  boot_disk {
    auto_delete = true

    initialize_params {
      image = local.resolved_source_image
      size  = var.disk_size_gb
      type  = "pd-balanced"

      labels = merge(local.common_labels, {
        role = each.value.role
      })
    }
  }

  network_interface {
    network    = data.google_compute_network.vpc.self_link
    subnetwork = data.google_compute_subnetwork.subnet.self_link

    dynamic "access_config" {
      for_each = var.allow_external_ip ? [1] : []
      content {
        # Shared control variable: even when the project default tier is
        # STANDARD, the external IPv4 of an experiment VM is always Premium.
        network_tier = "PREMIUM"
      }
    }
  }

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "TERMINATE"
    provisioning_model  = "STANDARD"
  }

  metadata = {
    block-project-ssh-keys = var.block_project_ssh_keys ? "TRUE" : "FALSE"
    # This workflow uses the ssh_user and public key from tfvars together with
    # the matching private key. OS Login is disabled in the instance metadata so
    # a project-level OS Login setting cannot change that explicit key path.
    enable-oslogin        = "FALSE"
    ssh-keys              = "${var.ssh_user}:${trimspace(file(var.ssh_public_key_path))}"
    experiment-name       = var.experiment_name
    experiment-role       = each.value.role
    experiment-role-index = tostring(each.value.role_index)
    bootstrap-revision    = local.bootstrap_revision
  }

  # Always injected as LF, so a template file turned CRLF by a Windows checkout
  # cannot fail on Linux with "bad interpreter".
  metadata_startup_script = replace(
    "${templatefile(local.bootstrap_template_path, {
      role                     = each.value.role
      kubernetes_minor_version = var.kubernetes_minor_version
      kubernetes_apt_version   = var.kubernetes_apt_version
      cilium_cli_version       = var.cilium_cli_version
      bootstrap_revision       = local.bootstrap_revision
    })}\n# bootstrap-revision: ${local.bootstrap_revision}\n",
    "\r\n", "\n"
  )

  dynamic "service_account" {
    for_each = var.service_account_email == null ? [] : [var.service_account_email]
    content {
      email  = service_account.value
      scopes = var.service_account_scopes
    }
  }

  lifecycle {
    # Browser SSH from the GCP console injects a temporary key into the
    # instance metadata ssh-keys of a VM with OS Login off (marked google-ssh,
    # with an expireOn). If Terraform tried to revert that to the managed key
    # only, the node would stop being a no-op in the 4->8 expansion plan and the
    # "existing nodes stay no-op" guard in check-terraform-plan.ps1 would block
    # it. Such a key is not a control variable and expires by itself, so only
    # later changes to ssh-keys are ignored. CREATE still applies the rule, so a
    # new worker is created with the managed experiment key (var.ssh_user).
    ignore_changes = [metadata["ssh-keys"]]
  }
}
