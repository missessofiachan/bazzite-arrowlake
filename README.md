# bazzite-arrowlake

[![Build container image](https://github.com/missessofiachan/bazzite-arrowlake/actions/workflows/build.yml/badge.svg)](https://github.com/missessofiachan/bazzite-arrowlake/actions/workflows/build.yml)

Custom, high-performance [bootc](https://github.com/bootc-dev/bootc) image based on **Bazzite Nvidia Open** (`ghcr.io/ublue-os/bazzite-nvidia-open:stable`), engineered specifically for **Intel Core Ultra 200 Series (Arrow Lake-S)** desktop processors paired with **NVIDIA GeForce RTX (Ada Lovelace)** GPUs.

---

## ⚡ Key Highlights & Optimizations

### 1. Custom Arrow Lake-S Kernel & Rebuilt Drivers
> [!NOTE]
> **Status:** The custom Arrow Lake-S kernel is temporarily on hold to ensure seamless NVIDIA Open driver compatibility and full GPU hardware acceleration. Bazzite's stock kernel with verified NVIDIA drivers is active for now. See [TODO.md](TODO.md) for details and roadmap.

- **Kernel:** Incorporates customized, optimized OGC kernel RPMs built specifically with `-O3 -march=arrowlake-s -mtune=arrowlake-s -pipe` from [missessofiachan/kernel-packagesArrowlake](https://github.com/missessofiachan/kernel-packagesArrowlake).
- **Nvidia Open Kernel Modules:** Automatically compiles NVIDIA Open GPU drivers (`akmods --force --kernels "${KVER}" --kmod nvidia`) matching the custom kernel release during container build.
- **Bootc-Compliant Initramfs:** Reproducible Dracut initramfs rebuilt against the custom kernel with OSTree support and hardware-tuned compression tools.

### 2. High-Performance Arrow Lake Userspace Toolchain
Key system allocators, math routines, databases, security crypto, and compression libraries are built natively for `arrowlake-s` with aggressive optimizations (`-O3 -march=arrowlake-s -mtune=arrowlake-s -flto=auto -fno-plt -pipe -g0`):
- **jemalloc 5.3.0 & mimalloc 2.1.7:** Low-overhead, high-throughput multi-threaded memory allocators for gaming and heavy workloads.
- **zlib-ng 2.3.3:** Accelerated deflate implementation tuned for Arrow Lake architecture without AVX-512 extensions.
- **zstd 1.5.7, libdeflate & lz4 1.10.0:** Native compression and decompression binaries and shared libraries for rapid asset and disk streaming.
- **libjpeg-turbo 3.1.0:** SIMD/AVX2 accelerated texture and 2D image decoding for fast UI overlays and in-game asset streaming.
- **SQLite3 3.48.0:** Natively compiled with memory optimizations and fast table indexing (`-DSQLITE_ENABLE_MEMSYS5`, `-DSQLITE_ENABLE_FTS5`, `-DSQLITE_ENABLE_RTREE`) for Steam, browser, and local game cache operations.
- **SLEEF 3.6.1:** Hardware-vectorized SIMD math library (`libsleef.so.3`) tuned for AVX2 + FMA for physics, shaders, and gaming audio pipelines.
- **OpenSSL (`libcrypto.so.3` & `libssl.so.3`):** *(Temporarily on hold for system utility compatibility; see [TODO.md](TODO.md))* Stock OpenSSL with native dynamic CPU acceleration (VAES/SHA-NI) remains active.
- **FastMem Primitives (`libfastmem.so`):** Native AVX2 256-bit vectorized `memcpy` & `memset` preload library tailored for Arrow Lake's high L2 cache bandwidth.

### 3. Tuned Kernel Arguments (`10-arrowlake-gaming.toml`)
Optimized for ultra-low latency, real-time audio/input responsiveness, and peak gaming frame rates:
- `preempt=full`, `threadirqs` for scheduling responsiveness.
- `intel_pstate=active` for responsive hardware P-state transitions.
- `iommu=pt`, `pcie_aspm=off` for unrestricted PCIe bus performance.
- `transparent_hugepage=madvise`, `split_lock_detect=off`.
- `nowatchdog`, `nmi_watchdog=0`, `tsc=reliable`, `clocksource=tsc`.
- `usbcore.autosuspend=-1` to prevent latency spikes and disconnects on USB peripherals.

### 4. System & Subsystem Customizations
- **Sched-ext (`scx_loader`):** Enabled for pluggable userspace/eBPF gaming schedulers (e.g. `scx_lavd`, `scx_bpfland`).
- **NVIDIA GPU Tuning:** Low-latency environment variables and module options (`99-nvidia-gaming.conf`, `99-nvidia-custom.conf`).
- **I/O & Sysctl:** NVMe/SSD gaming queue scheduler rules (`60-iosched-gaming.rules`) and virtual memory responsiveness tweaks (`99-bazzite-arrowlake.conf`).
- **Pro Audio:** PipeWire latency and quantum settings optimized for gaming audio (`99-gaming-audio.conf`).
- **Network:** Disabled Wi-Fi power saving and masked blocking network wait services (`NetworkManager-wait-online.service`).
- **Mullvad VPN:** Preinstalled official client, CLI, and systemd service (`mullvad-daemon.service`) for instant privacy protection and secure networking.
- **Google Antigravity IDE:** Integrated AI development and agent orchestration platform (`/usr/bin/antigravity`) with desktop entry and custom protocol handler (`x-scheme-handler/antigravity`).

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
