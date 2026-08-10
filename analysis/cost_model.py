#!/usr/bin/env python3
"""C2: List-price cost model for mechanism-specific managed-service costs.

Produces figure/cost_crossover.pdf — monthly managed-service cost vs cluster
size for the three native routing mechanisms — and prints the crossover point.

Scope: mechanism-SPECIFIC costs only. Shared components (VM compute, disks,
inter-zone/region traffic) are identical across configurations and omitted.
Control-plane BGP traffic is negligible (per GCP pricing docs); pod data-plane
traffic does not traverse the NCC hub once routes are installed, so ADN
data-processing fees do not apply to steady-state pod traffic.

List prices (accessed 2026-07-04):
  - GKE cluster management fee: $0.10 per cluster-hour
      https://cloud.google.com/kubernetes-engine/pricing
      (free tier: $74.40/mo credit covers ONE zonal/Autopilot cluster;
       the model uses list price, free tier noted in the paper caption)
  - NCC router-appliance spoke: $0.075 per spoke-hour
      https://cloud.google.com/network-connectivity/pricing
      (Cloud Router itself is free; BGP between Cloud Router and VM instances
       requires router-appliance spokes via Network Connectivity Center)
  - N-Static / B-VXLAN: no managed-service fee (static routes and alias IPs
      are free; only non-cost constraints apply)
"""

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

# ── List prices ──────────────────────────────────────────────────────────────
GKE_MGMT_PER_HR = 0.10       # $/cluster-hour
NCC_SPOKE_PER_HR = 0.075     # $/spoke-hour
HOURS_PER_MONTH = 730

# Router-appliance instances per spoke: NCC always groups up to 8 router
# appliances into one spoke (coauthor-verified against billing reports).
K_NODES_PER_SPOKE = 8

GKE_MONTHLY = GKE_MGMT_PER_HR * HOURS_PER_MONTH            # $73.00 /mo
SPOKE_MONTHLY = NCC_SPOKE_PER_HR * HOURS_PER_MONTH         # $54.75 /mo per spoke

STATIC_CEILING = 200  # verified static-route ceiling (coauthor-confirmed)

# ── Model ────────────────────────────────────────────────────────────────────
n = np.arange(1, 201)
cost_ncloud = np.full_like(n, GKE_MONTHLY, dtype=float)
cost_ndynamic = np.ceil(n / K_NODES_PER_SPOKE) * SPOKE_MONTHLY

# crossover: first n where ceil(n/8)*54.75 exceeds the GKE fee -> n = 9
crossover = int(np.argmax(cost_ndynamic > GKE_MONTHLY)) + 1
print(f"GKE fixed fee            : ${GKE_MONTHLY:.2f}/month")
print(f"NCC spoke fee            : ${SPOKE_MONTHLY:.2f}/month per spoke (K={K_NODES_PER_SPOKE})")
print(f"Crossover (N-Dyn > N-Cld): N-Cloud cheaper from n = {crossover} nodes")
print(f"N-Dynamic managed cost at the static ceiling (n=200): ${cost_ndynamic[199]:,.2f}/month")

# ── Figure ───────────────────────────────────────────────────────────────────
# Style matched to fig:provisioning: Arial (Liberation Sans fallback), plain
# frame, no minor ticks, separate legend (no inline labels).
plt.rcParams.update({
    "font.size": 7,
    "font.family": "sans-serif",
    "font.sans-serif": ["Arial", "Liberation Sans", "DejaVu Sans"],
    "mathtext.fontset": "dejavusans",
})
fig, ax = plt.subplots(figsize=(3.3, 2.1))
ax.axhline(1, color="#920923", lw=1.6, label="N-Static (no managed cost)")
ax.step(n, cost_ndynamic, where="post", color="#000080", lw=1.6, label="N-Dynamic")
ax.axhline(GKE_MONTHLY, color="#FFA500", lw=1.6, label="N-Cloud")
ax.set_yscale("log")
ax.set_xlim(0, 200); ax.set_ylim(0.8, 4000)
ax.set_xticks([0, 50, 100, 150, 200])
ax.set_yticks([1, 10, 100, 1000])
ax.set_yticklabels(["1", "10", "$10^2$", "$10^3$"])
ax.minorticks_off()
ax.set_xlabel("Cluster size (nodes)", fontsize=7)
ax.set_ylabel("Managed cost (USD/month)", fontsize=7)
ax.tick_params(labelsize=6.5)
ax.legend(loc="upper left", fontsize=6.5, frameon=False, handlelength=1.6)
ax.grid(True, which="major", axis="y", alpha=0.25, lw=0.4)
ax.set_axisbelow(True)
fig.tight_layout(pad=0.3)
fig.savefig("../figure/cost_crossover.pdf")
print("wrote ../figure/cost_crossover.pdf")
