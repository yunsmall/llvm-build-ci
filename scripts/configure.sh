#!/usr/bin/env bash
# 把 preset 和输入框解析成实际参数，记下真正执行的 cmake 命令，然后配置
# 环境变量：DIST_NAME, PRESET, TARGETS, PROJECTS, RUNTIMES（后可跟 DEP_*）
set -euo pipefail

# 预设只负责给下面三项填默认值：输入框留空就跟随预设，填了就以你填的为准，
# 所以既能一键用官方配置，也能只改其中一项
case "${PRESET}" in
  official)
    def_targets="AArch64;ARM;X86;BPF;WebAssembly;RISCV;NVPTX"
    def_projects="clang;clang-tools-extra;lld"
    def_runtimes="compiler-rt;openmp"
    ;;
  *)
    def_targets="X86"
    def_projects="clang;lld"
    def_runtimes=""
    ;;
esac

targets="${TARGETS:-$def_targets}"
projects="${PROJECTS:-$def_projects}"
runtimes="${RUNTIMES:-$def_runtimes}"
# none/off 用来显式关掉 Windows 上自动补的 compiler-rt：清空之后下面 Windows 分支
# 还会按"空就补 compiler-rt"处理，所以单独记一笔，别让它被补回去
runtimes_forbidden=0
case "${runtimes}" in
  none | off | None | Off)
    runtimes=""
    runtimes_forbidden=1
    ;;
esac

has_runtime() {
  case ";$1;" in
    *";$2;"*) return 0 ;;
    *) return 1 ;;
  esac
}

# 从分号列表里去掉一项，用于把当前平台编不了的 runtime 降级掉
drop_runtime() {
  local item keep=''
  local IFS=';'
  for item in $1; do
    [ "$item" = "$2" ] || keep="${keep:+$keep;}$item"
  done
  printf '%s' "$keep"
}

# 交叉目标的 compiler-rt builtins（软浮点、64 位除法这类编译器辅助函数）。
# LLVM_BUILTIN_TARGETS 只构建 lib/builtins，不碰 sanitizer；裸机目标本身不需要
# 任何目标头文件，Linux 目标则要特殊处理（见下面的 -ffreestanding / 裸机模式）。
# 输入留空=默认列表；none=关；all=再加冷门架构
builtin_targets_default="i686-unknown-linux-gnu
aarch64-unknown-linux-gnu
armv7-unknown-linux-gnueabi
armv7-unknown-linux-gnueabihf
aarch64-none-elf
armv6m-none-eabi
armv7m-none-eabi
armv7em-none-eabi
riscv32-unknown-elf
riscv64-unknown-elf
riscv64-unknown-linux-gnu
wasm32-unknown-unknown"

builtin_targets_all="${builtin_targets_default}
loongarch64-unknown-linux-gnu
powerpc64le-unknown-linux-gnu
s390x-unknown-linux-gnu
mips64el-unknown-linux-gnuabi64
sparcv9-unknown-linux-gnu
aarch64_be-unknown-linux-gnu"
if [ "${RUNNER_OS}" = "Windows" ]; then
  # Windows 目标的 builtins 需要 clang-cl 和 MSVC 头文件，只有 Windows 宿主编得了
  builtin_targets_all="${builtin_targets_all}
i686-pc-windows-msvc
aarch64-pc-windows-msvc
x86_64-unknown-linux-gnu"
fi

# 输入里允许空格、换行、逗号混用，统一成 cmake 要的分号列表
normalize_targets() {
  # 最后的  */  至少匹配一个空格；写成  *  会匹配空串，把每个字符之间都插上分号
  printf '%s' "$1" | tr -s '[:space:]' ' ' |
    sed -e 's/^ *//' -e 's/ *$//' -e 's/ *, */;/g' -e 's/  */;/g'
}

case "${BUILTIN_TARGETS:-default}" in
  default | Default) builtin_targets=$(normalize_targets "$builtin_targets_default") ;;
  none | off | None | Off) builtin_targets='' ;;
  all | All) builtin_targets=$(normalize_targets "$builtin_targets_all") ;;
  *) builtin_targets=$(normalize_targets "$BUILTIN_TARGETS") ;;
esac

# triple 的第一个字段映射到 LLVM 后端名。builtins 由刚编出来的 clang 编译，
# 后端没编进 clang 的话配置能过、编译时才会报 unknown target
target_backend() {
  case "$1" in
    x86_64 | i?86 | amd64) echo X86 ;;
    aarch64* | arm64*) echo AArch64 ;;
    arm* | thumb*) echo ARM ;;
    riscv*) echo RISCV ;;
    wasm32 | wasm64) echo WebAssembly ;;
    loongarch*) echo LoongArch ;;
    powerpc* | ppc*) echo PowerPC ;;
    s390x) echo SystemZ ;;
    mips*) echo Mips ;;
    sparc*) echo Sparc ;;
    avr) echo AVR ;;
    hexagon) echo Hexagon ;;
    nvptx*) echo NVPTX ;;
    amdgpu* | amdgcn*) echo AMDGPU ;;
    ve) echo VE ;;
    *) return 1 ;;
  esac
}

builtin_extra_args=()
if [ -n "${builtin_targets}" ]; then
  if ! has_runtime "${projects}" clang; then
    echo "::error::builtin_targets 需要 clang（builtins 由刚编出来的 clang 编译），但 projects=${projects}"
    exit 1
  fi

  builtin_extra_backends=''
  # clear_cache.c 在 __linux__ 下 include assert.h，而交叉编时目标 libc 头不可用；
  # 垫片只把 assert 变成空操作（Release 构建本来也是空操作），按需生成
  stub_include="${GITHUB_WORKSPACE}/builtins-stub-include"
  stub_include_ready=0
  # triple 里不会有空白，直接按空格拆，避免 here-string 带的换行混进最后一个字段
  for triple in $(printf '%s' "${builtin_targets}" | tr ';' ' '); do
    arch=${triple%%-*}
    if ! backend=$(target_backend "${arch}"); then
      echo "::error::无法从 ${triple} 推断 LLVM 后端；请把这个 triple 从 builtin_targets 去掉，或手动把对应后端填进 targets"
      exit 1
    fi
    # Linux 宿主的 builtins 子构建会按宿主 OS 顺带编 crtbegin/crtend，wasm32
    # 这类没有 init/fini 实现的架构会直接报错；Windows 宿主本来就不编。
    # 交叉只需要 builtins 库本身，统一关掉让两个宿主的产物一致
    builtin_extra_args+=("-DBUILTINS_${triple}_COMPILER_RT_BUILD_CRT=OFF")
    # Linux / 裸机目标要 freestanding：否则 clang 的 limits.h、stdint.h 会
    # include_next 宿主 glibc（i686 上直接缺 bits/libc-header-start.h 而失败）。
    # Windows 目标走 clang-cl，不接受这个 flag，且 MSVC 头本来就在
    case "${triple}" in
      *windows* | *msvc*) ;;
      *)
        cflags='-ffreestanding'
        # builtins 默认会编 emutls / eprintf / enable_execute_stack，它们要目标
        # libc 的 stdlib.h、stdio.h、sys/mman.h；交叉时没有目标 sysroot（Windows
        # 宿主更是一个 Linux 头文件都没有）。裸机模式去掉这三个，它们正常链接
        # Linux 程序时由目标 libc 提供，builtins 里的份用不上
        builtin_extra_args+=("-DBUILTINS_${triple}_COMPILER_RT_BAREMETAL_BUILD=ON")
        case "${triple}" in
          *linux*)
            # 剩下少量代码在 __linux__ 下要 assert.h、sys/auxv.h、sys/cachectl.h
            # 等头，用只含声明的垫片顶上
            if [ "${stub_include_ready}" -eq 0 ]; then
              mkdir -p "${stub_include}/sys"
              cat > "${stub_include}/assert.h" <<'HEADER'
#ifndef BUILTINS_STUB_ASSERT_H
#define BUILTINS_STUB_ASSERT_H

/* 交叉编 builtins 专用：目标 libc 头不可用，clear_cache.c 只用 assert 检查
   缓存刷新系统调用是否失败，Release 构建本来就把断言编成空操作 */
#define assert(expr) ((void)0)

#endif
HEADER
              cat > "${stub_include}/sys/auxv.h" <<'HEADER'
#ifndef BUILTINS_STUB_SYS_AUXV_H
#define BUILTINS_STUB_SYS_AUXV_H

/* 交叉编 aarch64 Linux builtins 专用：cpu_model/aarch64.c 用 getauxval 查
   HWCAP 决定是否启用 LSE 原子操作，这里只声明原型，实现由目标 libc 提供 */
unsigned long int getauxval(unsigned long int type);

#endif
HEADER
              # MIPS 的 clear_cache.c 在 ISA6 以下走 libc 的 _flush_cache，
              # 另外两个头只是顺带 include 的，这里给空壳
              cat > "${stub_include}/sys/cachectl.h" <<'HEADER'
#ifndef BUILTINS_STUB_SYS_CACHECTL_H
#define BUILTINS_STUB_SYS_CACHECTL_H

/* 交叉编 MIPS Linux builtins 专用；BCACHE 的值取自 linux/arch/mips 的
   asm/cachectl.h，_flush_cache 的实现由目标 libc 提供 */
#define BCACHE 3
int _flush_cache(char *addr, const int nbytes, const int op);

#endif
HEADER
              cat > "${stub_include}/sys/syscall.h" <<'HEADER'
#ifndef BUILTINS_STUB_SYS_SYSCALL_H
#define BUILTINS_STUB_SYS_SYSCALL_H
#endif
HEADER
              cat > "${stub_include}/unistd.h" <<'HEADER'
#ifndef BUILTINS_STUB_UNISTD_H
#define BUILTINS_STUB_UNISTD_H
#endif
HEADER
              stub_include_ready=1
            fi
            # CMake 参数里的反斜杠会被当转义符，Windows 宿主下换成斜杠
            stub_flags=$(printf '%s' "${stub_include}" | tr '\\' '/')
            cflags="${cflags} -I${stub_flags}"
            ;;
        esac
        builtin_extra_args+=("-DBUILTINS_${triple}_CMAKE_C_FLAGS=${cflags}")
        # C++ 那份也要加：aarch64 的 emupac.cpp 会 include 带 stdint.h 的头，
        # Linux 宿主上不 freestanding 就会 include_next 到 /usr/include/stdint.h，
        # 再找目标架构的 bits/libc-header-start.h 而失败
        builtin_extra_args+=("-DBUILTINS_${triple}_CMAKE_CXX_FLAGS=${cflags}")
        ;;
    esac
    if [ "${targets}" = "all" ]; then
      continue
    fi
    if ! has_runtime "${targets}" "${backend}" && ! has_runtime "${builtin_extra_backends}" "${backend}"; then
      builtin_extra_backends="${builtin_extra_backends:+$builtin_extra_backends;}$backend"
    fi
  done
  # 只为 builtins 补后端，用户填的 targets 内容原样保留
  if [ -n "${builtin_extra_backends}" ]; then
    targets="${targets};${builtin_extra_backends}"
  fi
fi

extra=()
extra+=("${builtin_extra_args[@]}")
if [ "${RUNNER_OS}" = "Linux" ]; then
  # 用 lld 链接，比 GNU ld 快很多，LLVM 这种巨型项目差别明显
  extra+=("-DLLVM_USE_LINKER=lld")
  if has_runtime "${runtimes}" compiler-rt; then
    # compiler-rt 的 sanitizer 运行时只能用 clang 编，gcc 会直接报错
    if command -v clang >/dev/null 2>&1 && command -v clang++ >/dev/null 2>&1; then
      extra+=("-DCMAKE_C_COMPILER=clang" "-DCMAKE_CXX_COMPILER=clang++")
    else
      echo "::warning::runner 上没有 clang，去掉 compiler-rt"
      runtimes=$(drop_runtime "${runtimes}" compiler-rt)
    fi
  fi
  # 没编 compiler-rt 就明确走 libgcc：否则 clang 会去 resource dir 里
  # 找不存在的 clang_rt.builtins，个别代码（__int128 除法之类）链接失败
  if ! has_runtime "${runtimes}" compiler-rt; then
    extra+=("-DCLANG_DEFAULT_RTLIB=libgcc")
  fi
elif [ "${RUNNER_OS}" = "Windows" ]; then
  # cl.exe 编不了 compiler-rt，而 Windows 版 clang 的产物里带
  # /DEFAULTLIB:clang_rt.builtins，缺了它有些代码链不上。
  # runner 镜像自带 LLVM，用它自举：快，且能编 compiler-rt。
  if command -v clang-cl >/dev/null 2>&1 && command -v lld-link >/dev/null 2>&1; then
    extra+=(
      "-DCMAKE_C_COMPILER=clang-cl"
      "-DCMAKE_CXX_COMPILER=clang-cl"
      "-DCMAKE_LINKER=lld-link"
      "-DLLVM_ENABLE_LLD=ON"
    )
    # 用户显式填了 none 就别补，但要说清代价：没 compiler-rt 的 Windows 工具链
    # 连 __int128 除法这类内置辅助函数都链不上，等于半残
    if [ "${runtimes_forbidden}" -eq 1 ]; then
      echo "::warning::显式指定 runtimes=none：产物将不带 compiler-rt，__int128 除法、sanitizer、profile 等会链接失败"
    else
      [ -n "${runtimes}" ] || runtimes="compiler-rt"
    fi
  else
    echo "::warning::找不到 clang-cl/lld-link，退回 cl.exe，且不编 compiler-rt"
    runtimes=""
  fi
fi

if [ -n "${runtimes}" ]; then
  extra+=("-DLLVM_ENABLE_RUNTIMES=${runtimes}")
  # 官方也关：ORC 的运行时这里用不上，编起来还费时间
  if has_runtime "${runtimes}" compiler-rt; then
    extra+=("-DCOMPILER_RT_BUILD_ORC=OFF")
  fi
fi

if [ -n "${builtin_targets}" ]; then
  extra+=("-DLLVM_BUILTIN_TARGETS=${builtin_targets}")
fi
# 校验步骤按这个文件逐行检查，空文件表示没请求交叉 builtins
printf '%s' "${builtin_targets}" | tr ';' '\n' > "${GITHUB_WORKSPACE}/builtins-targets.txt"

# 可选的动态 LLVM 库：Windows 上产 LLVM.dll，Linux 上产 libLLVM-<ver>.so。
# 自己写测试时链接这个库，就不必每个 exe 静态塞一份 LLVM。
if [ "${SHARED_LLVM:-false}" = "true" ]; then
  extra+=("-DLLVM_BUILD_LLVM_DYLIB=ON" "-DLLVM_LINK_LLVM_DYLIB=ON")
  if [ "${RUNNER_OS}" = "Windows" ]; then
    # 用 cl.exe 时导出的内联成员不受 /Zc:dllexportInlines- 控制，很容易撞 64k 导出上限；
    # 转发桩也依赖 lld-link，所以这条路只支持 clang-cl 工具链
    if ! command -v clang-cl >/dev/null 2>&1 || ! command -v lld-link >/dev/null 2>&1; then
      echo "::error::shared_llvm 在 Windows 上需要 clang-cl 和 lld-link"
      exit 1
    fi
    # 不设 VIS 时 llvm-shlib 对 MSVC 直接 FATAL "Generating libLLVM is not supported"
    extra+=("-DLLVM_BUILD_LLVM_DYLIB_VIS=ON")
    # C API 单独要一个稳定入口就给 LLVM-C.dll。它链的是 LLVM.dll，
    # 链接器只会生成转发桩，不会再复制一份 LLVM
    extra+=("-DLLVM_BUILD_LLVM_C_DYLIB=ON")
    # clang 的 C++ 头没有 LLVM_ABI 注解，clang-cpp.dll 在 Windows 上导不出符号。
    # 工具改成静态链 clang 自己的库，LLVM 部分仍然走 LLVM.dll
    extra+=("-DCLANG_LINK_CLANG_DYLIB=OFF")
    # DLL 和调用方共用一份 CRT：静态 CRT 时跨 DLL 传递分配过的内存会炸
    extra+=("-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL")
    # PCH 对象里的 inline 模板实例会和 DLL 的导出撞车，lld-link 报
    # duplicate symbol（basic_parser<T> 等）；CMake 这个变量直接禁用 PCH
    extra+=("-DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON")
    # CIR 默认开启会顺带把 MLIR 拉进来；MLIR 的工具同时链静态 LLVMSupport 等
    # 和 LLVM.dll，COFF 下会报 duplicate symbol（mlir-src-sharder）。
    # CIR 是实验特性，关掉不影响 C/C++ 编译
    extra+=("-DCLANG_ENABLE_CIR=OFF")
  fi
fi

# official 档链上一步现编的三个库（路径由那一步写进环境变量），
# 其余档一律关掉，保证产物不依赖 runner 上碰巧存在的库
if [ -n "${DEP_ZLIB_LIBRARY:-}" ]; then
  extra+=(
    "-DLLVM_ENABLE_ZLIB=FORCE_ON"
    "-DLLVM_ENABLE_ZSTD=FORCE_ON"
    "-DLLVM_ENABLE_LIBXML2=FORCE_ON"
    "-DCLANG_ENABLE_LIBXML2=OFF"
    "-DZLIB_INCLUDE_DIR=${DEP_ZLIB_INCLUDE}"
    "-DZLIB_LIBRARY=${DEP_ZLIB_LIBRARY}"
    "-DZLIB_LIBRARY_RELEASE=${DEP_ZLIB_LIBRARY}"
    "-Dzstd_INCLUDE_DIR=${DEP_ZSTD_INCLUDE}"
    "-Dzstd_LIBRARY=${DEP_ZSTD_LIBRARY}"
    "-DLIBXML2_INCLUDE_DIR=${DEP_LIBXML2_INCLUDE}"
    "-DLIBXML2_LIBRARIES=${DEP_LIBXML2_LIBRARY}"
  )
  # 静态 libxml2 的头部默认按 dllimport 声明，Windows 上必须显式说静态
  if [ "${RUNNER_OS}" = "Windows" ]; then
    extra+=("-DCMAKE_C_FLAGS=-DLIBXML_STATIC" "-DCMAKE_CXX_FLAGS=-DLIBXML_STATIC")
  fi
  third_party="zlib+zstd+libxml2"
else
  extra+=(
    "-DLLVM_ENABLE_ZLIB=OFF"
    "-DLLVM_ENABLE_ZSTD=OFF"
    "-DLLVM_ENABLE_LIBXML2=OFF"
  )
  third_party="off"
fi

echo "preset=${PRESET} targets=${targets} projects=${projects} runtimes=${runtimes:-<none>} third_party=${third_party} builtins=${builtin_targets:-<none>} shared_llvm=${SHARED_LLVM:-false}"

# 把实际用的 cmake 命令原样记下来：release notes 要贴这份，
# 不能靠事后照着 workflow 手抄，手抄的会和真正执行的对不上。
# 值里带分号的要加引号，否则用户照着贴时 shell 会把分号当命令分隔符。
# 路径换成占位符，不然别人复制下来只能看着 runner 的绝对路径干瞪眼
placeholder() {
  local v="$1"
  # pattern 必须加引号：Windows 下 GITHUB_WORKSPACE 形如 D:\a\repo\repo，
  # 未加引号的 pattern 会把反斜杠当转义符吃掉，替换静默失效、notes 里漏出 runner 绝对路径
  v="${v//"$GITHUB_WORKSPACE"/<workspace>}"
  printf '%s' "$v"
}
# 关掉可选依赖，产物不绑定 runner 上碰巧装了的库；UTILS 关掉能省掉
# FileCheck 等测试工具（前提是 TESTS 也关，LLVM 的 CMake 有这个断言）。
# zlib/zstd/libxml2 由 preset 决定，下面单独处理
HERMETIC_FLAGS=(
  -DLLVM_ENABLE_CURL=OFF
  -DLLVM_ENABLE_LIBEDIT=OFF
  -DLLVM_ENABLE_FFI=OFF
  -DLLVM_ENABLE_BINDINGS=OFF
  -DLLVM_ENABLE_TERMINFO=OFF
  -DLLVM_INCLUDE_TESTS=OFF
  -DLLVM_INCLUDE_DOCS=OFF
  -DLLVM_INCLUDE_EXAMPLES=OFF
  -DLLVM_INCLUDE_BENCHMARKS=OFF
  -DLLVM_INCLUDE_UTILS=OFF
  -DLLVM_INCLUDE_GO_TESTS=OFF
  -DLLVM_OPTIMIZED_TABLEGEN=ON
  -DLLVM_ENABLE_ASSERTIONS=OFF
)

cmake_args=(
  -S llvm-project/llvm
  -B build
  -G Ninja
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="${GITHUB_WORKSPACE}/stage/${DIST_NAME}"
  -DLLVM_ENABLE_PROJECTS="${projects}"
  -DLLVM_TARGETS_TO_BUILD="${targets}"
  "${HERMETIC_FLAGS[@]}"
  "${extra[@]}"
)
{
  echo '```'
  printf 'cmake'
  for arg in "${cmake_args[@]}"; do
    case "$arg" in
      -D*)
        printf ' \\\n  '
        # -F 走固定字符串：Windows 路径里的反斜杠当正则用会匹配不中，该加引号的没加
        if printf '%s' "$arg" | grep -F -q -e ';' -e "$GITHUB_WORKSPACE"; then
          # 只给等号后面的值加引号，-DNAME 部分保持裸露更易读
          printf '"%s=%s"' "${arg%%=*}" "$(placeholder "${arg#*=}")"
        else
          printf '%s' "$arg"
        fi
        ;;
      *) printf ' %s' "$(placeholder "$arg")" ;;
    esac
  done
  printf '\n```\n'
  echo
  echo "源码目录布局：\`llvm-project/\` 是 LLVM 源码，\`thirdparty/\` 是上面三个"
  echo "静态库的安装前缀（\`<workspace>\` 指这两者共同的上一级目录）。"
} > "${GITHUB_WORKSPACE}/cmake-cmd-${RUNNER_OS}.md"
cat "${GITHUB_WORKSPACE}/cmake-cmd-${RUNNER_OS}.md"

cmake "${cmake_args[@]}"
