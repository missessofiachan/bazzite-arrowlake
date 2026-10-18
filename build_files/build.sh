#!/usr/bin/bash
set -ouex pipefail

export HOME=/tmp
export CMAKE_POLICY_VERSION_MINIMUM=3.5

# ==============================================================================
# Dynamic Version & Tag Resolution Helpers
# ==============================================================================
# 1. Query installed RPM version cleanly (strips epochs and release suffixes)
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

# 2. Install temporary compiler toolchain (including ccache, binutils, libxcb-devel & xcb-util-*)
BUILD_DEPS=(
    gcc gcc-c++ make cmake ninja-build meson autoconf automake libtool pkgconf-pkg-config
    ccache binutils git bzip2 curl jq
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
)
dnf5 install -y --setopt=disable_excludes=* "${BUILD_DEPS[@]}"

# Provide xwayland.pc for wlroots/gamescope when terra-xorg-x11-server-Xwayland is installed
# (Fedora's xorg-x11-server-Xwayland-devel conflicts with Terra's newer Xwayland package)
if [ ! -f /usr/share/pkgconfig/xwayland.pc ] && [ ! -f /usr/lib64/pkgconfig/xwayland.pc ]; then
    XWAYLAND_VER=$(get_rpm_ver terra-xorg-x11-server-Xwayland xorg-x11-server-Xwayland)
    mkdir -p /usr/share/pkgconfig
    cat << EOF > /usr/share/pkgconfig/xwayland.pc
prefix=/usr
exec_prefix=\${prefix}
xwayland=/usr/bin/Xwayland
have_glamor=true
have_eglstream=false
have_initfd=true
have_listenfd=true
have_verbose=true
have_terminate_delay=true
have_no_touch_pointer_emulation=true
have_force_xrandr_emulation=true
have_geometry=true
have_fullscreen=true
have_host_grab=true
have_decorate=true
have_enable_ei_portal=true
have_byteswappedclients=true
have_hidpi=true

Name: Xwayland
Description: X Server for Wayland
Version: ${XWAYLAND_VER:-24.1.0}
EOF
fi

export PKG_CONFIG_PATH="/usr/lib64/pkgconfig:/usr/share/pkgconfig:${PKG_CONFIG_PATH:-}"

# Configure persistent ccache & Cargo cache inside /var/cache mount
mkdir -p /var/cache/ccache /var/cache/cargo /var/cache/cargo-target
export CCACHE_DIR="/var/cache/ccache"
export CCACHE_COMPRESS=1
export CCACHE_MAXSIZE="5G"
export CARGO_HOME="/var/cache/cargo"
export CARGO_TARGET_DIR="/var/cache/cargo-target"
export CMAKE_C_COMPILER_LAUNCHER=ccache
export CMAKE_CXX_COMPILER_LAUNCHER=ccache

# 3. Arrow Lake-S optimization flags (Userspace Libraries & Rust)
# -fno-semantic-interposition + -Wl,-Bsymbolic-functions eliminates PLT/GOT overhead for internal library calls
# -fdata-sections -ffunction-sections + -Wl,--gc-sections minimizes L1i cache footprint on Lion Cove & Skymont
export CFLAGS="-O3 -march=arrowlake-s -mtune=arrowlake-s -flto=auto -fno-plt -fno-semantic-interposition -fomit-frame-pointer -momit-leaf-frame-pointer -fdata-sections -ffunction-sections -pipe -g0"
export CXXFLAGS="${CFLAGS}"
export LDFLAGS="-Wl,-O3 -Wl,--as-needed -Wl,-Bsymbolic-functions -Wl,--gc-sections -flto=auto -Wl,-s"
export RUSTFLAGS="-C target-cpu=arrowlake-s -C opt-level=3 -C codegen-units=1 -C strip=symbols -C lto=thin -C embed-bitcode=yes"

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
  -DWITH_AVX2=ON -DWITH_SSE42=ON -DWITH_PCLMULQDQ=ON -DWITH_VPCLMULQDQ=ON \
  -DWITH_AVX512=OFF -DWITH_AVX512VNNI=OFF -DBUILD_SHARED_LIBS=ON
cmake --build /tmp/zlib-ng/build
ZLIB_SO=$(find /tmp/zlib-ng/build -maxdepth 1 -type f -name "libz.so.1.*" | head -n 1)
install -m 755 "${ZLIB_SO}" /usr/lib64/
ln -sf "$(basename "${ZLIB_SO}")" /usr/lib64/libz.so.1
ln -sf libz.so.1 /usr/lib64/libz.so
rm -rf /tmp/zlib-ng

# 7. Build Arrow Lake-S zstd (shared library + native CLI binaries for dracut & asset streaming)
SYS_ZSTD_VER=$(get_rpm_ver libzstd zstd)
clone_dynamic "https://github.com/facebook/zstd.git" "/tmp/zstd" "${SYS_ZSTD_VER:+v${SYS_ZSTD_VER}}" "^v[0-9]+\.[0-9]+\.[0-9]+$"
cmake -B /tmp/zstd/build_cmake -S /tmp/zstd/build/cmake -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=/usr/lib64 \
  -DZSTD_BUILD_STATIC=OFF -DZSTD_BUILD_PROGRAMS=ON -DZSTD_BUILD_TESTS=OFF
cmake --build /tmp/zstd/build_cmake
cmake --install /tmp/zstd/build_cmake
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

# 9. Build Arrow Lake-S lz4 (shared library + native CLI binary)
SYS_LZ4_VER=$(get_rpm_ver lz4-libs lz4)
clone_dynamic "https://github.com/lz4/lz4.git" "/tmp/lz4" "${SYS_LZ4_VER:+v${SYS_LZ4_VER}}" "^v[0-9]+\.[0-9]+\.[0-9]+$"
make -C /tmp/lz4 -j"$(nproc)" BUILD_STATIC=no CFLAGS="${CFLAGS} -fPIC"
make -C /tmp/lz4 install PREFIX=/usr LIBDIR=/usr/lib64 BUILD_STATIC=no
rm -rf /tmp/lz4

# 10. Build Arrow Lake-S libjpeg-turbo, libpng & brotli (Accelerated Texture, UI & Web Decoding)
SYS_JPEG_VER=$(get_rpm_ver libjpeg-turbo)
clone_dynamic "https://github.com/libjpeg-turbo/libjpeg-turbo.git" "/tmp/libjpeg-turbo" "${SYS_JPEG_VER}" "^[0-9]+\.[0-9]+\.[0-9]+$"
cmake -B /tmp/libjpeg-turbo/build -S /tmp/libjpeg-turbo -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=/usr/lib64 \
  -DENABLE_STATIC=OFF -DWITH_SIMD=ON -DWITH_JPEG8=ON
cmake --build /tmp/libjpeg-turbo/build
cmake --install /tmp/libjpeg-turbo/build
rm -rf /tmp/libjpeg-turbo

SYS_PNG_VER=$(get_rpm_ver libpng)
clone_dynamic "https://github.com/pnggroup/libpng.git" "/tmp/libpng" "${SYS_PNG_VER:+v${SYS_PNG_VER}}" "^v1\.6\.[0-9]+$"
cmake -B /tmp/libpng/build -S /tmp/libpng -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=/usr/lib64 \
  -DPNG_SHARED=ON -DPNG_STATIC=OFF -DPNG_TESTS=OFF -DPNG_HARDWARE_OPTIMIZATIONS=ON
cmake --build /tmp/libpng/build
cmake --install /tmp/libpng/build
rm -rf /tmp/libpng

SYS_BROTLI_VER=$(get_rpm_ver libbrotli brotli)
clone_dynamic "https://github.com/google/brotli.git" "/tmp/brotli" "${SYS_BROTLI_VER:+v${SYS_BROTLI_VER}}" "^v[0-9]+\.[0-9]+\.[0-9]+$"
cmake -B /tmp/brotli/build -S /tmp/brotli -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=/usr/lib64 \
  -DBUILD_SHARED_LIBS=ON -DBROTLI_DISABLE_TESTS=ON
cmake --build /tmp/brotli/build
cmake --install /tmp/brotli/build
rm -rf /tmp/brotli

# 11. Build Arrow Lake-S SQLite3 (dynamically matching system or latest upstream)
SYS_SQLITE_VER=$(get_rpm_ver sqlite-libs)
clone_dynamic "https://github.com/sqlite/sqlite.git" "/tmp/sqlite" "${SYS_SQLITE_VER:+version-${SYS_SQLITE_VER}}" "^version-[0-9]+\.[0-9]+\.[0-9]+$"
cd /tmp/sqlite
./configure --prefix=/usr --libdir=/usr/lib64 --disable-static --disable-tcl --soname=legacy \
  CFLAGS="${CFLAGS} -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_RTREE -DSQLITE_ENABLE_MEMSYS5 -DSQLITE_ENABLE_COLUMN_METADATA -DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1"
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

# 14. Build Arrow Lake-S AVX2 Fast Memory Primitives (libfastmem.so: 4x-unrolled AVX2 + branchless tails + ERMS)
mkdir -p /tmp/fastmem
cat << 'EOF' > /tmp/fastmem/fastmem.c
#define _GNU_SOURCE
#include <stddef.h>
#include <stdint.h>
#include <immintrin.h>

/*
 * Arrow Lake-S (Lion Cove + Skymont) Tuned Memory Primitives:
 * - < 32B: Branchless overlapping scalar/XMM transfers
 * - 32B..128B: Overlapping unaligned 256-bit YMM loads/stores (zero byte-loop tails)
 * - 128B..2MB: 4x-unrolled (128B / 2-cache-line) AVX2 YMM loop with overlapping 32B tail
 * - > 2MB: Hardware Enhanced REP MOVSB / STOSB (ERMS) to avoid L2 cache thrashing
 */

void *memcpy(void *restrict dest, const void *restrict src, size_t n) {
    uint8_t *d = (uint8_t *)dest;
    const uint8_t *s = (const uint8_t *)src;

    if (n < 32) {
        if (n >= 16) {
            __m128i head = _mm_loadu_si128((const __m128i *)s);
            __m128i tail = _mm_loadu_si128((const __m128i *)(s + n - 16));
            _mm_storeu_si128((__m128i *)d, head);
            _mm_storeu_si128((__m128i *)(d + n - 16), tail);
            return dest;
        }
        if (n >= 8) {
            uint64_t head = *(const uint64_t *)s;
            uint64_t tail = *(const uint64_t *)(s + n - 8);
            *(uint64_t *)d = head;
            *(uint64_t *)(d + n - 8) = tail;
            return dest;
        }
        if (n >= 4) {
            uint32_t head = *(const uint32_t *)s;
            uint32_t tail = *(const uint32_t *)(s + n - 4);
            *(uint32_t *)d = head;
            *(uint32_t *)(d + n - 4) = tail;
            return dest;
        }
        if (n > 0) {
            d[0] = s[0];
            d[n >> 1] = s[n >> 1];
            d[n - 1] = s[n - 1];
        }
        return dest;
    }

    if (n <= 128) {
        __m256i first = _mm256_loadu_si256((const __m256i *)s);
        __m256i last  = _mm256_loadu_si256((const __m256i *)(s + n - 32));
        if (n > 64) {
            __m256i second = _mm256_loadu_si256((const __m256i *)(s + 32));
            __m256i second_last = _mm256_loadu_si256((const __m256i *)(s + n - 64));
            _mm256_storeu_si256((__m256i *)(d + 32), second);
            _mm256_storeu_si256((__m256i *)(d + n - 64), second_last);
        }
        _mm256_storeu_si256((__m256i *)d, first);
        _mm256_storeu_si256((__m256i *)(d + n - 32), last);
        _mm256_zeroupper();
        return dest;
    }

    if (n > (2u * 1024u * 1024u)) {
        void *d_erms = dest;
        const void *s_erms = src;
        size_t cnt = n;
        __asm__ __volatile__("rep movsb" : "+D"(d_erms), "+S"(s_erms), "+c"(cnt) : : "memory");
        return dest;
    }

    /* Save the final 128 bytes up front so the tail is handled branchlessly */
    __m256i tail0 = _mm256_loadu_si256((const __m256i *)(s + n - 128));
    __m256i tail1 = _mm256_loadu_si256((const __m256i *)(s + n - 96));
    __m256i tail2 = _mm256_loadu_si256((const __m256i *)(s + n - 64));
    __m256i tail3 = _mm256_loadu_si256((const __m256i *)(s + n - 32));

    uint8_t *d_end = d + n - 128;
    const uint8_t *s_cur = s;
    uint8_t *d_cur = d;

    do {
        __m256i v0 = _mm256_loadu_si256((const __m256i *)(s_cur + 0));
        __m256i v1 = _mm256_loadu_si256((const __m256i *)(s_cur + 32));
        __m256i v2 = _mm256_loadu_si256((const __m256i *)(s_cur + 64));
        __m256i v3 = _mm256_loadu_si256((const __m256i *)(s_cur + 96));
        _mm256_storeu_si256((__m256i *)(d_cur + 0), v0);
        _mm256_storeu_si256((__m256i *)(d_cur + 32), v1);
        _mm256_storeu_si256((__m256i *)(d_cur + 64), v2);
        _mm256_storeu_si256((__m256i *)(d_cur + 96), v3);
        s_cur += 128;
        d_cur += 128;
    } while (d_cur < d_end);

    _mm256_storeu_si256((__m256i *)(d + n - 128), tail0);
    _mm256_storeu_si256((__m256i *)(d + n - 96), tail1);
    _mm256_storeu_si256((__m256i *)(d + n - 64), tail2);
    _mm256_storeu_si256((__m256i *)(d + n - 32), tail3);
    _mm256_zeroupper();
    return dest;
}

void *memmove(void *dest, const void *src, size_t n) {
    uint8_t *d = (uint8_t *)dest;
    const uint8_t *s = (const uint8_t *)src;
    if (d == s || n == 0) return dest;
    if ((uintptr_t)(d - s) >= n) {
        return memcpy(dest, src, n);
    }
    /* Overlapping backward copy */
    while (n >= 32) {
        n -= 32;
        __m256i v = _mm256_loadu_si256((const __m256i *)(s + n));
        _mm256_storeu_si256((__m256i *)(d + n), v);
    }
    while (n > 0) {
        --n;
        d[n] = s[n];
    }
    _mm256_zeroupper();
    return dest;
}

void *memset(void *s, int c, size_t n) {
    uint8_t *p = (uint8_t *)s;
    uint8_t byte = (uint8_t)c;

    if (n < 32) {
        while (n--) *p++ = byte;
        return s;
    }

    __m256i v = _mm256_set1_epi8((char)byte);
    if (n <= 128) {
        _mm256_storeu_si256((__m256i *)p, v);
        _mm256_storeu_si256((__m256i *)(p + n - 32), v);
        if (n > 64) {
            _mm256_storeu_si256((__m256i *)(p + 32), v);
            _mm256_storeu_si256((__m256i *)(p + n - 64), v);
        }
        _mm256_zeroupper();
        return s;
    }

    uint8_t *p_end = p + n - 128;
    uint8_t *p_cur = p;
    do {
        _mm256_storeu_si256((__m256i *)(p_cur + 0), v);
        _mm256_storeu_si256((__m256i *)(p_cur + 32), v);
        _mm256_storeu_si256((__m256i *)(p_cur + 64), v);
        _mm256_storeu_si256((__m256i *)(p_cur + 96), v);
        p_cur += 128;
    } while (p_cur < p_end);

    _mm256_storeu_si256((__m256i *)(p + n - 128), v);
    _mm256_storeu_si256((__m256i *)(p + n - 96), v);
    _mm256_storeu_si256((__m256i *)(p + n - 64), v);
    _mm256_storeu_si256((__m256i *)(p + n - 32), v);
    _mm256_zeroupper();
    return s;
}

int memcmp(const void *s1, const void *s2, size_t n) {
    const uint8_t *a = (const uint8_t *)s1;
    const uint8_t *b = (const uint8_t *)s2;

    while (n >= 32) {
        __m256i va = _mm256_loadu_si256((const __m256i *)a);
        __m256i vb = _mm256_loadu_si256((const __m256i *)b);
        uint32_t mask = (uint32_t)_mm256_movemask_epi8(_mm256_cmpeq_epi8(va, vb));
        if (mask != 0xFFFFFFFFu) {
            int idx = __builtin_ctz(~mask);
            _mm256_zeroupper();
            return (int)a[idx] - (int)b[idx];
        }
        a += 32;
        b += 32;
        n -= 32;
    }
    _mm256_zeroupper();
    while (n--) {
        if (*a != *b) return (int)*a - (int)*b;
        a++;
        b++;
    }
    return 0;
}
EOF
gcc -O3 -march=arrowlake-s -mtune=arrowlake-s -fPIC -shared \
  -fno-builtin-memcpy -fno-builtin-memmove -fno-builtin-memset -fno-builtin-memcmp \
  -Wl,-O3 -Wl,-Bsymbolic-functions -Wl,-s /tmp/fastmem/fastmem.c -o /usr/lib64/libfastmem.so
rm -rf /tmp/fastmem

# Ensure Steam & Game Launch Wrappers exist and include topology-aware Lion Cove P-core pinning
cat << 'EOF' > /usr/bin/run-jemalloc
#!/usr/bin/bash
export LD_PRELOAD="/usr/lib64/libjemalloc.so.2${LD_PRELOAD:+:${LD_PRELOAD}}"
exec "$@"
EOF
cat << 'EOF' > /usr/bin/run-mimalloc
#!/usr/bin/bash
export LD_PRELOAD="/usr/lib64/libmimalloc.so.2${LD_PRELOAD:+:${LD_PRELOAD}}"
exec "$@"
EOF
cat << 'EOF' > /usr/bin/run-fastmem
#!/usr/bin/bash
export LD_PRELOAD="/usr/lib64/libfastmem.so${LD_PRELOAD:+:${LD_PRELOAD}}"
exec "$@"
EOF
cat << 'EOF' > /usr/bin/run-pcores
#!/usr/bin/bash
# Dynamically detect Arrow Lake Lion Cove P-cores via kernel CPU capacity/frequency topology (fallback: 0-7)
PCORES="0-7"
if [ -r /sys/devices/cpu_core/cpus ]; then
    PCORES=$(cat /sys/devices/cpu_core/cpus)
fi
exec taskset -c "${PCORES}" "$@"
EOF
chmod 0755 /usr/bin/run-jemalloc /usr/bin/run-mimalloc /usr/bin/run-fastmem /usr/bin/run-pcores

# 15. Build Arrow Lake-S xxHash (dynamically matching system or latest upstream)
SYS_XXHASH_VER=$(get_rpm_ver xxhash-libs)
clone_dynamic "https://github.com/Cyan4973/xxHash.git" "/tmp/xxhash" "${SYS_XXHASH_VER:+v${SYS_XXHASH_VER}}" "^v[0-9]+\.[0-9]+\.[0-9]+$"
make -C /tmp/xxhash -j"$(nproc)" CFLAGS="${CFLAGS} -fPIC"
make -C /tmp/xxhash install PREFIX=/usr LIBDIR=/usr/lib64
rm -rf /tmp/xxhash

# 16. Build Arrow Lake-S Vulkan Loader (dynamically matching system or latest upstream SDK tag)
SYS_VK_VER=$(get_rpm_ver vulkan-loader.x86_64 vulkan-loader)
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
  if [ -f "${CARGO_TARGET_DIR}/release/${sched}" ]; then
    install -m 755 "${CARGO_TARGET_DIR}/release/${sched}" "/usr/bin/${sched}"
  elif [ -f "/tmp/scx/target/release/${sched}" ]; then
    install -m 755 "/tmp/scx/target/release/${sched}" "/usr/bin/${sched}"
  fi
done
rm -rf /tmp/scx
unset RUSTFLAGS CARGO_HOME CARGO_TARGET_DIR

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

# 20. Clear userspace LTO & ccache flags before kernel module work
unset CFLAGS CXXFLAGS LDFLAGS CMAKE_C_COMPILER_LAUNCHER CMAKE_CXX_COMPILER_LAUNCHER

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

# Ensure unprivileged /dev/ntsync access for Proton-Sofia-ArrowLake
mkdir -p /usr/lib/udev/rules.d
cat << 'EOF' > /usr/lib/udev/rules.d/60-ntsync.rules
KERNEL=="ntsync", MODE="0666", TAG+="uaccess"
EOF

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

# 22. AVX-512 Safety Verification Gate (Ensure zero illegal zmm instructions in custom libraries)
echo "--> Running Arrow Lake-S AVX-512 (zmm) instruction sanity check..."
for lib in /usr/lib64/libfastmem.so /usr/lib64/libjemalloc.so.2 /usr/lib64/libmimalloc.so.2 /usr/lib64/libvulkan.so.1 /usr/lib64/libxxhash.so.0; do
    if [ -f "${lib}" ] && objdump -d "${lib}" 2>/dev/null | grep -q '%zmm'; then
        echo "::error:: Illegal AVX-512 (%zmm) register detected in ${lib}!"
        exit 1
    fi
done
echo "--> AVX-512 safety check passed: 0 illegal %zmm instructions found."

# 23. Clean up build tools and caches (Keep runtime libraries intact)
dnf5 remove -y cmake meson ninja-build autoconf automake libtool ccache golang-oras oras akmods \
    clang bpftool libbpf-devel elfutils-libelf-devel rust cargo vulkan-headers \
    brotli-devel bzip2-devel libpng-devel glib2-devel libicu-devel \
    libxcb-devel xcb-util-devel xcb-util-wm-devel xcb-util-image-devel \
    xcb-util-keysyms-devel xcb-util-renderutil-devel \
    libX11-devel libXrandr-devel libXdamage-devel libXcomposite-devel libXcursor-devel \
    libXrender-devel libXext-devel libXfixes-devel libXxf86vm-devel libXtst-devel \
    libXres-devel libXmu-devel libXi-devel libdrm-devel libeis-devel \
    wayland-devel wayland-protocols-devel libxkbcommon-devel libcap-devel \
    sdl2-compat-devel mesa-libGLU-devel libavif-devel pixman-devel systemd-devel libdecor-devel \
    luajit-devel libinput-devel pipewire-devel glslang \
    spirv-headers-devel glm-devel libseat-devel lcms2-devel || true
rm -f /usr/share/pkgconfig/xwayland.pc
dnf5 clean all
ldconfig

# 24. Install Mullvad VPN, Visual Studio Code & Google Antigravity GUI
rm -f /opt && mkdir -p /opt

# 24a. Mullvad VPN (Client, CLI & systemd daemon)
dnf5 config-manager addrepo --from-repofile=https://repository.mullvad.net/rpm/stable/mullvad.repo
dnf5 install -y mullvad-vpn
dnf5 clean all

# 24b. Visual Studio Code
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

# 24c. Google Antigravity GUI program (Dynamic GCS latest build lookup with safe fallback)
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

# 25. Enable services & Print Build Telemetry Summary
systemctl enable scx_loader.service
systemctl enable mullvad-daemon.service
systemctl mask NetworkManager-wait-online.service

echo "=============================================================================="
echo " Bazzite Arrow Lake-S Build Verification Summary"
echo "=============================================================================="
echo " Kernel Version       : ${KVER}"
echo " NVIDIA Module        : ${KMOD_ACTIVE_VER} (GSP Firmware Verified)"
echo " Initramfs Size       : $(du -h "/usr/lib/modules/${KVER}/initramfs.img" | awk '{print $1}')"
echo " Vulkan Loader        : $(readlink -f /usr/lib64/libvulkan.so.1)"
echo " Allocators           : jemalloc, mimalloc, fastmem (AVX2 4x-unrolled + ERMS)"
echo " Sched-Ext Binaries   : $(ls -1 /usr/bin/scx_* | tr '\n' ' ')"
echo " Launch Wrappers      : run-jemalloc, run-mimalloc, run-fastmem, run-pcores"
echo "=============================================================================="
