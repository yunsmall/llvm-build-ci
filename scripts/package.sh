#!/usr/bin/env bash
# 按 COMPRESS 打包 stage/ 下的产物并生成 sha256
# 环境变量：DIST_NAME, COMPRESS
set -euo pipefail

case "${COMPRESS}" in
  zstd) ext="tar.zst" ;;
  gzip) ext="tar.gz" ;;
  xz) ext="tar.xz" ;;
  none) ext="tar" ;;
  *) echo "未知的压缩格式: ${COMPRESS}" >&2; exit 1 ;;
esac
out="${DIST_NAME}.${ext}"

tar_extra=()
# Windows 上解包时符号链接建不出来（目标可能还没被解出来），
# 打包时展开成真实文件最省事
if [ "${RUNNER_OS}" = "Windows" ]; then
  tar_extra+=("--dereference")
fi

cd stage
# --long=27 是 128 MB 窗口，正好是 zstd 默认解压上限：压缩率明显好于
# 8 MB 默认窗口，又不至于让用户解压时非带 --long 参数不可
case "${COMPRESS}" in
  zstd) tar "${tar_extra[@]}" -cf - "${DIST_NAME}" | zstd -19 --long=27 -T0 -q -o "${out}" ;;
  gzip) tar "${tar_extra[@]}" -cf - "${DIST_NAME}" | gzip -9 > "${out}" ;;
  xz) tar "${tar_extra[@]}" -cf - "${DIST_NAME}" | xz -9 -T0 -c > "${out}" ;;
  none) tar "${tar_extra[@]}" -cf "${out}" "${DIST_NAME}" ;;
esac
# Windows 的 Git Bash 有可能把行尾写成 CRLF，去掉免得 Linux 上 -c 校验失败
sha256sum "${out}" | tr -d '\r' > "${out}.sha256"
# 配置命令跟着产物一起走，发布时直接贴进 release notes
cp "${GITHUB_WORKSPACE}/cmake-cmd-${RUNNER_OS}.md" "${DIST_NAME}-cmake.md"
ls -lh
