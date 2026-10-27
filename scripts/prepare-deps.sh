#!/usr/bin/env bash
# 现编 official 档要静态链进 LLVM 的三个库，安装到 $GITHUB_WORKSPACE/thirdparty，
# 路径以 DEP_* 写进 $GITHUB_ENV 供配置步骤使用
# 环境变量：ZLIB_VERSION, ZSTD_VERSION, LIBXML2_VERSION
set -euo pipefail

prefix="${GITHUB_WORKSPACE}/thirdparty"
work="${RUNNER_TEMP}/deps"
mkdir -p "$prefix" "$work"
cd "$work"

fetch() {
  curl -fsSL -o "$3" "$1"
  echo "$2  $3" | sha256sum -c -
}

build() {
  local src="$1" bdir="$2" idir="$3"
  shift 3
  cmake -S "$src" -B "$bdir" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$idir" "${pic_flags[@]}" "$@"
  ninja -C "$bdir" install
}

# 这三个静态库最后会被链进 libclang-cpp.so 之类的共享库，Linux 上
# 不带 -fPIC 就会报 "relocation R_X86_64_PC32 ... recompile with -fPIC"
pic_flags=()
if [ "${RUNNER_OS}" = "Linux" ]; then
  pic_flags+=("-DCMAKE_POSITION_INDEPENDENT_CODE=ON" "-DCMAKE_C_FLAGS=-fPIC")
fi

fetch "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz" \
  bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16 zlib.tgz
tar xf zlib.tgz
build "zlib-${ZLIB_VERSION}" bzlib "$prefix/zlib" \
  -DZLIB_BUILD_TESTING=OFF -DZLIB_BUILD_SHARED=OFF \
  -DZLIB_BUILD_STATIC=ON -DZLIB_INSTALL=ON

# zstd/libxml2 的包里带测试目录，里面有符号链接，Windows 上解不出来
fetch "https://github.com/facebook/zstd/releases/download/v${ZSTD_VERSION}/zstd-${ZSTD_VERSION}.tar.gz" \
  eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3 zstd.tgz
tar xf zstd.tgz --exclude 'tests/*'
build "zstd-${ZSTD_VERSION}/build/cmake" bzstd "$prefix/zstd" \
  -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_TESTS=OFF \
  -DZSTD_BUILD_STATIC=ON -DZSTD_BUILD_SHARED=OFF

fetch "https://gitlab.gnome.org/GNOME/libxml2/-/archive/v${LIBXML2_VERSION}/libxml2-v${LIBXML2_VERSION}.tar.gz" \
  98bfa7a9a5e2a75638422050740448ee9f02bf4dc2075c9822d7747d5ff9e617 libxml2.tgz
tar xf libxml2.tgz --exclude 'test/*'
build "libxml2-v${LIBXML2_VERSION}" bxml "$prefix/libxml2" \
  -DBUILD_SHARED_LIBS=OFF -DLIBXML2_WITH_C14N=OFF -DLIBXML2_WITH_CATALOG=OFF \
  -DLIBXML2_WITH_DEBUG=OFF -DLIBXML2_WITH_DOCB=OFF -DLIBXML2_WITH_FTP=OFF \
  -DLIBXML2_WITH_HTML=OFF -DLIBXML2_WITH_HTTP=OFF -DLIBXML2_WITH_ICONV=OFF \
  -DLIBXML2_WITH_ICU=OFF -DLIBXML2_WITH_ISO8859X=OFF -DLIBXML2_WITH_LEGACY=OFF \
  -DLIBXML2_WITH_LZMA=OFF -DLIBXML2_WITH_MEM_DEBUG=OFF -DLIBXML2_WITH_MODULES=OFF \
  -DLIBXML2_WITH_OUTPUT=ON -DLIBXML2_WITH_PATTERN=OFF -DLIBXML2_WITH_PROGRAMS=OFF \
  -DLIBXML2_WITH_PUSH=OFF -DLIBXML2_WITH_PYTHON=OFF -DLIBXML2_WITH_READER=OFF \
  -DLIBXML2_WITH_REGEXPS=OFF -DLIBXML2_WITH_RUN_DEBUG=OFF -DLIBXML2_WITH_SAX1=ON \
  -DLIBXML2_WITH_SCHEMAS=OFF -DLIBXML2_WITH_SCHEMATRON=OFF -DLIBXML2_WITH_TESTS=OFF \
  -DLIBXML2_WITH_THREADS=ON -DLIBXML2_WITH_THREAD_ALLOC=OFF -DLIBXML2_WITH_TREE=ON \
  -DLIBXML2_WITH_VALID=OFF -DLIBXML2_WITH_WRITER=OFF -DLIBXML2_WITH_XINCLUDE=OFF \
  -DLIBXML2_WITH_XPATH=OFF -DLIBXML2_WITH_XPTR=OFF -DLIBXML2_WITH_ZLIB=OFF

# 静态库文件名各平台/各版本不一样，编完直接找出来，别猜
pick() {
  local dir="$1" name
  shift
  for name in "$@"; do
    if [ -e "${dir}/${name}" ]; then
      echo "${dir}/${name}"
      return 0
    fi
  done
  echo "找不到 $* —— 目录 ${dir} 内容：" >&2
  ls -l "${dir}" >&2
  return 1
}

zlib_lib=$(pick "$prefix/zlib/lib" zs.lib libzs.a libz.a)
zstd_lib=$(pick "$prefix/zstd/lib" zstd_static.lib libzstd.a)
xml_lib=$(pick "$prefix/libxml2/lib" libxml2s.lib libxml2.a)

{
  echo "DEP_ZLIB_INCLUDE=${prefix}/zlib/include"
  echo "DEP_ZLIB_LIBRARY=${zlib_lib}"
  echo "DEP_ZSTD_INCLUDE=${prefix}/zstd/include"
  echo "DEP_ZSTD_LIBRARY=${zstd_lib}"
  echo "DEP_LIBXML2_INCLUDE=${prefix}/libxml2/include/libxml2"
  echo "DEP_LIBXML2_LIBRARY=${xml_lib}"
} >> "$GITHUB_ENV"
echo "第三方库: zlib=${zlib_lib} zstd=${zstd_lib} libxml2=${xml_lib}"
