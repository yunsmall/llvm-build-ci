#!/usr/bin/env bash
# 编译并安装到 stage/，Linux 上顺手 strip
# 环境变量：无（用 RUNNER_OS）
set -euo pipefail

# 编译晚期最常见的失败原因是内存或磁盘被吃满，先把基线打出来，
# 免得事后只能对着 "FAILED" 猜
df -h . || true
if [ "${RUNNER_OS}" = "Linux" ]; then free -m || true; fi

if ! ninja -C build; then
  if [ "${RUNNER_OS}" = "Linux" ]; then
    echo "::error::ninja 失败，以下是与 OOM 相关的内核日志（若有）"
    sudo dmesg | tail -n 300 | grep -i -E "out of memory|killed process|oom-kill" || true
  fi
  df -h . || true
  exit 1
fi
# 只装不编译，装的时候顺手 strip：不 strip 的话 Linux 包会大出好几百 MB
# （Windows 上没有 strip，CMake 会当成空操作，所以分开写避免踩坑）
if [ "${RUNNER_OS}" = "Linux" ]; then
  cmake --install build --strip
else
  cmake --install build
fi
