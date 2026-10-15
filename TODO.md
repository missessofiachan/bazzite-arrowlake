# Project TODOs & Technical Tracking

## 1. Custom Arrow Lake-S Kernel & NVIDIA Driver Integration

- **Status:** ⏸️ Deferred / Temporarily Commented Out
- **Affects:** `build_files/build.sh` (Section 15)

### Problem Description
When replacing the base Bazzite kernel with the custom Arrow Lake-S OGC kernel (`ghcr.io/missessofiachan/kernel-packagesarrowlake-fedora:latest-fc44`), the NVIDIA Open GPU drivers fail to load into the kernel. 

As a consequence:
- The Wayland compositor (Gamescope / KDE Plasma / GNOME) cannot initialize hardware GPU acceleration.
- The desktop falls back to software rasterization via **LLVMpipe** (`llvmpipe (LLVM 19.x, 256 bits)`).
- The GUI renders extremely slowly, experiencing severe stutter, cursor lag, dropped frames, and 100% CPU spikes on compositor threads.

### Root Cause Analysis
Kernel modules in Linux enforce strict vermagic and ABI verification (`module_layout`). Simply copying the precompiled `/usr/lib/modules/<stock_kver>/extra/` and `/updates/` NVIDIA module directories into the custom kernel directory does not work across different kernel builds and ABI revisions. The kernel loader rejects the modules due to mismatched symbol versions and structure layouts.

### Current Mitigation
- Section 15 in `build_files/build.sh` (custom kernel RPM installation, module copying, and Dracut initramfs regeneration) is temporarily commented out.
- The build retains the upstream Bazzite stock kernel with its matching, verified NVIDIA Open drivers (`bazzite-nvidia-open:stable`).
- Hardware GPU acceleration, NVENC, and low-latency Wayland rendering function out-of-the-box.
- All userspace optimizations (Arrow Lake-S native builds for jemalloc, mimalloc, zlib-ng, zstd, libdeflate, lz4, libjpeg-turbo, SQLite3, SLEEF, OpenSSL, and fastmem) remain active.

### Action Plan to Re-enable Custom Kernel
- [ ] **1. Dedicated NVIDIA Kmod Compilation:**
  - Build the NVIDIA open kernel modules against the specific custom kernel headers (`kernel-devel` and `kernel-headers` matching `${KVER}`).
  - *Option A:* Build in container during image creation using `akmods --force --kernels "${KVER}" --kmod nvidia`.
  - *Option B (Recommended):* Compile `kmod-nvidia` in the [kernel-packagesArrowlake](https://github.com/missessofiachan/kernel-packagesArrowlake) CI repository and publish pre-built matching NVIDIA RPMs to the ORAS registry alongside `kernel-core`.
- [ ] **2. Rebuild Out-of-tree Auxiliary Modules:**
  - Build matching modules for other Bazzite dependencies if needed (`xone` for Xbox dongles, `v4l2loopback` for virtual cameras).
- [ ] **3. Verification Checkpoints:**
  - Run `modinfo nvidia` and verify vermagic matches `${KVER}` and symbols resolve without error.
  - Verify `nvidia-smi` successfully communicates with the GPU.
  - Verify `glxinfo | grep "OpenGL renderer"` and `vulkaninfo` report `NVIDIA GeForce RTX ...` and NOT `llvmpipe`.
- [ ] **4. Re-enable Section 15 in `build_files/build.sh`:**
  - Uncomment the kernel installation block, test the local container build, and verify bootc deployment.
