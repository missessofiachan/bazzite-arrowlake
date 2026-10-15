# bazzite-arrowlake

Custom, high-performance [bootc](https://github.com/bootc-dev/bootc) image based on **Bazzite Nvidia Open** (`ghcr.io/ublue-os/bazzite-nvidia-open:stable`), engineered specifically for **Intel Core Ultra 200 Series (Arrow Lake-S)** desktop processors paired with **NVIDIA GeForce RTX (Ada Lovelace)** GPUs.

---

## ⚡ Key Highlights & Optimizations

### 1. Custom Arrow Lake-S Kernel & Rebuilt Drivers
- **Kernel:** Incorporates customized, optimized OGC kernel RPMs built specifically with `-O3 -march=arrowlake-s -mtune=arrowlake-s -pipe`.
- **Nvidia Open Kernel Modules:** Automatically compiles NVIDIA Open GPU drivers (`akmods --force --kernels "${KVER}" --kmod nvidia`) matching the custom kernel release during container build.
- **Bootc-Compliant Initramfs:** Reproducible Dracut initramfs rebuilt against the custom kernel with OSTree support and hardware-tuned compression tools.

### 2. High-Performance Arrow Lake Userspace Toolchain
Key system allocators and compression libraries are built natively for `arrowlake-s` with aggressive optimizations (`-O3 -march=arrowlake-s -mtune=arrowlake-s -flto=auto -fno-plt -pipe -g0`):
- **jemalloc 5.3.0 & mimalloc 2.1.7:** Low-overhead, high-throughput multi-threaded memory allocators for gaming and heavy workloads.
- **zlib-ng 2.3.3:** Accelerated deflate implementation tuned for Arrow Lake architecture without AVX-512 extensions.
- **zstd 1.5.7, libdeflate & lz4 1.10.0:** Native compression and decompression binaries and shared libraries for rapid asset and disk streaming.

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
- **Kernel RPM Source:** `ghcr.io/missessofiachan/kernel-packagesarrowlake-fedora:latest`
- **Container Registry:** `ghcr.io/missessofiachan/bazzite-arrowlake`
