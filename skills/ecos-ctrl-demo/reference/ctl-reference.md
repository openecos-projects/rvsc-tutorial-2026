# `ctl` command reference

Every command goes through `scripts/ctl <action> ...`. It is exactly
`ecos-studio --ctrl`, with Chromium/Mesa launcher noise filtered from stderr.
**Global options go before the action:** `ctl --pretty state`,
`ctl --instance be30c429 state`.

Global options: `--instance <id|label>`, `--ctrl-socket <path>`, `--pretty`
(indented JSON, for humans only; never when a script parses the output),
`--quiet` (no progress on stderr). The environment variable
`ECOS_CTRL_INSTANCE` is the same as `--instance`.

## Actions (standalone call and batch JSON)

In a batch, send one JSON object per line. Use absolute paths.

| Standalone | Batch JSON | Notes |
| --- | --- | --- |
| `ctl list` | - | Live control instances for this user |
| `ctl state` | `{"method":"state","params":{}}` | Route, workspace, flow, projects, dialogs, caption, toolchain |
| `ctl windows` | `{"method":"windows","params":{}}` | Window list. Answered by the main process only, so it is the fastest "is the server alive" probe |
| `ctl controls [--scope <testId>]` | `{"method":"controls","params":{}}` | Interactive elements (max 300) with role, name, testId, enabled |
| `ctl goto <route> [--query k=v,k2=v2]` | `{"method":"goto","params":{"route":"/projects"}}` | Navigate the control window |
| `ctl click --role R --name N` | `{"method":"click","params":{"target":{"role":"button","name":"N"}}}` | Real mouse click at the target center |
| `ctl click --test-id T` | `{"method":"click","params":{"target":{"testId":"T"}}}` | Click by `data-testid` |
| `... --match prefix` | `"target":{"role":"button","name":"Open","match":"prefix"}` | Prefix match on the accessible name |
| `... --within <testId>` | `"target":{...,"within":{"testId":"<testId>"}}` | Search only inside one subtree (when names repeat) |
| `ctl click ... --double` / `--button right` | `"double":true` / `"button":"right"` | Double click / other mouse button |
| `ctl type --test-id T --text S [--replace]` | `{"method":"type","params":{"target":{"testId":"T"},"text":"S","replace":true}}` | Type text (max 4096 chars). `replace` selects all first |
| `ctl press Enter [--modifiers control,shift]` | `{"method":"press","params":{"key":"Enter","modifiers":["control"]}}` | Keys: Enter, Escape, Tab, arrows, Backspace, Delete, PageUp/PageDown, Home, End, A-Z, 0-9. Modifiers: alt, control, meta, shift |
| `ctl wait --route R [--timeout MS]` | `{"method":"waitFor","params":{"route":"R","timeoutMs":MS}}` | Wait for a route |
| `ctl wait --test-id T --state enabled` | `{"method":"waitFor","params":{"target":{"testId":"T"},"state":"enabled","timeoutMs":MS}}` | States: visible, hidden, enabled. **Does not check that the target is unobscured** |
| `ctl wait --operation [--timeout MS]` | `{"method":"waitFor","params":{"operation":true,"timeoutMs":MS}}` | Wait for the current flow to end (max 1800000 = 30 min) |
| `ctl screenshot --out /abs/f.png [--max-width N]` | `{"method":"screenshot","params":{}}` | In a batch the result is `{"pngBase64":...}`; **no file is written** |
| `ctl load <path>... [--focus <ws>]` / `--from-file list.txt` | `{"method":"load","params":{"paths":["/abs/p"],"focus":"ws"}}` | Show existing projects on the Projects page (max 64 paths) |
| `ctl create --design D ...` | see "create" below | Create workspaces from ecc.toml designs |
| `ctl run [--step S] [--rerun]` | `{"method":"run","params":{}}` | Start the flow directly (no click, no pointer animation) |
| `ctl command --json '<request>'` | `{"method":"command","params":{"request":{...}}}` | Whitelist only: `workspace.run`, `workspace.runStep`, `workspace.cancel` |
| `ctl caption "text" [--duration MS]` | `{"method":"caption","params":{"text":"text","durationMs":0}}` | Bottom caption (max 200 chars, max 60000 ms). 0 = until the next caption **or until the connection closes** |
| `ctl pace --delay MS --cues on` | `{"method":"pace","params":{"delayMs":1200,"cues":true}}` | Pause and pointer cue before each UI action (0-3000 ms). **Per connection** |
| `ctl batch [--keep-going]` | - | Read JSONL from stdin and run it in order over one connection |

### `create`

Standalone, one design:

```bash
ctl create --design /abs/designs/minirv --projects-dir /abs/runs --name minirv_base \
  --pdk-root /abs/pdk --set design.frequency_mhz=50
```

Standalone flags: `--design DIR`, one of `--projects-dir DIR` / `--project ROOT`,
`--name WS`, one of `--pdk-id ID` / `--pdk-root DIR`, `--set k=v` (repeatable),
`--from STEP`, `--to STEP`. Batch from a TOML script: `ctl create --script
designs.toml` (template: `templates/designs.toml`).

Batch JSON:

```json
{"method":"create","params":{
  "projectsDir":"/abs/runs",
  "focus":"minirv_base",
  "items":[{
    "kind":"design",
    "designDir":"/abs/designs/minirv",
    "workspaceName":"minirv_base",
    "pdk":{"root":"/abs/pdk"},
    "set":{"design.frequency_mhz":50}
  }]
}}
```

- Use either `projectsDir` (new project named after `design.name` in ecc.toml)
  or the item field `projectRoot` (add to an existing project), not both.
- `pdk` is `{"root":"<dir>"}` or `{"installationId":"<id>"}`.
- `set` keys are `section.key`; keep JSON types (numbers unquoted).
- The result has one entry per item: `status` is `created`, `failed`,
  `skipped` or `not_started`; on success `targetDirectory` is the workspace
  path. After a create the GUI shows the Projects page.

### Status values

`flow.steps[].status` and `projects[].workspaces[].status` use: `succeeded`,
`failed`, `running`, `not-started`, `skipped`, `cancelled`, `interrupted`.
A step that was killed is `incomplete` in ECC but may show as `not-started`
in the GUI.

## Exit codes (standalone calls)

| Exit | Meaning | What to do |
| --- | --- | --- |
| 0 | OK. **`wait --operation` also exits 0 for `interrupted`** | Continue, but read `status` |
| 1 | Action error, or a failed item in `load`/`create` | Read `error.code` and use the table below |
| 2 | Usage error (bad flags, global option after the action, invalid create script) | Fix the command; never retry it unchanged |
| 3 | Server not reachable (GUI not running, no `--enable-ctrl`, different environment) | Stop and follow setup.md. **Do not switch to another instance on your own** |
| 4 | `TIMEOUT`, or the flow ended `failed`/`cancelled` | `ctl state` to see what actually happened |
| 5 | Protocol mismatch between client and GUI | Use the same ecos-studio build as the client |
| 6 | `UNSUPPORTED_PLATFORM` (workspace actions off Linux) | Use Linux |
| 7 | Instance selection failed (`--instance` matched 0 or several, or the pinned instance restarted) | `ctl list`, then `export ECOS_CTRL_INSTANCE=<new id>` |

## Error codes and fixes

| `error.code` | Usual cause | Fix |
| --- | --- | --- |
| `TARGET_NOT_FOUND` | Wrong name, page not rendered yet, or wrong page | `ctl controls` and copy the name again; `ctl state` to check the route; wait 2-3 s and retry once |
| `TARGET_AMBIGUOUS` | Several visible elements match | Add `--within <testId>` or use a testId |
| `TARGET_OBSCURED` | Something covers the target (page switching, overlay, dialog) | Wait 3 s and retry; after 3 failures take a screenshot to see what covers it |
| `TARGET_DISABLED` | Button is disabled (e.g. Run while a flow is running) | Check `flow.running` in `ctl state`; do not force it |
| `TIMEOUT` | The awaited thing did not happen in time | `ctl state` first, then decide to retry or report |
| `NO_WORKSPACE` | `run`/`wait --operation` without an open workspace | Open a workspace first |
| `WINDOW_BUSY` | A create batch is already running | Wait for it; never run creates in parallel |
| `ENV_NOT_READY` | ECC environment check (doctor) failed | Stop; run `ecc doctor --plain` from setup.md and report what is missing |
| `RENDERER_UNAVAILABLE` | The window is reloading or closing | Wait 3 s; `ctl windows` to confirm the window exists |
| `NOT_CONTROL_WINDOW` / `NO_WINDOW` | The control window was closed | Ask the user to reopen the GUI window |
| `DISCONNECTED_BY_USER` | The user clicked Disconnect on the banner | **Stop all actions.** Control returns only after the GUI is restarted |
| `INSTANCE_MISMATCH` | The pinned instance restarted | `ctl list` and pin the new id |
| `LIMIT_EXCEEDED` | Too many requests on one connection (>64 queued or >4096 total) | Split into several batches |
| `UNKNOWN_ACTION` / `BAD_REQUEST` | Malformed request | Fix the JSON against the table above; never retry unchanged |
| `BAD_REQUEST` "focus ... does not name a created workspace" | `create` had a `focus`, and that item failed. The real item error is hidden | Send the same create **without** `focus` to see the item's `error.code` (usually `target_exists`) |
| `COMMAND_REJECTED` | `command` outside the whitelist | Only `workspace.run`, `workspace.runStep`, `workspace.cancel` |
| `SHUTTING_DOWN` / `SHUTDOWN_IN_PROGRESS` | The GUI is quitting | Stop |

`create` item errors (`items[].status == "failed"`, code in `items[].error.code`):

| Code | Meaning | Fix |
| --- | --- | --- |
| `target_exists` | A workspace with that name already exists | Use a new `--name` |
| `project_design_conflict` | Adding a design with a different top module to an existing project | Use `--projects-dir` to create a new project |
| `project_init_conflict` | Two items try to initialize the same new project differently | Put them in separate projects or make them identical |
| `project_root_required` / `project_root_unwritable` | No usable project location | Pass a writable absolute `--projects-dir` or `--project` |
| `pdk_unknown` / `pdk_ambiguous` | The PDK id does not exist or matches several | Use `--pdk-root` |
| `unsupported_design_key` | ecc.toml has a key the create path does not accept | Remove it, or create the design another way |
| `project_init_failed` | `ecc init` or the RTL import failed for a new project | Report verbatim; check `rtl` paths and `top` in ecc.toml |
| `cleanup_failed` | A failed create could not be cleaned up | Report the path; do not delete anything yourself |
| `not_started` | An earlier item failed, so this one did not run | Fix the earlier item first |
