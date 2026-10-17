# Known issues

Found while building this skill (2026-10-16/17). Each entry: what you see,
the evidence, the workaround for a demo, and the status. **None of these is
filed upstream yet.** Ask the user before filing anything.

Versions: ECOS Studio `yell/refactor_gui_cli` at `b9f2c885`; ECC CI bundle
from `emin/add-agent-ctrl` at `d5b04c3c` (ecc-dreamplace `979e33cf`); nightly
PDK, Sizer and kepler-formal `v0.1.0-nightly.20261015`.

## ECC

### ECC-1 Placement crashes reading early-router output from a hard-coded `iEDA/` path

- **Symptom:** placement fails after several minutes:
  `FileNotFoundError: ... <workspace>/iEDA/data/rt/rt_temp_directory/early_router/gcell.info`.
  The workspace is marked `failed`, placement `incomplete`.
- **Evidence:** ecc-dreamplace `dreamplace/ops/routability/l_shape_inputs.py`
  lines 302-305 (and line 355 for `route_planar.guide`) build the directory as
  `dirname^3(params.result_dir) + "iEDA/data/rt/rt_temp_directory/early_router/"`.
  The ECC early router actually writes to
  `<workspace>/place_dreamplace/data/rt/rt_temp_directory/early_router/`
  (the `congestion_eval.cpp` log line prints that path for both demand_dir and
  supply_dir, and `gcell.info` exists there). The `iEDA/` prefix is a leftover
  from the iEDA layout. Reached through
  `NonLinearPlace.one_descent_step -> placement_topology_iteration ->
  l_shape_iteration.update_iteration -> prepare_l_shape_inputs_from_egr`.
- **Reproduced with:** minirv, workspace `minirv_fast` created with
  `place.diff_timing_driven_placement=0`, `place.differentiable_timing_obj=0`,
  `place.timing_opt_enabled=0`; crash after 9 min of placement.
- **Workaround:** none for a live run. Do not run placement live.
- **Fix direction:** derive the early-router directory from the step's data
  directory (the path the router was given) instead of a fixed `iEDA/` path.

### ECC-2 Timing-driven placement is too slow on CPU and may not converge

- **Symptom:** placement runs for 30+ minutes. Below overflow 0.35 each
  iteration takes 10-17 s ("Diff TDP enabled timing objective" in
  `place_dreamplace/log/place.log`). zipdiv stalls around overflow 0.2 with an
  iteration rollback; the stop target is 0.1 with up to 3000 iterations.
- **Evidence:** the CI branch's `dreamplace_ecc.json` defaults to
  `diff_timing_driven_placement=1`, `differentiable_timing_obj=1`,
  `timing_opt_enabled=1`; the nightly release had
  `differentiable_timing_obj=0` and neither of the other two keys.
- **Workaround:** do not run placement live; see `params.md`.

### ECC-3 `place.diff_timing_driven_placement` / `place.differentiable_timing_obj` overrides are ignored at run time

- **Symptom:** the workspace's `config/dreamplace_ecc.json` contains both
  keys as `0`, but the `parameters = {...}` line at the top of
  `place_dreamplace/log/place.log` shows both as `1`, and Diff TDP still turns
  on. `place.timing_opt_enabled=0` is honored.
- **Status:** cause not located. The ECC module marks every config key as
  explicit, and dreamplace's `_set_flow_default` respects explicit keys, so
  the value is changed somewhere after loading.

### ECC-4 Cancelling a packaged-ECC run does not stop the running step

- **Symptom:** GUI cancel / `workspace.cancel` / `ecc process cancel` return
  `cancel_requested`, but the `ecc run` process keeps running placement at
  ~450% CPU; `ecc process inspect` keeps reporting `status=alive`.
- **Evidence:** frozen (PyInstaller) builds run steps in-process
  (`ECC_STEP_SUBPROCESS=0` fallback), and the placement loop does not check
  the cancel request.
- **Workaround:** `kill -TERM` the `ecc run` process (SKILL.md section 6).

### ECC-5 The PyInstaller bundle needs `libxcb.so.1` and `libfontconfig.so.1` from the host

- **Symptom:** `ecc doctor` reports `dreamplace: import failed -
  libxcb.so.1: cannot open shared object file`, then
  `OSError: no library called "cairo-2" was found`.
- **Evidence:** `dreamplace.Placer -> PlaceDrawer -> cairocffi` loads the
  bundled `libcairo`, which needs `_internal/libX11.so.6 -> libxcb.so.1` and
  `libfontconfig.so.1`; PyInstaller excludes both as system libraries. The
  nightly-release bundle has the same dependency, but its doctor does not
  import `dreamplace.Placer`, so it only fails later, when placement runs.
- **Workaround:** provide both libraries (setup.md section 5).

### ECC-6 CI: PyInstaller smoke step runs the helper with Python 3.9

- **Symptom:** "Smoke test PyInstaller artifact" fails with
  `TypeError: unsupported operand type(s) for |: 'type' and 'NoneType'` at
  `packaging/experience_cli_smoke.py:239`.
- **Cause:** the manylinux container's `python3` is 3.9; the script uses
  PEP 604 annotations.
- **Status:** fixed locally as ecc commit `d178d12c`
  (`ci: run the experience CLI smoke with the managed Python`), branch
  `emin/add-agent-ctrl-smoke`; not pushed. The same CI run also failed `ruff
  format` on two test files and two pytest cases
  (`test_parameter_catalog_is_context_free_and_typed`, `test_ics55_gcd`).

## ECOS Studio GUI

### GUI-1 A flow that fails before its first step is reported as `succeeded`

- **Symptom:** `wait --operation` returns `"status":"succeeded"` (exit 0)
  although the ECC run log ends with `flow_failed ...` and no step changed.
- **Evidence:** `eccCli/runtimeService.ts` `terminalState()` derives the
  result only from step states; all `Success`/`Unstart` counts as success.
- **Workaround:** after every wait, check that all steps are
  `succeeded`/`skipped` (`demo.mjs` does this).

### GUI-2 A killed run is shown as "not started", and `wait --operation` can return `idle`

- **Symptom:** after the `ecc run` process is killed, ECC records the step as
  `incomplete`, but `ctl state` shows it as `not-started`.
- **`idle` (exit 0):** `wait --operation` only knows operations started
  through ctrl `run`/`command`. For a flow started by **clicking** Run (what
  `demo.mjs` does), it looks for an operation that is still `running`; if the
  flow already ended (fast failure, or killed before the wait arrived) it
  returns `idle` and the outcome is lost.
- **Workaround:** start `wait --operation` right after the click, in the same
  batch (as `demo.mjs` and `templates/run-flow.jsonl` do), and read the
  authoritative state with
  `ecc status --project <root> --workspace <ws> --plain`.

### GUI-3 The first "Open workspace" click after a create can be dropped silently

- **Symptom:** the click returns ok, the route stays `/workspace/projects`,
  nothing is logged. A second click works.
- **Evidence:** `ProjectsView.vue` `openWorkspace()` activates only if the
  route and current workspace did not change during the open
  (`shouldActivate`); the Projects page is still refreshing after a create.
- **Workaround:** verify with `waitFor route` and retry (`demo.mjs` does this).

### GUI-4 `TARGET_OBSCURED` on the Run button right after a workspace opens

- **Symptom:** clicking `testId: flow-run` fails with `TARGET_OBSCURED`,
  even after `waitFor ... state enabled` (which does not check occlusion).
- **Workaround:** wait 3 s and retry (`demo.mjs` does this).

### GUI-5 Captions are cleared whenever a client connection closes

- **Symptom:** `ctl caption "..."` followed by another `ctl` call: the
  caption disappears immediately, while `ctl state` still reports it (the main
  process keeps it, the overlay cleared it).
- **Workaround:** caption + actions in one `ctl batch`.

### GUI-6 `ctl state` became very slow in a long-running GUI instance

- **Symptom:** after about 4 hours (several created workspaces, three killed
  `ecc run` processes), `ctl windows` answered in ~0.2 s but `ctl state` took
  17-165 s. A fresh GUI instance with the same 4 projects answered in
  0.6-0.8 s.
- **What is known:** `state` is assembled in the Electron **main** process
  (`buildCtrlState` with `historyProjects`, `ecc.workspaceFlow` and
  `cliInstallerStatus`, wired in `main/mainFull.ts`), not in the renderer.
  The slow instance's main process had used little CPU, so it was most likely
  waiting on something rather than computing. Its renderer had used 208 CPU
  minutes over the session. Single ECC CLI calls took ~0.4 s at the time.
- **Status:** cause unknown. An earlier guess (Chromium background throttling
  of a hidden window) does not fit, because `state` does not go through the
  renderer.
- **Workaround:** restart the GUI.

### GUI-7 Smaller rough edges

- A `create` with `focus` whose item fails returns `BAD_REQUEST` ("focus ...
  does not name a created workspace") instead of the item's own error
  (e.g. `target_exists`). `demo.mjs` sends no focus for this reason.
- `screenshot` inside a batch ignores `out` and returns base64.
- Global options after the action (`ctl state --pretty`) are a usage error.
- Every `--ctrl` call starts a full Electron process (~0.5 s) and prints
  Fontconfig/GPU noise on stderr (`scripts/ctl` filters it).
