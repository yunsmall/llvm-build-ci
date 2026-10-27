#!/usr/bin/env bash
# 按 LLVM_REF 浅拉源码到 llvm-project/，并用 EXPECTED_SHA 校验
# 环境变量：LLVM_REPO, LLVM_REF, EXPECTED_SHA
set -euo pipefail

git init -q llvm-project
cd llvm-project
git remote add origin "https://github.com/${LLVM_REPO}.git"
if ! git fetch -q --depth 1 origin "${LLVM_REF}"; then
  git fetch -q --depth 1 origin "refs/heads/${LLVM_REF}"
fi
git checkout -q --detach FETCH_HEAD

# ref 是分支时，prepare 和 build 之间可能又推进了，编译前确认拿到的
# 还是同一个提交，否则产物和你以为的版本不一致
actual=$(git rev-parse HEAD)
if [ "${actual}" != "${EXPECTED_SHA}" ]; then
  echo "提交不一致：期望 ${EXPECTED_SHA}，实际 ${actual}" >&2
  exit 1
fi
echo "sources: ${actual}"
