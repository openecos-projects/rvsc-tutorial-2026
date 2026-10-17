# Environment setup

Do these checks in order. If a check fails, stop and report it; do not work
around it silently.

## 1. Versions that work together

| Component                | Required                                         | Known-good source (2026-10-17)                                                                     |
| ------------------------ | ------------------------------------------------ | -------------------------------------------------------------------------------------------------- |
| ECOS Studio GUI          | A build that has `--enable-ctrl`                 | ecos-studio branch `yell/refactor_gui_cli`, at or after `b9f2c885` (persistent control banner)     |
| ECC CLI                  | `ecc version --json` reports `"cli_contract": 1` | CI artifact `ecc-cli-linux-x86_64` of the ecc branch `emin/add-agent-ctrl` (run 38890117759)       |
| ecc-sizer, kepler-formal | Any recent build                                 | `ecc-sizer/` and `kepler-formal/` from the ecos-installer nightly bundle `v0.1.0-nightly.20261015` |
| ICS55 PDK                | Assembled PDK directory                          | `pdk/` from the same nightly bundle                                                                |
| yosys (with slang)       | On `PATH`                                        | nixpkgs `yosys`, or OSS CAD Suite                                                                  |

Things that do **not** work:

- The ECC inside the nightly bundle `v0.1.0-nightly.20261015` reports
  `"schema_version": 1` and no `cli_contract`. The GUI refuses it
  (`Installed ECC does not support CLI contract 1`), and `create` fails.
- The ecos-studio and ecc revisions pinned in this repository's `flake.nix`
  (default branches) do not have `--enable-ctrl` / `cli_contract`. Changing
  the flake inputs is the repository owner's decision; ask before editing.

Download the ECC CI artifact (needs `gh` and repository access):

```bash
mkdir -p /abs/ecc-ci && cd /abs/ecc-ci
gh run download 38890117759 -R openecos-projects/ecc -n ecc-cli-linux-x86_64 -D .
mkdir -p bundle && tar -xf ecc.tar -C bundle      # gives bundle/ecc and bundle/_internal
```

The artifact is ~570 MB and can download slowly (~200 KiB/s observed); start
it early.

## 2. ECC environment variables

The GUI finds ECC through these variables. Set them in the shell that
**launches the GUI**:

```bash
export ECOS_ECC_BIN_DIR=/abs/ecc-ci/bundle                      # directory that contains `ecc`
export CHIPCOMPILER_ECC_SIZER_ROOT=/abs/nightly/ecc-sizer       # contains bin/Sizer
export CHIPCOMPILER_KEPLER_FORMAL_ROOT=/abs/nightly/kepler-formal
```

`ECOS_ECC_BIN_DIR` points to a directory, not to the binary. The external ECC
is used read-only; the GUI does not install or repair it.

Check it before starting the GUI:

```bash
"$ECOS_ECC_BIN_DIR/ecc" version --json      # must contain "cli_contract": 1
"$ECOS_ECC_BIN_DIR/ecc" doctor --plain      # first line must contain status=ok
```

Expected `doctor` output (abridged):

```
doctor=environment status=ok checked=9 failed=0 attention=0 run="ecc run"
component=yosys status=pass ...
component=ecc-tools status=pass ...
component=dreamplace status=pass ...
component=sizer status=pass ...
component=kepler-formal status=pass ...
component=pdk status=skip ... (normal outside a project)
```

If `dreamplace` fails with `libxcb.so.1` or `cairo-2` errors, see section 5.

## 3. Start the GUI with control enabled

Packaged build:

```bash
ecos-studio --enable-ctrl --ctrl-label demo
```

Development build of the ecos-studio repository:

```bash
cd /abs/ecos-studio/ecos/gui && pnpm run desktop:build
mkdir -p /abs/ctrl-app
cat > /abs/ctrl-app/package.json <<'EOF'
{"main":"/abs/ecos-studio/ecos/gui/apps/desktop-electron/dist/main/index.js","name":"ecos-ctrl-demo","type":"module"}
EOF
electron /abs/ctrl-app --enable-ctrl --ctrl-label demo
```

The GUI log shows `[ctrl] Control socket: ... (instance <id>)` when control is
on. An orange/grey pill banner at the top of the window ("External control
enabled · instance <id> (demo)") confirms it visually.

Only one GUI per user data directory can run with control. A second launch
with `--enable-ctrl` prints a hint and quits.

Optional: isolate the GUI's settings from the user's real profile by
exporting separate `XDG_CONFIG_HOME`, `XDG_DATA_HOME`, `XDG_CACHE_HOME` and
`XDG_STATE_HOME` before launching. The client must then use the same values
(section 4).

## 4. Point the client at the GUI

`scripts/ctl` runs `$ECOS_CTRL_CMD --ctrl ...` (default `ecos-studio`):

```bash
export ECOS_CTRL_CMD="ecos-studio"                         # packaged
export ECOS_CTRL_CMD="electron /abs/ctrl-app"              # development build (same app dir as the GUI)
```

The client finds the GUI's default socket through the same environment as the
GUI: `XDG_RUNTIME_DIR` (socket directory) and `XDG_CONFIG_HOME` (user data).
If the client runs with different values it exits 3 and lists the live
instances. Then either run the client with the GUI's environment, or pin the
instance:

```bash
ctl list                                   # shows instanceId and label
export ECOS_CTRL_INSTANCE=<instanceId>     # pin by id, not by label
```

## 5. NixOS specifics

- The Electron binary that npm downloads cannot start on NixOS (missing
  `libglib-2.0.so.0`). Use nixpkgs `electron` for development builds.
- The ECC PyInstaller bundle expects `libxcb.so.1` and `libfontconfig.so.1`
  from the host. NixOS does not provide them on the default library path, so
  `ecc doctor` reports `dreamplace: import failed - libxcb.so.1` and later
  `no library called "cairo-2"`. Wrap ECC:

  ```bash
  XCB=$(nix build --no-link --print-out-paths 'nixpkgs#xorg.libxcb.out')
  FC=$(nix build --no-link --print-out-paths 'nixpkgs#fontconfig.lib')
  mkdir -p /abs/ecc-wrap
  cat > /abs/ecc-wrap/ecc <<EOF
  #!/usr/bin/env bash
  export LD_LIBRARY_PATH=$XCB/lib:$FC/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
  exec /abs/ecc-ci/bundle/ecc "\$@"
  EOF
  chmod +x /abs/ecc-wrap/ecc
  export ECOS_ECC_BIN_DIR=/abs/ecc-wrap
  ```

  Minimal containers and headless servers without X libraries hit the same
  problem (known issue ECC-5).

- `kepler-formal` (post-route LEC) needs `libcrypt.so.1` (known issue
  ECC-9). Build a kepler root whose `bin/kepler-formal` adds it:

  ```bash
  K=/abs/nightly/kepler-formal
  X=$(nix build --no-link --print-out-paths 'nixpkgs#libxcrypt-legacy.out')
  mkdir -p /abs/kepler/bin
  for f in "$K"/*; do [ "$(basename "$f")" = bin ] || ln -sfn "$f" /abs/kepler/; done
  cat > /abs/kepler/bin/kepler-formal <<EOF
  #!/usr/bin/env bash
  export LD_LIBRARY_PATH=$X/lib:$K/lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
  exec $K/bin/kepler-formal "\$@"
  EOF
  chmod +x /abs/kepler/bin/kepler-formal
  export CHIPCOMPILER_KEPLER_FORMAL_ROOT=/abs/kepler
  ```

- The dev build also has a `--cli ecc` entry. It runs the same ECC as the
  ctrl GUI, so workspaces it creates can be opened by that GUI (warning 14):
  `electron /abs/ctrl-app --cli ecc run ...` with the same environment
  variables as the GUI.

## 6. Final checklist

```bash
ctl list          # one instance with your label
ctl windows       # returns in well under a second
ctl state         # "toolchain":{"status":"ready"}, returns in about a second
```

If `ctl windows` is fast but `ctl state` takes more than 10 seconds, the GUI
is in the slow state described in known issue GUI-6; restarting the GUI
cleared it.
