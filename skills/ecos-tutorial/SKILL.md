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
export ECC="/abs/ECOS-Studio_0.1.0-alpha.9_x86_64.AppImage --cli ecc"  # AppImage
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
$ECC check
$ECC doctor --plain       # first line must say status=ok
```

| What you see                                       | Do                                                                                                                 |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `pdk.root is required`                             | Ask the user for the ICsprout55 PDK path, then `$ECC pdk set-root <path>`                                          |
| `PDK has no liberty files` / `tech LEF is missing` | The PDK was not unpacked. Ask the user to run `make unzip` in the PDK, or to point at another PDK. Do not continue |
| `top` / `clock_port` look wrong                    | Read the RTL; ask the user if unsure. A wrong clock port makes timing meaningless                                  |

## 3. Measure one baseline run first

If no workspace has passed signoff yet, run the default once and time it:

```bash
( time $ECC run --workspace default ) > run-default.log 2>&1
```

Reference numbers (gcd, 8-core laptop, CPU only): one full run is about
8 minutes alone and about 10 minutes when 3 runs share the machine. STA over
13 corners takes more than half of it. **Use your own measured time for all
planning.**

## 4. Explore: the rules

1. **One value = one new workspace.** Name it after the value:
   ```bash
   $ECC run --workspace u0.75 --set floorplan.core_util=0.75 > run-u0.75.log 2>&1 &
   ```
   `--set` only works when the run creates the workspace. Never use
   `--overwrite`, never delete or rename a workspace, never edit `ecc.toml`.
2. **At most 3 runs at once** (each run uses about 1.5 CPU cores and up to
   1.5 GB RAM; reduce on smaller machines).
3. **Poll, don't stream.** Every 30-60 s:
   `$ECC status --workspace <ws> --plain`. Do not print whole logs.
4. **Success means signoff, not `status=success`:**
   ```bash
   $ECC signoff inspect --workspace <ws> --plain   # status=ready|attention -> pass, status=blocked -> fail
   ```
   `attention` is fine (optional files such as `config.macro_locations` for a
   design without macros). A run can finish every step and still be
   `blocked` by DRC/LVS violations.
5. **Explain every failure in one sentence**, from evidence:
   - flow failed: `$ECC log <step> --workspace <ws>` and quote the error line;
   - signoff blocked: `$ECC report summary --workspace <ws>` and read
     `DRC Status`, `LVS Status`, setup/hold slack.
6. **Search: coarse, then fine, in parallel.**
   - Round 1: three values spread over the plausible range (for
     `floorplan.core_util`: 0.6 / 0.75 / 0.9).
   - Next rounds: split the gap between the **highest passing** and the
     **lowest failing** value into up to 3 new values.
   - Results are **not monotonic**. A routing short can make a low value fail
     while a higher one passes. Do not discard the range above a value that
     failed in DRC/LVS; mark it in the report instead.
   - A value that fails in placement with
     `utilization is larger than 0.99` is a hard limit: skip every larger value.
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

Known result for the tutorial's gcd (2026-10-17, alpha.9 AppImage, nightly
PDK): 0.4 / 0.75 / 0.8 / 0.85 pass; 0.6 is blocked by one routing short
(DRC + LVS); 0.9 fails in placement (`utilization is larger than 0.99`).
Highest passing value found: **0.85**, open gap 0.85-0.9.
