#!/usr/bin/bash
set -ouex pipefail

export HOME=/tmp
export CMAKE_POLICY_VERSION_MINIMUM=3.5

# 1. Copy baked-in system configs
cp -rv /ctx/system_files/* /
rm -f /usr/share/ublue-os/image-template-check

# 2. Install temporary compiler toolchain
dnf5 install -y gcc gcc-c++ make cmake ninja-build autoconf automake git bzip2 zlib-ng-compat-devel
# (Kernel module build deps 'elfutils-libelf-devel akmods' disabled while custom kernel is on hold)

# 3. Arrow Lake-S optimization flags (Userspace Libraries)
export CFLAGS="-O3 -march=arrowlake-s -mtune=arrowlake-s -flto=auto -fno-plt -pipe -g0"
export CXXFLAGS="${CFLAGS}"
export LDFLAGS="-Wl,-O3 -Wl,--as-needed -flto=auto -Wl,-s"

# 4. Build Arrow Lake-S jemalloc (libjemalloc.so.2)
git clone --depth 1 --branch 5.3.0 https://github.com/jemalloc/jemalloc.git /tmp/jemalloc
cd /tmp/jemalloc
./autogen.sh --prefix=/usr --libdir=/usr/lib64 --disable-stats --disable-cxx --disable-static --enable-autogen
make -j"$(nproc)" build_lib_shared
install -m 755 lib/libjemalloc.so.2 /usr/lib64/libjemalloc.so.2
ln -sf libjemalloc.so.2 /usr/lib64/libjemalloc.so
cd / && rm -rf /tmp/jemalloc

# 5. Build Arrow Lake-S mimalloc (libmimalloc.so.2)
git clone --depth 1 --branch v2.1.7 https://github.com/microsoft/mimalloc.git /tmp/mimalloc
cmake -B /tmp/mimalloc/build -S /tmp/mimalloc -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=/usr/lib64 \
  -DMI_BUILD_STATIC=OFF -DMI_BUILD_OBJECT=OFF -DMI_BUILD_TESTS=OFF -DMI_INSTALL_TOPLEVEL=ON
cmake --build /tmp/mimalloc/build
MIMALLOC_SO=$(find /tmp/mimalloc/build -maxdepth 1 -type f -name "libmimalloc.so.2.*")
install -m 755 "${MIMALLOC_SO}" /usr/lib64/
ln -sf "$(basename "${MIMALLOC_SO}")" /usr/lib64/libmimalloc.so.2
ln -sf libmimalloc.so.2 /usr/lib64/libmimalloc.so
rm -rf /tmp/mimalloc

# 6. Build Arrow Lake-S zlib-ng 2.3.3
git clone --depth 1 --branch 2.3.3 https://github.com/zlib-ng/zlib-ng.git /tmp/zlib-ng
sed -i 's/evex512//g' /tmp/zlib-ng/arch/x86/*.c /tmp/zlib-ng/CMakeLists.txt || true
cmake -B /tmp/zlib-ng/build -S /tmp/zlib-ng -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=/usr/lib64 \
  -DZLIB_COMPAT=ON -DZLIB_ENABLE_TESTS=OFF -DWITH_GTEST=OFF -DWITH_NATIVE_INSTRUCTIONS=OFF \
  -DWITH_AVX512=OFF -DWITH_AVX512VNNI=OFF -DBUILD_SHARED_LIBS=ON
cmake --build /tmp/zlib-ng/build
ZLIB_SO=$(find /tmp/zlib-ng/build -maxdepth 1 -type f -name "libz.so.1.*")
install -m 755 "${ZLIB_SO}" /usr/lib64/
ln -sf "$(basename "${ZLIB_SO}")" /usr/lib64/libz.so.1
rm -rf /tmp/zlib-ng

# 7. Build Arrow Lake-S zstd (libzstd.so.1)
git clone --depth 1 --branch v1.5.7 https://github.com/facebook/zstd.git /tmp/zstd
cmake -B /tmp/zstd/build_cmake -S /tmp/zstd/build/cmake -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=/usr/lib64 \
  -DZSTD_BUILD_STATIC=OFF -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_TESTS=OFF
cmake --build /tmp/zstd/build_cmake
ZSTD_SO=$(find /tmp/zstd/build_cmake/lib -maxdepth 1 -type f -name "libzstd.so.1.*")
install -m 755 "${ZSTD_SO}" /usr/lib64/
ln -sf "$(basename "${ZSTD_SO}")" /usr/lib64/libzstd.so.1
rm -rf /tmp/zstd

# 8. Build Arrow Lake-S libdeflate (libdeflate.so.0)
git clone --depth 1 https://github.com/ebiggers/libdeflate.git /tmp/libdeflate
sed -i 's/,evex512//g; s/"evex512"/""/g' /tmp/libdeflate/lib/x86/*.h
cmake -B /tmp/libdeflate/build -S /tmp/libdeflate -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=/usr/lib64 \
  -DLIBDEFLATE_BUILD_STATIC_LIB=OFF -DLIBDEFLATE_BUILD_GZIP=OFF -DLIBDEFLATE_BUILD_TESTS=OFF
cmake --build /tmp/libdeflate/build
install -m 755 /tmp/libdeflate/build/libdeflate.so.0 /usr/lib64/libdeflate.so.0
ln -sf libdeflate.so.0 /usr/lib64/libdeflate.so
rm -rf /tmp/libdeflate

# 9. Build Arrow Lake-S lz4 (liblz4.so.1)
git clone --depth 1 --branch v1.10.0 https://github.com/lz4/lz4.git /tmp/lz4
make -C /tmp/lz4/lib -j"$(nproc)" BUILD_STATIC=no CFLAGS="${CFLAGS} -fPIC"
LZ4_SO=$(find /tmp/lz4/lib -maxdepth 1 -type f -name "liblz4.so.1.*")
install -m 755 "${LZ4_SO}" /usr/lib64/
ln -sf "$(basename "${LZ4_SO}")" /usr/lib64/liblz4.so.1
rm -rf /tmp/lz4

# 10. Build Arrow Lake-S libjpeg-turbo (libjpeg.so.62 & libturbojpeg.so.0)
git clone --depth 1 --branch 3.1.0 https://github.com/libjpeg-turbo/libjpeg-turbo.git /tmp/libjpeg-turbo
cmake -B /tmp/libjpeg-turbo/build -S /tmp/libjpeg-turbo -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=/usr/lib64 \
  -DENABLE_STATIC=OFF -DWITH_SIMD=ON -DWITH_JPEG8=ON
cmake --build /tmp/libjpeg-turbo/build
cmake --install /tmp/libjpeg-turbo/build
rm -rf /tmp/libjpeg-turbo

# 11. Build Arrow Lake-S SQLite3 (libsqlite3.so.0)
git clone --depth 1 --branch version-3.48.0 https://github.com/sqlite/sqlite.git /tmp/sqlite
cd /tmp/sqlite
./configure --prefix=/usr --libdir=/usr/lib64 --disable-static --disable-tcl --soname=legacy \
  CFLAGS="${CFLAGS} -DSQLITE_ENABLE_FTS5 -DSQLITE_ENABLE_RTREE -DSQLITE_ENABLE_MEMSYS5 -DSQLITE_ENABLE_COLUMN_METADATA"
make -j"$(nproc)"
make install
cd / && rm -rf /tmp/sqlite

# 12. Build Arrow Lake-S SLEEF SIMD Math Library (libsleef.so.3)
git clone --depth 1 --branch 3.6.1 https://github.com/shibatch/sleef.git /tmp/sleef
cmake -B /tmp/sleef/build -S /tmp/sleef -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=/usr/lib64 \
  -DBUILD_SHARED_LIBS=ON -DBUILD_TESTS=OFF -DSLEEF_ENABLE_AVX512F=OFF
cmake --build /tmp/sleef/build
cmake --install /tmp/sleef/build
rm -rf /tmp/sleef

# 13. Build Arrow Lake-S OpenSSL (libcrypto.so.3 & libssl.so.3 with VAES/SHA-NI)
OPENSSL_SYS_VER=$(rpm -q --qf "%{VERSION}\n" openssl-libs 2>/dev/null | head -n 1 || true)
OPENSSL_BRANCH="openssl-${OPENSSL_SYS_VER:-3.5.9}"
git clone --depth 1 --branch "${OPENSSL_BRANCH}" https://github.com/openssl/openssl.git /tmp/openssl || \
git clone --depth 1 --branch openssl-3.5.9 https://github.com/openssl/openssl.git /tmp/openssl || \
git clone --depth 1 --branch openssl-3.4.1 https://github.com/openssl/openssl.git /tmp/openssl
cd /tmp/openssl
./Configure linux-x86_64 --prefix=/usr --libdir=lib64 --openssldir=/etc/pki/tls \
  shared enable-ec_nistp_64_gcc_128 no-static-engine no-tests \
  "${CFLAGS}"
make -j"$(nproc)" build_libs

# Detect system shared library targets (e.g. /usr/lib64/libcrypto.so.3.5.9 on Fedora/Bazzite)
SYS_CRYPTO_SO=$(readlink -f /usr/lib64/libcrypto.so.3 2>/dev/null || true)
SYS_SSL_SO=$(readlink -f /usr/lib64/libssl.so.3 2>/dev/null || true)

if [ -n "${SYS_CRYPTO_SO}" ] && [ "$(basename "${SYS_CRYPTO_SO}")" != "libcrypto.so.3" ]; then
    install -m 755 /tmp/openssl/libcrypto.so.3 "${SYS_CRYPTO_SO}"
    ln -sf "$(basename "${SYS_CRYPTO_SO}")" /usr/lib64/libcrypto.so.3
else
    install -m 755 /tmp/openssl/libcrypto.so.3 /usr/lib64/libcrypto.so.3
fi

if [ -n "${SYS_SSL_SO}" ] && [ "$(basename "${SYS_SSL_SO}")" != "libssl.so.3" ]; then
    install -m 755 /tmp/openssl/libssl.so.3 "${SYS_SSL_SO}"
    ln -sf "$(basename "${SYS_SSL_SO}")" /usr/lib64/libssl.so.3
else
    install -m 755 /tmp/openssl/libssl.so.3 /usr/lib64/libssl.so.3
fi

ln -sf libcrypto.so.3 /usr/lib64/libcrypto.so
ln -sf libssl.so.3 /usr/lib64/libssl.so
cd / && rm -rf /tmp/openssl

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

# Refresh shared library cache
ldconfig

# 15. Clear userspace LTO flags
unset CFLAGS CXXFLAGS LDFLAGS

# ==============================================================================
# TODO: Re-enable Custom Arrow Lake-S OGC Kernel once NVIDIA driver loading is fixed.
#
# Reason:
#   Swapping the kernel with the custom Arrow Lake-S OGC kernel caused NVIDIA
#   drivers to fail to load (vermagic / kernel module ABI mismatch). Without
#   NVIDIA GPU acceleration, the GUI fell back to llvmpipe software rendering,
#   causing severe lag and very slow rendering.
#
# Required Steps to Re-enable:
#   1. Compile or package matching nvidia-open kernel modules against the custom
#      kernel version (e.g. via akmods or prebuilt kmods in CI).
#   2. Verify kernel module symbol resolution and loadability (`modinfo nvidia`).
#   3. Re-enable the kernel swap and initramfs generation steps below.
# See TODO.md for more details.
# ==============================================================================
# export KCFLAGS="-O3 -march=arrowlake-s -mtune=arrowlake-s -pipe -Wno-error"
#
# # Install oras
# dnf5 install -y oras
#
# # Pull the custom Arrow Lake-S RPMs from your ORAS package (tag: latest-fc44)
# mkdir -p /tmp/ogc-rpms
# oras pull ghcr.io/missessofiachan/kernel-packagesarrowlake-fedora:latest-fc44 -o /tmp/ogc-rpms
# ls -la /tmp/ogc-rpms
#
# # Detect custom kernel version from downloaded RPMs (with fallback)
# KVER=$(rpm -qp --qf "%{VERSION}-%{RELEASE}.%{ARCH}\n" /tmp/ogc-rpms/kernel-core-*.rpm 2>/dev/null | head -n 1 || true)
# KVER="${KVER:-7.2.9-ogc3.1.fc44.x86_64}"
#
# # Back up Bazzite's prebuilt extra/ and updates/ modules (Nvidia Open 4080 Super, xone, v4l2loopback, etc.)
# mkdir -p /tmp/bazzite-extra-mods
# for mod_dir in "/usr/lib/modules/${KVER}" /usr/lib/modules/*; do
#     if [ -d "${mod_dir}/extra" ] && [ ! -d /tmp/bazzite-extra-mods/extra ]; then
#         cp -a "${mod_dir}/extra" /tmp/bazzite-extra-mods/
#     fi
#     if [ -d "${mod_dir}/updates" ] && [ ! -d /tmp/bazzite-extra-mods/updates ]; then
#         cp -a "${mod_dir}/updates" /tmp/bazzite-extra-mods/
#     fi
# done
#
# # Overwrite stock kernel RPMs IN-PLACE without removing nvidia-driver or running broken grub scriptlets
# rm -rf "/usr/lib/modules/${KVER}"
# rpm -Uvh --oldpackage --replacepkgs --replacefiles --noscripts --nodeps \
#     /tmp/ogc-rpms/kernel-[0-9]*.rpm \
#     /tmp/ogc-rpms/kernel-core-*.rpm \
#     /tmp/ogc-rpms/kernel-modules-*.rpm \
#     /tmp/ogc-rpms/kernel-devel-*.rpm \
#     /tmp/ogc-rpms/kernel-headers-*.rpm \
#     /tmp/ogc-rpms/kernel-tools-*.rpm
#
# # Restore Bazzite's extra/ and updates/ kernel modules (Nvidia Open, xone, etc.) into the new kernel tree
# if [ -d "/tmp/bazzite-extra-mods/extra" ]; then
#     cp -a /tmp/bazzite-extra-mods/extra "/usr/lib/modules/${KVER}/"
# fi
# if [ -d "/tmp/bazzite-extra-mods/updates" ]; then
#     cp -a /tmp/bazzite-extra-mods/updates "/usr/lib/modules/${KVER}/"
# fi
# rm -rf /tmp/bazzite-extra-mods
#
# # Ensure vmlinuz is placed in bootc standard location (/usr/lib/modules/${KVER}/vmlinuz) and clean /boot
# if [ -f "/boot/vmlinuz-${KVER}" ] && [ ! -f "/usr/lib/modules/${KVER}/vmlinuz" ]; then
#     cp -a "/boot/vmlinuz-${KVER}" "/usr/lib/modules/${KVER}/vmlinuz"
# fi
# rm -f /boot/vmlinuz* /boot/initramfs*
#
# # Generate module dependencies & initramfs
# depmod -a "${KVER}"
# export DRACUT_NO_XATTR=1
# dracut --no-hostonly --kver "${KVER}" --reproducible -v --add ostree -f "/usr/lib/modules/${KVER}/initramfs.img"
# chmod 0600 "/usr/lib/modules/${KVER}/initramfs.img"
# rm -rf /tmp/ogc-rpms

# 16. Clean up build tools and caches
dnf5 remove -y cmake ninja-build autoconf automake golang-oras oras || true
dnf5 clean all
ldconfig

# 17. Enable services
systemctl enable scx_loader.service
systemctl mask NetworkManager-wait-online.service

