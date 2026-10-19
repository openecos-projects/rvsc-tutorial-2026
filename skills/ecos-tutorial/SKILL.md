---
name: ecos-tutorial
description: Run the ECC RTL-to-GDS flow through the ECOS Studio AppImage (`--cli ecc`) and explore parameters the way the ysyx E8 lecture asks, in particular "find the highest core utilization that still exports a signoff package". Use for the RVSC 2026 ECOS tutorial, ysyx NPC backend design, `ecc run` parameter sweeps, and "explore the highest util" requests.
---

# ECOS tutorial: explore with ECC

You drive **ECC** (ECOS Chip Compiler) from the command line, create one
workspace per parameter value, and judge every result by **signoff**, not by
exit codes. The human reviews the workspaces afterwards in the ECOS Studio GUI.

> Follow the steps in order. Never guess a command or a parameter name: read
> `--help` or `ecc param show` first. If something happens that this skill
> does not describe, stop and report the exact command and its full output.

## 1. Find ECC

Use the first one that works and keep it in `$ECC` for every later call:

```bash
export ECC="ecc"                                                   # installed CLI
export ECC="/abs/ECOS-Studio_<version>_x86_64.AppImage --cli ecc"  # AppImage
# NixOS: the AppImage needs an FHS wrapper
export ECC="nix shell nixpkgs#appimage-run -c appimage-run /abs/ECOS-Studio_...AppImage --cli ecc"
$ECC version
```

- `--cli` must be the **first** argument after the AppImage path.
- `The ECC core component is not ready`: ask the user to open the GUI once
  (it downloads ECC), then retry.
- The AppImage may print its own lines (`... installed in ...`,
  `INFO [desktop] ...`) before ECC output. Ignore them; with `--plain`, read
  only lines that start with `key=`.

## 2. Check the project before running anything

```bash
cd <project>              # directory with ecc.toml; or pass --project <dir>
$ECC doctor --plain       # first line must say status=ok
$ECC pdk set-root <pdk>   # if pdk.root is empty; also validates the PDK contents
$ECC check --workspace <ws>   # only after a workspace exists
```

On a new project (no workspace yet), `$ECC check` fails with
`workspace_required ... declared workspaces: (none)`. That is expected in ECC
`emin/add-agent-ctrl`; use `doctor` and `pdk set-root` before the first run.

| What you see                                       | Do                                                                                                                 |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `pdk.root is required`                             | Ask the user for the ICsprout55 PDK path, then `$ECC pdk set-root <path>`                                          |
| `PDK has no liberty files` / `tech LEF is missing` | The PDK was not unpacked. Ask the user to run `make unzip` in the PDK, or to point at another PDK. Do not continue |
| `top` / `clock_port` look wrong                    | Read the RTL; ask the user if unsure. A wrong clock port makes timing meaningless                                  |

## 3. Measure one baseline run first

If no workspace has passed signoff yet, run the default once and time it:

```bash
( time $ECC run --workspace u0.4 --set floorplan.core_util=0.4 ) > run-u0.4.log 2>&1
```

Reference numbers (gcd, 8-core CPU, no GPU, ECC `emin/add-agent-ctrl`): one
full run takes about 37 minutes, mostly `placement` (about 25 min) and
`diff_sizing` (7-9 min). An older ECC with no `diff_sizing` step (alpha.9
AppImage) took about 8 minutes. **Use your own measured time for all
planning.**

## 4. Explore: the rules

1. **One value = one new workspace.** Name it after the value:
   ```bash
   $ECC run --workspace u0.75 --set floorplan.core_util=0.75 > run-u0.75.log 2>&1 &
   ```
   `--set` only works when the run creates the workspace. Never use
   `--overwrite`, never delete or rename a workspace, never edit `ecc.toml`.
2. **Check memory before every launch.** `diff_sizing` refuses to start
   unless about 6.3 GiB of `MemAvailable` is free _for that run_ (error:
   `insufficient CPU routing memory budget`). Run at most
   `floor((MemAvailable_GiB - 2) / 6.5)` flows at once, and never more than 3.
   Each run also uses about 3 CPU cores during placement.
3. **Poll, don't stream.** Every 30-60 s:
   `$ECC status --workspace <ws> --plain`. Do not print whole logs.
4. **Success means signoff, not `status=success`:**
   ```bash
   $ECC signoff inspect --workspace <ws> --plain   # status=ready|attention -> pass, status=blocked -> fail
   ```
   `attention` is fine (optional files such as `config.macro_locations` for a
   design without macros). A run can finish every step and still be
   `blocked` by DRC/LVS violations. A run that stops before `harden` reports
   `[blocked] Signoff checklist unavailable`; then judge the value by
   `report summary` (`DRC Status`, `LVS Status`, slack) and say clearly that
   signoff could not be checked.
5. **Explain every failure in one sentence**, from evidence:
   - flow failed: `$ECC log <step> --workspace <ws>` and quote the error line;
   - signoff blocked: `$ECC report summary --workspace <ws>` and read
     `DRC Status`, `LVS Status`, setup/hold slack.
6. **Search: coarse, then fine, in parallel.**
   - Round 1: values spread over the plausible range (for
     `floorplan.core_util`: 0.6 / 0.75 / 0.9, as many as rule 2 allows).
   - Next rounds: split the gap between the **highest passing** and the
     **lowest failing** value into up to 3 new values.
   - Results are **not monotonic**. A routing short can make a low value fail
     while a higher one passes. Do not discard the range above a value that
     failed in DRC/LVS; mark it in the report instead.
   - A value that fails with `utilization is larger than 0.99` is a hard
     limit: skip every larger value. It can appear in `placement`, or later
     in `timing_optimization` when Sizer adds hold buffers (read
     `DPL-0006 ... Utilization:` in that step's log).
   - A failure that has nothing to do with the parameter (missing tool or
     library, missing PDK file such as `EMIR technology_file_path is a
placeholder`) is an **environment problem**, not a data point. Stop
     the search and report it to the user.
7. **Respect the time budget.** If the remaining budget is shorter than one
   measured round, stop and report the best value found so far.
8. **Only stop processes you started.** Find them with
   `ps -eo pid,etime,args | grep "[e]cc run"` and `kill -TERM <pid>`; tell the
   user first.

## 5. Summarize

```bash
scripts/sweep-table.sh <project> default u0.6 u0.75 u0.9     # set ECC first
```

The script prints one row per workspace: flow status, signoff status, first
failed step, die area, utilization, Fmax. For a failed flow, the area and Fmax
columns come from the steps that did run; do not present them as results.

Export the best passing workspace:

```bash
$ECC signoff export --workspace <best> -o <project>/../<design>_max_util_signoff.tar.gz
```

Report to the user:

- the table, including the failure reason of every failing value;
- the best value, the gap to the nearest failing value above it (that is your
  precision), and any non-monotonic points;
- the signoff package path, and how to review it in the GUI: Projects ->
  Import Project -> select the project directory -> open the workspace
  (to have the agent present it in a running GUI, use the sibling skill
  `ecos-ctrl-demo`, section 5a);
- the next step you would take with more time (for example: retry the
  non-monotonic value, or split the remaining gap).

Known results for the tutorial's gcd (2026-10-17, nightly PDK, 8-core CPU).
They depend on the ECC build; use them to sanity-check, never as your answer.

- ECC `emin/add-agent-ctrl` (d5b04c3c, 21-step `rtl2gds`): one run takes
  about 37 minutes. 0.4 is DRC clean / LVS matched; 0.75 has 11 DRC
  violations (4 metal shorts, 7 parallel-run-length spacing) and 4 LVS
  mismatches; 0.85 fails in `timing_optimization` (35 hold buffers push the
  core to 109% utilization). 0.4 and 0.75 both stop at `emir` because the
  nightly PDK has no EMIR technology file, so neither exports a signoff
  package yet.
- ECC in the alpha.9 AppImage (15-step `rtl2gds`): one run takes about
  8 minutes; 0.4 / 0.75 / 0.8 / 0.85 pass; 0.6 is blocked by one routing
  short; 0.9 fails in placement (`utilization is larger than 0.99`).
