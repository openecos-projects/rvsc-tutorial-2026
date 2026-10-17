---
name: ecos-ctrl-demo
description: Drive a running ECOS Studio GUI from the command line through its external control interface (`ecos-studio --ctrl`) - list instances, read state, create workspaces from an ecc.toml design, open them, run the RTL-to-GDS flow, show captions, take screenshots. Use for live demos, tutorials, and scripted GUI walkthroughs of ECOS Studio. Triggers on "ecos ctrl", "--ctrl", "drive/control ECOS Studio", "demo the GUI", "let the agent operate the GUI".
---

# ECOS Studio external control (`--ctrl`) demos

Drive an ECOS Studio window that is **already running**: create a workspace,
open it, click Run, wait for the flow, show captions, take screenshots. The
audience sees real GUI interaction, with a pointer cue and on-screen captions.

> This skill is written for models with limited autonomy. **Follow the steps
> in order. Do not skip verification. Never guess a button name. Never invent
> parameters.** If something happens that this skill does not describe, stop
> and report the exact command and its full output to the user.

## 0. Read these warnings first (every one of them has bitten us)

1. **The GUI must be started with `--enable-ctrl`.** Otherwise every `--ctrl`
   call exits 3. You cannot turn control on from the client side: ask the user
   to restart the GUI (see `reference/setup.md`).
2. **`ctl state` normally answers in about 1 second.** After a long session
   (hours, several killed runs) it was once seen taking 17-165 s; the cause is
   not known yet (known issue GUI-6). If `ctl state` takes more than 10
   seconds: run `ctl windows` (should answer in well under a second). If
   `windows` is fast but `state` stays slow, tell the user and suggest
   restarting the GUI (a fresh instance answered in 0.6-0.8 s again). Keep the
   control window visible during demos anyway: the audience needs to see it.
3. **Captions only live as long as the connection that set them.** Every
   `ctl <action>` call is a new connection, and the caption is cleared when it
   closes. To keep a caption on screen, put the caption **and the actions it
   describes into one `ctl batch`** (section 4). `scripts/demo.mjs` already
   does this. The same applies to `pace`.
4. **Never guess target names.** Run `ctl controls` first and copy `role` +
   `name`, or `testId`, from its output. Names must match **exactly**
   (case and spaces).
5. **The page is still settling right after a create or an open:**
   - The first click on `Open workspace <name>` right after a create can be
     **dropped silently** (the click returns ok, the page does not change).
     Always verify with `waitFor route /workspace/home`; click again if it
     did not change.
   - Clicking Run (`testId: flow-run`) right after the workspace opens can
     fail with `TARGET_OBSCURED`, even after `waitFor ... enabled`. Wait 3
     seconds and retry.
6. **`succeeded` from `wait --operation` does not prove the flow finished.**
   The GUI can report `succeeded` when ECC failed before the first step. Always
   check `ctl state` afterwards: every `flow.steps[].status` must be
   `succeeded` or `skipped`.
7. **`interrupted` from `wait --operation` exits 0.** Only `failed` and
   `cancelled` exit 4. Read the `status` field, not just the exit code.
8. **The full flow will probably not finish right now.** Placement is extremely
   slow on CPU or crashes (`reference/known-issues.md`, ECC-1 and ECC-2). In a
   live demo, **do not promise a complete RTL-to-GDS run.** Recommended: run
   live until placement starts, then `load` a workspace that was finished
   beforehand and present that.
9. **Cancel does not work.** The GUI cancel and `workspace.cancel` only
   _request_ a cancel; ECC keeps running placement. The only way to stop a run
   is to end the `ecc run` process (section 6). **Only stop runs you started
   yourself, and tell the user first.**
10. Global options (`--pretty`, `--quiet`, `--instance`) go **before** the
    action: `ctl --pretty state` works, `ctl state --pretty` exits 2.
11. When a script parses output, **do not use `--pretty`**: each result is one
    JSON line. `create`/`load` print progress lines like
    `{"index":1,"total":1,"status":"creating",...}` on stderr; those are not
    results.
12. Use **absolute paths** everywhere (design dir, projects dir, PDK root).
13. **`--projects-dir` must already exist.** Otherwise `create` fails with
    `project_root_unwritable` (`ENOENT ... mkdir`). Run `mkdir -p` first.
14. **The GUI and the workspaces must use the same ECC build.** A workspace
    made by another ECC (for example the alpha.9 AppImage's `--cli ecc`, which
    has no `cli_contract`) opens with a red toast
    `ENGINEERING_SNAPSHOT_READ_FAILED: ... home/engineering-snapshot.json`.
    Stop and report it; do not try to repair the workspace.

## 1. Check the environment (at the start of every session)

Full details: `reference/setup.md` (versions, ECC environment variables,
NixOS specifics). At minimum:

```bash
SKILL=.claude/skills/ecos-ctrl-demo      # this skill, relative to the repo root
export ECOS_CTRL_CMD="ecos-studio"       # client command; dev builds: see setup.md
$SKILL/scripts/ctl list                  # expect: at least one instance
$SKILL/scripts/ctl state                 # expect: one JSON line with "toolchain":{"status":"ready"}
```

| What you see                                    | Meaning                                                                                             | What to do                                                                |
| ----------------------------------------------- | --------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| `ctl list` prints `{"instances":[]}` or exits 3 | No GUI with `--enable-ctrl`, or the client runs in a different user environment (`XDG_RUNTIME_DIR`) | Follow setup.md. **Do not continue.**                                     |
| Several instances                               | More than one GUI has control enabled                                                               | `export ECOS_CTRL_INSTANCE=<instanceId>` (use the id, not the label)      |
| `toolchain.status` is not `ready`               | ECC is not set up                                                                                   | Run the `ecc doctor --plain` check in setup.md and report what is missing |
| `ctl state` takes > 10 s                        | Known slowdown after long sessions (GUI-6)                                                          | Check `ctl windows`; if it is fast, suggest restarting the GUI            |

## 2. Prepare a design directory

A design directory is one `ecc.toml` plus the RTL. Directories that already
have an `ecc.toml` (for example ecc-ci-designs) can be used as is. If you only
have Verilog files, generate one:

```bash
$SKILL/scripts/new-design.sh <out-dir> <top-module> <clock-port> <freq-MHz> <rtl.v>...
# example
$SKILL/scripts/new-design.sh /home/me/demo/designs/minirv minirv clock 50 /home/me/Downloads/minirv.v
```

- **Top module:** find `module <name>(` in the RTL and pick the **outermost**
  module, the one no other module instantiates (in minirv.v it is `minirv`,
  not `NPC` or `IFU`). Chisel output usually puts the top module last.
- **Clock port:** read the top module's `input` list. Chisel output uses
  `clock` (and `reset`); hand-written RTL often uses `clk` or `i_clk`.
  **If unsure, ask the user.** A wrong clock port makes timing meaningless.
- **Frequency:** use 50 (MHz) unless the user asks otherwise. See
  `reference/params.md`.
- The script refuses to overwrite an existing `ecc.toml`; pick a new directory.

## 3. One-command demo (recommended)

```bash
node $SKILL/scripts/demo.mjs \
  --design /home/me/demo/designs/minirv \
  --name minirv_base \
  --projects-dir /home/me/demo/runs \
  --pdk-root /path/to/ics55/pdk \
  --pace 1200
```

| Option                           | Meaning                                                                                    |
| -------------------------------- | ------------------------------------------------------------------------------------------ |
| `--design DIR`                   | Directory containing `ecc.toml` (required)                                                 |
| `--name WS`                      | Workspace name to create; must not exist yet (required)                                    |
| `--projects-dir DIR`             | Create a **new** project at `DIR/<design.name>`                                            |
| `--project ROOT`                 | Add the workspace to an **existing** project (same top module only)                        |
| `--pdk-root DIR` / `--pdk-id ID` | PDK directory, or an already-installed PDK id (exactly one)                                |
| `--set KEY=VALUE`                | Parameter override, repeatable (see `reference/params.md`)                                 |
| `--pace MS`                      | Pause before each UI action, with pointer cue (default 1200; 0-3000)                       |
| `--no-run`                       | Stop after the workspace is open (rehearsals, or when the flow cannot finish)              |
| `--timeout-min N`                | How long to wait for the flow (default and max 30). The flow keeps running after a timeout |

Exactly one of `--projects-dir` / `--project`, and exactly one of
`--pdk-root` / `--pdk-id`, is required. Missing or conflicting options print
the usage and exit 2.

How to read the output:

| Output                                               | Meaning                              | What to do                                             |
| ---------------------------------------------------- | ------------------------------------ | ------------------------------------------------------ |
| `[create] <path>`                                    | Workspace created                    | Continue                                               |
| `[open] /workspace/home`                             | Workspace is open in the GUI         | Continue                                               |
| `[open] attempt 1 hit ...; retrying in 3s`           | Known settling race (warning 5)      | Nothing; the script retries                            |
| `[run] flow started`                                 | Run was clicked and the flow started | Wait; tell the user the flow is running                |
| `[wait] operation status: succeeded` and exit 0      | Every step finished                  | Take a screenshot, present results                     |
| `[wait] TIMEOUT: ...`                                | Not finished within the limit        | `ctl state` to see progress; report to the user        |
| `reported succeeded, but these steps did not finish` | GUI false success (warning 6)        | Read `<workspace>/log/<operationId>.log` and report it |
| `[stage] failed: {...}`                              | A stage failed                       | Look up `error.code` in `reference/ctl-reference.md`   |

## 4. Step-by-step control (custom flows)

The loop is **look, find, act, verify**. Verify after every action; never chain
blind clicks.

```bash
ctl() { $SKILL/scripts/ctl "$@"; }
ctl state                                                    # 1. look: route, workspace, flow.running, dialogs
ctl controls                                                 # 2. find: copy role+name or testId
ctl click --role button --name "Open workspace minirv_base"  # 3. act
ctl wait --route /workspace/home --timeout 20000             # 4. verify
```

When captions or pacing must stay on screen, send the whole segment as JSONL to
`ctl batch` (one request per line, one connection):

```bash
ctl batch <<'EOF'
{"method":"pace","params":{"delayMs":1200,"cues":true}}
{"method":"caption","params":{"text":"Open minirv_base","durationMs":0}}
{"method":"click","params":{"target":{"role":"button","name":"Open workspace minirv_base"}}}
{"method":"waitFor","params":{"route":"/workspace/home","timeoutMs":20000}}
EOF
```

- A batch **stops at the first error** (unless `--keep-going`); later requests
  do not run. The last output line is that error.
- Every action's JSON shape, every exit code and every error code with its fix:
  `reference/ctl-reference.md`.
- Ready-made JSONL segments: `templates/`.

## 5. Show finished results without running (safest demo)

Load the **workspace directory** (not the project root): only then does the
result contain a ready-made click target.

```bash
ctl load /abs/runs/minirv/minirv_base
# result item contains:
# "openTarget":{"name":"Open workspace minirv_base","role":"button","within":{"testId":"project-row:proj_minirv_..."}}
```

Send that `openTarget` unchanged as the click target (it is scoped to the
right project row, so equal workspace names in other projects do not clash):

```bash
ctl batch <<'EOF'
{"method":"click","params":{"target":{"name":"Open workspace minirv_base","role":"button","within":{"testId":"project-row:proj_minirv_..."}}}}
{"method":"waitFor","params":{"route":"/workspace/home","timeoutMs":20000}}
EOF
```

A project-root input is also accepted, but its result lists no workspaces and
no `openTarget`; you would have to find the button with `ctl controls`.
Loading opens instantly and does not depend on placement finishing.

## 5a. Run with `--cli`, then present in the GUI (recommended live demo)

Run the flow headless with the **same build's** `--cli ecc` entry (warning
14), then use `--ctrl` only to show the result. The flow takes minutes; the
presentation takes seconds.

```bash
ECC="ecos-studio --cli ecc"                     # dev build: "electron /abs/ctrl-app --cli ecc"
cd /abs/gcd                                     # project dir with ecc.toml
$ECC run --workspace u0.75 --set floorplan.core_util=0.75 > run-u0.75.log 2>&1
$ECC status --workspace u0.75 --plain           # read every step before presenting
```

- Start the run **before** the talk, or in the background, and present an
  already finished workspace. Rehearsal numbers (ctrl-branch ECC, gcd, CPU):
  one run took 11 to 36 minutes.
- Do not `ctl load` a project while an `ecc run` in it is still going: the
  load fails with `Live runtime process does not hold the Workspace lock`.
- With the ctrl-branch ECC, signoff currently stays `blocked` at the `emir`
  step (`EMIR technology_file_path is a placeholder`): the nightly PDK has no
  EMIR technology file. Say so on screen; do not invent a path.

The steps below then load the workspaces, walk the result with captions, open
one, and show its signoff checklist. Get every number from
`ecos-tutorial/scripts/sweep-table.sh` or `ecc report summary`; never invent
them.

````bash
Rehearsed on 2026-10-17 (ctrl-branch dev build, gcd, `u0.75` made by
`--cli`). Replace the caption text with numbers from your own run:

```bash
ctl load /abs/gcd/u0.75 /abs/gcd/u0.4          # workspace dirs; keep each openTarget
ctl batch <<'EOF'
{"method":"pace","params":{"delayMs":1500,"cues":true}}
{"method":"caption","params":{"text":"Agent: open u0.75, made by ecc --cli","durationMs":0}}
{"method":"click","params":{"target":<openTarget of u0.75, unchanged>}}
{"method":"waitFor","params":{"route":"/workspace/home","timeoutMs":20000}}
{"method":"caption","params":{"text":"Signoff checklist: what still blocks export","durationMs":0}}
{"method":"waitFor","params":{"target":{"role":"button","name":"Sign-off details"},"state":"enabled","timeoutMs":20000}}
{"method":"click","params":{"target":{"role":"button","name":"Sign-off details"}}}
EOF
ctl screenshot --out /abs/signoff.png
````

The batch ends with the last click, which closes the connection and clears
the caption. To keep the last caption on screen for the screenshot, start the
batch in the background, take the screenshot from a second call while it runs,
and end the batch with a wait that is meant to time out:
`{"method":"waitFor","params":{"route":"/nowhere","timeoutMs":6000}}`.

- `pace` delays every request, so consecutive captions stay readable; keep
  each caption under 80 characters.
- Route still `/workspace/projects` after the click: warning 5, resend from
  the `click` line.
- Red **Failed to Open Project** toast: warning 14. Stop.
- Close the dialog with `{"method":"press","params":{"key":"Escape"}}`.

## 6. Stop a run (only after the user agrees)

The GUI cancel does not stop placement. When the user confirms:

```bash
ps -eo pid,etime,args | grep "[e]cc run --project <project-root> --workspace <workspace>"
kill -TERM <pid from the first column>
ctl wait --operation --timeout 60000      # expect "status":"interrupted" (exit 0)
```

- The brackets in `grep "[e]cc"` stop grep from matching itself. **Do not use
  `pgrep -f`**: it matches your own shell command line, so you may conclude a
  dead process is "still alive" or kill the wrong process.
- Afterwards ECC records the step as `incomplete`; the GUI may show it as
  `not-started`. This is a known issue.

## 7. Screenshots

```bash
ctl screenshot --out /abs/shot.png
```

Inside a batch, `screenshot` **does not write a file**: it returns
`{"pngBase64":"..."}`. A screenshot is itself a connection, so the banner may
show the grey "External control enabled" instead of the orange "Controlled by
an external client". That is a harmless timing effect.

## 8. When you finish

- Tell the user which workspaces you created (absolute paths), how far the flow
  got, and every error (verbatim).
- If an `ecc run` you started is still running, **ask** the user whether to
  stop it. Do not silently leave it or kill it.
- For a problem not listed in `reference/known-issues.md`, report the exact
  command and its full output.
