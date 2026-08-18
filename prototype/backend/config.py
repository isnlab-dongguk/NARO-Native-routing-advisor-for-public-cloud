from dataclasses import dataclass, field
from typing import Dict, List

# ── Criterion metadata ──────────────────────────────────────────────────────
# c1 throughput (Gbps)  benefit   (measured, iperf3 TCP; latency dropped
#                                  from the measurement set in the GKE round
#                                  — no RTT criterion)
# c2 route convergence time (s) cost (measured join convergence, 4/8-worker
#                                  average; B-VXLAN needs no cloud-side route
#                                  registration and enters as zero)

CRITERIA_NAMES = ["TCP throughput", "Routing convergence time", "Monthly routing cost", "Provisioning time", "Routing scalability"]
CRITERIA_BENEFIT = [True, False, False, False, True]  # True = higher is better

# Decision matrix from experimental results (dataplane v3, GKE round —
# analysis/dataplane_v3_data.csv: iperf3 TCP receiver throughput, single
# client/server pod pair on different workers, 3-run averages; host ceiling
# 9.889 Gbps = VM egress cap; N-Cloud measured on real GKE). The natives
# measure 9.735-9.752 Gbps (spread < 0.2%, below noise), entered as equal.
# Rows: B1, N1, N2, N3  (B2 excluded from recommendations)
# Code-order columns: [tput, convergence, fee(query), provisioning, headroom(query)]
# Provisioning time = mean of the measured initial 4-worker deployment and the
# 4->8 scale-up time (Section 3.3): B1 (207.1+159.1)/2, N1 (643.7+201.4)/2,
# N2 (282.7+239.5)/2, N3 (412.7+253.6)/2.
DECISION_MATRIX: Dict[str, List[float]] = {
    "B1": [8.64, 0.0, 0, 183.10, 0],
    "N1": [9.74, 5.2, 0, 422.55, 0],
    "N2": [9.74, 16.4, 0, 261.10, 0],
    "N3": [9.74, 10.4, 0, 333.15, 0],
}

import math as _math

# Effective route-quota ceilings (single region, default quotas) — §3.4.
EFFECTIVE_QUOTA: Dict[str, int] = {"B1": 5000, "N1": 65000, "N2": 200, "N3": 250}


def cost_of(config_id: str, scale: int) -> float:
    """Query-time monthly configuration-specific fee (USD), paper c5."""
    if config_id == "N1":
        return 73.0  # GKE cluster management fee, 730-h month
    if config_id == "N3":
        return 54.75 * _math.ceil(scale / 8)  # Router Appliance spokes
    return 0.0


def headroom_of(config_id: str, scale: int) -> float:
    """Query-time remaining ceiling share (Q_i - n)/Q_i, paper c3."""
    q = EFFECTIVE_QUOTA[config_id]
    return max(0.0, (q - scale) / q)



# Importance levels 0-3 (low/medium/high; 0 = criterion removed), Table weight-profiles.
# code order [tput, conv, fee, provisioning, headroom] = paper [c1, -, c4, c2, c3].
# Convergence (code index 1) was dropped from the paper's criterion set in the
# 2026-08 revision; its level is fixed at 0 so the pipeline never activates it.
WEIGHT_PRESETS: Dict[str, List[float]] = {
    "cost_first":  [1, 0, 3, 2, 1],
    "balanced":    [2, 0, 2, 2, 1],
    "perf_first":  [3, 0, 1, 1, 1],
}

# Human-readable config descriptions
CONFIG_META: Dict[str, dict] = {
    "B1": {
        "name": "VXLAN Overlay",
        "short": "B1",
        "encapsulation": "VXLAN",
        "route_management": "Automatic (Cilium)",
        "infrastructure": "Self-managed (kubeadm)",
        "description": (
            "Cilium default overlay mode. Encapsulates pod traffic in VXLAN "
            "headers. Works on any cloud without additional VPC configuration. "
            "12.6% throughput reduction vs. the host ceiling due to encapsulation overhead."
        ),
    },
    "N1": {
        "name": "GKE Native (Alias IP)",
        "short": "N1",
        "encapsulation": "None",
        "route_management": "Automatic (GKE)",
        "infrastructure": "GKE",
        "description": (
            "GKE VPC-native networking with Alias IP. Pod CIDRs are registered "
            "as alias IPs on the VM NIC, recognized natively by GCP VPC. "
            "No BGP or manual routes needed. Scales beyond the 200-node "
            "custom route quota. Requires GKE management (incurs GKE fees)."
        ),
    },
    "N2": {
        "name": "Static Native Routing",
        "short": "N2",
        "encapsulation": "None",
        "route_management": "Operator-implemented (cloud API)",
        "infrastructure": "Self-managed (kubeadm)",
        "description": (
            "Self-managed cluster with per-node VPC route entries created "
            "through the cloud API. Simplest and lowest-cost native routing "
            "option; a route automation controller applies route updates on "
            "node events. Limited to ~200 nodes by the GCP custom route quota."
        ),
    },
    "N3": {
        "name": "Dynamic Native Routing (BGP)",
        "short": "N3",
        "encapsulation": "None",
        "route_management": "Automatic (BGP + Cloud Router)",
        "infrastructure": "Self-managed (kubeadm)",
        "description": (
            "Self-managed cluster with Cilium BGP control plane. "
            "Each node peers with GCP Cloud Router and dynamically advertises "
            "its pod CIDR. Routes are registered and withdrawn automatically via BGP; "
            "per-node peer provisioning is operator-implemented. "
            "Costs $54.75 per spoke-month; each NCC spoke serves up to eight nodes. "
            "Limited to ~250 nodes by the Cloud Router learned-prefix quota (single-region scope)."
        ),
    },
}

# Sub-parameter definitions per config
SUBPARAM_DEFS: Dict[str, List[dict]] = {
    "N1": [
        {
            "key": "pod_cidr_size",
            "label": "Pod CIDR block size",
            "options": {"/24": "65-128 pods/node (default 110)", "/25": "33-64 pods/node", "/23": "129-256 pods/node"},
            "default": "/24",
            "criterion": "r_scale",
        },
    ],
    "N2": [
        {
            "key": "pod_cidr_size",
            "label": "Pod CIDR block size",
            "options": {"/24": "110 pods/node", "/25": "46 pods/node", "/26": "14 pods/node"},
            "default": "/24",
            "criterion": "r_scale",
        },
        {
            "key": "quota_headroom",
            "label": "Route quota headroom",
            "options": {"10%": "20 reserved entries", "20%": "40 reserved (recommended)", "30%": "60 reserved (near-limit)"},
            "default": "20%",
            "criterion": "r_scale",
        },
        {
            "key": "automation_controller",
            "label": "Route automation controller",
            "options": {"enabled": "Auto-manages VPC routes on node events", "disabled": "Manual operator intervention"},
            "default": "disabled",
            "criterion": "r_autoscale",
        },
    ],
    "N3": [
        {
            "key": "bgp_keepalive",
            "label": "BGP keepalive timer (hold = 3x)",
            "options": {"20s": "Shortest prototype option; tightest failure-detection bound (60 s hold)", "40s": "Balanced (120 s hold)", "60s": "Fewest control-plane messages (180 s hold)"},
            "default": "20s",
            "criterion": "convergence_preference",
        },
        {
            "key": "cloud_router_redundancy",
            "label": "BGP peer redundancy",
            "options": {"single": "Single peer; lower cost", "HA": "Redundant peer pair (policy: enabled above 100 nodes)"},
            "default": "single",
            "criterion": "availability_requirement",
        },
        {
            "key": "asn",
            "label": "BGP ASN assignment",
            "options": {"auto": "Auto-assign from private range (64512–65534)"},
            "default": "auto",
            "criterion": "peering_policy",
        },
        {
            "key": "prefix_filter",
            "label": "Max advertised prefix length",
            "options": {"/24": "Recommended — prevents route leaks", "/22": "Allows larger blocks", "/16": "Permissive (not recommended)"},
            "default": "/24",
            "criterion": "security",
        },
    ],
    "B1": [
        {
            "key": "pod_mtu",
            "label": "Pod MTU",
            "options": {"1410": "GCP-optimized (GCP VPC MTU 1460 − 50B overhead)", "1450": "Generic default"},
            "default": "1410",
            "criterion": "vpc_mtu",
        },
        {
            "key": "encryption",
            "label": "In-transit encryption",
            "options": {"none": "No encryption (default)", "wireguard": "WireGuard — ~5% throughput overhead"},
            "default": "none",
            "criterion": "security_requirement",
        },
    ],
}
