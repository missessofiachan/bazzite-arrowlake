#!/usr/bin/bash
set -ouex pipefail

# 1. Copy baked-in system configs (/usr/lib/sysctl.d, udev, environment.d, etc.)
cp -rv /ctx/system_files/* /
rm -f /usr/share/ublue-os/image-template-check

# 2. Install temporary compiler toolchain & zlib headers (needed by libpng)
dnf5 install -y gcc gcc-c++ make cmake ninja-build autoconf automake git bzip2 zlib-ng-compat-devel

# 3. Arrow Lake-S (Core Ultra 7 265KF) compiler & linker optimization flags
export CFLAGS="-O3 -march=arrowlake-s -mtune=arrowlake-s -flto=auto -fno-plt -pipe -g0"
export CXXFLAGS="${CFLAGS}"
export LDFLAGS="-Wl,-O3 -Wl,--as-needed -flto=auto -Wl,-s"

# 4. Build Arrow Lake-S jemalloc (libjemalloc.so.2)
git clone --depth 1 --branch 5.3.0 https://github.com/jemalloc/jemalloc.git /tmp/jemalloc
cd /tmp/jemalloc
./autogen.sh --prefix=/usr --libdir=/usr/lib64 --disable-stats --disable-cxx --disable-static --enable-autogen
make -j"$(nproc)" build_lib_shared
cp -f lib/libjemalloc.so.2 /usr/lib64/libjemalloc.so.2
chmod 755 /usr/lib64/libjemalloc.so.2
cd / && rm -rf /tmp/jemalloc

# 5. Build Arrow Lake-S mimalloc (libmimalloc.so.2)
git clone --depth 1 --branch v2.1.7 https://github.com/microsoft/mimalloc.git /tmp/mimalloc
cmake -B /tmp/mimalloc/build -S /tmp/mimalloc -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=/usr/lib64 \
  -DMI_BUILD_STATIC=OFF -DMI_BUILD_OBJECT=OFF -DMI_BUILD_TESTS=OFF -DMI_INSTALL_TOPLEVEL=ON
cmake --build /tmp/mimalloc/build
cp -f /tmp/mimalloc/build/libmimalloc.so.2.* /usr/lib64/
ln -sf /usr/lib64/$(basename /tmp/mimalloc/build/libmimalloc.so.2.*) /usr/lib64/libmimalloc.so.2
ln -sf /usr/lib64/libmimalloc.so.2 /usr/lib64/libmimalloc.so
chmod 755 /usr/lib64/libmimalloc.so.2.*
rm -rf /tmp/mimalloc

# 6. Build Arrow Lake-S zlib-ng (libz.so.1)
git clone --depth 1 --branch 2.2.4 https://github.com/zlib-ng/zlib-ng.git /tmp/zlib-ng
cmake -B /tmp/zlib-ng/build -S /tmp/zlib-ng -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=/usr/lib64 \
  -DZLIB_COMPAT=ON -DZLIB_ENABLE_TESTS=OFF -DWITH_GTEST=OFF -DWITH_NATIVE_INSTRUCTIONS=OFF
cmake --build /tmp/zlib-ng/build
cp -f /tmp/zlib-ng/build/libz.so.1.* /usr/lib64/
ln -sf /usr/lib64/$(basename /tmp/zlib-ng/build/libz.so.1.*) /usr/lib64/libz.so.1
chmod 755 /usr/lib64/libz.so.1.*
rm -rf /tmp/zlib-ng

# 7. Build Arrow Lake-S zstd (libzstd.so.1)
git clone --depth 1 --branch v1.5.7 https://github.com/facebook/zstd.git /tmp/zstd
cmake -B /tmp/zstd/build_cmake -S /tmp/zstd/build/cmake -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=/usr/lib64 \
  -DZSTD_BUILD_STATIC=OFF -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_TESTS=OFF
cmake --build /tmp/zstd/build_cmake
cp -f /tmp/zstd/build_cmake/lib/libzstd.so.1.* /usr/lib64/
ln -sf /usr/lib64/$(basename /tmp/zstd/build_cmake/lib/libzstd.so.1.*) /usr/lib64/libzstd.so.1
chmod 755 /usr/lib64/libzstd.so.1.*
rm -rf /tmp/zstd

# 8. Build Arrow Lake-S libdeflate (libdeflate.so.0)
git clone --depth 1 --branch v1.23 https://github.com/ebiggers/libdeflate.git /tmp/libdeflate
cmake -B /tmp/libdeflate/build -S /tmp/libdeflate -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=/usr/lib64 \
  -DLIBDEFLATE_BUILD_STATIC_LIB=OFF -DLIBDEFLATE_BUILD_GZIP=OFF -DLIBDEFLATE_BUILD_TESTS=OFF
cmake --build /tmp/libdeflate/build
cp -f /tmp/libdeflate/build/libdeflate.so.0 /usr/lib64/libdeflate.so.0
chmod 755 /usr/lib64/libdeflate.so.0
rm -rf /tmp/libdeflate

# 9. Build Arrow Lake-S lz4 (liblz4.so.1)
git clone --depth 1 --branch v1.10.0 https://github.com/lz4/lz4.git /tmp/lz4
make -C /tmp/lz4/lib -j"$(nproc)" BUILD_STATIC=no CFLAGS="${CFLAGS} -fPIC"
cp -f /tmp/lz4/lib/liblz4.so.1.* /usr/lib64/
ln -sf /usr/lib64/$(basename /tmp/lz4/lib/liblz4.so.1.*) /usr/lib64/liblz4.so.1
chmod 755 /usr/lib64/liblz4.so.1.*
rm -rf /tmp/lz4

# 10. Build Arrow Lake-S AVX2 xxHash (libxxhash.so.0)
git clone --depth 1 --branch v0.8.3 https://github.com/Cyan4973/xxHash.git /tmp/xxhash
make -C /tmp/xxhash -j"$(nproc)" libxxhash.so CFLAGS="${CFLAGS} -fPIC"
cp -f /tmp/xxhash/libxxhash.so.0.* /usr/lib64/
ln -sf /usr/lib64/$(basename /tmp/xxhash/libxxhash.so.0.*) /usr/lib64/libxxhash.so.0
chmod 755 /usr/lib64/libxxhash.so.0.*
rm -rf /tmp/xxhash

# 11. Build Arrow Lake-S SIMD libpng (libpng16.so.16)
git clone --depth 1 --branch v1.6.47 https://github.com/pnggroup/libpng.git /tmp/libpng
cmake -B /tmp/libpng/build -S /tmp/libpng -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=/usr/lib64 \
  -DPNG_SHARED=ON -DPNG_STATIC=OFF -DPNG_TESTS=OFF -DPNG_TOOLS=OFF -DPNG_INTEL_SSE=ON
cmake --build /tmp/libpng/build
cp -f /tmp/libpng/build/libpng16.so.16.* /usr/lib64/
ln -sf /usr/lib64/$(basename /tmp/libpng/build/libpng16.so.16.*) /usr/lib64/libpng16.so.16
chmod 755 /usr/lib64/libpng16.so.16.*
rm -rf /tmp/libpng

# 12. Build Arrow Lake-S brotli (libbrotlicommon.so.1 / libbrotlidec.so.1 / libbrotlienc.so.1)
git clone --depth 1 --branch v1.1.0 https://github.com/google/brotli.git /tmp/brotli
cmake -B /tmp/brotli/build -S /tmp/brotli -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=/usr/lib64 \
  -DBUILD_SHARED_LIBS=ON -DBROTLI_DISABLE_TESTS=ON
cmake --build /tmp/brotli/build
cp -f /tmp/brotli/build/libbrotli*.so.1.* /usr/lib64/
for lib in libbrotlicommon libbrotlidec libbrotlienc; do
  ln -sf /usr/lib64/$(basename /tmp/brotli/build/${lib}.so.1.*) /usr/lib64/${lib}.so.1
done
chmod 755 /usr/lib64/libbrotli*.so.1.*
rm -rf /tmp/brotli

# 13. Clean up build-only tools, refresh shared library cache, and clean /tmp + /var
dnf5 remove -y cmake ninja-build autoconf automake zlib-ng-compat-devel
dnf5 clean all
ldconfig
rm -rf /tmp/* /var/cache/* /var/log/*

# 14. Enable scx_lavd scheduler and mask boot-stalling wait-online service
systemctl enable scx_loader.service
systemctl mask NetworkManager-wait-online.service
