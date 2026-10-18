#!/usr/bin/bash
set -ouex pipefail

export HOME=/tmp
export CMAKE_POLICY_VERSION_MINIMUM=3.5

# ==============================================================================
# Dynamic Version & Tag Resolution Helpers
# ==============================================================================
# 1. Query installed RPM version cleanly (strips epochs/release suffixes)
get_rpm_ver() {
    rpm -q --qf "%{VERSION}\n" "$@" 2>/dev/null | grep -v "not installed" | head -n 1 | sed 's/[\^+~].*//' || true
}

# 2. Query the latest stable upstream Git tag matching a regex pattern
get_latest_tag() {
    local repo_url="$1"
    local tag_regex="${2:-^[vV]?[0-9]+\.[0-9]+(\.[0-9]+)*$}"
    git ls-remote --tags --refs --sort=-v:refname "${repo_url}" 2>/dev/null \
        | awk -F'refs/tags/' '{print $2}' \
        | grep -E "${tag_regex}" \
        | head -n 1 || true
}

# 3. Clone a repo trying: (1) RPM-matched tag, (2) Latest upstream release tag, (3) Default branch
clone_dynamic() {
    local repo_url="$1"
    local dest_dir="$2"
    local preferred_tag="$3"
    local fallback_regex="${4:-^[vV]?[0-9]+\.[0-9]+(\.[0-9]+)*$}"
    shift 4
    local extra_git_args=("$@")

    rm -rf "${dest_dir}"
    if [ -n "${preferred_tag}" ]; then
        echo "--> Attempting clone of ${repo_url} at system-matched tag: ${preferred_tag}"
        if git clone --depth 1 "${extra_git_args[@]}" --branch "${preferred_tag}" "${repo_url}" "${dest_dir}" 2>/dev/null; then
            return 0
        fi
    fi

    local latest_tag
    latest_tag=$(get_latest_tag "${repo_url}" "${fallback_regex}")
    if [ -n "${latest_tag}" ]; then
        echo "--> Attempting clone of ${repo_url} at latest upstream tag: ${latest_tag}"
        if git clone --depth 1 "${extra_git_args[@]}" --branch "${latest_tag}" "${repo_url}" "${dest_dir}" 2>/dev/null; then
            return 0
        fi
    fi

    echo "--> Falling back to default HEAD branch for ${repo_url}"
    git clone --depth 1 "${extra_git_args[@]}" "${repo_url}" "${dest_dir}"
}

# 1. Copy baked-in system configs
cp -rv /ctx/system_files/* /
rm -f /usr/share/ublue-os/image-template-check

# 2. Install temporary compiler toolchain (including libxcb-devel & xcb-util-* for Vulkan & Gamescope)
BUILD_DEPS=(
    gcc gcc-c++ make cmake ninja-build meson autoconf automake libtool pkgconf-pkg-config
    git bzip2 curl jq
    zlib-ng-compat-devel vulkan-headers clang bpftool libbpf-devel elfutils-libelf-devel
    rust cargo brotli-devel bzip2-devel libpng-devel glib2-devel libicu-devel
    libxcb-devel xcb-util-devel xcb-util-wm-devel xcb-util-image-devel
    xcb-util-keysyms-devel xcb-util-renderutil-devel
    libX11-devel libXrandr-devel libXdamage-devel libXcomposite-devel libXcursor-devel
    libXrender-devel libXext-devel libXfixes-devel libXxf86vm-devel libXtst-devel
    libXres-devel libXmu-devel libXi-devel libdrm-devel libeis-devel
    wayland-devel wayland-protocols-devel libxkbcommon-devel libcap-devel
    sdl2-compat-devel libavif-devel pixman-devel systemd-devel libdecor-devel
    luajit-devel libinput-devel pipewire-devel hwdata glslang
    spirv-headers-devel glm-devel libseat-devel lcms2-devel
    xorg-x11-server-Xwayland-devel
)
dnf5 install -y "${BUILD_DEPS[@]}"

export PKG_CONFIG_PATH="/usr/lib64/pkgconfig:/usr/share/pkgconfig:${PKG_CONFIG_PATH:-}"

# 3. Arrow Lake-S optimization flags (Userspace Libraries & Rust)
export CFLAGS="-O3 -march=arrowlake-s -mtune=arrowlake-s -flto=auto -fno-plt -pipe -g0"
export CXXFLAGS="${CFLAGS}"
export LDFLAGS="-Wl,-O3 -Wl,--as-needed -flto=auto -Wl,-s"
export RUSTFLAGS="-C target-cpu=arrowlake-s -C opt-level=3 -C codegen-units=1"

# 4. Build Arrow Lake-S jemalloc (dynamically matching system or latest upstream)
SYS_JEMALLOC_VER=$(get_rpm_ver jemalloc)
clone_dynamic "https://github.com/jemalloc/jemalloc.git" "/tmp/jemalloc" "${SYS_JEMALLOC_VER}" "^[0-9]+\.[0-9]+\.[0-9]+$"
cd /tmp/jemalloc
./autogen.sh --prefix=/usr --libdir=/usr/lib64 --disable-stats --disable-cxx --disable-static --enable-autogen
make -j"$(nproc)" build_lib_shared
install -m 755 lib/libjemalloc.so.2 /usr/lib64/libjemalloc.so.2
ln -sf libjemalloc.so.2 /usr/lib64/libjemalloc.so
cd / && rm -rf /tmp/jemalloc

# 5. Build Arrow Lake-S mimalloc (dynamically matching system or latest v2.x ABI)
SYS_MIMALLOC_VER=$(get_rpm_ver mimalloc)
clone_dynamic "https://github.com/microsoft/mimalloc.git" "/tmp/mimalloc" "${SYS_MIMALLOC_VER:+v${SYS_MIMALLOC_VER}}" "^v2\.[0-9]+\.[0-9]+$"
cmake -B /tmp/mimalloc/build -S /tmp/mimalloc -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=/usr/lib64 \
  -DMI_BUILD_STATIC=OFF -DMI_BUILD_OBJECT=OFF -DMI_BUILD_TESTS=OFF -DMI_INSTALL_TOPLEVEL=ON
cmake --build /tmp/mimalloc/build
MIMALLOC_SO=$(find /tmp/mimalloc/build -maxdepth 1 -type f -name "libmimalloc.so.*.*" | head -n 1)
install -m 755 "${MIMALLOC_SO}" /usr/lib64/
ln -sf "$(basename "${MIMALLOC_SO}")" /usr/lib64/libmimalloc.so.2
ln -sf libmimalloc.so.2 /usr/lib64/libmimalloc.so
rm -rf /tmp/mimalloc

# 6. Build Arrow Lake-S zlib-ng (dynamically matching system or latest upstream)
SYS_ZLIB_VER=$(get_rpm_ver zlib-ng-compat zlib-ng)
clone_dynamic "https://github.com/zlib-ng/zlib-ng.git" "/tmp/zlib-ng" "${SYS_ZLIB_VER}" "^[0-9]+\.[0-9]+\.[0-9]+$"
sed -i 's/evex512//g' /tmp/zlib-ng/arch/x86/*.c /tmp/zlib-ng/CMakeLists.txt || true
cmake -B /tmp/zlib-ng/build -S /tmp/zlib-ng -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=/usr/lib64 \
  -DZLIB_COMPAT=ON -DZLIB_ENABLE_TESTS=OFF -DWITH_GTEST=OFF -DWITH_NATIVE_INSTRUCTIONS=OFF \
  -DWITH_AVX512=OFF -DWITH_AVX512VNNI=OFF -DBUILD_SHARED_LIBS=ON
cmake --build /tmp/zlib-ng/build
ZLIB_SO=$(find /tmp/zlib-ng/build -maxdepth 1 -type f -name "libz.so.1.*" | head -n 1)
install -m 755 "${ZLIB_SO}" /usr/lib64/
ln -sf "$(basename "${ZLIB_SO}")" /usr/lib64/libz.so.1
rm -rf /tmp/zlib-ng

# 7. Build Arrow Lake-S zstd (dynamically matching system or latest upstream)
SYS_ZSTD_VER=$(get_rpm_ver libzstd)
clone_dynamic "https://github.com/facebook/zstd.git" "/tmp/zstd" "${SYS_ZSTD_VER:+v${SYS_ZSTD_VER}}" "^v[0-9]+\.[0-9]+\.[0-9]+$"
cmake -B /tmp/zstd/build_cmake -S /tmp/zstd/build/cmake -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=/usr/lib64 \
  -DZSTD_BUILD_STATIC=OFF -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_TESTS=OFF
cmake --build /tmp/zstd/build_cmake
ZSTD_SO=$(find /tmp/zstd/build_cmake/lib -maxdepth 1 -type f -name "libzstd.so.1.*" | head -n 1)
install -m 755 "${ZSTD_SO}" /usr/lib64/
ln -sf "$(basename "${ZSTD_SO}")" /usr/lib64/libzstd.so.1
rm -rf /tmp/zstd

# 8. Build Arrow Lake-S libdeflate (dynamically matching system or latest upstream)
SYS_DEFLATE_VER=$(get_rpm_ver libdeflate)
clone_dynamic "https://github.com/ebiggers/libdeflate.git" "/tmp/libdeflate" "${SYS_DEFLATE_VER:+v${SYS_DEFLATE_VER}}" "^v[0-9]+\.[0-9]+$"
sed -i 's/,evex512//g; s/"evex512"/""/g' /tmp/libdeflate/lib/x86/*.h || true
cmake -B /tmp/libdeflate/build -S /tmp/libdeflate -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=/usr/lib64 \
  -DLIBDEFLATE_BUILD_STATIC_LIB=OFF -DLIBDEFLATE_BUILD_GZIP=OFF -DLIBDEFLATE_BUILD_TESTS=OFF
cmake --build /tmp/libdeflate/build
cmake --install /tmp/libdeflate/build
rm -rf /tmp/libdeflate

# 9. Build Arrow Lake-S lz4 (dynamically matching system or latest upstream)
SYS_LZ4_VER=$(get_rpm_ver lz4-libs)
clone_dynamic "https://github.com/lz4/lz4.git" "/tmp/lz4" "${SYS_LZ4_VER:+v${SYS_LZ4_VER}}" "^v[0-9]+\.[0-9]+\.[0-9]+$"
make -C /tmp/lz4/lib -j"$(nproc)" BUILD_STATIC=no CFLAGS="${CFLAGS} -fPIC"
LZ4_SO=$(find /tmp/lz4/lib -maxdepth 1 -type f -name "liblz4.so.1.*" | head -n 1)
install -m 755 "${LZ4_SO}" /usr/lib64/
ln -sf "$(basename "${LZ4_SO}")" /usr/lib64/liblz4.so.1
rm -rf /tmp/lz4

# 10. Build Arrow Lake-S libjpeg-turbo (dynamically matching system or latest upstream)
SYS_JPEG_VER=$(get_rpm_ver libjpeg-turbo)
clone_dynamic "https://github.com/libjpeg-turbo/libjpeg-turbo.git" "/tmp/libjpeg-turbo" "${SYS_JPEG_VER}" "^[0-9]+\.[0-9]+\.[0-9]+$"
cmake -B /tmp/libjpeg-turbo/build -S /tmp/libjpeg-turbo -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=/usr/lib64 \
  -DENABLE_STATIC=OFF -DWITH_SIMD=ON -DWITH_JPEG8=ON
cmake --build /tmp/libjpeg-turbo/build
cmake --install /tmp/libjpeg-turbo/build
rm -rf /tmp/libjpeg-turbo

# 11. Build Arrow Lake-S SQLite3 (dynamically matching system or latest upstream)
SYS_SQLITE_VER=$(get_rpm_ver sqlite-libs)
clone_dynamic "https://github.com/sqlite/sqlite.git" "/tmp/sqlite" "${SYS_SQLITE_VER:+version-${SYS_SQLITE_VER}}" "^version-[0-9]+\.[0-9]+\.[0-9]+$"
cd /tmp/sqlite
./configure --prefix=/usr --libdir=/usr/lib64 --disable-static --disable-tcl --soname=legacy \
  CFLAGS="${CFLAGS} -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_RTREE -DSQLITE_ENABLE_MEMSYS5 -DSQLITE_ENABLE_COLUMN_METADATA"
make -j"$(nproc)"
make install
cd / && rm -rf /tmp/sqlite

# 12. Build Arrow Lake-S SLEEF SIMD Math Library (dynamically matching latest upstream)
SYS_SLEEF_VER=$(get_rpm_ver sleef)
clone_dynamic "https://github.com/shibatch/sleef.git" "/tmp/sleef" "${SYS_SLEEF_VER}" "^[0-9]+\.[0-9]+(\.[0-9]+)?$"
cmake -B /tmp/sleef/build -S /tmp/sleef -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=/usr/lib64 \
  -DBUILD_SHARED_LIBS=ON -DBUILD_TESTS=OFF -DSLEEF_ENABLE_AVX512F=OFF -DSLEEF_BUILD_QUAD=OFF
cmake --build /tmp/sleef/build
cmake --install /tmp/sleef/build
rm -rf /tmp/sleef

# 14. Build Arrow Lake-S AVX2 Fast Memory Primitives (libfastmem.so for memcpy & memset)
mkdir -p /tmp/fastmem
cat << 'EOF' > /tmp/fastmem/fastmem.c
#define _GNU_SOURCE
#include <stddef.h>
#include <stdint.h>
#include <immintrin.h>

void *memcpy(void *dest, const void *src, size_t n) {
    char *d = (char *)dest;
    const char *s = (const char *)src;
    if (n >= 64) {
        size_t chunks = n / 32;
        __m256i *d_vec = (__m256i *)d;
        const __m256i *s_vec = (const __m256i *)s;
        while (chunks--) {
            _mm256_storeu_si256(d_vec++, _mm256_loadu_si256(s_vec++));
        }
        d = (char *)d_vec;
        s = (const char *)s_vec;
        n %= 32;
    }
    while (n--) {
        *d++ = *s++;
    }
    return dest;
}

void *memset(void *s, int c, size_t n) {
    char *p = (char *)s;
    if (n >= 64) {
        __m256i v = _mm256_set1_epi8((char)c);
        size_t chunks = n / 32;
        __m256i *p_vec = (__m256i *)p;
        while (chunks--) {
            _mm256_storeu_si256(p_vec++, v);
        }
        p = (char *)p_vec;
        n %= 32;
    }
    while (n--) {
        *p++ = (char)c;
    }
    return s;
}
EOF
gcc -O3 -march=arrowlake-s -mtune=arrowlake-s -fPIC -shared -fno-builtin-memcpy -fno-builtin-memset \
  -Wl,-O3 -Wl,-s /tmp/fastmem/fastmem.c -o /usr/lib64/libfastmem.so
rm -rf /tmp/fastmem

# 15. Build Arrow Lake-S xxHash (dynamically matching system or latest upstream)
SYS_XXHASH_VER=$(get_rpm_ver xxhash-libs)
clone_dynamic "https://github.com/Cyan4973/xxHash.git" "/tmp/xxhash" "${SYS_XXHASH_VER:+v${SYS_XXHASH_VER}}" "^v[0-9]+\.[0-9]+\.[0-9]+$"
make -C /tmp/xxhash -j"$(nproc)" CFLAGS="${CFLAGS} -fPIC"
make -C /tmp/xxhash install PREFIX=/usr LIBDIR=/usr/lib64
rm -rf /tmp/xxhash

# 16. Build Arrow Lake-S Vulkan Loader (dynamically matching system or latest upstream SDK tag)
SYS_VK_VER=$(get_rpm_ver vulkan-loader.x86_64 vulkan-loader)
# Try both vX.Y.Z and vulkan-sdk-X.Y.Z.0 formats dynamically
VK_TAG=""
if [ -n "${SYS_VK_VER}" ]; then
    if git ls-remote --exit-code --tags https://github.com/KhronosGroup/Vulkan-Loader.git "refs/tags/v${SYS_VK_VER}" >/dev/null 2>&1; then
        VK_TAG="v${SYS_VK_VER}"
    elif git ls-remote --exit-code --tags https://github.com/KhronosGroup/Vulkan-Loader.git "refs/tags/vulkan-sdk-${SYS_VK_VER}" >/dev/null 2>&1; then
        VK_TAG="vulkan-sdk-${SYS_VK_VER}"
    elif git ls-remote --exit-code --tags https://github.com/KhronosGroup/Vulkan-Loader.git "refs/tags/vulkan-sdk-${SYS_VK_VER}.0" >/dev/null 2>&1; then
        VK_TAG="vulkan-sdk-${SYS_VK_VER}.0"
    fi
fi
clone_dynamic "https://github.com/KhronosGroup/Vulkan-Loader.git" "/tmp/vulkan-loader" "${VK_TAG}" "^(v|vulkan-sdk-)[0-9]+\.[0-9]+\.[0-9]+(\.[0-9]+)?$"
cmake -B /tmp/vulkan-loader/build -S /tmp/vulkan-loader -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=/usr/lib64 \
  -DBUILD_TESTS=OFF -DENABLE_WERROR=OFF
cmake --build /tmp/vulkan-loader/build
cmake --install /tmp/vulkan-loader/build
rm -rf /tmp/vulkan-loader

# 17. Build Arrow Lake-S Sched-Ext Schedulers (scx_bpfland, scx_lavd, scx_rusty)
SYS_SCX_VER=$(get_rpm_ver scx-scheds scx-scheds-git)
clone_dynamic "https://github.com/sched-ext/scx.git" "/tmp/scx" "${SYS_SCX_VER:+v${SYS_SCX_VER}}" "^v[0-9]+\.[0-9]+\.[0-9]+$"
cargo build --release --manifest-path /tmp/scx/Cargo.toml -p scx_bpfland -p scx_lavd -p scx_rusty
for sched in scx_bpfland scx_lavd scx_rusty; do
  if [ -f "/tmp/scx/target/release/${sched}" ]; then
    install -m 755 "/tmp/scx/target/release/${sched}" "/usr/bin/${sched}"
  fi
done
rm -rf /tmp/scx /root/.cargo /tmp/cargo-home
unset RUSTFLAGS

# 18. Build Arrow Lake-S FreeType (libfreetype.so.6) & HarfBuzz (libharfbuzz.so.0)
SYS_FREETYPE_VER=$(get_rpm_ver freetype)
FREETYPE_TAG="${SYS_FREETYPE_VER:+VER-$(echo "${SYS_FREETYPE_VER}" | tr '.' '-')}"
clone_dynamic "https://gitlab.freedesktop.org/freetype/freetype.git" "/tmp/freetype" "${FREETYPE_TAG}" "^VER-[0-9]+-[0-9]+-[0-9]+$"

SYS_HARFBUZZ_VER=$(get_rpm_ver harfbuzz)
clone_dynamic "https://github.com/harfbuzz/harfbuzz.git" "/tmp/harfbuzz" "${SYS_HARFBUZZ_VER}" "^[0-9]+\.[0-9]+\.[0-9]+$"

# Stage 1: FreeType baseline build without HarfBuzz dependency
meson setup /tmp/freetype/build /tmp/freetype \
  --prefix=/usr --libdir=/usr/lib64 --buildtype=release \
  -Ddefault_library=shared -Dbrotli=auto -Dbzip2=auto -Dpng=auto -Dzlib=system -Dharfbuzz=disabled -Dtests=disabled
meson compile -C /tmp/freetype/build
meson install -C /tmp/freetype/build

# Stage 2: HarfBuzz build compiled against optimized FreeType
meson setup /tmp/harfbuzz/build /tmp/harfbuzz \
  --prefix=/usr --libdir=/usr/lib64 --buildtype=release \
  -Ddefault_library=shared -Dglib=enabled -Dgobject=enabled -Dcairo=auto -Dfreetype=enabled \
  -Dtests=disabled -Ddocs=disabled -Dutilities=disabled -Dbenchmark=disabled
meson compile -C /tmp/harfbuzz/build
meson install -C /tmp/harfbuzz/build

# Stage 3: Reconfigure & re-link FreeType with HarfBuzz auto-hinting enabled
meson configure /tmp/freetype/build -Dharfbuzz=enabled
meson compile -C /tmp/freetype/build
meson install -C /tmp/freetype/build
rm -rf /tmp/freetype /tmp/harfbuzz

# 19. Build Arrow Lake-S Gamescope (Valve's Micro-Compositor)
SYS_GAMESCOPE_VER=$(get_rpm_ver terra-gamescope gamescope)
clone_dynamic "https://github.com/ValveSoftware/gamescope.git" "/tmp/gamescope" "${SYS_GAMESCOPE_VER}" "^3\.[0-9]+\.[0-9]+$" --shallow-submodules --recurse-submodules

meson setup /tmp/gamescope/build /tmp/gamescope \
  --prefix=/usr \
  --libdir=/usr/lib64 \
  --buildtype=release \
  -Davif_screenshots=enabled \
  -Dbenchmark=disabled \
  -Ddrm_backend=enabled \
  -Denable_gamescope=true \
  -Denable_gamescope_wsi_layer=true \
  -Denable_openvr_support=false \
  -Denable_tests=false \
  -Dinput_emulation=enabled \
  -Dpipewire=enabled \
  -Drt_cap=enabled \
  -Dsdl2_backend=enabled
meson compile -C /tmp/gamescope/build
meson install -C /tmp/gamescope/build
setcap 'CAP_SYS_NICE=eip' /usr/bin/gamescope || true
rm -rf /tmp/gamescope

# Refresh shared library cache
ldconfig

# 20. Clear userspace LTO flags
unset CFLAGS CXXFLAGS LDFLAGS

# 21. Install Custom Arrow Lake-S Kernel & Matching NVIDIA Driver (with Self-Healing Contract)
export KCFLAGS="-O3 -march=arrowlake-s -mtune=arrowlake-s -pipe -Wno-error"

dnf5 install -y oras

# Dynamically match Fedora release version for the ORAS kernel tag (with fallback to latest-fc44)
FEDORA_VER=$(rpm -E %fedora)
mkdir -p /tmp/ogc-rpms
oras pull "ghcr.io/missessofiachan/kernel-packagesarrowlake-fedora:latest-fc${FEDORA_VER}" -o /tmp/ogc-rpms || \
oras pull "ghcr.io/missessofiachan/kernel-packagesarrowlake-fedora:latest-fc44" -o /tmp/ogc-rpms
ls -la /tmp/ogc-rpms

# Dynamically detect base image NVIDIA driver version & target custom kernel version from RPM metadata
SYS_NVIDIA_VER=$(get_rpm_ver nvidia-driver nvidia-driver-cuda)
KVER=$(rpm -qp --qf "%{VERSION}-%{RELEASE}.%{ARCH}\n" /tmp/ogc-rpms/kernel-core-*.rpm 2>/dev/null | head -n 1)

if [ -z "${KVER}" ]; then
    echo "::error:: Could not determine kernel version from downloaded kernel-core RPM!"
    exit 1
fi

# Prevent any stale conflicting kmod-nvidia-open RPM from ever being installed
rm -f /tmp/ogc-rpms/kmod-nvidia-open-*.rpm

# Overwrite stock kernel RPMs
rm -rf "/usr/lib/modules/${KVER}"
rpm -Uvh --oldpackage --replacepkgs --replacefiles --noscripts --nodeps \
    /tmp/ogc-rpms/kernel-[0-9]*.rpm \
    /tmp/ogc-rpms/kernel-core-*.rpm \
    /tmp/ogc-rpms/kernel-modules-*.rpm \
    /tmp/ogc-rpms/kernel-devel-*.rpm \
    /tmp/ogc-rpms/kernel-headers-*.rpm \
    /tmp/ogc-rpms/kernel-tools-*.rpm

# Check pre-built kmod-nvidia version from the ORAS package
KMOD_NVIDIA_VER=$(rpm -qp --qf "%{VERSION}\n" /tmp/ogc-rpms/kmod-nvidia-*.rpm 2>/dev/null | grep -v open | head -n 1 || true)
echo "Base system NVIDIA version : ${SYS_NVIDIA_VER}"
echo "Prebuilt kmod-nvidia version: ${KMOD_NVIDIA_VER}"
echo "Target kernel version       : ${KVER}"

# Self-healing contract: install prebuilt matching kmod OR compile in-place
if [ -n "${KMOD_NVIDIA_VER}" ] && [ -n "${SYS_NVIDIA_VER}" ] && [ "${KMOD_NVIDIA_VER}" = "${SYS_NVIDIA_VER}" ]; then
    echo "Using prebuilt matching kmod-nvidia RPM (${KMOD_NVIDIA_VER})..."
    rpm -Uvh --oldpackage --replacepkgs --replacefiles --noscripts --nodeps /tmp/ogc-rpms/kmod-nvidia-*.rpm
else
    echo "Prebuilt kmod-nvidia (${KMOD_NVIDIA_VER:-none}) does not match base image (${SYS_NVIDIA_VER}). Compiling in-place with akmods..."
    cat << 'EOF' > /etc/yum.repos.d/negativo17-fedora-nvidia.repo
[fedora-nvidia]
name=negativo17 - Nvidia
baseurl=https://negativo17.org/repos/nvidia/fedora-$releasever/$basearch/
enabled=1
gpgcheck=1
gpgkey=https://negativo17.org/repos/RPM-GPG-KEY-slaanesh
repo_gpgcheck=0
skip_if_unavailable=1
priority=70
EOF
    dnf5 install -y --enablerepo=fedora-nvidia akmod-nvidia akmods
    akmods --force --kernels "${KVER}" --kmod nvidia
    find /var/cache/akmods/ -name "kmod-nvidia-*.rpm" -exec rpm -Uvh --oldpackage --replacepkgs --replacefiles --noscripts --nodeps {} \;
fi

# Install any auxiliary kmods (e.g. xone, v4l2loopback)
if compgen -G "/tmp/ogc-rpms/kmod-*.rpm" > /dev/null; then
    rpm -Uvh --oldpackage --replacepkgs --replacefiles --noscripts --nodeps /tmp/ogc-rpms/kmod-*.rpm || true
fi

# Ensure vmlinuz is placed in bootc standard location (/usr/lib/modules/${KVER}/vmlinuz) and clean /boot
if [ -f "/boot/vmlinuz-${KVER}" ] && [ ! -f "/usr/lib/modules/${KVER}/vmlinuz" ]; then
    cp -a "/boot/vmlinuz-${KVER}" "/usr/lib/modules/${KVER}/vmlinuz"
fi
rm -f /boot/vmlinuz* /boot/initramfs*

# Generate module dependencies & initramfs
depmod -a "${KVER}"

# Strict verification gate: fail build immediately if modules or firmware mismatch
if ! modinfo -k "${KVER}" nvidia > /dev/null 2>&1; then
    echo "::error:: NVIDIA kernel module failed to link or is missing for kernel ${KVER}!"
    exit 1
fi

KMOD_ACTIVE_VER=$(modinfo -k "${KVER}" -F version nvidia 2>/dev/null || true)
echo "Verified NVIDIA kernel module version: ${KMOD_ACTIVE_VER}"

if [ ! -d "/lib/firmware/nvidia/${KMOD_ACTIVE_VER}" ]; then
    echo "::error:: Missing GSP firmware in /lib/firmware/nvidia/${KMOD_ACTIVE_VER}! Fallback will occur if booted."
    exit 1
fi

export DRACUT_NO_XATTR=1
dracut --no-hostonly --kver "${KVER}" --reproducible -v --add ostree -f "/usr/lib/modules/${KVER}/initramfs.img"
chmod 0600 "/usr/lib/modules/${KVER}/initramfs.img"
rm -rf /tmp/ogc-rpms

# 22. Clean up build tools and caches (Keep runtime libraries intact)
dnf5 remove -y cmake meson ninja-build autoconf automake libtool golang-oras oras akmods \
    clang bpftool libbpf-devel elfutils-libelf-devel rust cargo vulkan-headers \
    brotli-devel bzip2-devel libpng-devel glib2-devel libicu-devel \
    libxcb-devel xcb-util-devel xcb-util-wm-devel xcb-util-image-devel \
    xcb-util-keysyms-devel xcb-util-renderutil-devel \
    libX11-devel libXrandr-devel libXdamage-devel libXcomposite-devel libXcursor-devel \
    libXrender-devel libXext-devel libXfixes-devel libXxf86vm-devel libXtst-devel \
    libXres-devel libXmu-devel libXi-devel libdrm-devel libeis-devel \
    wayland-devel wayland-protocols-devel libxkbcommon-devel libcap-devel \
    sdl2-compat-devel libavif-devel pixman-devel systemd-devel libdecor-devel \
    luajit-devel libinput-devel pipewire-devel glslang \
    spirv-headers-devel glm-devel libseat-devel lcms2-devel \
    xorg-x11-server-Xwayland-devel || true
dnf5 clean all
ldconfig

# 23. Install Mullvad VPN, Visual Studio Code & Google Antigravity GUI
rm -f /opt && mkdir -p /opt

# 23a. Mullvad VPN (Client, CLI & systemd daemon)
dnf5 config-manager addrepo --from-repofile=https://repository.mullvad.net/rpm/stable/mullvad.repo
dnf5 install -y mullvad-vpn
dnf5 clean all

# 23b. Visual Studio Code
rpm --import https://packages.microsoft.com/keys/microsoft.asc
cat << 'EOF' > /etc/yum.repos.d/vscode.repo
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF
dnf5 install -y code
dnf5 clean all

# 23c. Google Antigravity GUI program (Dynamic GCS latest build lookup with safe fallback)
mkdir -p /opt/antigravity
ANTIGRAVITY_FALLBACK_URL="https://storage.googleapis.com/antigravity-public/antigravity-hub/2.23.0-5238607586394112/linux-x64/Antigravity.tar.gz"
ANTIGRAVITY_LATEST_PATH=$(curl -fsSL "https://storage.googleapis.com/storage/v1/b/antigravity-public/o?prefix=antigravity-hub/" 2>/dev/null \
    | jq -r '.items[]?.name | select(endswith("/linux-x64/Antigravity.tar.gz"))' 2>/dev/null \
    | sort -V | tail -n 1 || true)

if [ -n "${ANTIGRAVITY_LATEST_PATH}" ]; then
    ANTIGRAVITY_URL="https://storage.googleapis.com/antigravity-public/${ANTIGRAVITY_LATEST_PATH}"
else
    ANTIGRAVITY_URL="${ANTIGRAVITY_FALLBACK_URL}"
fi
echo "--> Downloading Antigravity from: ${ANTIGRAVITY_URL}"
curl -sSL "${ANTIGRAVITY_URL}" | tar -xz -C /opt/antigravity --strip-components=1
ln -sf /opt/antigravity/antigravity /usr/bin/antigravity

mkdir -p /usr/share/applications
cat << 'EOF' > /usr/share/applications/antigravity.desktop
[Desktop Entry]
Name=Antigravity
Comment=Google Antigravity GUI Program
GenericName=GUI Program
Exec=/usr/bin/antigravity %F
Icon=antigravity
Type=Application
StartupNotify=true
StartupWMClass=Antigravity
Categories=Development;IDE;Utility;
MimeType=x-scheme-handler/antigravity;
Keywords=antigravity;gui;
EOF

cat << 'EOF' > /usr/share/applications/antigravity-url-handler.desktop
[Desktop Entry]
Name=Antigravity - URL Handler
Comment=Google Antigravity GUI Program URL Handler
GenericName=GUI Program
Exec=/usr/bin/antigravity "%U"
Icon=antigravity
Type=Application
NoDisplay=true
Terminal=false
StartupNotify=true
StartupWMClass=Antigravity
Categories=Utility;Development;
MimeType=x-scheme-handler/antigravity;
Keywords=antigravity;
EOF

update-desktop-database /usr/share/applications || true

# 24. Enable services
systemctl enable scx_loader.service
systemctl enable mullvad-daemon.service
systemctl mask NetworkManager-wait-online.service
