# bazzite-arrowlake

[![Build container image](https://github.com/missessofiachan/bazzite-arrowlake/actions/workflows/build.yml/badge.svg)](https://github.com/missessofiachan/bazzite-arrowlake/actions/workflows/build.yml)

Custom, high-performance [bootc](https://github.com/bootc-dev/bootc) image based on **Bazzite Nvidia Open** (`ghcr.io/ublue-os/bazzite-nvidia-open:stable`), engineered specifically for **Intel Core Ultra 200 Series (Arrow Lake-S)** desktop processors paired with **NVIDIA GeForce RTX (Ada Lovelace)** GPUs.

---

## ⚡ Key Highlights & Optimizations

### 1. Custom Arrow Lake-S Kernel & Self-Healing NVIDIA Driver Contract
> [!NOTE]
> **Status:** ✅ Active & Verified. Running custom Arrow Lake-S OGC kernel with matching NVIDIA drivers (`kmod-nvidia`) and full hardware acceleration.

- **Kernel:** Incorporates customized, optimized OGC kernel RPMs built specifically with `-O3 -march=arrowlake-s -mtune=arrowlake-s -pipe` from [missessofiachan/kernel-packagesArrowlake](https://github.com/missessofiachan/kernel-packagesArrowlake).
- **Self-Healing NVIDIA Version Contract:** `build.sh` dynamically verifies that `kmod-nvidia` matches the exact driver version in Bazzite's base image. If a pre-built kmod matches, it installs in seconds; if mismatched or missing, it dynamically compiles the matching driver in-place with `akmods`.
- **Strict Build Verification Gate:** `modinfo` vermagic and GSP firmware presence checks guarantee that an unbootable or fallback image can never be built or pushed.
- **Bootc-Compliant Initramfs:** Reproducible Dracut initramfs rebuilt against the custom kernel with OSTree support and hardware-tuned compression tools.
- **Unprivileged /dev/ntsync Access:** Udev rules configured for ultra-fast NT synchronization primitives (`ntsync`) utilized by Proton gaming builds.

### 2. High-Performance Arrow Lake Userspace Toolchain & Bulletproof Build Architecture
Key system allocators, math routines, graphics dispatchers, schedulers, and compression libraries are built natively for `arrowlake-s` with aggressive optimizations (`-O3 -march=arrowlake-s -mtune=arrowlake-s -flto=auto -fno-plt -fno-semantic-interposition -fomit-frame-pointer -Wl,-Bsymbolic-functions -Wl,--gc-sections -pipe -g0`), dynamically tracking the **latest and greatest upstream stable releases** with automatic fallback to system RPM tags:
- **jemalloc 5.4.0 & mimalloc 2.5.2:** Low-overhead, high-throughput multi-threaded memory allocators for gaming and heavy workloads.
- **Vulkan Loader (`libvulkan.so.1`, v1.4.365):** Synchronized build against matching latest Khronos `Vulkan-Headers` (v1.4.365) with LTO and `-Bsymbolic-functions` to minimize trampoline indirection and function pointer dispatch latency across millions of draw calls per second.
- **xxHash (`libxxhash.so.0`, v0.8.4):** Native Arrow Lake-S build with AVX2 & BMI2 acceleration for DXVK pipeline cache lookups, graphics driver state tracking, and Btrfs deduplication (`bees`).
- **`scx` Sched-Ext Schedulers (`scx_bpfland`, `scx_lavd`, `scx_rusty`, v1.1.4):** Built with Cargo scoped target flags (`CARGO_TARGET_X86_64_UNKNOWN_LINUX_GNU_RUSTFLAGS="-C target-cpu=arrowlake-s -C opt-level=3 -C strip=symbols"`, ThinLTO) ensuring host `build.rs` compatibility during cross-architecture CI while maximizing runtime scheduling across Lion Cove P-cores and Skymont E-cores.
- **zlib-ng (2.3.3):** Accelerated deflate implementation tuned for Arrow Lake architecture without AVX-512 bloat.
- **zstd (v1.5.7), libdeflate (v1.26) & lz4 (v1.10.0):** Native compression and decompression binaries (`/usr/bin/zstd`, `/usr/bin/lz4`) and shared libraries for rapid asset and disk streaming.
- **libjpeg-turbo (3.2.0), libpng (v1.6.59) & brotli (v1.2.0):** SIMD/AVX2 accelerated texture and 2D image decoding (with Fedora ABI-matched `libjpeg.so.62`) for fast UI overlays, Steam CEF windows, and in-game asset streaming.
- **SQLite3 (version-3.54.1):** Natively compiled with memory optimizations, WAL synchronous tuning, and fast table indexing (`-DSQLITE_ENABLE_MEMSYS5`, `-DSQLITE_ENABLE_FTS5`, `-DSQLITE_ENABLE_RTREE`) for Steam, browser, and local game cache operations.
- **SLEEF 3.9.0:** Hardware-vectorized SIMD math library (`libsleef.so.3`) tuned for AVX2 + FMA for physics, shaders, and gaming audio pipelines.
- **FastMem Primitives (`libfastmem.so`):** Native AVX2 256-bit vectorized `memcpy`, `memmove`, `memset`, and `memcmp` preload library featuring 4x-unrolled 128-byte loops, branchless tail loads/stores, and ERMS fallback for large transfers.
- **Gamescope (Valve's Micro-Compositor, 3.16.31):** Native `-O3 -march=arrowlake-s -mtune=arrowlake-s -flto=auto` build with bundled WSI layer and `cap_sys_nice=eip` capability. Sits directly in the critical render path for games running under FSR, integer scaling, and HDR tonemapping.
- **HarfBuzz (14.6.0) & FreeType (VER-2-15-0):** 3-stage mutual circular native compilation with ICU enabled (`libharfbuzz-icu.so.0`) for text shaping and glyph rasterization. Delivers smooth UI transitions and prevents micro-stutters when Steam overlays, browser windows, or in-game HUD fonts are rendered.
- **Steam & Game Launch Wrappers:** Convenient drop-in CLI launchers (`run-jemalloc %command%`, `run-mimalloc %command%`, `run-fastmem %command%`, `run-pcores %command%`) to instantly preload Arrow Lake-optimized allocators or dynamically pin legacy game threads to Lion Cove P-cores.
- **Bulletproof Build Pipeline:**
  - **Network Retry Resilience:** Automatic exponential-backoff retries for Git clones, submodule initialization (with shallow-to-full fallback), and package downloads.
  - **dnf5 Package Overwrite Protection:** Automated staging of custom `.so` and executable artifacts into `/tmp/arrowlake-stage`, restored after all package manager transactions.
  - **Comprehensive Verification Gates:** Automated 21-binary/library AVX-512 (`%zmm`) sanity scans and `ldd` dynamic linkage checks on all critical gaming executables.

### 3. Tuned Kernel Arguments (`10-arrowlake-gaming.toml`)
Optimized for ultra-low latency, real-time audio/input responsiveness, and peak gaming frame rates:
- `preempt=full`, `threadirqs` for scheduling responsiveness.
- `intel_pstate=active` for responsive hardware P-state transitions.
- `iommu=pt`, `pcie_aspm=off` for unrestricted PCIe bus performance.
- `transparent_hugepage=madvise`, `split_lock_detect=off`.
- `nowatchdog`, `nmi_watchdog=0`, `tsc=reliable`, `clocksource=tsc`.
- `usbcore.autosuspend=-1` to prevent latency spikes and disconnects on USB peripherals.

### 4. System & Subsystem Customizations
- **Sched-ext (`scx_loader`):** Enabled for pluggable userspace/eBPF gaming schedulers with native Arrow Lake-S compiled binaries (`scx_bpfland`, `scx_lavd`, `scx_rusty`).
- **NVIDIA GPU Tuning:** Low-latency environment variables, G-Sync / VRR flags on Wayland, and module options (`99-nvidia-gaming.conf`, `99-nvidia-custom.conf`).
- **I/O & Sysctl:** NVMe/SSD gaming queue scheduler rules (`60-iosched-gaming.rules`), boosted inotify watchers for IDEs, and virtual memory responsiveness tweaks (`99-bazzite-arrowlake.conf`).
- **Pro Audio:** PipeWire latency and quantum settings optimized for gaming audio (`99-gaming-audio.conf`).
- **Network:** Disabled Wi-Fi power saving and masked blocking network wait services (`NetworkManager-wait-online.service`).
- **Mullvad VPN:** Preinstalled official client, CLI, and systemd service (`mullvad-daemon.service`) for instant privacy protection and secure networking.
- **Visual Studio Code:** Preinstalled official Microsoft VS Code (`/usr/bin/code`) with desktop entries and URL handlers.
- **Google Antigravity:** Preinstalled Google Antigravity GUI program (`/usr/bin/antigravity`) with desktop entry and custom protocol handler (`x-scheme-handler/antigravity`).

---

## 🚀 Rebase & Installation

To rebase an existing Fedora Atomic / Bazzite system to this image:

```bash
sudo bootc switch ghcr.io/missessofiachan/bazzite-arrowlake:latest
```

Then reboot:
```bash
systemctl reboot
```

### Verification
Check running kernel and architecture after reboot:
```bash
uname -r
cat /proc/cmdline
modinfo nvidia
```

---

## 🛠 Local Development & Building

### Prerequisites
- [just](https://just.systems/)
- [podman](https://podman.io/)

### Build Container Image Locally
```bash
just build
```

Or test-switch locally without pushing to GHCR:
```bash
sudo just build
sudo bootc switch --transport containers-storage localhost/bazzite-arrowlake:latest
sudo reboot
```

### Linting
```bash
just check
just lint
just format
```

---

## 📦 Upstream & Architecture

- **Base Image:** `ghcr.io/ublue-os/bazzite-nvidia-open:stable`
- **Kernel Repository:** [missessofiachan/kernel-packagesArrowlake](https://github.com/missessofiachan/kernel-packagesArrowlake)
- **Kernel RPM Package Registry:** `ghcr.io/missessofiachan/kernel-packagesarrowlake-fedora:latest-fc44`
- **Container Registry:** `ghcr.io/missessofiachan/bazzite-arrowlake`
