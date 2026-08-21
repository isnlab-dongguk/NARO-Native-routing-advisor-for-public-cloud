output "project_id" {
  value = var.project_id
}

output "region" {
  value = var.region
}

output "zone" {
  value = var.zone
}

output "ssh_user" {
  value = var.ssh_user
}

output "ssh_private_key_path" {
  value = local.ssh_private_key_path
}

output "kubernetes_version" {
  value = local.kubernetes_version
}

output "cilium_version" {
  value = var.cilium_version
}

output "resolved_source_image" {
  value = local.resolved_source_image
}

output "bootstrap_revision" {
  value = local.bootstrap_revision
}

output "experiment_name" {
  value = var.experiment_name
}

output "node_count" {
  value = local.node_count
}

output "worker_count" {
  value = var.worker_count
}

output "resource_prefix" {
  value = local.resource_prefix
}

output "node_tag" {
  value = local.node_tag
}

output "pod_cidr" {
  value = var.pod_cidr
}

output "compact_policy_self_link" {
  value = google_compute_resource_policy.compact.self_link
}

output "control_plane_private_ip" {
  value = google_compute_instance.node["cp-0"].network_interface[0].network_ip
}

output "inventory" {
  value = {
    for key, vm in google_compute_instance.node : key => {
      name              = vm.name
      role              = local.nodes[key].role
      role_index        = local.nodes[key].role_index
      project_id        = var.project_id
      zone              = vm.zone
      machine_type      = vm.machine_type
      private_ip        = vm.network_interface[0].network_ip
      external_ip       = try(vm.network_interface[0].access_config[0].nat_ip, null)
      network_tier      = try(vm.network_interface[0].access_config[0].network_tier, null)
      can_ip_forward    = vm.can_ip_forward
      tags              = vm.tags
      resource_policies = vm.resource_policies
    }
  }
}
