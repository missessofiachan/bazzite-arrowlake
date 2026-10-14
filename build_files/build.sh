#!/usr/bin/bash
set -ouex pipefail

# 1. Copy baked-in system configs (/usr/lib/sysctl.d, modprobe.d, kargs.d, etc.)
cp -rv /ctx/system_files/* /

# 2. Remove default template placeholder file if present
rm -f /usr/share/ublue-os/image-template-check

# 3. Install temporary compiler toolchain
dnf5 install -y gcc gcc-c++ make cmake ninja-build autoconf automake git bzip2

# 4. Arrow Lake-S (Core Ultra 7 265KF) compiler & linker optimization flags (-g0 strips debug bloat)
export CFLAGS="-O3 -march=arrowlake-s -mtune=arrowlake-s -flto=auto -fno-plt -pipe -g0"
export CXXFLAGS="${CFLAGS}"
export LDFLAGS="-Wl,-O3 -Wl,--as-needed -flto=auto -Wl,-s"

# 5. Build Arrow Lake-S optimized jemalloc (libjemalloc.so.2)
# --disable-cxx fixes GCC 16 std::__throw_bad_alloc error; --disable-static speeds up build 2x
git clone --depth 1 --branch 5.3.0 https://github.com/jemalloc/jemalloc.git /tmp/jemalloc
cd /tmp/jemalloc
./autogen.sh --prefix=/usr --libdir=/usr/lib64 --disable-stats --disable-cxx --disable-static --enable-autogen
make -j"$(nproc)" build_lib_shared
cp -f lib/libjemalloc.so.2 /usr/lib64/libjemalloc.so.2
chmod 755 /usr/lib64/libjemalloc.so.2
cd /
rm -rf /tmp/jemalloc

# 6. Build Arrow Lake-S optimized zlib-ng as drop-in replacement for system libz.so.1
git clone --depth 1 --branch 2.2.4 https://github.com/zlib-ng/zlib-ng.git /tmp/zlib-ng
cmake -B /tmp/zlib-ng/build -S /tmp/zlib-ng -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DCMAKE_INSTALL_LIBDIR=/usr/lib64 \
  -DZLIB_COMPAT=ON \
  -DZLIB_ENABLE_TESTS=OFF \
  -DWITH_GTEST=OFF \
  -DWITH_NATIVE_INSTRUCTIONS=OFF
cmake --build /tmp/zlib-ng/build
cp -f /tmp/zlib-ng/build/libz.so.1.* /usr/lib64/
ln -sf /usr/lib64/$(basename /tmp/zlib-ng/build/libz.so.1.*) /usr/lib64/libz.so.1
chmod 755 /usr/lib64/libz.so.1.*
rm -rf /tmp/zlib-ng

# 7. Clean up build-only tools, refresh shared library cache, and clean /tmp + /var
dnf5 remove -y cmake ninja-build autoconf automake
dnf5 clean all
ldconfig
rm -rf /tmp/* /var/cache/* /var/log/*

# 8. Enable scx_lavd scheduler and mask boot-stalling wait-online service
systemctl enable scx_loader.service
systemctl mask NetworkManager-wait-online.service
