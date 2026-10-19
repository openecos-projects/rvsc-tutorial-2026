#!/usr/bin/env bash
# ECOS Studio nightly 工具链环境脚本（放在 nightly bundle 根目录下）
#
# 用法：
#   source ./ecos-env.sh          # 只配置当前 shell（PATH + 工具根目录 + PDK）
#   ./ecos-env.sh                 # 配置后直接启动 Studio（AppImage）
#   ./ecos-env.sh --check         # 配置 + 打印各工具自检结果
#   ./ecos-env.sh -- --no-sandbox # '--' 之后的参数透传给 Studio
#
# 脚本按自身所在目录定位 bundle，整个目录可以随意移动/重新解压。
# 可覆盖的环境变量（在 source / 执行之前设置）：
#   ECOS_BUNDLE_ROOT          显式指定 bundle 根目录（默认=脚本所在目录）
#   ECOS_LOCAL_ECC            本地 ecc checkout（自动识别 <root>、<root>/.venv/bin、<root>/bin）
#   ECOS_ECC_BIN_DIR          直接指定 ecc 可执行文件所在目录（优先级最高）
#   ECOS_USE_BUNDLE_ECC=0     不把 bundle 自带的 ecc 注入 GUI（回退到 GUI 自己的 pinned runtime）
#   ECOS_STUDIO_ARGS          Studio 附加参数（空格分隔）
#   ECOS_STUDIO_NO_SANDBOX=1  启动时追加 --no-sandbox（Electron 沙箱不可用时）
#   ECOS_STUDIO_NATIVE=1      强制原生运行 AppImage（默认在 NixOS 上走 nix run appimage-run）
#   ECOS_STUDIO_NO_EXTRACT=1  原生运行时用 FUSE 挂载（默认自解压运行，不依赖 FUSE）
#   ECOS_KEEP_NIX_LD=1        保留 dev shell 的 NIX_LD/NIX_LD_LIBRARY_PATH（默认启动时去掉）
#   ECOS_ENV_VERBOSE=1        source 时打印完整信息

# shellcheck shell=bash

_ECOS_ENV_SOURCED=0
[ "${BASH_SOURCE[0]}" != "${0}" ] && _ECOS_ENV_SOURCED=1

_ecos_env_log() { printf '[ecos-env] %s\n' "$*" >&2; }

_ecos_env_fail() {
  _ecos_env_log "错误: $*"
  if [ "$_ECOS_ENV_SOURCED" = 1 ]; then return 1; else exit 1; fi
}

_ecos_env_usage() {
  cat >&2 <<'USAGE'
ECOS Studio nightly 工具链环境脚本

  source ./ecos-env.sh          # 只配置当前 shell
  ./ecos-env.sh                 # 配置并启动 Studio
  ./ecos-env.sh --check         # 配置并自检工具
  ./ecos-env.sh -- <args...>    # 配置并启动，参数透传给 Studio

环境变量：ECOS_BUNDLE_ROOT / ECOS_LOCAL_ECC / ECOS_ECC_BIN_DIR / ECOS_USE_BUNDLE_ECC /
         ECOS_STUDIO_ARGS / ECOS_STUDIO_NO_SANDBOX / ECOS_STUDIO_NATIVE /
         ECOS_STUDIO_NO_EXTRACT / ECOS_KEEP_NIX_LD / ECOS_ENV_VERBOSE
USAGE
}

# 启动 Studio 时使用的 loader 环境：nix develop / nix-shell 里 NIX_LD 指向该
# shell 的 glibc（例如 2.40），而 bundle 里 kepler-formal 需要的 libxcrypt 是按
# 更新版本的 glibc 编译的，会报 "GLIBC_2.43 not found"。启动时把这两个变量去掉，
# 让外来二进制（kepler-formal、OSS CAD Suite）走系统 loader / appimage-run 的 FHS。
_ecos_env_launch_env() {
  if [ "${ECOS_KEEP_NIX_LD:-0}" = 1 ]; then
    env "$@"
  else
    env -u NIX_LD -u NIX_LD_LIBRARY_PATH "$@"
  fi
}

# 把目录放到变量（PATH / LD_LIBRARY_PATH）最前面，并去掉重复项。
# usage: _ecos_env_prepend <VAR_NAME> <dir>
_ecos_env_prepend() {
  local name="$1" dir="$2"
  local current="${!name:-}"
  local entry joined=""
  local oldIFS="$IFS"
  local -a kept=()
  IFS=:
  for entry in $current; do
    [ -z "$entry" ] && continue
    [ "$entry" = "$dir" ] && continue
    kept+=("$entry")
  done
  IFS="$oldIFS"
  if [ "${#kept[@]}" -gt 0 ]; then
    printf -v joined '%s:' "${kept[@]}"
    joined="${joined%:}"
  fi
  export "$name"="$dir${joined:+:$joined}"
}

# kepler-formal 缺 libcrypt.so.1（NixOS 的 loader 路径里没有）。
# 只补缺失的库，并且必须实测能跑起来才生效，避免注入不兼容的版本。
_ecos_env_fix_kepler_libs() {
  local kepler="$ECOS_BUNDLE_ROOT/kepler-formal"
  local out lib found target
  [ -x "$kepler/kepler-formal" ] || return 0
  [ -d "$kepler/lib" ] || return 0
  [ -d /nix/store ] || return 0

  # 直接按 ECC 的调用方式试跑：它会在拉起 kepler-formal 前 pop LD_LIBRARY_PATH/
  # LD_PRELOAD（只信任随附 wrapper 设置的 $SCRIPT_DIR/lib），所以缺的库必须补进
  # bundle 的 lib/ 才会生效。这里逐次解析 loader 的缺失库并重试（不用 ldd：
  # nix shell 里的 ldd 用的是 shell 自己的 glibc，会误判）。
  for _ in 1 2 3 4 5; do
    out="$(_ecos_env_launch_env -u LD_LIBRARY_PATH -u LD_PRELOAD \
      "$kepler/kepler-formal" --version 2>&1)" && return 0
    lib="$(printf '%s\n' "$out" |
      sed -n 's/.*error while loading shared libraries: \([^:]*\):.*/\1/p' | head -1)"
    [ -n "$lib" ] || break
    target="$kepler/lib/$lib"
    [ -e "$target" ] && break
    found="$(find /nix/store -maxdepth 4 -path "*/lib/$lib" -print -quit 2>/dev/null)"
    if [ -z "$found" ]; then
      _ecos_env_log "警告: 未找到 kepler-formal 需要的 $lib（可 nix-shell -p libxcrypt 提供）"
      break
    fi
    if ln -sfn "$found" "$target" 2>/dev/null; then
      _ecos_env_log "kepler-formal 链接库已补齐: $lib -> $found"
    else
      _ecos_env_log "警告: 无法写入 $target（bundle 目录只读？）"
      break
    fi
  done

  if _ecos_env_launch_env -u LD_LIBRARY_PATH -u LD_PRELOAD \
    "$kepler/kepler-formal" --version >/dev/null 2>&1; then
    return 0
  fi
  _ecos_env_log "警告: kepler-formal 仍无法运行（若在 nix shell 里，需 unset NIX_LD NIX_LD_LIBRARY_PATH）"
}

_ecos_env_resolve_ecc() {
  local root="$1" cand
  for cand in "$root" "$root/.venv/bin" "$root/bin"; do
    if [ -f "$cand/ecc" ] && [ -x "$cand/ecc" ]; then
      printf '%s' "$cand"
      return 0
    fi
  done
  return 1
}

# ECOS Studio 的 AppImage 只带了 chip-viewer-native 和 Sizer，没有 ECC。
# chip-viewer 先检查 resources/binaries/{ecc,_internal/ecc_tools_bin}，缺失后
# 才回退到 PATH；但 AppImage 内的 PATH 里也不会有 chip-viewer-native。这里把
# bundle 的 ECC 链进解包目录，让 layout 视图走 packaged 分支。
_ecos_env_patch_chip_viewer() {
  local binaries="$1/resources/binaries"
  [ -n "${_ecos_ecc_bin:-}" ] || return 0
  [ -x "$_ecos_ecc_bin/ecc" ] || return 0
  [ -d "$_ecos_ecc_bin/_internal/ecc_tools_bin" ] || return 0
  [ -d "$binaries" ] || return 0

  local patched=0
  if [ ! -e "$binaries/ecc" ]; then
    if ln -sfn "$_ecos_ecc_bin/ecc" "$binaries/ecc" 2>/dev/null; then
      patched=1
    else
      _ecos_env_log "警告: 无法写入 $binaries/ecc，layout 视图可能打不开"
    fi
  fi
  if [ ! -e "$binaries/_internal" ]; then
    if ln -sfn "$_ecos_ecc_bin/_internal" "$binaries/_internal" 2>/dev/null; then
      patched=1
    else
      _ecos_env_log "警告: 无法写入 $binaries/_internal，layout 视图可能打不开"
    fi
  fi
  [ "$patched" = 1 ] &&
    _ecos_env_log "chip viewer: 已用 bundle ECC 补齐 $binaries"
  return 0
}

# ---------------------------------------------------------------- 参数解析
_ECOS_ENV_MODE=launch
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) _ECOS_ENV_MODE=check; shift ;;
    -h|--help) _ecos_env_usage; if [ "$_ECOS_ENV_SOURCED" = 1 ]; then return 0; else exit 0; fi ;;
    --) shift; break ;;
    *) break ;;
  esac
done
_ECOS_ENV_STUDIO_ARGS=("$@")

# ---------------------------------------------------------------- bundle 定位
_ecos_env_script_dir="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ECOS_BUNDLE_ROOT="${ECOS_BUNDLE_ROOT:-$_ecos_env_script_dir}"
case "$ECOS_BUNDLE_ROOT" in
  /*) ;;
  *) _ecos_env_fail "ECOS_BUNDLE_ROOT 必须是绝对路径: $ECOS_BUNDLE_ROOT" || return 1 ;;
esac
[ -d "$ECOS_BUNDLE_ROOT" ] ||
  { _ecos_env_fail "bundle 目录不存在: $ECOS_BUNDLE_ROOT" || return 1; }

_ecos_env_missing=""
for _d in ecc ecc-sizer kepler-formal; do
  [ -d "$ECOS_BUNDLE_ROOT/$_d" ] || _ecos_env_missing="$_ecos_env_missing $_d"
done
[ -z "$_ecos_env_missing" ] ||
  { _ecos_env_fail "bundle 结构不完整，缺少:$_ecos_env_missing" || return 1; }

# ---------------------------------------------------------------- ECC 路径
_ecos_ecc_bin=""
if [ -n "${ECOS_ECC_BIN_DIR:-}" ]; then
  _ecos_ecc_bin="$ECOS_ECC_BIN_DIR"
elif [ -n "${ECOS_LOCAL_ECC:-}" ]; then
  _ecos_ecc_bin="$(_ecos_env_resolve_ecc "$ECOS_LOCAL_ECC")" ||
    { _ecos_env_fail "ECOS_LOCAL_ECC=$ECOS_LOCAL_ECC 下找不到可执行的 ecc" || return 1; }
elif [ "${ECOS_USE_BUNDLE_ECC:-1}" != "0" ] && [ -x "$ECOS_BUNDLE_ROOT/ecc/ecc" ]; then
  _ecos_ecc_bin="$ECOS_BUNDLE_ROOT/ecc"
fi
if [ -n "$_ecos_ecc_bin" ]; then
  [ -x "$_ecos_ecc_bin/ecc" ] ||
    { _ecos_env_fail "ECC 目录里没有可执行的 ecc: $_ecos_ecc_bin" || return 1; }
  export ECOS_ECC_BIN_DIR="$_ecos_ecc_bin"
fi

# ---------------------------------------------------------------- 环境变量
if [ -n "$_ecos_ecc_bin" ]; then
  _ecos_env_prepend PATH "$_ecos_ecc_bin"
elif [ -x "$ECOS_BUNDLE_ROOT/ecc/ecc" ]; then
  _ecos_env_prepend PATH "$ECOS_BUNDLE_ROOT/ecc"
fi
if [ -d "$ECOS_BUNDLE_ROOT/ecc-sizer/bin" ]; then
  _ecos_env_prepend PATH "$ECOS_BUNDLE_ROOT/ecc-sizer/bin"
  export CHIPCOMPILER_ECC_SIZER_ROOT="$ECOS_BUNDLE_ROOT/ecc-sizer"
fi
if [ -x "$ECOS_BUNDLE_ROOT/kepler-formal/kepler-formal" ]; then
  _ecos_env_prepend PATH "$ECOS_BUNDLE_ROOT/kepler-formal"
  export CHIPCOMPILER_KEPLER_FORMAL_ROOT="$ECOS_BUNDLE_ROOT/kepler-formal"
fi
if [ -d "$ECOS_BUNDLE_ROOT/pdk" ]; then
  export CHIPCOMPILER_ICS55_PDK_ROOT="$ECOS_BUNDLE_ROOT/pdk"
fi
# OSS CAD Suite installed by tools/install-ecos-nightly.sh. ECC finds yosys
# through CHIPCOMPILER_OSS_CAD_DIR; an already-set value (e.g. nix develop) wins.
if [ -z "${CHIPCOMPILER_OSS_CAD_DIR:-}" ] && [ -x "$ECOS_BUNDLE_ROOT/oss-cad-suite/bin/yosys" ]; then
  export CHIPCOMPILER_OSS_CAD_DIR="$ECOS_BUNDLE_ROOT/oss-cad-suite"
fi

_ecos_env_fix_kepler_libs

# ---------------------------------------------------------------- 契约检查
if [ -n "$_ecos_ecc_bin" ]; then
  _ecos_payload="$("$_ecos_ecc_bin/ecc" version --json 2>/dev/null)"
  _ecos_env_contract="$(printf '%s' "$_ecos_payload" |
    sed -n 's/.*"cli_contract": *\([0-9][0-9]*\).*/\1/p')"
  if [ -n "$_ecos_env_contract" ] && [ "$_ecos_env_contract" != "1" ]; then
    _ecos_env_log "警告: ecc cli_contract=$_ecos_env_contract，Studio 只支持 1，可能导致运行时不兼容"
  fi
fi

# ---------------------------------------------------------------- 输出
if [ "$_ECOS_ENV_MODE" = check ] || [ "${ECOS_ENV_VERBOSE:-0}" = 1 ]; then
  _ecos_env_log "bundle : $ECOS_BUNDLE_ROOT"
  if [ -n "$_ecos_ecc_bin" ]; then
    _ecos_env_log "ecc    : $_ecos_ecc_bin -> $("$_ecos_ecc_bin/ecc" --version 2>&1 | head -1)"
  fi
  [ -n "${CHIPCOMPILER_ICS55_PDK_ROOT:-}" ] &&
    _ecos_env_log "pdk    : $CHIPCOMPILER_ICS55_PDK_ROOT"
fi

if [ "$_ECOS_ENV_MODE" = check ]; then
  printf '\n%-8s %s\n' "tool" "status"
  printf '%-8s %s\n' "sizer" "$("$ECOS_BUNDLE_ROOT/ecc-sizer/bin/Sizer" -v 2>&1 | head -1)"
  printf '%-8s %s\n' "kepler" "$(_ecos_env_launch_env -u LD_LIBRARY_PATH -u LD_PRELOAD "$ECOS_BUNDLE_ROOT/kepler-formal/kepler-formal" --version 2>&1 | head -1)"
  if [ -x "$ECOS_BUNDLE_ROOT/ecc/ecc" ]; then
    printf '%-8s %s\n' "ecc" "$("$ECOS_BUNDLE_ROOT/ecc/ecc" version --json 2>&1 | head -1)"
  fi
  printf '%-8s %s\n' "studio" \
    "$(find "$ECOS_BUNDLE_ROOT/studio" -maxdepth 1 -name '*.AppImage' -print -quit 2>/dev/null)"
  if [ -n "${CHIPCOMPILER_OSS_CAD_DIR:-}" ] && [ -x "$CHIPCOMPILER_OSS_CAD_DIR/bin/yosys" ]; then
    printf '%-8s %s\n' "yosys" "$("$CHIPCOMPILER_OSS_CAD_DIR/bin/yosys" -V 2>&1 | head -1)"
  elif ! command -v yosys >/dev/null 2>&1; then
    _ecos_env_log "提示: 没有 yosys；跑 flow 需要 OSS CAD Suite（tools/install-ecos-nightly.sh 会装到 bundle/oss-cad-suite，或 nix develop）"
  fi
  if [ "$_ECOS_ENV_SOURCED" = 1 ]; then return 0; else exit 0; fi
fi

# ---------------------------------------------------------------- 启动 Studio
if [ "$_ECOS_ENV_SOURCED" = 1 ]; then
  [ "${ECOS_ENV_VERBOSE:-0}" = 1 ] ||
    _ecos_env_log "已配置 nightly 工具链（ecc: ${_ecos_ecc_bin:-PATH}, pdk: ${CHIPCOMPILER_ICS55_PDK_ROOT:-未设置}）"
  # 当前 shell 的 NIX_LD 仍指向 dev shell 的 glibc，手动跑 kepler-formal 会缺 GLIBC_2.43；
  # 启动 Studio 时脚本已经自动去掉这两个变量，这里只提示。
  if [ -n "${NIX_LD:-}" ] &&
    ! "$ECOS_BUNDLE_ROOT/kepler-formal/kepler-formal" --version >/dev/null 2>&1; then
    _ecos_env_log "提示: 在 dev shell 里手动跑 kepler-formal 需先 unset NIX_LD NIX_LD_LIBRARY_PATH（Studio 启动时已自动处理）"
  fi
  return 0
fi

_ecos_appimage="$(find "$ECOS_BUNDLE_ROOT/studio" -maxdepth 1 -name '*.AppImage' -print -quit 2>/dev/null)"
[ -n "$_ecos_appimage" ] || { _ecos_env_fail "studio/ 下没有 AppImage"; }
[ -x "$_ecos_appimage" ] || chmod +x "$_ecos_appimage" 2>/dev/null

# 让 GUI 会话及其子进程（kepler-formal 等）使用系统 loader。
if [ "${ECOS_KEEP_NIX_LD:-0}" != 1 ]; then
  unset NIX_LD NIX_LD_LIBRARY_PATH
fi

_ecos_extra=()
[ -n "${ECOS_STUDIO_NO_SANDBOX:-}" ] && _ecos_extra+=("--no-sandbox")
if [ -n "${ECOS_STUDIO_ARGS:-}" ]; then
  read -r -a _ecos_user_args <<<"$ECOS_STUDIO_ARGS"
  _ecos_extra+=("${_ecos_user_args[@]}")
fi

# NixOS 上 AppImage 里的 Electron 需要 /bin/bash 和一批系统库，
# 直接跑会报 AppRun 找不到或 libglib-2.0.so.0 缺失；交给 appimage-run 的 FHS 环境。
# appimage-run 按 AppImage 的 sha256 缓存在 ~/.cache/appimage-run/<sha>；先解包并补
# 上 chip viewer 需要的 ECC，再交给 appimage-run 启动（它会复用这个目录）。
if [ "${ECOS_STUDIO_NATIVE:-0}" != 1 ] && [ -d /nix/store ] && command -v nix >/dev/null 2>&1; then
  _ecos_appdir="${XDG_CACHE_HOME:-$HOME/.cache}/appimage-run/$(sha256sum "$_ecos_appimage" | awk '{print $1}')"
  if [ ! -x "$_ecos_appdir/AppRun" ]; then
    _ecos_env_log "首次启动：解包 AppImage 到 $_ecos_appdir"
    mkdir -p "$(dirname "$_ecos_appdir")"
    rm -rf "$_ecos_appdir"
    nix run nixpkgs#appimage-run -- -x "$_ecos_appdir" "$_ecos_appimage" >/dev/null ||
      _ecos_env_fail "AppImage 解包失败: $_ecos_appimage"
  fi
  _ecos_env_patch_chip_viewer "$_ecos_appdir"
  exec nix run nixpkgs#appimage-run -- "$_ecos_appimage" "${_ecos_extra[@]}" "${_ECOS_ENV_STUDIO_ARGS[@]}"
fi

# 原生路径：自己解包到缓存目录，补上 chip viewer 需要的 ECC，再跑 AppRun。
# FUSE 挂载是只读的，无法补链接；仅在显式设置 ECOS_STUDIO_NO_EXTRACT=1 时使用。
if [ "${ECOS_STUDIO_NO_EXTRACT:-0}" = 1 ] && [ -e /dev/fuse ] && [ -x /bin/bash ]; then
  _ecos_env_log "提示: FUSE 模式下无法补齐 chip viewer 的 ECC，layout 视图可能打不开"
  exec "$_ecos_appimage" "${_ecos_extra[@]}" "${_ECOS_ENV_STUDIO_ARGS[@]}"
fi

_ecos_cache_root="${XDG_CACHE_HOME:-$HOME/.cache}/ecos-studio-nightly"
_ecos_key="$(basename "$_ecos_appimage")-$(stat -c '%s-%Y' "$_ecos_appimage" 2>/dev/null | tr -d ' ')"
_ecos_appdir="$_ecos_cache_root/appdir-$_ecos_key"
if [ ! -x "$_ecos_appdir/AppRun" ]; then
  _ecos_env_log "首次运行：解包 AppImage 到 $_ecos_appdir（后续启动直接复用）"
  mkdir -p "$_ecos_cache_root"
  rm -rf "$_ecos_cache_root/.tmp-extract"
  mkdir -p "$_ecos_cache_root/.tmp-extract"
  ( cd "$_ecos_cache_root/.tmp-extract" && "$_ecos_appimage" --appimage-extract ) >/dev/null 2>&1 ||
    _ecos_env_fail "AppImage 解包失败: $_ecos_appimage"
  rm -rf "$_ecos_appdir"
  mv "$_ecos_cache_root/.tmp-extract/squashfs-root" "$_ecos_appdir" ||
    _ecos_env_fail "AppImage 解包结果不完整: $_ecos_cache_root/.tmp-extract"
fi
_ecos_env_patch_chip_viewer "$_ecos_appdir"
# AppRun 在没有 APPDIR 时会用 $1 猜目录，带参数启动会猜错，所以显式指定。
export APPDIR="$_ecos_appdir"
if [ -x /bin/bash ]; then
  exec "$_ecos_appdir/AppRun" "${_ecos_extra[@]}" "${_ECOS_ENV_STUDIO_ARGS[@]}"
fi
exec bash "$_ecos_appdir/AppRun" "${_ecos_extra[@]}" "${_ECOS_ENV_STUDIO_ARGS[@]}"
