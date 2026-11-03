#!/usr/bin/env bash
# 按 LLVM_REF 浅拉源码到 llvm-project/，并用 EXPECTED_SHA 校验
# 环境变量：LLVM_REPO, LLVM_REF, EXPECTED_SHA
set -euo pipefail

git init -q llvm-project
cd llvm-project
git remote add origin "https://github.com/${LLVM_REPO}.git"
# 直接按 prepare 解析好的 SHA 取：分支名会在 prepare 和 build 之间前进，
# 按 ref 取就会和 prepare 的版本对不上（已实际踩到）。服务端不允许按
# SHA 取时才退回 ref，让下面的校验报错。
if ! git fetch -q --depth 1 origin "${EXPECTED_SHA}"; then
  echo "按 SHA 拉取失败，回退到按 ref 取" >&2
  if ! git fetch -q --depth 1 origin "${LLVM_REF}"; then
    git fetch -q --depth 1 origin "refs/heads/${LLVM_REF}"
  fi
fi
git checkout -q --detach FETCH_HEAD

# 回退路径下仍要确认拿到的还是同一个提交
actual=$(git rev-parse HEAD)
if [ "${actual}" != "${EXPECTED_SHA}" ]; then
  echo "提交不一致：期望 ${EXPECTED_SHA}，实际 ${actual}" >&2
  exit 1
fi
echo "sources: ${actual}"
