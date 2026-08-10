# Explanation faithfulness audit, v2 pipeline (E5)

Input: `results_v2/explanations.json` (generated 2026-08-06 by `gen_explanations_v2.py`,
engine pipeline — constraints + TOPSIS with the revised presets — with `claude-opus-5`
via gateway). Grounding context per the revised Section 4.6 contract: elimination
reasons, instantiated criterion values, weights after zero-variance removal, phi
scores, unresolved assumptions, and the operator's expertise level. No deployment
parameters are supplied (stage removed from the framework).

Method: every independently checkable factual statement in each explanation was
compared against (a) the grounding context and (b) the measurements and rules of the
paper (Section 3, Section 4). **OK** = supported by context or consistent domain
knowledge not contradicting the paper; **FLAW** = contradicts the paper or attributes
an outcome to a rationale that is not the actual rule. All scale-dependent numbers
were re-derived independently (fees 54.75*ceil(n/8), headroom 1-n/Q).

## Tally

| Case | Statements | OK | Flawed |
|------|-----------|----|--------|
| CS1 | 12 | 12 | 0 |
| CS2 | 11 | 11 | 0 |
| CS3 | 8  | 8  | 0 |
| CS4 | 11 | 11 | 0 |
| CS5 | 12 | 12 | 0 |
| **Total** | **54** | **54** | **0** |

No explanation misstates a score, rank, elimination reason, criterion value, weight,
or fee. No statement attributes the outcome to a rationale that the decision record
does not support. The two flaw classes of the previous audit are structurally
addressed: parameter-rationale misattribution can no longer occur (parameters left
the pipeline), and criterion-rationale misattribution did not recur because the
instantiated matrix and weights are now part of the grounding context.

## Statement lists

### CS1 (12 OK)
1. Recommended B-VXLAN, phi 0.981 rank 1 — matches record.
2. N-Cloud removed at filtering: provider-managed vs self-managed requirement — matches rule.
3. cost_first puts heaviest weight 0.30 on monthly fee — matches weights.
4. Fees 0 (B-VXLAN) = 0 (N-Static) vs 219 USD/mo (N-Dynamic at 30 nodes) — 54.75*ceil(30/8)=219. OK.
5. Best on the two next-heaviest criteria: convergence 0.0 vs 16.4/10.4 s; both at weight 0.20 — OK.
6. Effort 2 = lowest of feasible set (2/3/4) — OK.
7. Suits beginner: needs no BGP peering or Cloud Router — consistent with S3.2.
8. Overlay handles pod reachability itself — consistent with S2/S3.
9. Delegated preference: fit 3 = highest of feasible set (3/2/1) — OK.
10. Trade-off: throughput 8.64 vs 9.74 Gbps, weight only 0.10 — OK.
11. Headroom 0.994 highest (vs 0.85/0.88) — OK.
12. No unresolved assumptions — matches record.

### CS2 (11 OK)
1. B-VXLAN removed: transparency vs VXLAN encapsulation — matches rule.
2. N-Cloud removed: provider-managed vs self-managed requirement — matches rule.
3. Throughput tie 9.74 and neutral fit tie dropped as zero-variance — matches engine behavior.
4. Active criteria convergence/fee/effort/headroom, cost share 0.375 — matches renormalized weights.
5. Fee 0 vs 1040.25 USD/mo — 54.75*ceil(150/8)=1040.25. OK.
6. Effort 3 vs 4 — OK.
7. N-Dynamic better convergence 10.4 vs 16.4 s and headroom 0.4 vs 0.25 — OK.
8. phi 0.813 / 0.187, ranks — matches record.
9. Practice: per-node route entries vs Cloud Router + per-node BGP peering — consistent with S3.
10. Intermediate fit: avoids BGP sessions, requires route upkeep on node events; slower activation per c4 — consistent with S3.6.
11. Headroom gap is the criterion to revisit under growth — grounded in c3 values; no unresolved assumptions — matches record.

### CS3 (8 OK)
1. Decision settled by filtering alone; no weighing — matches singleton path.
2. B-VXLAN removed: transparency — matches rule.
3. N-Static/N-Dynamic removed on scale: 400 > ~200-route and ~250-prefix quotas — matches rule and S3.4.
4. Self-managed not required, so no ground to retain the self-managed natives — consistent.
5. Effort 1 (lowest) and delegated fit 4 (highest) — consistent with S3.2/S3.6.
6. 9.74 Gbps, 5.2 s convergence, headroom 0.994, 73 USD/mo — all match (1-400/65000=0.9938).
7. Practice: provider-managed integration; no Cloud Router, BGP peerings, or custom routes — consistent.
8. Good match for beginner background — consistent contextualization.

### CS4 (11 OK)
1. B-VXLAN removed: transparency vs encapsulation — matches rule.
2. Throughput tie 9.74 dropped as zero-variance — matches.
3. Fit carries double weight 0.333 under perf_first + delegated — matches weights.
4. Fit 4 vs 2 vs 1 — OK.
5. Headroom 0.998 vs 0.4 vs 0.52 — 1-120/65000=0.9982. OK.
6. Convergence 5.2 vs 16.4 vs 10.4 s — OK.
7. Effort 1 lowest — OK.
8. Fee 73 between 0 and 821.25 — 54.75*ceil(120/8)=821.25; only losing criterion vs N-Static. OK.
9. phi 0.955 / 0.476 / 0.148 — matches record.
10. Practice: provider route tables vs Cloud Router + per-node BGP; modest surface for intermediate team — consistent.
11. Self-managed not required; no unresolved assumptions — matches record.

### CS5 (12 OK)
1. Rank 1, phi 0.523 vs 0.476 — matches record.
2. B-VXLAN removed: transparency — matches rule.
3. N-Cloud removed: provider-managed vs self-managed requirement — matches rule.
4. Throughput tie dropped by zero-variance — matches.
5. Fit double weight 0.333 under perf_first, reflecting direct preference — matches weights.
6. Fit 4 vs 3 — OK (direct ordering).
7. Headroom 0.2 vs 0.0; N-Static none at 200 nodes — OK.
8. Convergence 10.4 vs 16.4 s — OK.
9. Loses effort 4 vs 3 and cost 1368.75 vs 0 USD/mo — 54.75*ceil(200/8)=1368.75. OK.
10. Losing criteria at 0.167 each, outweighed by double-weighted fit + convergence + headroom — consistent with weights and outcome.
11. Practice: Cloud Router + per-node BGP peering is the source of the effort score and the fee — consistent with S3.2/S3.7.
12. Expert background absorbs the trade; no unresolved assumptions — consistent; matches record.

## Notes (not counted as flaws)

- CS3 "there is no reason to work around those limits" — editorial framing, not a factual claim.
- CS1 "on top of whatever the cloud network already provides" — vague but not contradicting.
- Single audit run per case (temperature-default generation); the paper reports this
  as a statement-level audit of one generated explanation per case, as before.
