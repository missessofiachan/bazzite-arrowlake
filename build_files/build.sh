#!/usr/bin/bash
set -ouex pipefail

export HOME=/tmp
export CMAKE_POLICY_VERSION_MINIMUM=3.5

# 1. Copy baked-in system configs
cp -rv /ctx/system_files/* /
rm -f /usr/share/ublue-os/image-template-check

# 2. Install temporary compiler toolchain + kernel module build deps
dnf5 install -y gcc gcc-c++ make cmake ninja-build autoconf automake git bzip2 zlib-ng-compat-devel elfutils-libelf-devel akmods

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

# Refresh shared library cache before building kernel/initramfs
ldconfig

# 10. Clear userspace LTO flags and swap in Custom Arrow Lake-S OGC Kernel
unset CFLAGS CXXFLAGS LDFLAGS
export KCFLAGS="-O3 -march=arrowlake-s -mtune=arrowlake-s -pipe -Wno-error"

# Install oras
dnf5 install -y oras

# Pull the custom Arrow Lake-S RPMs from your ORAS package (tag: latest-fc44)
mkdir -p /tmp/ogc-rpms
oras pull ghcr.io/missessofiachan/kernel-packagesarrowlake-fedora:latest-fc44 -o /tmp/ogc-rpms
ls -la /tmp/ogc-rpms

# Detect custom kernel version from downloaded RPMs (with fallback)
KVER=$(rpm -qp --qf "%{VERSION}-%{RELEASE}.%{ARCH}\n" /tmp/ogc-rpms/kernel-core-*.rpm 2>/dev/null | head -n 1 || true)
KVER="${KVER:-7.2.9-ogc3.1.fc44.x86_64}"

# Back up Bazzite's prebuilt extra/ and updates/ modules (Nvidia Open 4080 Super, xone, v4l2loopback, etc.)
mkdir -p /tmp/bazzite-extra-mods
for mod_dir in "/usr/lib/modules/${KVER}" /usr/lib/modules/*; do
    if [ -d "${mod_dir}/extra" ] && [ ! -d /tmp/bazzite-extra-mods/extra ]; then
        cp -a "${mod_dir}/extra" /tmp/bazzite-extra-mods/
    fi
    if [ -d "${mod_dir}/updates" ] && [ ! -d /tmp/bazzite-extra-mods/updates ]; then
        cp -a "${mod_dir}/updates" /tmp/bazzite-extra-mods/
    fi
done

# Overwrite stock kernel RPMs IN-PLACE without removing nvidia-driver or running broken grub scriptlets
rm -rf "/usr/lib/modules/${KVER}"
rpm -Uvh --oldpackage --replacepkgs --replacefiles --noscripts --nodeps \
    /tmp/ogc-rpms/kernel-[0-9]*.rpm \
    /tmp/ogc-rpms/kernel-core-*.rpm \
    /tmp/ogc-rpms/kernel-modules-*.rpm \
    /tmp/ogc-rpms/kernel-devel-*.rpm \
    /tmp/ogc-rpms/kernel-headers-*.rpm \
    /tmp/ogc-rpms/kernel-tools-*.rpm

# Restore Bazzite's extra/ and updates/ kernel modules (Nvidia Open, xone, etc.) into the new kernel tree
if [ -d "/tmp/bazzite-extra-mods/extra" ]; then
    cp -a /tmp/bazzite-extra-mods/extra "/usr/lib/modules/${KVER}/"
fi
if [ -d "/tmp/bazzite-extra-mods/updates" ]; then
    cp -a /tmp/bazzite-extra-mods/updates "/usr/lib/modules/${KVER}/"
fi
rm -rf /tmp/bazzite-extra-mods

# Ensure vmlinuz is placed in bootc standard location (/usr/lib/modules/${KVER}/vmlinuz) and clean /boot
if [ -f "/boot/vmlinuz-${KVER}" ] && [ ! -f "/usr/lib/modules/${KVER}/vmlinuz" ]; then
    cp -a "/boot/vmlinuz-${KVER}" "/usr/lib/modules/${KVER}/vmlinuz"
fi
rm -f /boot/vmlinuz* /boot/initramfs*

# Generate module dependencies & initramfs
depmod -a "${KVER}"
export DRACUT_NO_XATTR=1
dracut --no-hostonly --kver "${KVER}" --reproducible -v --add ostree -f "/usr/lib/modules/${KVER}/initramfs.img"
chmod 0600 "/usr/lib/modules/${KVER}/initramfs.img"
rm -rf /tmp/ogc-rpms

# 11. Clean up build tools and caches
dnf5 remove -y cmake ninja-build autoconf automake golang-oras oras || true
dnf5 clean all
ldconfig

# 12. Enable services
systemctl enable scx_loader.service
systemctl mask NetworkManager-wait-online.service

