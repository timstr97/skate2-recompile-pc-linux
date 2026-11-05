# Linux

Skate 2 PC also builds and runs **natively on Linux**. The recompiled game code is the same as on Windows; graphics use ReXGlue's **Vulkan** backend instead of Direct3D 12, and input/audio go through SDL3 (PipeWire, PulseAudio or ALSA). Wine/Proton is not involved.

> **Status: experimental.** The Linux path is new. The SDK build and the project-side changes compile on Linux, but full gameplay has not yet been validated on Linux hardware the way the Windows build has. Please [report problems](https://github.com/christianortel/skate2-recompile-pc/issues/new/choose) and mention "Linux", your distribution, GPU and driver.

Everything goes through one script in the repository root, `skate2.sh`.

## Requirements

| Item | Requirement |
| --- | --- |
| Operating system | x86-64 Linux with glibc; the SDK build was verified on Ubuntu 24.04 — current Fedora and Arch releases should also work |
| Processor | x86-64-v2 (any CPU from roughly 2009 onwards) |
| Graphics | GPU with a **Vulkan 1.2+** driver: Mesa RADV (AMD), Mesa ANV (Intel) or the NVIDIA proprietary driver |
| Display | X11 or Wayland |
| Build tools | Clang/LLVM **20 or later**, CMake 3.25+, Ninja, Git, pkg-config |
| Game data | Your own extracted copy of the [supported revision](INSTALL.md#supported-game-version) (`default.xex` + `data`) |
| Disk | ~7 GB for the imported game plus SDK sources, generated code and build output (allow ~20 GB total) |

Check that Vulkan works before you start:

```bash
vulkaninfo --summary
```

## 1. Install the build dependencies

```bash
./skate2.sh deps
```

This uses `apt`, `dnf` or `pacman` (with `sudo`) to install Clang, CMake, Ninja and the X11/Wayland/GTK/audio/Vulkan development packages. On Ubuntu 22.04 or older Debian releases, `clang-20` is not in the default sources; add the LLVM repository first:

```bash
wget https://apt.llvm.org/llvm.sh && sudo bash llvm.sh 20
```

## 2. Fetch the pinned SDK

```bash
./skate2.sh bootstrap
```

This clones ReXGlue v0.10.0 at the same pinned commit as the Windows build (`f5337cdc…`) into `tools/rexglue-sdk-source`, plus only the submodules the Linux/Vulkan build needs.

## 3. Import your game files

```bash
./skate2.sh import "/path/to/extracted/Skate 2"
```

Point it at the folder that directly contains `default.xex` and `data`. The importer checks the executable's SHA-256, copies everything into `game/` through a staging folder, verifies every copied file, and never overwrites an existing `game/` folder. Without an argument it opens a folder picker if `zenity` is installed.

## 4. Build

```bash
./skate2.sh build
```

This runs the same stages as `scripts/Build-Skate2.ps1`:

1. applies the SDK patches from `patches/` (including the two Vulkan ports listed below),
2. builds and installs the SDK with the Vulkan backend,
3. translates `game/default.xex` into C++ with `rexglue codegen`,
4. builds `skate2/out/build/linux-amd64-release/skate2`.

Options: `--jobs N` (default: up to 4; lower it if you run out of RAM), `--stage sdk|generate|build` to rerun a single stage, `--performance-counters` for frame-capture builds. Logs are written to `reports/`.

## 5. Play

```bash
./skate2.sh launch
```

The default profile matches **Launch Skate 2.cmd** on Windows: 2× rendering, unlimited FPS, synchronous shader compilation and GPU idle-clean synchronization. Other profiles mirror the Windows CMD launchers:

| Windows launcher | Linux command |
| --- | --- |
| Launch Skate 2.cmd / 2x Quality | `./skate2.sh launch` |
| Launch Skate 2 - 1x Performance | `./skate2.sh launch --profile performance` |
| Launch Skate 2 - 4x Quality | `./skate2.sh launch --profile 4x` |
| Launch Skate 2 - 60 FPS | `./skate2.sh launch --profile 60fps` |
| Launch Skate 2 - Unlocked FPS | `./skate2.sh launch --profile unlocked` |

Useful options: `--windowed`, `--monitor N`, `--keyboard` (keyboard/mouse controller emulation), `--frame-rate 60|120|144|…`, `--render-scale 1-4`, `--diagnostics`. `--check` prints the resolved command line without starting the game. Run `./skate2.sh help` for the full list.

Saves, settings (`skate2.toml`), shader cache and logs are stored under `skate2/` exactly as on Windows.

### Steam / desktop shortcut

Add `skate2.sh` as a non-Steam game and set the launch options to `launch` (plus any profile options). Do **not** force a Proton compatibility tool — this is a native Linux program. For a desktop entry:

```ini
[Desktop Entry]
Type=Application
Name=Skate 2
Exec=/path/to/skate2-recompile-pc/skate2.sh launch
Terminal=false
Categories=Game;
```

## Linux-specific notes

- **GPU selection (laptops with two GPUs).** Vulkan picks a device automatically. To force one, list devices in the log or with `vulkaninfo --summary` and pass `--device N`, or use your distribution's mechanism (`DRI_PRIME=1 ./skate2.sh launch`, `prime-run ./skate2.sh launch`, or `switcherooctl launch`).
- **Render target path.** The Windows build forces the D3D12 ROV path. On Vulkan the SDK chooses automatically between the framebuffer path (`fbo`) and fragment-shader-interlock (`fsi`, the Vulkan equivalent of ROV). If you see blending or depth glitches, try `--render-target-path fsi` (if your GPU supports `VK_EXT_fragment_shader_interlock`) or `--render-target-path fbo`.
- **Controllers.** Input uses SDL3. A DualSense/DualShock works over USB or Bluetooth; if it is not detected, make sure your user can access `/dev/hidraw*` (Steam's udev rules, package `steam-devices`, are the usual fix). Close Steam Input remapping if inputs are doubled.
- **Audio.** SDL3 uses PipeWire or PulseAudio automatically. The in-game audio-output selection uses SDL3 on both platforms.
- **Crash reports.** The Windows minidump writer is not available on Linux; use `--diagnostics` and the log files beside the executable, or run under `gdb`.

## What differs from the Windows build

| Area | Windows | Linux |
| --- | --- | --- |
| GPU backend | Direct3D 12 | Vulkan |
| Render target path | `render_target_path_d3d12=rov` | automatic (`render_target_path_vulkan`) |
| Idle-clean GPU sync | `d3d12_present_idleclean_sync` | `vulkan_present_idleclean_sync` (ported, `patches/rexglue-0.10.0-vulkan-present-idleclean.patch`) |
| Vertex-buffer coherency fix | D3D12 command processor | ported to the Vulkan command processor (`patches/rexglue-0.10.0-vulkan-vertex-buffer-coherency.patch`) |
| Automatic high-performance GPU | DXGI preference | Vulkan auto-selection / `--device` / PRIME |
| Launcher | `Launch Skate 2.exe`, CMD + PowerShell | `skate2.sh` |
| Crash minidumps | yes | not yet |
