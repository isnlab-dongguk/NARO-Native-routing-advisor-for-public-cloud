output "experiment_name" {
  value = var.experiment_name
}

# Values the experiment 3 GKE context reads while building itself.
output "project_id" {
  value = var.project_id
}

output "region" {
  value = var.region
}

output "zone" {
  value = var.zone
}

output "network_name" {
  value = var.network_name
}

output "subnetwork_name" {
  value = var.subnetwork_name
}

output "resource_prefix" {
  value = local.resource_prefix
}

output "cluster_name" {
  value = google_container_cluster.cluster.name
}

output "cluster_location" {
  value = google_container_cluster.cluster.location
}

output "cluster_master_version" {
  value = google_container_cluster.cluster.master_version
}

output "gke_version" {
  value = var.gke_version
}

output "kubernetes_version" {
  # Script compatibility: GKE records its exact version instead of the kubeadm apt version.
  value = var.gke_version
}

output "cilium_cli_version" {
  value = var.cilium_cli_version
}

output "worker_node_count" {
  value = google_container_node_pool.worker.node_count
}

output "bench_node_count" {
  value = google_container_node_pool.bench.node_count
}

output "node_tag" {
  value = local.node_tag
}

output "pod_cidr" {
  value = var.pod_cidr
}

output "services_cidr" {
  value = var.services_cidr
}

output "compact_policy_self_link" {
  value = google_compute_resource_policy.compact.self_link
}

output "ssh_user" {
  value = var.ssh_user
}

output "ssh_private_key_path" {
  value = local.ssh_private_key_path
}

output "ops_bootstrap_revision" {
  value = local.ops_bootstrap_revision
}

output "ops_vm_name" {
  value = var.create_ops_vm ? google_compute_instance.ops[0].name : null
}

output "ops_vm_external_ip" {
  value = var.create_ops_vm ? google_compute_instance.ops[0].network_interface[0].access_config[0].nat_ip : null
}

output "ops_vm_internal_ip" {
  value = var.create_ops_vm ? google_compute_instance.ops[0].network_interface[0].network_ip : null
}
