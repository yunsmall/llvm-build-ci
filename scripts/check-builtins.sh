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

  # Windows 目标的库名带 clang_rt.builtins-*.lib，其余是 libclang_rt.builtins-*.a
  if [ -n "${runtime_dir}" ] && compgen -G "${runtime_dir}/*clang_rt.builtins-*" >/dev/null; then
    echo "builtins: ${triple} -> ${runtime_dir}"
  elif compgen -G "${stage}/lib/clang/*/lib/${canonical}/*clang_rt.builtins-*" >/dev/null; then
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
