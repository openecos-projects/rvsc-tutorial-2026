# Parameter notes

Everything here was observed on 2026-10-16/17 with the ECC CI bundle from
`emin/add-agent-ctrl`, the nightly ICS55 PDK, CPU only (no GPU). Re-check when
ECC changes.

## How to pass parameters

- In `ecc.toml`: `[design]` (`name`, `top`, `rtl`, `clock_port`,
  `frequency_mhz`), `[pdk]`, `[flow]` (`preset = "rtl2gds"`), and optional
  `[params.<section>]` tables, e.g.

  ```toml
  [params.floorplan]
  core_util = 0.40

  [params.cts]
  max_fanout = 6
  ```

- At create time: `--set section.key=value` (repeatable) in `demo.mjs` and
  `ctl create`, or `"set": {"section.key": value}` in batch JSON. Values keep
  their JSON type: `--set design.frequency_mhz=50` is a number,
  `--set floorplan.core_util=0.4` is a number.
- Keys are ECC spec keys in `section.key` form. Known-valid examples:
  `design.frequency_mhz`, `floorplan.core_util`, `cts.max_fanout`,
  `place.target_density`, `place.timing_opt_enabled`.
- Do not invent keys. If the user asks for a parameter you do not know, list
  the valid ones with `"$ECOS_ECC_BIN_DIR/ecc" param list --all --plain`
  (slow: can take more than 2 minutes) and ask the user to pick.
- One parameter set = one workspace. To compare settings, create one workspace
  per variant in the same project (`--project <root> --name <variant>`).
- After a create, ECC's consistency check may report a `parameter_patch`
  derived-field mismatch. It is expected (derived fields refresh after a run)
  and is not a mapping error.

## Design facts that worked

| Design | top | clock_port | frequency_mhz | Notes |
| --- | --- | --- | --- | --- |
| zipdiv (ecc-ci-designs) | `zipdiv` | `i_clk` | 50 | `core_util = 0.40`, `cts.max_fanout = 6`; 1118 std cells, die 7208 um2, core util 40% |
| minirv (Chisel, single file) | `minirv` | `clock` | 50 | Top module is the last module in the file; reset is `reset` |

Observed step times (minirv, CPU): synthesis 25 s, pre/post floorplan and
macro placement about 1 s each, preplace 8 s. Creating a workspace takes
about 13-15 s; create + open in `demo.mjs` about 20 s.

## Placement: the bottleneck

With the current ECC defaults placement does **not** finish in demo time:

- Placement runs at about 1 iteration per second until density overflow drops
  below 0.35. Then differentiable timing-driven placement ("Diff TDP")
  switches on and each iteration takes 10-17 s. The stop condition is overflow
  0.1, with up to 3000 iterations.
- zipdiv: overflow stuck around 0.2 for more than 30 minutes, with an
  iteration rollback. minirv: overflow 0.28 after 20 minutes.
- Overriding `place.diff_timing_driven_placement=0` and
  `place.differentiable_timing_obj=0` is written into the workspace config
  but **does not take effect** at run time (ECC-3). Only
  `place.timing_opt_enabled=0` is honored. Do not promise the user that these
  overrides speed placement up.
- With those overrides placement then crashed after 9 minutes on a hard-coded
  early-router path (ECC-1).

Practical advice for demos:

1. Rehearse with `demo.mjs --no-run` (create + open only).
2. Live: run until placement starts (about 40 s for minirv), narrate the early
   steps, then stop the run (SKILL.md section 6) and `load` a workspace that
   was finished beforehand.
3. Never leave a placement run going unattended on the presenter's laptop: it
   uses about 4-5 CPU cores for hours.

As of 2026-10-17 no complete RTL-to-GDS run has finished with this ECC on a
CPU-only machine, so a "finished beforehand" workspace has to come from
elsewhere (a GPU machine, an older ECC, or a CI end-to-end run). Check that
the workspace you plan to `load` really shows every step `succeeded` before
the demo.
