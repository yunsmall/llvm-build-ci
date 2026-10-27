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

extra=()
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

echo "preset=${PRESET} targets=${targets} projects=${projects} runtimes=${runtimes:-<none>} third_party=${third_party}"

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
