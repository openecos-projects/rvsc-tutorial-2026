# Templates

| File                   | Use                                                                                                         |
| ---------------------- | ----------------------------------------------------------------------------------------------------------- |
| `designs.toml`         | `ctl create --script designs.toml`: create several workspaces in one call. Edit every `/abs/...` path first |
| `open-workspace.jsonl` | Open a workspace from the Projects page with a caption                                                      |
| `run-flow.jsonl`       | Click Run and wait up to 30 min, caption on screen the whole time                                           |

Replace `@WORKSPACE@` before sending a JSONL file, then pipe it to `ctl batch`:

```bash
sed 's/@WORKSPACE@/minirv_base/g' templates/open-workspace.jsonl | scripts/ctl batch
```

Check the output line by line. The batch stops at the first error, and the
last line is that error. If `open-workspace.jsonl` fails with `TIMEOUT` on the
route, or `run-flow.jsonl` fails with `TARGET_OBSCURED`, wait 3 seconds and
send the same file again (known issues GUI-3 and GUI-4). Before resending
`run-flow.jsonl`, check `ctl state`: if `flow.running` is already set, only
send the last `waitFor` line, otherwise you start a second run.
