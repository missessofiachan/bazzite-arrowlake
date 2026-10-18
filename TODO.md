# Project TODOs & Technical Tracking

## 1. Custom Arrow Lake-S Kernel & NVIDIA Driver Integration

- **Status:** ✅ Resolved & Active
- **Affects:** `build_files/build.sh` (Section 15)

### Status & Verification Summary
The custom Arrow Lake-S OGC kernel is active with verified NVIDIA Open GPU acceleration:
- Kernel vermagic and symbols match pre-compiled `kmod-nvidia` drivers built against the Negativo17 release (615.x).
- Automated Self-Healing Version Contract: `build_files/build.sh` automatically checks whether prebuilt `kmod-nvidia` matches the base image's `nvidia-driver` version. If mismatched or missing, it dynamically compiles the matching driver in-place with `akmods`.
- Strict Build Verification Gate: `modinfo` and firmware presence checks guarantee that an unbootable or 1080p-fallback image can never be generated or published.
- Wayland compositor (KWin / Gamescope) renders at peak hardware refresh rates (3840x2160 @ 144Hz) with G-Sync/VRR.

### Completed Action Items
- [x] **1. Dedicated NVIDIA Kmod Compilation:**
  - Implemented in [kernel-packagesArrowlake/.github/workflows/fedora.yaml](file:///run/media/sofia/cc258147-6cb1-40b1-b682-64f9c8f50f64/GitHub/kernel-packagesArrowlake/.github/workflows/fedora.yaml). The CI pipeline compiles `kmod-nvidia` directly against the custom kernel's `kernel-devel` RPM and packages it into the ORAS OCI artifact.
- [x] **2. Rebuild Out-of-tree Auxiliary Modules:**
  - Automated in kernel CI (`akmod-xone` and `akmod-v4l2loopback`).
- [x] **3. Self-Healing Version Contract & Verification Gate:**
  - Added build-time verification and automated `akmods` fallback in `build_files/build.sh`.
- [x] **4. Dynamic System Version Matching for Optimized Userspace Libraries:**
  - Userspace libraries (`zstd`, `zlib-ng`, `lz4`, `libjpeg-turbo`, `sqlite`) dynamically query the base system's package versions before compilation.

---

## 2. In-Place Arrow Lake-S OpenSSL Build

- **Status:** ⏸️ Deferred / Temporarily Commented Out
- **Affects:** `build_files/build.sh` (Section 13)

### Problem Description & Context
OpenSSL (`libcrypto.so.3` and `libssl.so.3`) is one of the most critical foundational libraries on Fedora/Bazzite, directly used by `dnf5`, `rpm`, `curl`, `systemd`, `ostree`, `bootc`, and network stacks. 

Swapping it in-place during the container build requires careful handling:
1. **Dynamic Version & Symbol Matching:** Upstream Fedora 44 builds `openssl-libs` 3.5.9 with symbol version `OPENSSL_3.5.0`. Compiling against mismatched upstream tags or older releases (e.g. 3.4.x) breaks runtime symbol resolution.
2. **Shared Library Symlink Naming:** Upstream OpenSSL creates `libcrypto.so.3` directly, while Fedora packaging links `libcrypto.so.3 -> libcrypto.so.3.5.9`. Overwriting symlinks or creating duplicate soname files can confuse `ldconfig` and package managers.
3. **Hardware Crypto Already Active:** Modern Intel processors (including Arrow Lake-S) already benefit from OpenSSL's dynamic runtime CPU detection (VAES, VPCLMULQDQ, SHA-NI, AVX2) in the stock Fedora build.

### Current Mitigation
- Section 13 in `build_files/build.sh` is commented out.
- The system relies on the stock, fully tested `openssl-libs-3.5.x` package provided by Bazzite/Fedora.
- All core tools (`dnf5`, `bootc`, container updates) operate with 100% stability.

### Action Plan to Re-enable
- [ ] Verify runtime symbol version compatibility against stock `openssl-libs` (`readelf -V /usr/lib64/libcrypto.so.3`).
- [ ] Test in-place replacement in an isolated container test build.
- [ ] Run test suite for downstream consumers (`curl`, `rpm`, `git`, `dnf5`) before finalizing.
- [ ] Uncomment Section 13 in `build_files/build.sh`.

---

## 3. Tier 1 Performance Packages (xxHash, Vulkan-Loader, scx Schedulers)

- **Status:** ✅ Integrated & Active
- **Affects:** `build_files/build.sh` (Sections 15, 16, 17)

### Highlights
- **xxHash (`libxxhash.so.0`):** Native Arrow Lake-S build with AVX2 & BMI2 acceleration for DXVK pipeline cache lookups, graphics driver state tracking, and Btrfs deduplication (`bees`).
- **Vulkan Loader (`libvulkan.so.1`):** Native `-O3 -march=arrowlake-s -flto=auto` build to reduce trampoline and function pointer dispatch overhead across millions of draw calls per second.
- **`scx` Sched-Ext Schedulers (`scx_bpfland`, `scx_lavd`, `scx_rusty`):** Compiled with `RUSTFLAGS="-C target-cpu=arrowlake-s -C opt-level=3"` for tailored hybrid thread scheduling across Lion Cove P-cores (1T) and Skymont E-cores (1T).
