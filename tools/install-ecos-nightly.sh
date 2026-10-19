#!/usr/bin/env bash
# Install the ECOS nightly toolchain used in the RVSC 2026 tutorial.
#
#   tools/install-ecos-nightly.sh [--dir DIR] [--tarball FILE] [--force] [--mirror]
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
# --mirror downloads everything from the CNB mirrors under
# https://cnb.cool/ecoslab/ instead of GitHub (useful when GitHub is slow or
# blocked). The OSS CAD Suite mirror can lag a day behind the pinned build; in
# that case the newest Linux x64 build the mirror has is used, with the SHA-256
# published in the mirror's release metadata.
#
# On NixOS, run ECC inside `nix develop` from this repository: it provides the
# host libraries the prebuilt binaries expect (xcb, fontconfig, libcrypt).
set -euo pipefail

# The tutorial repo re-publishes the ecos-installer v0.1.0-nightly.20261013
# bundle as its own release asset. While that release is not reachable (the
# repo is still private), the download falls back to the original ecos-installer
# release, which has the same bytes. Override any of these from the environment.
#
# CNB mirror origin (https://cnb.cool/ecoslab/...); --mirror uses these instead
# of GitHub for every download in this script.
MIRROR_ORIGIN="https://cnb.cool"

TAG="${ECOS_RELEASE_TAG:-v0.1.0-nightly.20261013}"
ASSET="${ECOS_RELEASE_ASSET:-ecos-nightly-linux-x86_64.tar.gz}"
REPO="${ECOS_RELEASE_REPO:-openecos-projects/rvsc-tutorial-2026}"
URL="${ECOS_RELEASE_URL:-https://github.com/${REPO}/releases/download/${TAG}/${ASSET}}"
MIRROR_ECOS_URL="${MIRROR_ORIGIN}/ecoslab/ecos-installer/-/releases/download/${TAG}/${ASSET}"
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
LAYERMAP_COMMIT="0a2ee73001ce1e7168b1e2779985875ef0c6ad00"
LAYERMAP_URL="${ECOS_LAYERMAP_URL:-https://raw.githubusercontent.com/openecos-projects/icsprout55-pdk/${LAYERMAP_COMMIT}/techfile/icsprout55.layermap}"
MIRROR_LAYERMAP_URL="${MIRROR_ORIGIN}/ecoslab/icsprout55-pdk/-/git/raw/${LAYERMAP_COMMIT}/techfile/icsprout55.layermap"
LAYERMAP_SHA256="513a9aefb48de2b3eadec1dd2fa1fb1c84bb0460cf40bf32cc56797b86a8b05d"

HERE="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DIR="${HERE}/../ecos-nightly"
TARBALL=""
FORCE=0
MIRROR=0

usage() {
  cat >&2 <<'USAGE'
Install the ECOS nightly toolchain used in the RVSC 2026 tutorial.

  tools/install-ecos-nightly.sh [--dir DIR] [--tarball FILE] [--force] [--mirror]

  --dir DIR        install directory (default: <repo>/ecos-nightly)
  --tarball FILE   use an already downloaded bundle tarball
  --force          reinstall even if the bundle directory exists
  --mirror         download from the CNB mirrors instead of GitHub:
                   https://cnb.cool/ecoslab/ecos-installer/-/releases
                   https://cnb.cool/ecoslab/oss-cad-suite-build
                   https://cnb.cool/ecoslab/icsprout55-pdk (layer map)
USAGE
}
log() { printf '[install] %s\n' "$*" >&2; }
die() { log "error: $*"; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir) DIR="$2"; shift 2 ;;
    --tarball) TARBALL="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --mirror) MIRROR=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "unknown option: $1" ;;
  esac
done

if [ "$MIRROR" = 1 ]; then
  # An explicit ECOS_RELEASE_URL / ECOS_LAYERMAP_URL still wins over --mirror.
  if [ -z "${ECOS_RELEASE_URL:-}" ]; then
    URL="$MIRROR_ECOS_URL"
  fi
  FALLBACK_URL=""   # the mirror is the only source in mirror mode
  if [ -z "${ECOS_LAYERMAP_URL:-}" ]; then
    LAYERMAP_URL="$MIRROR_LAYERMAP_URL"
  fi
fi

# The CNB mirror lags behind GitHub for the daily OSS CAD Suite builds. In
# --mirror mode, use the pinned release when the mirror already has it;
# otherwise take the newest linux-x64 asset from the mirror's release list and
# the SHA-256 the mirror publishes for it.
resolve_mirror_oss_cad() {
  local pinned code releases page path sha re
  pinned="${MIRROR_ORIGIN}/ecoslab/oss-cad-suite-build/-/releases/download/${OSS_CAD_RELEASE}/${OSS_CAD_ASSET}"
  code="$(curl -sIL -o /dev/null -w '%{http_code}' --max-time 30 "$pinned" || true)"
  if [ "$code" = 200 ]; then
    OSS_CAD_URL="$pinned"
    log "using mirror OSS CAD Suite $OSS_CAD_RELEASE"
    return 0
  fi

  releases="${MIRROR_ORIGIN}/ecoslab/oss-cad-suite-build/-/releases"
  log "mirror has no OSS CAD Suite $OSS_CAD_RELEASE; looking for the newest build"
  page="$(curl -fsSL --retry 3 --retry-all-errors --max-time 60 "$releases")" ||
    die "cannot read the mirror's release list: $releases"
  # The releases page embeds its metadata as JSON, newest release first.
  re='"path":"([^"]*oss-cad-suite-linux-x64-[0-9]+\.tgz)","name":"[^"]*","content_type":"application/gzip","hash_algo":"sha256","hash_value":"([0-9a-f]{64})"'
  [[ $page =~ $re ]] || die "no linux-x64 OSS CAD Suite asset on the mirror: $releases"
  path="${BASH_REMATCH[1]}"
  sha="${BASH_REMATCH[2]}"

  OSS_CAD_ASSET="${path##*/}"
  OSS_CAD_RELEASE="${path%/*}"; OSS_CAD_RELEASE="${OSS_CAD_RELEASE##*/}"
  OSS_CAD_URL="${MIRROR_ORIGIN}${path}"
  OSS_CAD_SHA256="$sha"
  log "using mirror OSS CAD Suite $OSS_CAD_RELEASE ($OSS_CAD_ASSET)"
}

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
      SOURCES=("$URL")
      if [ -n "$FALLBACK_URL" ]; then
        SOURCES+=("$FALLBACK_URL")
      fi
      downloaded=0
      for src in "${SOURCES[@]}"; do
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
installed_release="$(cat "$OSS_CAD/.ecos-release" 2>/dev/null || true)"
# In mirror mode the mirror decides which daily build is available; keep an
# existing installation instead of re-downloading 750 MB whenever it moves on.
if [ -x "$OSS_CAD/bin/yosys" ] && [ -n "$installed_release" ] &&
  { [ "$MIRROR" = 1 ] || [ "$installed_release" = "$OSS_CAD_RELEASE" ]; }; then
  log "OSS CAD Suite $installed_release already present"
else
  if [ "$MIRROR" = 1 ]; then
    resolve_mirror_oss_cad
  fi
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
