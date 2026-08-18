# Experimental data

All measurement data is stored as CSV. File names follow
`fig<N>_<metric>_<raw|summary>.csv`, where `<N>` is the figure number in the paper.

| File | Figure | Contents |
|---|---|---|
| `fig2_dataplane_summary.csv` | Fig. 2 | TCP throughput and per-CPU-state shares, mean of three runs |
| `fig3_provisioning_raw.csv` | Fig. 3 | Provisioning wall-clock time, one row per phase **per repetition** |
| `fig3_provisioning_summary.csv` | Fig. 3 | Mean and sample SD over the three repetitions |
| `fig4_cost_model.csv` | Fig. 4 | Modelled routing-specific monthly fee versus cluster size |
| `fig6_sensitivity_margin.csv` | Fig. 6 | Recommendation margin under weight perturbations |

Long format throughout: one observation per row, with the measured quantity in
`value`/`mean` and its unit in `unit`.

* `figure` — figure number the row belongs to
* `config` — `B-Host`, `B-VXLAN`, `N-Static`, `N-Dynamic`, `N-Cloud`
* `set` — `initial_4node` (Fig. 3a) or `scaleup_4to8node` (Fig. 3b)
* `phase_id` / `phase` — measurement interval; `T0_to_T5` / `total` is the sum of
  the four preceding phases
* `run` — repetition index, 1–3

## Reproducing the figures

    python3 dataplane_fig.py       # Fig. 2   from fig2_dataplane_summary.csv
    python3 provisioning_fig.py    # Fig. 3   from fig3_provisioning_raw.csv
    python3 cost_model.py          # Fig. 4   model; also rewrites fig4_cost_model.csv
    python3 sensitivity_fig.py     # Fig. 6   decision engine; rewrites fig6_sensitivity_margin.csv
    python3 regen_eval.py          # Table 9 case-study scores

`sensitivity_fig.py` and `regen_eval.py` import the decision engine from
`../prototype/backend`.

## Notes

* Fig. 2 retains run-level means only; per-repetition values were not kept for
  that experiment. Every other measured quantity is published per repetition.
* Fig. 4 and Fig. 6 are computed rather than measured, so they carry no `run`
  column.
* `_superseded/` holds the pre-conversion spreadsheets and the data of the
  routing-convergence dimension, which the paper no longer reports.
