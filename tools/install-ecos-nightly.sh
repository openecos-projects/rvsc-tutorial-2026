#!/usr/bin/env bash
# Install the ECOS nightly toolchain used in the RVSC 2026 tutorial.
#
#   tools/install-ecos-nightly.sh [--dir DIR] [--tarball FILE] [--force]
#
# Downloads the v0.1.0-nightly.20261013 bundle from this repository's release
# (a copy of the ecos-installer release), checks its SHA-256, extracts it, and
# patches three gaps of this nightly:
#   - pdk/techfile/icsprout55.layermap is missing, so pre_floorplan fails with
#     "gds_save requires -layer_map <path>". It is fetched from the PDK commit
#     that added it (a direct descendant of the bundle's PDK commit).
#   - the bundle has no yosys. OSS CAD Suite (yosys + slang) is downloaded into
#     <bundle>/oss-cad-suite; ecos-env.sh points ECC at it.
#   - the bundle has no environment script; tools/ecos-env.sh is copied in.
# Then it runs `ecos-env.sh --check`.
#
# On NixOS, run ECC inside `nix develop` from this repository: it provides the
# host libraries the prebuilt binaries expect (xcb, fontconfig, libcrypt).
set -euo pipefail

# The tutorial repo re-publishes the ecos-installer v0.1.0-nightly.20261013
# bundle as its own release asset. While that release is not reachable (the
# repo is still private), the download falls back to the original ecos-installer
# release, which has the same bytes. Override any of these from the environment.
TAG="${ECOS_RELEASE_TAG:-v0.1.0-nightly.20261013}"
ASSET="${ECOS_RELEASE_ASSET:-ecos-nightly-linux-x86_64.tar.gz}"
REPO="${ECOS_RELEASE_REPO:-openecos-projects/rvsc-tutorial-2026}"
URL="${ECOS_RELEASE_URL:-https://github.com/${REPO}/releases/download/${TAG}/${ASSET}}"
FALLBACK_URL="https://github.com/openecos-projects/ecos-installer/releases/download/${TAG}/${ASSET}"
# SHA-256 of ecos-installer's v0.1.0-nightly.20261013 asset; the re-published
# copy must be byte-identical.
SHA256="${ECOS_RELEASE_SHA256:-36d3020b6081ed0ce0c5613680e6ae4efea7550c9179a830a549d50722e57ade}"
# OSS CAD Suite (yosys with the slang frontend); the nightly bundle ships none.
OSS_CAD_RELEASE="2026-10-19"
OSS_CAD_ASSET="oss-cad-suite-linux-x64-20261019.tgz"
OSS_CAD_URL="https://github.com/YosysHQ/oss-cad-suite-build/releases/download/${OSS_CAD_RELEASE}/${OSS_CAD_ASSET}"
OSS_CAD_SHA256="ed9cbe56ed516bce72e97ccde489ab2be8d56a6a7f51068660e005b783b1c72f"
# icsprout55-pdk commit "feat: add ICsprout55 GDS layer map"
LAYERMAP_URL="https://raw.githubusercontent.com/openecos-projects/icsprout55-pdk/0a2ee73001ce1e7168b1e2779985875ef0c6ad00/techfile/icsprout55.layermap"
LAYERMAP_SHA256="513a9aefb48de2b3eadec1dd2fa1fb1c84bb0460cf40bf32cc56797b86a8b05d"

HERE="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DIR="${HERE}/../ecos-nightly"
TARBALL=""
FORCE=0

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//' >&2; }
log() { printf '[install] %s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    --tarball) TARBALL="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown option: $1" ;;
  esac
done

[ "$(uname -s)-$(uname -m)" = "Linux-x86_64" ] || die "only Linux x86_64 is supported"
for cmd in curl tar sha256sum; do
  command -v "$cmd" >/dev/null 2>&1 || die "missing command: $cmd"
done

mkdir -p "$DIR"
DIR="$(cd -P -- "$DIR" && pwd)"
ROOT="$DIR/ecos-nightly-linux-x86_64"

if [ -d "$ROOT" ] && [ "$FORCE" != 1 ]; then
  log "already installed at $ROOT (use --force to reinstall)"
else
  if [ -z "$TARBALL" ]; then
    TARBALL="$DIR/$ASSET"
    if [ -f "$TARBALL" ] && echo "$SHA256  $TARBALL" | sha256sum -c --status; then
      log "reusing downloaded $TARBALL"
    else
      downloaded=0
      for src in "$URL" "$FALLBACK_URL"; do
        # A missing asset (404, e.g. the repo is still private) skips to the
        # next source right away; only real transfer errors are retried.
        code="$(curl -sIL -o /dev/null -w '%{http_code}' --max-time 30 "$src" || true)"
        if [ "$code" = 404 ]; then
          log "not available (HTTP 404): $src"
          continue
        fi
        log "downloading $src (about 1.2 GB)"
        if curl -fL --retry 5 --retry-all-errors -C - -o "$TARBALL.part" "$src"; then
          downloaded=1
          break
        fi
        log "not available: $src"
        rm -f "$TARBALL.part"   # do not resume one source's error page onto another
      done
      [ "$downloaded" = 1 ] || die "download failed from every source"
      mv "$TARBALL.part" "$TARBALL"
    fi
  fi
  log "checking SHA-256"
  echo "$SHA256  $TARBALL" | sha256sum -c --status || die "checksum mismatch: $TARBALL"

  rm -rf "$ROOT"
  log "extracting to $DIR"
  tar -xzf "$TARBALL" -C "$DIR"
  [ -x "$ROOT/ecc/ecc" ] || die "unexpected archive layout: $ROOT/ecc/ecc not found"
fi

# Patch 1: GDS layer map.
# (the extracted bundle is already in place at this point)
LAYERMAP="$ROOT/pdk/techfile/icsprout55.layermap"
if [ -f "$LAYERMAP" ] && echo "$LAYERMAP_SHA256  $LAYERMAP" | sha256sum -c --status; then
  log "layer map already present"
else
  log "adding pdk/techfile/icsprout55.layermap"
  mkdir -p "$(dirname "$LAYERMAP")"
  curl -fsSL --retry 5 --retry-all-errors -o "$LAYERMAP.part" "$LAYERMAP_URL"
  echo "$LAYERMAP_SHA256  $LAYERMAP.part" | sha256sum -c --status ||
    { rm -f "$LAYERMAP.part"; die "layer map checksum mismatch"; }
  mv "$LAYERMAP.part" "$LAYERMAP"
fi

# Patch 2: yosys (OSS CAD Suite) into <bundle>/oss-cad-suite.
OSS_CAD="$ROOT/oss-cad-suite"
if [ -x "$OSS_CAD/bin/yosys" ] && [ "$(cat "$OSS_CAD/.ecos-release" 2>/dev/null)" = "$OSS_CAD_RELEASE" ]; then
  log "OSS CAD Suite $OSS_CAD_RELEASE already present"
else
  OSS_TARBALL="${OSS_CAD_TARBALL:-$DIR/$OSS_CAD_ASSET}"
  if [ -f "$OSS_TARBALL" ] && echo "$OSS_CAD_SHA256  $OSS_TARBALL" | sha256sum -c --status; then
    log "reusing downloaded $OSS_TARBALL"
  else
    log "downloading OSS CAD Suite $OSS_CAD_RELEASE (about 750 MB)"
    curl -fL --retry 5 --retry-all-errors -C - -o "$OSS_TARBALL.part" "$OSS_CAD_URL"
    mv "$OSS_TARBALL.part" "$OSS_TARBALL"
  fi
  echo "$OSS_CAD_SHA256  $OSS_TARBALL" | sha256sum -c --status ||
    die "OSS CAD Suite checksum mismatch: $OSS_TARBALL"
  log "extracting OSS CAD Suite to $OSS_CAD"
  rm -rf "$OSS_CAD"
  tar -xzf "$OSS_TARBALL" -C "$ROOT"   # the archive's top-level directory is oss-cad-suite/
  [ -x "$OSS_CAD/bin/yosys" ] || die "unexpected OSS CAD Suite layout: $OSS_CAD/bin/yosys not found"
  printf '%s\n' "$OSS_CAD_RELEASE" > "$OSS_CAD/.ecos-release"
fi

# Patch 3: environment script.
install -m 0755 "$HERE/ecos-env.sh" "$ROOT/ecos-env.sh"
log "installed $ROOT/ecos-env.sh"

log "self-check:"
"$ROOT/ecos-env.sh" --check || log "warning: self-check reported problems (see above)"

cat >&2 <<EOF

[install] done. Next:
  source "$ROOT/ecos-env.sh"     # ecc, yosys, Sizer, kepler-formal and the PDK on this shell
  "$ROOT/ecos-env.sh"            # start ECOS Studio
On NixOS, run these inside \`nix develop\` (it provides the missing host libraries).
EOF
