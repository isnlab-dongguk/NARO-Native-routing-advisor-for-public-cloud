# Explanation-faithfulness verification (v4, 2026-08-11; Cases 3 and 5 updated same day)

2026-08-18 (re-audit after the provisioning-criterion change and the new explanation prompt):
c2 was redefined to exclude the readiness-check phase (B-VXLAN 156.55 s, N-Static 234.19 s,
N-Dynamic 304.46 s, N-Cloud 394.54 s), which changed the scores of Cases 1, 3, and 4, and the
explanation prompt was replaced with the grounding/readability/expertise-profile version. All five
explanations were regenerated with gpt-5.6-luna and re-checked against the decision record. Counted
with the same rubric as below (one item per verifiable claim: elimination reason, criterion value or
comparison, weight statement, score or rank), the cases now contribute 7, 7, 9, 7, and 8 checkable
statements. Totals: 38 statements, 38 supported, 0 flawed. Every numeric claim was re-derived
independently from the decision matrix (fees 54.75*ceil(n/8), remaining ceiling share 1-n/Q).


2026-08-13 (Case 1 explanation regenerated): the published Case 1 sample listed
lower TCP throughput among the factors "supporting" B-VXLAN's first-place rank.
The values were correct, but the framing attributed the rank partly to a
disadvantage. Case 1 was regenerated with gpt-5.6-luna (three samples drawn,
sample 3 published; samples kept in the run log). The new text states the
throughput comparison in N-Static's favour and drops phi(N-Static)=0.144 and the
weight vector, so Case 1 now contributes 8 checkable statements instead of 9:
(1) N-Dynamic excluded, BGP expertise vs beginner rule; (2) N-Cloud excluded,
provider-managed vs self-managed rule; (3) both fees $0, cost removed as
zero-variance; (4) cost_first preset; (5) phi(B-VXLAN)=0.856 rank 1;
(6) provisioning 183.1 s; (7) scalability share 0.994; (8) throughput 9.74 vs
8.64 Gbps favouring N-Static. Totals: 44 statements, 44 supported, 0 flawed.

2026-08-12: extraction benchmark re-run end-to-end with gpt-5.6-luna (reasoning_effort="none" is required for the gateway to accept function tools), unifying both LLM stages on one model: 93.3% (126/135) over seven fields, all nine errors in stated_priority (S02, S08, S09), repeat-consistent on all 50 scenarios, 15/15 clarifications. Prior claude-opus-5 runs kept in results_v2/raw_runs_claude.jsonl.

2026-08-11 (preset update): Cases 3 and 5 switched from perf_first to
balanced (user request; balanced preset now exercised). Case 3 rescored:
N-Cloud 0.864 vs N-Dynamic 0.136 (weights 0.4 cost / 0.4 prov / 0.2 scal
after tput zero-variance). Case 5 unchanged (filter-decided). Both
explanations regenerated and re-audited: Case 3 = 9/9 (eliminations x2,
equal tput, balanced weights, two phis, cost, scal, prov values); Case 5 =
9/9 (sole survivor, eliminations x3, four criterion values, singleton
no-scores statement). Totals remain 45/45.

2026-08-11 (Case 3 update): Case 3 rescaled from 400 to 230 nodes so the
scale rule removes only N-Static (quota-ladder asymmetry) and the case is
TOPSIS-scored: N-Cloud 0.888 vs N-Dynamic 0.112. Explanation regenerated;
9 checkable statements, all supported: (1) N-Static eliminated 230>200-route
quota; (2) B-VXLAN eliminated by transparency; (3) equal tput 9.74;
(4) scalability 0.996 vs 0.08; (5) cost $73.00 vs $1,587.75; (6) N-Dynamic
provisions faster 333.15 vs 422.55 s; (7) equal one-third weights over
cost/prov/scal; (8) phi(N-Cloud)=0.888; (9) phi(N-Dynamic)=0.112.
Case 3 count unchanged (9), totals remain 45/45.

2026-08-11 (final): Case 5 became the multi-VPC scenario with an AUTOMATED
routing-adaptability requirement (self-managed dropped) — filter-decided:
B-VXLAN (transparency), N-Cloud (in-place change impossible), N-Static
(manual-only adaptation) eliminated; N-Dynamic sole candidate, no scores.
Case 5 explanation regenerated for the singleton record: 9 checkable
statements, all supported: (1) N-Dynamic sole survivor; (2) N-Cloud
elimination reason; (3) N-Static elimination reason; (4) B-VXLAN elimination
reason; (5) tput 9.74; (6) provisioning 333.15 s; (7) ceiling share 0.2;
(8) fee $1,368.75; (9) singleton set, no scores/weights, feasibility-decided.
Totals below updated: Case 5 = 9, total = 45/45. Case 4's JSON entry was
restored from the published App C text after an accidental overwrite (decision
record identical).

Explanations regenerated after the convergence criterion was removed from the
paper's criterion set (four criteria: c1 throughput, c2 provisioning time,
c3 routing scalability, c4 monthly cost) and Case 1 gained the beginner
routing-expertise statement (expertise feasibility rule).
Generator: regen_explanations_v4.py; decision records from pipeline_v2
(WEIGHT_PRESETS with convergence level 0). Model: gpt-5.6-luna via the
OpenAI-compatible gateway. One generation per case as published (Case 1 and
Case 4 were regenerated once after their first samples contained a factual
error / a broken sentence; the published generations are the ones audited
below). Every checkable statement was compared against the decision record
(eliminations, instantiated criterion values, weights, scores).

Recommendation change vs. v3: Case 5 now selects N-Static (0.504 vs 0.496);
Case 1 phi = 0.856/0.144, Case 2 = 0.905/0.095, Case 4 = 0.785/0.673/0.143.

| Case | Checkable statements | Supported | Flawed |
|---|---|---|---|
| Case 1 | 7  | 7  | 0 |
| Case 2 | 7  | 7  | 0 |
| Case 3 | 9  | 9  | 0 |
| Case 4 | 7  | 7  | 0 |
| Case 5 | 8  | 8  | 0 |
| Total  | 38 | 38 | 0 |

Checked statements per case (all supported):

Case 1: (1) N-Dynamic eliminated by beginner-expertise rule; (2) N-Cloud
eliminated by self-managed rule; (3) both fees $0, cost removed as
zero-variance; (4) active criteria tput/prov/scal with weights 0.25/0.5/0.25;
(5) phi(B-VXLAN)=0.856 rank 1; (6) phi(N-Static)=0.144; (7) provisioning
183.1 vs 261.1 s; (8) scalability share 0.994 vs 0.85; (9) throughput 8.64 vs
9.74 Gbps.

Case 2: (1) transparency eliminates B-VXLAN; (2) self-managed eliminates
N-Cloud; (3) cost weight 0.5 highest; (4) $0 vs $1,040.25/month; (5) equal
throughput 9.74; (6) provisioning 261.1 vs 333.15 s; (7) scalability 0.4 vs
0.25; (8) phi(N-Static)=0.905 rank 1; (9) phi(N-Dynamic)=0.095.

Case 3: (1) sole survivor of filtering; (2) N-Static 400>200-route quota;
(3) N-Dynamic 400>250-prefix quota; (4) B-VXLAN transparency; (5) 9.74 Gbps;
(6) 422.55 s provisioning; (7) 0.994 ceiling share; (8) $73 fee; (9) no
scores computed for singleton set.

Case 4: (1) B-VXLAN eliminated by transparency; (2) throughput identical
9.74, removed as zero-variance; (3) equal weights over cost/prov/scal;
(4) scalability 0.998 highest; (5) $73 fee; (6) provisioning longest at
422.55 s; (7) phi(N-Cloud)=0.785 recommended; (8) N-Static 0.673;
(9) N-Dynamic 0.143.

Case 5 (superseded by the same-day update above; see header note for the
current 10-statement audit of the multi-VPC renumbering version).

No statement contradicts the record or the Section 3 measurements.
