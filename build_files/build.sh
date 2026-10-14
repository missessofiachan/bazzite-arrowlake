#!/usr/bin/bash
set -ouex pipefail

# Keep git/compiler caches in /tmp so /var/roothome stays clean for bootc lint
export HOME=/tmp

# Allow CMake 4.3.0 (Fedora 44) to configure projects with older CMakeLists headers
export CMAKE_POLICY_VERSION_MINIMUM=3.5

# 1. Copy baked-in system configs (/usr/lib/sysctl.d, udev, environment.d, etc.)
cp -rv /ctx/system_files/* /
rm -f /usr/share/ublue-os/image-template-check

# 2. Install temporary compiler toolchain
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
install -m 755 lib/libjemalloc.so.2 /usr/lib64/libjemalloc.so.2
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

# 6. Build Arrow Lake-S zlib-ng 2.3.3 (matches Fedora 44 version; -mno-evex512 guard for GCC 16)
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

# 8. Build Arrow Lake-S libdeflate (strip obsolete GCC 14/15 evex512 attribute for GCC 16)
git clone --depth 1 https://github.com/ebiggers/libdeflate.git /tmp/libdeflate
sed -i 's/,evex512//g; s/"evex512"/""/g' /tmp/libdeflate/lib/x86/*.h
cmake -B /tmp/libdeflate/build -S /tmp/libdeflate -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=/usr/lib64 \
  -DLIBDEFLATE_BUILD_STATIC_LIB=OFF -DLIBDEFLATE_BUILD_GZIP=OFF -DLIBDEFLATE_BUILD_TESTS=OFF
cmake --build /tmp/libdeflate/build
install -m 755 /tmp/libdeflate/build/libdeflate.so.0 /usr/lib64/libdeflate.so.0
rm -rf /tmp/libdeflate

# 9. Build Arrow Lake-S lz4 (liblz4.so.1)
git clone --depth 1 --branch v1.10.0 https://github.com/lz4/lz4.git /tmp/lz4
make -C /tmp/lz4/lib -j"$(nproc)" BUILD_STATIC=no CFLAGS="${CFLAGS} -fPIC"
LZ4_SO=$(find /tmp/lz4/lib -maxdepth 1 -type f -name "liblz4.so.1.*")
install -m 755 "${LZ4_SO}" /usr/lib64/
ln -sf "$(basename "${LZ4_SO}")" /usr/lib64/liblz4.so.1
rm -rf /tmp/lz4

# 10. Build Arrow Lake-S AVX2 xxHash (libxxhash.so.0)
git clone --depth 1 --branch v0.8.3 https://github.com/Cyan4973/xxHash.git /tmp/xxhash
make -C /tmp/xxhash -j"$(nproc)" libxxhash.so CFLAGS="${CFLAGS} -fPIC"
XXH_SO=$(find /tmp/xxhash -maxdepth 1 -type f -name "libxxhash.so.0.*")
install -m 755 "${XXH_SO}" /usr/lib64/
ln -sf "$(basename "${XXH_SO}")" /usr/lib64/libxxhash.so.0
rm -rf /tmp/xxhash

# 11. Build Arrow Lake-S SIMD libpng (libpng16.so.16)
git clone --depth 1 --branch v1.6.47 https://github.com/pnggroup/libpng.git /tmp/libpng
cmake -B /tmp/libpng/build -S /tmp/libpng -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=/usr/lib64 \
  -DPNG_SHARED=ON -DPNG_STATIC=OFF -DPNG_TESTS=OFF -DPNG_TOOLS=OFF -DPNG_INTEL_SSE=ON
cmake --build /tmp/libpng/build
PNG_SO=$(find /tmp/libpng/build -maxdepth 1 -type f -name "libpng16.so.16.*")
install -m 755 "${PNG_SO}" /usr/lib64/
ln -sf "$(basename "${PNG_SO}")" /usr/lib64/libpng16.so.16
rm -rf /tmp/libpng

# 12. Build Arrow Lake-S brotli (libbrotlicommon / libbrotlidec / libbrotlienc)
git clone --depth 1 --branch v1.1.0 https://github.com/google/brotli.git /tmp/brotli
cmake -B /tmp/brotli/build -S /tmp/brotli -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=/usr/lib64 \
  -DBUILD_SHARED_LIBS=ON -DBROTLI_DISABLE_TESTS=ON
cmake --build /tmp/brotli/build
for lib in libbrotlicommon libbrotlidec libbrotlienc; do
  BROTLI_SO=$(find /tmp/brotli/build -maxdepth 1 -type f -name "${lib}.so.1.*")
  install -m 755 "${BROTLI_SO}" /usr/lib64/
  ln -sf "$(basename "${BROTLI_SO}")" /usr/lib64/${lib}.so.1
done
rm -rf /tmp/brotli

# 13. Remove only the temporary build tools we added and refresh library cache
dnf5 remove -y cmake ninja-build autoconf automake
dnf5 clean all
ldconfig

# 14. Enable scx_lavd scheduler and mask boot-stalling wait-online service
systemctl enable scx_loader.service
systemctl mask NetworkManager-wait-online.service
