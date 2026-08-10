"""Direct-decision comparison for paper Case 5 (cost-first).

Asks the configured LLM to choose a configuration directly from the operator
request (no NARO pipeline), 10 repetitions each without and with the measured
values of the decision matrix. Requires prototype/.env (LLM_BASE_URL,
GATEWAY_API_KEY, LLM_MODEL); the published results were produced with
LLM_MODEL=gpt-5.6-luna.
"""
import json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "prototype", "backend"))
env_path = os.path.join(ROOT, "prototype", ".env")
if os.path.exists(env_path):
    for line in open(env_path):
        if "=" in line and not line.strip().startswith("#"):
            k, v = line.strip().split("=", 1); os.environ.setdefault(k, v)
import llm

OUTFILE = 'results_cost_first.json'

REQUEST = 'We run batch analytics on preemptible Spot VMs, 200 nodes at peak, on a self-managed kubeadm cluster in Google Cloud. Encapsulation is prohibited because our on-premises systems must reach pod IPs directly over BGP. Our network team operates BGP daily and insists on owning the routing control plane end to end. Cost matters more than performance for this workload; we want to minimize monthly spend.'

CHOICES = ("B-VXLAN (Cilium VXLAN overlay), N-Static (static VPC routes via cloud API), "
"N-Dynamic (per-node BGP peering with Cloud Router), N-Cloud (GKE with alias-IP native routing)")

FACTS = """Measured facts for this Google Cloud setup (at 200 worker nodes):
- TCP throughput (Gbps): B-VXLAN 8.64; N-Static / N-Dynamic / N-Cloud 9.74 each
- Operational effort (1=lowest..4=highest): N-Cloud 1, B-VXLAN 2, N-Static 3, N-Dynamic 4
- Route quotas: N-Static 200 static routes (full at 200 nodes), N-Dynamic 250 learned prefixes
- Route convergence after node addition (s): N-Cloud 5.2, N-Dynamic 10.4, N-Static 16.4, B-VXLAN no cloud-side step
- Monthly routing fee: B-VXLAN $0, N-Static $0, N-Cloud $73, N-Dynamic $1368.75
- On ungraceful node loss, BGP withdraws routes automatically; static routes go stale until cleaned up"""


def ask(with_facts, i):
    user = 'Operator request:\n"' + REQUEST + '"\n\n'
    if with_facts:
        user += FACTS + "\n\n"
    user += ("Choose exactly ONE pod-networking configuration for this deployment among: "
             + CHOICES + '. Reply with strict JSON only: '
             '{"choice": "<name>", "rationale": "<2-3 sentences>"}')
    client = llm._get_client()
    r = client.chat.completions.create(model=llm._MODEL,
        messages=[{"role": "user", "content": user}])
    txt = r.choices[0].message.content
    m = re.search(r"\{.*\}", txt, re.S)
    try:
        d = json.loads(m.group(0))
    except Exception:
        d = {"choice": "PARSE_ERROR", "rationale": txt[:300]}
    d["cond"] = "with_facts" if with_facts else "no_facts"
    d["run"] = i
    return d


if __name__ == "__main__":
    out = []
    for cond in (False, True):
        for i in range(10):
            d = ask(cond, i)
            out.append(d)
            print(d["cond"], i, "->", d["choice"], flush=True)
    json.dump(out, open(os.path.join(HERE, OUTFILE), "w"), indent=1)
