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

  # 驱动自己知道该去哪个目录找运行时；驱动的目录和 compiler-rt 的安装目录
  # 都按 clang 规范化后的 triple 命名，直接按目录名猜会漏掉补全的字段
  runtime_dir=''
  if "${clang_bin}" --target="${triple}" -print-runtime-dir >/dev/null 2>&1; then
    runtime_dir=$("${clang_bin}" --target="${triple}" -print-runtime-dir)
  fi

  # Windows 目标的库名带 clang_rt.builtins-*.lib，其余是 libclang_rt.builtins-*.a
  if [ -n "${runtime_dir}" ] && compgen -G "${runtime_dir}/*clang_rt.builtins-*" >/dev/null; then
    echo "builtins: ${triple} -> ${runtime_dir}"
  elif compgen -G "${stage}/lib/clang/*/lib/${triple}/*clang_rt.builtins-*" >/dev/null; then
    echo "builtins: ${triple} -> ${stage}/lib/clang/*/lib/${triple}"
  else
    echo "::error::缺少 ${triple} 的 builtins"
    missing=1
  fi
done < "${list}"

if [ "${missing}" -ne 0 ]; then
  echo "::error::有交叉目标的 builtins 没编出来，检查上面的 configure 日志和 LLVM_TARGETS_TO_BUILD"
  exit 1
fi
