#!/usr/bin/env bash
# Skate 2 PC - Linux entry point.
#
# Linux counterpart of the Windows PowerShell/CMD scripts. The game runs
# natively on Linux: ReXGlue's recompiled CPU code plus its Vulkan GPU backend
# (Xenos -> SPIR-V). No Wine/Proton is involved.
#
#   ./skate2.sh deps                 Install build dependencies (Debian/Ubuntu/Fedora/Arch)
#   ./skate2.sh bootstrap            Fetch the pinned ReXGlue SDK source
#   ./skate2.sh import <folder>      Copy and verify your extracted game into game/
#   ./skate2.sh build [options]      Patch + build SDK, generate code, build skate2
#   ./skate2.sh launch [options]     Start the game (default: 2x quality, unlimited FPS)
#
# Run "./skate2.sh help" for all options.

set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SDK_SOURCE="$ROOT/tools/rexglue-sdk-source"
SDK_REVISION="f5337cdc947ff6d4c4196737e2c807a48f2a1fc2"
SDK_REPOSITORY="https://github.com/rexglue/rexglue-sdk.git"
SDK_PRESET="linux-amd64"
SDK_INSTALL="$SDK_SOURCE/out/install/$SDK_PRESET"
PROJECT_ROOT="$ROOT/skate2"
APP_PRESET="linux-amd64-release"
MANIFEST="$PROJECT_ROOT/skate2_manifest.toml"
GAME_ROOT="$ROOT/game"
EXPECTED_XEX_SHA256="116ba3ee37fcf0d8db60b7d47c971fdb6d3eb2a7a4d3cfc3611a06704a588ae5"

# Same order as scripts/Build-Skate2.ps1, followed by the Linux/Vulkan ports
# of the two D3D12-only graphics fixes.
SDK_PATCHES=(
  rexglue-0.10.0-windows-build.patch
  rexglue-0.10.0-float16-pack.patch
  rexglue-0.10.0-input-diagnostics.patch
  rexglue-0.10.0-input-synchronization.patch
  rexglue-0.10.0-audio-output.patch
  rexglue-0.10.0-cvar-toml-escaping.patch
  rexglue-0.10.0-release-perf-counters.patch
  rexglue-0.10.0-live-frame-capture.patch
  rexglue-0.10.0-cvar-validator.patch
  rexglue-0.10.0-vertex-buffer-coherency.patch
  rexglue-0.10.0-present-idleclean-diagnostic.patch
  rexglue-0.10.0-vulkan-vertex-buffer-coherency.patch
  rexglue-0.10.0-vulkan-present-idleclean.patch
)

# Runtime + codegen + Vulkan dependencies only (no MoltenVK, tests or Tracy).
SDK_SUBMODULES=(cli11 libmspack FFmpeg tomlplusplus simde xxHash spdlog fmt utfcpp
  imgui sdl3 o1heap inja vulkan-headers vulkan-memory-allocator spirv-headers
  spirv-tools glslang)

die() { printf '\e[31mSkate 2: %s\e[0m\n' "$*" >&2; exit 1; }
info() { printf '\e[36m==>\e[0m %s\n' "$*"; }

sha256_of() { sha256sum -- "$1" | cut -d' ' -f1; }

clang_major() { "$1" --version 2>/dev/null | sed -nE 's/.*clang version ([0-9]+).*/\1/p' | head -1; }

select_compilers() {
  # LLVM 20 or later is required (C++23, matching the Windows toolchain).
  for v in 22 21 20; do
    if command -v "clang-$v" >/dev/null && command -v "clang++-$v" >/dev/null; then
      CC_BIN="clang-$v"; CXX_BIN="clang++-$v"; return 0
    fi
  done
  if command -v clang >/dev/null && command -v clang++ >/dev/null; then
    local major; major="$(clang_major clang)"
    if [[ -n "$major" && "$major" -ge 20 ]]; then CC_BIN=clang; CXX_BIN=clang++; return 0; fi
  fi
  die "Clang 20 or later is required. Run './skate2.sh deps' or install clang-20 from your distribution / apt.llvm.org."
}

check_build_tools() {
  local t
  for t in git cmake ninja pkg-config; do
    command -v "$t" >/dev/null || die "'$t' is missing. Run './skate2.sh deps' first."
  done
  local cmake_version
  cmake_version="$(cmake --version | sed -nE 's/cmake version ([0-9]+\.[0-9]+).*/\1/p')"
  if [[ "$(printf '%s\n3.25\n' "$cmake_version" | sort -V | head -1)" != "3.25" ]]; then
    die "CMake 3.25 or later is required (found $cmake_version)."
  fi
  select_compilers
}

# ---------------------------------------------------------------------------
cmd_deps() {
  local sudo=""
  [[ $EUID -ne 0 ]] && sudo="sudo"
  if command -v apt-get >/dev/null; then
    local clang_pkgs="clang-20 lld-20"
    if ! apt-cache show clang-20 >/dev/null 2>&1; then
      die "clang-20 is not in your apt sources. Add https://apt.llvm.org (./llvm.sh 20) and re-run."
    fi
    $sudo apt-get update
    # shellcheck disable=SC2086
    $sudo apt-get install -y git cmake ninja-build pkg-config build-essential autoconf python3 \
      $clang_pkgs \
      libgtk-3-dev libx11-dev libx11-xcb-dev libxss-dev libxext-dev libxrandr-dev libxcursor-dev \
      libxi-dev libxinerama-dev libxkbcommon-dev libwayland-dev libwayland-bin wayland-protocols \
      libdecor-0-dev libasound2-dev libpulse-dev libpipewire-0.3-dev libudev-dev libdbus-1-dev \
      libdrm-dev libgbm-dev libegl-dev libvulkan-dev vulkan-tools
  elif command -v dnf >/dev/null; then
    $sudo dnf install -y git cmake ninja-build pkgconf-pkg-config gcc-c++ autoconf python3 \
      clang lld gtk3-devel libX11-devel libXScrnSaver-devel libXext-devel libXrandr-devel \
      libXcursor-devel libXi-devel libXinerama-devel libxkbcommon-devel wayland-devel \
      wayland-protocols-devel libdecor-devel alsa-lib-devel pulseaudio-libs-devel \
      pipewire-devel systemd-devel dbus-devel libdrm-devel mesa-libgbm-devel \
      mesa-libEGL-devel vulkan-loader-devel vulkan-tools
  elif command -v pacman >/dev/null; then
    $sudo pacman -S --needed git cmake ninja pkgconf base-devel python clang lld gtk3 libx11 \
      libxss libxext libxrandr libxcursor libxi libxinerama libxkbcommon wayland \
      wayland-protocols libdecor alsa-lib libpulse pipewire systemd-libs dbus libdrm mesa \
      vulkan-icd-loader vulkan-headers vulkan-tools
  else
    die "Unknown package manager. Install the packages listed in docs/LINUX.md manually."
  fi
  info "Dependencies installed. A Vulkan driver for your GPU (Mesa RADV/ANV or NVIDIA) is also required to play."
}

# ---------------------------------------------------------------------------
cmd_bootstrap() {
  command -v git >/dev/null || die "git is missing. Run './skate2.sh deps' first."
  if [[ -d "$SDK_SOURCE" ]]; then
    local top actual
    top="$(git -C "$SDK_SOURCE" rev-parse --show-toplevel 2>/dev/null || true)"
    [[ "$(readlink -f "$top")" == "$(readlink -f "$SDK_SOURCE")" ]] ||
      die "Existing SDK directory is not its own Git checkout. It was not changed."
    actual="$(git -C "$SDK_SOURCE" rev-parse HEAD)"
    if [[ "$actual" != "$SDK_REVISION" ]]; then
      # Allow a checkout whose only local commits sit on top of the pinned revision.
      git -C "$SDK_SOURCE" merge-base --is-ancestor "$SDK_REVISION" HEAD 2>/dev/null ||
        die "Existing SDK checkout is not the pinned revision. It was not reset."
    fi
    info "Pinned SDK source is already present; local patches are preserved."
  else
    mkdir -p "$ROOT/tools"
    # Source only. Never download or execute an SDK binary release.
    git clone --branch v0.10.0 --depth 1 --no-checkout "$SDK_REPOSITORY" "$SDK_SOURCE"
    [[ "$(git -C "$SDK_SOURCE" rev-parse HEAD)" == "$SDK_REVISION" ]] ||
      die "Upstream tag does not match the pinned revision. Checkout was left for inspection."
    git -C "$SDK_SOURCE" checkout --detach "$SDK_REVISION"
  fi
  local paths=()
  local m
  for m in "${SDK_SUBMODULES[@]}"; do paths+=("thirdparty/$m"); done
  git -C "$SDK_SOURCE" submodule update --init --recursive --depth 1 --jobs 4 -- "${paths[@]}"
  info "SDK source is ready. Next: './skate2.sh import <folder>' and './skate2.sh build'."
}

# ---------------------------------------------------------------------------
verify_xex() {
  local xex="$1"
  [[ -f "$xex" ]] || die "default.xex not found at $xex"
  [[ "$(sha256_of "$xex")" == "$EXPECTED_XEX_SHA256" ]] ||
    die "Unsupported game executable. See docs/INSTALL.md for the required revision and SHA-256."
}

cmd_import() {
  local source="${1:-}"
  if [[ -z "$source" ]]; then
    if command -v zenity >/dev/null && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
      source="$(zenity --file-selection --directory \
        --title='Select your extracted Skate 2 folder containing default.xex and data' || true)"
      [[ -n "$source" ]] || exit 0
    else
      die "Usage: ./skate2.sh import <extracted game folder containing default.xex and data>"
    fi
  fi
  source="$(readlink -f -- "$source")"
  [[ -d "$GAME_ROOT" || -e "$GAME_ROOT" ]] &&
    die "The game folder already exists. Import never overwrites an existing installation."
  [[ -f "$source/default.xex" && -d "$source/data" ]] ||
    die "Select the extracted folder containing default.xex and data, not its parent or an ISO/archive."
  verify_xex "$source/default.xex"
  if [[ -n "$(find "$source" -type l -print -quit)" ]]; then
    die "The source contains links. Import requires ordinary extracted files."
  fi

  # Stage beside the destination; an interrupted import never looks complete.
  local staging
  staging="$(mktemp -d "$ROOT/game-import-XXXXXXXX")"
  trap 'printf "Import incomplete. The partial copy is preserved at %s. Original files were not changed.\n" "$staging" >&2' ERR
  info "Copying game files..."
  cp -a -- "$source/." "$staging/"
  info "Verifying copied files..."
  (cd "$source" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$staging.src.sha256"
  (cd "$staging" && sha256sum --quiet -c "$staging.src.sha256") || die "Copy verification failed."
  rm -f "$staging.src.sha256"
  verify_xex "$staging/default.xex"
  [[ -e "$GAME_ROOT" ]] && die "Another import created game while this import was running."
  mv -T -- "$staging" "$GAME_ROOT"
  trap - ERR
  info "Game files imported and verified. Next: './skate2.sh build' (or './skate2.sh launch' for a built package)."
}

# ---------------------------------------------------------------------------
apply_sdk_patches() {
  local name patch
  for name in "${SDK_PATCHES[@]}"; do
    patch="$ROOT/patches/$name"
    [[ -f "$patch" ]] || die "Missing SDK patch $name"
    if git -C "$SDK_SOURCE" apply --reverse --check "$patch" 2>/dev/null; then
      continue  # already applied
    fi
    git -C "$SDK_SOURCE" apply --check "$patch" || die "SDK patch $name does not apply."
    git -C "$SDK_SOURCE" apply "$patch"
    info "Applied $name"
  done
}

cmd_build() {
  local stage=all jobs="" perf=OFF game_dir=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --stage) stage="${2,,}"; shift 2 ;;
      --stage=*) stage="${1#*=}"; stage="${stage,,}"; shift ;;
      -j|--jobs) jobs="$2"; shift 2 ;;
      --jobs=*) jobs="${1#*=}"; shift ;;
      --performance-counters) perf=ON; shift ;;
      --game-directory) game_dir="$2"; shift 2 ;;
      *) die "Unknown build option: $1" ;;
    esac
  done
  [[ "$stage" =~ ^(all|sdk|generate|build)$ ]] || die "--stage must be all, sdk, generate or build."
  [[ -z "$jobs" ]] && jobs="$(( $(nproc) > 4 ? 4 : $(nproc) ))"
  [[ "$jobs" =~ ^[0-9]+$ && "$jobs" -ge 1 ]] || die "--jobs must be a positive number."

  check_build_tools
  [[ -d "$SDK_SOURCE" ]] || die "SDK source is missing. Run './skate2.sh bootstrap' first."
  [[ -f "$MANIFEST" ]] || die "The authored skate2/skate2_manifest.toml is missing."
  git -C "$SDK_SOURCE" merge-base --is-ancestor "$SDK_REVISION" HEAD ||
    die "SDK source revision differs from the pinned, audited version."

  mkdir -p "$ROOT/reports"
  local log
  log="$ROOT/reports/build-linux-$stage-$(date +%Y%m%d-%H%M%S).log"
  info "Logging to $log"
  exec > >(tee -a "$log") 2>&1

  if [[ "$stage" =~ ^(all|generate|build)$ ]]; then
    if [[ ! -d "$GAME_ROOT" ]]; then
      if [[ -n "$game_dir" && "$stage" != build ]]; then
        cmd_import "$game_dir"
      else
        die "Import your extracted game first: ./skate2.sh import <folder>"
      fi
    fi
    verify_xex "$GAME_ROOT/default.xex"
  fi

  if [[ "$stage" =~ ^(all|sdk)$ ]]; then
    apply_sdk_patches
    info "Configuring ReXGlue SDK (Vulkan)..."
    (cd "$SDK_SOURCE" && cmake --preset "$SDK_PRESET" \
      -DCMAKE_C_COMPILER="$CC_BIN" -DCMAKE_CXX_COMPILER="$CXX_BIN" \
      -DREXGLUE_USE_VULKAN=ON -DREXGLUE_ENABLE_FIDELITYFX=OFF \
      -DREXGLUE_ENABLE_PERF_COUNTERS=ON -DREXGLUE_ENABLE_RELEASE_PERF_COUNTERS="$perf" \
      -DREXGLUE_ENABLE_TRACY=OFF -DREXGLUE_BUILD_TESTS=OFF)
    info "Building and installing ReXGlue SDK with $jobs jobs..."
    (cd "$SDK_SOURCE" && cmake --build "out/build/$SDK_PRESET" --config Release \
      --target install --parallel "$jobs")
  fi

  if [[ "$stage" =~ ^(all|generate|build)$ ]]; then
    local rexglue="$SDK_INSTALL/bin/rexglue"
    [[ -x "$rexglue" ]] || die "Local SDK has not been built. Run './skate2.sh build --stage sdk' first."
    if [[ "$stage" =~ ^(all|generate)$ ]]; then
      info "Translating default.xex to C++..."
      (cd "$PROJECT_ROOT" && "$rexglue" codegen "$MANIFEST" --ignore-stamp)
    fi
    if [[ "$stage" =~ ^(all|build)$ ]]; then
      [[ -f "$PROJECT_ROOT/generated/default/sources.cmake" ]] ||
        die "Code generation has not completed. Run '--stage generate' and resolve its errors first."
      info "Building skate2 with $jobs jobs..."
      (cd "$PROJECT_ROOT" && cmake --preset "$APP_PRESET" \
        -DCMAKE_C_COMPILER="$CC_BIN" -DCMAKE_CXX_COMPILER="$CXX_BIN" \
        -DCMAKE_PREFIX_PATH="$SDK_INSTALL")
      (cd "$PROJECT_ROOT" && cmake --build "out/build/$APP_PRESET" --config Release --parallel "$jobs")
      info "Build complete: $PROJECT_ROOT/out/build/$APP_PRESET/skate2"
      info "Start the game with './skate2.sh launch'."
    fi
  fi
}

# ---------------------------------------------------------------------------
cmd_launch() {
  local frame_rate="" render_scale="" monitor="" windowed=0 device="" keyboard=0
  local diagnostics=0 input_diag=0 perf_capture=0 check_only=0 idleclean=true
  local graphics_test="synchronous-shaders" render_path="" profile="quality"
  local extra=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile) profile="$2"; shift 2 ;;
      --frame-rate) frame_rate="${2,,}"; shift 2 ;;
      --render-scale) render_scale="$2"; shift 2 ;;
      --monitor) monitor="$2"; shift 2 ;;
      --windowed) windowed=1; shift ;;
      --device) device="$2"; shift 2 ;;
      --keyboard) keyboard=1; shift ;;
      --diagnostics) diagnostics=1; shift ;;
      --input-diagnostics) input_diag=1; shift ;;
      --performance-capture) perf_capture=1; shift ;;
      --graphics-test) graphics_test="$2"; shift 2 ;;
      --render-target-path) render_path="$2"; shift 2 ;;
      --no-idleclean-sync) idleclean=false; shift ;;
      --check) check_only=1; shift ;;
      --) shift; extra+=("$@"); break ;;
      *) die "Unknown launch option: $1 (see ./skate2.sh help)" ;;
    esac
  done

  # Profiles mirror the Windows CMD launchers.
  case "$profile" in
    quality|2x)     : "${frame_rate:=unlimited}"; : "${render_scale:=2}" ;;
    performance|1x) : "${frame_rate:=unlimited}"; : "${render_scale:=1}" ;;
    4x)             : "${frame_rate:=unlimited}"; : "${render_scale:=4}" ;;
    60|60fps)       : "${frame_rate:=60}" ;;
    unlocked)       : "${frame_rate:=unlimited}"; : "${render_scale:=2}" ;;
    custom)         ;;
    *) die "Unknown profile '$profile'. Use quality, performance, 4x, 60fps, unlocked or custom." ;;
  esac
  if [[ -n "$frame_rate" && ! "$frame_rate" =~ ^(original|60|120|144|165|200|240|unlimited)$ ]]; then
    die "--frame-rate must be original, 60, 120, 144, 165, 200, 240 or unlimited."
  fi
  if [[ -n "$render_scale" && ! "$render_scale" =~ ^[1-4]$ ]]; then die "--render-scale must be 1-4."; fi
  [[ "$graphics_test" =~ ^(default|synchronous-shaders|synchronous-memexport)$ ]] ||
    die "--graphics-test must be default, synchronous-shaders or synchronous-memexport."
  if [[ -n "$render_path" && ! "$render_path" =~ ^(any|fbo|fsi)$ ]]; then
    die "--render-target-path must be any, fbo or fsi."
  fi

  local candidates=(
    "$ROOT/skate2"
    "$ROOT/bin/skate2"
    "$PROJECT_ROOT/out/build/$APP_PRESET/skate2"
  )
  local exe="" c
  for c in "${candidates[@]}"; do
    if [[ -f "$c" && -x "$c" ]]; then exe="$c"; break; fi
  done
  [[ -n "$exe" ]] || die "The skate2 executable is missing. Build it with './skate2.sh build' (see docs/LINUX.md)."

  local app_root="$ROOT"
  [[ "$exe" == "${candidates[2]}" ]] && app_root="$PROJECT_ROOT"
  local game=""
  local game_candidates=("$ROOT/game" "$app_root/game")
  if [[ -f "$ROOT/.local/game-directory.txt" ]]; then
    game_candidates+=("$(tr -d '\r\n' < "$ROOT/.local/game-directory.txt")")
  fi
  for c in "${game_candidates[@]}"; do
    if [[ -f "$c/default.xex" && -d "$c/data" ]]; then game="$c"; break; fi
  done
  [[ -n "$game" ]] || die "Game data is missing. Run './skate2.sh import <folder>' with your extracted folder containing default.xex and data."
  verify_xex "$game/default.xex"

  local args=(
    "--game_data_root=$game" "--user_data_root=$app_root/userdata" "--cache_root=$app_root/cache"
    --gpu_plugin=xenos --input_backend=sdl
    "--vulkan_present_idleclean_sync=$idleclean"
  )
  [[ -n "$render_path" ]] && args+=("--render_target_path_vulkan=$render_path")
  [[ $keyboard -eq 1 ]] && args+=(--mnk_mode=true)
  [[ $input_diag -eq 1 ]] && args+=(--input_diag=true)
  [[ -n "$frame_rate" ]] && args+=("--skate2_frame_rate=$frame_rate")
  [[ "$graphics_test" == synchronous-shaders ]] && args+=(--async_shader_compilation=false)
  [[ "$graphics_test" == synchronous-memexport ]] && args+=(--readback_memexport_fast=false)
  if [[ -n "$render_scale" ]]; then
    args+=(--resolution_scale=1 "--draw_resolution_scale_x=$render_scale" "--draw_resolution_scale_y=$render_scale")
  fi
  [[ -n "$monitor" ]] && args+=("--monitor=$monitor")
  [[ $windowed -eq 1 ]] && args+=(--fullscreen=false)
  [[ -n "$device" ]] && args+=("--vulkan_device=$device")
  if [[ $perf_capture -eq 1 ]]; then
    local perf_dir; perf_dir="$(dirname "$exe")/logs/performance"
    [[ $check_only -eq 0 ]] && mkdir -p "$perf_dir"
    args+=("--perf_log_csv=$perf_dir/frames-$(date +%Y%m%d-%H%M%S)-$RANDOM.csv")
  fi
  [[ $diagnostics -eq 1 ]] && args+=(--log_level=debug --log_flush_interval=1)
  args+=("${extra[@]}")

  if [[ $check_only -eq 1 ]]; then
    printf 'Executable: %s\nGameData:   %s\nArguments:\n' "$exe" "$game"
    printf '  %s\n' "${args[@]}"
    exit 0
  fi
  if command -v vulkaninfo >/dev/null 2>&1 && ! vulkaninfo --summary >/dev/null 2>&1; then
    printf '\e[33mWarning: vulkaninfo found no working Vulkan device. Install your GPU'"'"'s Vulkan driver.\e[0m\n' >&2
  fi
  info "Starting Skate 2..."
  cd "$(dirname "$exe")"
  set +e
  "$exe" "${args[@]}"
  local rc=$?
  set -e
  [[ $rc -eq 0 ]] || die "Skate 2 exited with code $rc. Check the logs folder beside the executable."
}

# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Skate 2 PC for Linux (native, Vulkan)

Usage: ./skate2.sh <command> [options]

Commands:
  deps                       Install build dependencies (apt, dnf or pacman; uses sudo)
  bootstrap                  Fetch the pinned ReXGlue SDK v0.10.0 source and submodules
  import [folder]            Copy + verify your extracted game (default.xex + data) into game/
  build [options]            Patch/build SDK, translate default.xex, build skate2
      --stage all|sdk|generate|build   (default: all)
      --jobs N                          parallel jobs (default: min(nproc, 4))
      --performance-counters            enable Release frame-capture counters
      --game-directory DIR              import DIR first if game/ is missing
  launch [options]           Start the game
      --profile quality|performance|4x|60fps|unlocked|custom   (default: quality = 2x, unlimited FPS)
      --frame-rate original|60|120|144|165|200|240|unlimited
      --render-scale 1-4
      --windowed  --monitor N  --device N (Vulkan device index)
      --keyboard                      keyboard/mouse controller emulation
      --render-target-path any|fbo|fsi
      --graphics-test default|synchronous-shaders|synchronous-memexport
      --no-idleclean-sync             disable the GPU idle-clean synchronization
      --diagnostics  --input-diagnostics  --performance-capture
      --check                         print the resolved command line only
      -- <args>                       pass extra --flag=value options to skate2
EOF
}

main() {
  local cmd="${1:-help}"
  [[ $# -gt 0 ]] && shift
  case "$cmd" in
    deps) cmd_deps "$@" ;;
    bootstrap) cmd_bootstrap "$@" ;;
    import) cmd_import "$@" ;;
    build) cmd_build "$@" ;;
    launch|run|play) cmd_launch "$@" ;;
    help|-h|--help) usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
