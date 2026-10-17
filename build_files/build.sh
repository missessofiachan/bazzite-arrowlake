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

# 6. Build Arrow Lake-S zlib-ng (dynamically matching system version)
SYS_ZLIB_VER=$(rpm -q --qf "%{VERSION}\n" zlib-ng-compat 2>/dev/null | head -n 1 || true)
ZLIB_BRANCH="${SYS_ZLIB_VER:-2.3.3}"
git clone --depth 1 --branch "${ZLIB_BRANCH}" https://github.com/zlib-ng/zlib-ng.git /tmp/zlib-ng || \
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

# 7. Build Arrow Lake-S zstd (dynamically matching system version)
SYS_ZSTD_VER=$(rpm -q --qf "%{VERSION}\n" libzstd 2>/dev/null | head -n 1 || true)
ZSTD_BRANCH="v${SYS_ZSTD_VER:-1.5.7}"
git clone --depth 1 --branch "${ZSTD_BRANCH}" https://github.com/facebook/zstd.git /tmp/zstd || \
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

# 9. Build Arrow Lake-S lz4 (dynamically matching system version)
SYS_LZ4_VER=$(rpm -q --qf "%{VERSION}\n" lz4-libs 2>/dev/null | head -n 1 || true)
LZ4_BRANCH="v${SYS_LZ4_VER:-1.10.0}"
git clone --depth 1 --branch "${LZ4_BRANCH}" https://github.com/lz4/lz4.git /tmp/lz4 || \
git clone --depth 1 --branch v1.10.0 https://github.com/lz4/lz4.git /tmp/lz4
make -C /tmp/lz4/lib -j"$(nproc)" BUILD_STATIC=no CFLAGS="${CFLAGS} -fPIC"
LZ4_SO=$(find /tmp/lz4/lib -maxdepth 1 -type f -name "liblz4.so.1.*")
install -m 755 "${LZ4_SO}" /usr/lib64/
ln -sf "$(basename "${LZ4_SO}")" /usr/lib64/liblz4.so.1
rm -rf /tmp/lz4

# 10. Build Arrow Lake-S libjpeg-turbo (dynamically matching system version)
SYS_JPEG_VER=$(rpm -q --qf "%{VERSION}\n" libjpeg-turbo 2>/dev/null | head -n 1 || true)
JPEG_BRANCH="${SYS_JPEG_VER:-3.1.3}"
git clone --depth 1 --branch "${JPEG_BRANCH}" https://github.com/libjpeg-turbo/libjpeg-turbo.git /tmp/libjpeg-turbo || \
git clone --depth 1 --branch 3.1.3 https://github.com/libjpeg-turbo/libjpeg-turbo.git /tmp/libjpeg-turbo || \
git clone --depth 1 --branch 3.1.0 https://github.com/libjpeg-turbo/libjpeg-turbo.git /tmp/libjpeg-turbo
cmake -B /tmp/libjpeg-turbo/build -S /tmp/libjpeg-turbo -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=/usr/lib64 \
  -DENABLE_STATIC=OFF -DWITH_SIMD=ON -DWITH_JPEG8=ON
cmake --build /tmp/libjpeg-turbo/build
cmake --install /tmp/libjpeg-turbo/build
rm -rf /tmp/libjpeg-turbo

# 11. Build Arrow Lake-S SQLite3 (dynamically matching system version)
SYS_SQLITE_VER=$(rpm -q --qf "%{VERSION}\n" sqlite-libs 2>/dev/null | head -n 1 || true)
SQLITE_BRANCH="version-${SYS_SQLITE_VER:-3.51.2}"
git clone --depth 1 --branch "${SQLITE_BRANCH}" https://github.com/sqlite/sqlite.git /tmp/sqlite || \
git clone --depth 1 --branch version-3.51.2 https://github.com/sqlite/sqlite.git /tmp/sqlite || \
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

# ==============================================================================
# TODO: Re-enable Custom Arrow Lake-S OpenSSL (libcrypto.so.3 & libssl.so.3)
#
# Reason:
#   Building and swapping system-critical OpenSSL libraries in-place is temporarily
#   deferred to ensure stability and compatibility across core system utilities
#   (DNF5, RPM, Curl, systemd). Stock OpenSSL 3.5.x libraries with native hardware
#   crypto acceleration remain active. See TODO.md for details.
# ==============================================================================
# # 13. Build Arrow Lake-S OpenSSL (libcrypto.so.3 & libssl.so.3 with VAES/SHA-NI)
# OPENSSL_SYS_VER=$(rpm -q --qf "%{VERSION}\n" openssl-libs 2>/dev/null | head -n 1 || true)
# OPENSSL_BRANCH="openssl-${OPENSSL_SYS_VER:-3.5.9}"
# git clone --depth 1 --branch "${OPENSSL_BRANCH}" https://github.com/openssl/openssl.git /tmp/openssl || \
# git clone --depth 1 --branch openssl-3.5.9 https://github.com/openssl/openssl.git /tmp/openssl || \
# git clone --depth 1 --branch openssl-3.4.1 https://github.com/openssl/openssl.git /tmp/openssl
# cd /tmp/openssl
# ./Configure linux-x86_64 --prefix=/usr --libdir=lib64 --openssldir=/etc/pki/tls \
#   shared enable-ec_nistp_64_gcc_128 no-static-engine no-tests \
#   "${CFLAGS}"
# make -j"$(nproc)" build_libs
#
# # Detect system shared library targets (e.g. /usr/lib64/libcrypto.so.3.5.9 on Fedora/Bazzite)
# SYS_CRYPTO_SO=$(readlink -f /usr/lib64/libcrypto.so.3 2>/dev/null || true)
# SYS_SSL_SO=$(readlink -f /usr/lib64/libssl.so.3 2>/dev/null || true)
#
# if [ -n "${SYS_CRYPTO_SO}" ] && [ "$(basename "${SYS_CRYPTO_SO}")" != "libcrypto.so.3" ]; then
#     install -m 755 /tmp/openssl/libcrypto.so.3 "${SYS_CRYPTO_SO}"
#     ln -sf "$(basename "${SYS_CRYPTO_SO}")" /usr/lib64/libcrypto.so.3
# else
#     install -m 755 /tmp/openssl/libcrypto.so.3 /usr/lib64/libcrypto.so.3
# fi
#
# if [ -n "${SYS_SSL_SO}" ] && [ "$(basename "${SYS_SSL_SO}")" != "libssl.so.3" ]; then
#     install -m 755 /tmp/openssl/libssl.so.3 "${SYS_SSL_SO}"
#     ln -sf "$(basename "${SYS_SSL_SO}")" /usr/lib64/libssl.so.3
# else
#     install -m 755 /tmp/openssl/libssl.so.3 /usr/lib64/libssl.so.3
# fi
#
# ln -sf libcrypto.so.3 /usr/lib64/libcrypto.so
# ln -sf libssl.so.3 /usr/lib64/libssl.so
# cd / && rm -rf /tmp/openssl

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

# 15. Install Custom Arrow Lake-S Kernel & Matching NVIDIA Driver (with Self-Healing Contract)
export KCFLAGS="-O3 -march=arrowlake-s -mtune=arrowlake-s -pipe -Wno-error"

# Install oras
dnf5 install -y oras

# Pull the custom Arrow Lake-S RPMs from your ORAS package (tag: latest-fc44)
mkdir -p /tmp/ogc-rpms
oras pull ghcr.io/missessofiachan/kernel-packagesarrowlake-fedora:latest-fc44 -o /tmp/ogc-rpms
ls -la /tmp/ogc-rpms

# Detect base image NVIDIA driver version & target custom kernel version
SYS_NVIDIA_VER=$(rpm -q --qf "%{VERSION}\n" nvidia-driver 2>/dev/null | head -n 1 || true)
KVER=$(rpm -qp --qf "%{VERSION}-%{RELEASE}.%{ARCH}\n" /tmp/ogc-rpms/kernel-core-*.rpm 2>/dev/null | head -n 1 || true)
KVER="${KVER:-7.2.9-ogc3.1.fc44.x86_64}"

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

# 16. Clean up build tools and caches
dnf5 remove -y cmake ninja-build autoconf automake golang-oras oras akmods || true
dnf5 clean all
ldconfig

# 17. Install Mullvad VPN, Visual Studio Code & Google Antigravity GUI
# In OSTree/bootc base images, /opt is initially a symlink to /var/opt (which does not exist).
# Standard Universal Blue practice: convert /opt to an immutable directory in / so RPMs and binaries install cleanly.
rm -f /opt && mkdir -p /opt

# 17a. Mullvad VPN (Client, CLI & systemd daemon)
dnf5 config-manager addrepo --from-repofile=https://repository.mullvad.net/rpm/stable/mullvad.repo
dnf5 install -y mullvad-vpn
dnf5 clean all

# 17b. Visual Studio Code
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

# 17c. Google Antigravity GUI program
mkdir -p /opt/antigravity
curl -sSL "https://storage.googleapis.com/antigravity-public/antigravity-hub/2.23.0-5238607586394112/linux-x64/Antigravity.tar.gz" | tar -xz -C /opt/antigravity --strip-components=1
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

# 18. Enable services
systemctl enable scx_loader.service
systemctl enable mullvad-daemon.service
systemctl mask NetworkManager-wait-online.service

