#!/usr/bin/env bash
# 检查请求的每个交叉 triple 都装出了 libclang_rt.builtins。
# 配置能过、目标却没编出来时日志里只有一行 ninja 状态，不查的话会静默发出半残包。
# 环境变量：DIST_NAME
set -euo pipefail

list="${GITHUB_WORKSPACE}/builtins-targets.txt"
# 没请求交叉 builtins 时文件是空的
[ -s "${list}" ] || exit 0

stage="${GITHUB_WORKSPACE}/stage/${DIST_NAME}"
clang_bin="${stage}/bin/clang"
[ -x "${clang_bin}" ] || clang_bin="${stage}/bin/clang.exe"

# 按目标分目录的运行时目录里，文件名不带架构后缀（libclang_rt.builtins.a），
# 宿主自己那份还带（libclang_rt.builtins-x86_64.a）；两种命名都算数
found_builtins() {
  compgen -G "$1/*clang_rt.builtins-*" >/dev/null && return 0
  compgen -G "$1/*clang_rt.builtins.a" >/dev/null && return 0
  compgen -G "$1/*clang_rt.builtins.lib" >/dev/null && return 0
  return 1
}

missing=0
while IFS= read -r triple; do
  [ -n "${triple}" ] || continue

  # 安装目录按规范化后的 triple 命名（aarch64-none-elf -> aarch64-unknown-none-elf），
  # 拿原始字符串拼路径会找不到
  canonical=$("${clang_bin}" --target="${triple}" -print-target-triple 2>/dev/null | tr -d '\r')
  [ -n "${canonical}" ] || canonical="${triple}"

  # 驱动只在目录真实存在时才打印运行时目录，否则输出 "(runtime dir is not present)"；
  # Windows 下打印的是反斜杠路径，统一成斜杠再喂给 compgen
  runtime_dir=''
  if out=$("${clang_bin}" --target="${triple}" -print-runtime-dir 2>/dev/null); then
    out=$(printf '%s' "${out}" | tr -d '\r' | tr '\\' '/')
    case "${out}" in
      "("*) ;;
      *) [ -d "${out}" ] && runtime_dir="${out}" ;;
    esac
  fi

  # 驱动在 --rtlib=compiler-rt 下打印的路径就是链接时真正会用的文件，能打印就
  # 优先按它验证：目录里有文件但驱动找不到（命名/布局不一致）等于白编
  driver_lib=$("${clang_bin}" --target="${triple}" --rtlib=compiler-rt \
      -print-libgcc-file-name 2>/dev/null | tr -d '\r')
  if [ -n "${driver_lib}" ] && [ -f "${driver_lib}" ]; then
    echo "builtins: ${triple} -> ${driver_lib}"
  elif [ -n "${runtime_dir}" ] && found_builtins "${runtime_dir}"; then
    echo "builtins: ${triple} -> ${runtime_dir}"
  elif found_builtins "${stage}/lib/clang/*/lib/${canonical}"; then
    echo "builtins: ${triple} -> ${stage}/lib/clang/*/lib/${canonical}"
  else
    echo "::error::缺少 ${triple}（规范化后 ${canonical}）的 builtins"
    missing=1
  fi
done < "${list}"

if [ "${missing}" -ne 0 ]; then
  echo "::error::有交叉目标的 builtins 没编出来，检查上面的 configure 日志和 LLVM_TARGETS_TO_BUILD"
  exit 1
fi
