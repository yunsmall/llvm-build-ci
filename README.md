# llvm_build

手动触发的 LLVM 编译流水线。给自己仓库加一个 workflow，就能在 GitHub Actions 上
按任意分支 / tag / commit 编一份 `clang + lld`，产物是解压即用的压缩包
（默认 `.tar.zst`，可选 `.tar.gz` / `.tar.xz` / 不压缩）。

- workflow：[`.github/workflows/build-llvm.yml`](.github/workflows/build-llvm.yml)
- 平台：Windows x64（MSVC 工具链，clang-cl 自举 + Ninja）、Linux x64（gcc + lld 链接）
- 参考实现：[wasmerio/llvm-custom-builds](https://github.com/wasmerio/llvm-custom-builds)
  （产物形态一致，但那个项目版本写死在 matrix 里、只认 `release/N.x` 分支）

## 怎么用

1. 把 `.github/workflows/build-llvm.yml` 放进你自己仓库的这个路径，push。
2. 仓库 Settings → Actions → General，确认 Workflow permissions 允许
   `Read and write permissions`（只有勾了 `create_release` 才需要，否则只读就够）。
3. Actions 页面左侧选 **Build LLVM** → **Run workflow**，填参数。

public 仓库跑 Actions 不花额度；private 仓库按分钟计费，Windows 分钟按 2 倍算。

## 输入

| 输入 | 默认 | 说明 |
|---|---|---|
| `llvm_repo` | `llvm/llvm-project` | 换成自己的 fork 就能编带补丁的版本 |
| `llvm_ref` | `main` | 分支名、tag（`llvmorg-23.1.4`）、**完整** 40 位 commit SHA |
| `preset` | `simple` | 配置档下拉框：`simple` / `official` / `custom`，见下节 |
| `targets` | 空 | `LLVM_TARGETS_TO_BUILD`，留空=跟随 preset |
| `projects` | 空 | `LLVM_ENABLE_PROJECTS`，留空=跟随 preset |
| `runtimes` | 空 | `LLVM_ENABLE_RUNTIMES`，留空=跟随 preset；填 `none` 强制都不编 |
| `platforms` | `both` | `both` / `linux` / `windows` |
| `compress` | `zstd` | `zstd`（和官方包一致，多线程）/ `gzip`（到处都能解）/ `xz`（更小但很慢）/ `none` |
| `create_release` | `false` | 勾上则发布到本仓库 Release，tag 为 `build/<版本>-<sha7>`；release notes 里附各平台实际用的 cmake 配置命令 |

## 配置档（preset）

`preset` 只负责给 `targets` / `projects` / `runtimes` 填默认值：**输入框留空就跟随 preset，
填了就以你填的为准**，所以可以只覆盖其中一项。

| preset | targets | projects | runtimes |
|---|---|---|---|
| `simple`（默认） | `X86` | `clang;lld` | Windows 自动 `compiler-rt`，Linux 不编 |
| `official` | `AArch64;ARM;X86;BPF;WebAssembly;RISCV;NVPTX` | `clang;clang-tools-extra;lld` | `compiler-rt;openmp` |
| `custom` | 按你填的，留空退回 simple | 同左 | 同左 |

`official` 的取值来自官方 `llvm/utils/release/build_llvm_release.bat`（生成
`clang+llvm-23.1.4-x86_64-pc-windows-msvc.tar.zst` 和 MSI 的那个脚本），并且和官方包装出来的
东西核对过：`llvm-config --targets-built` 正好是上面 7 个后端，`bin/` 里有 clang-tidy、clangd、
clang-format（clang-tools-extra），`lib/` 里有 `libomp.dll`、`libiomp5md.dll` 和一堆 `clang_rt.*`。

用 `official` 时有两点要知道：

- 它比 `simple` 重很多（多 6 个后端、clang-tools-extra、OpenMP），4 核免费 runner 上
  Windows 约 2–2.5 h、Linux 约 2.5–3 h，贴着 6 h 上限时要留神。
- Linux 上 `compiler-rt` 的 sanitizer 只能用 clang 编，workflow 会优先用 runner 自带的
  `clang` 自举；万一镜像里没有 clang，会自动去掉 `compiler-rt`（保留 `openmp`）并打 warning。

官方那套 `LLVM_ENABLE_RPMALLOC=ON`（rpmalloc 分配器）和 MSI 安装包没有跟。
`official` 档会把 zlib 1.3.2 / zstd 1.5.7 / libxml2 2.9.12 三个库**现编并静态链进去**
（版本号和 sha256 与官方脚本一致），代价是每次多约半分钟；`simple` 档不编，产物不依赖
任何第三方库。

ref 解析发生在 `prepare` job：`git fetch --depth 1 origin <ref>`，所以分支名和 tag
直接可用；SHA 必须是完整 40 位且能从某个 ref 走到（GitHub 不允许按任意悬空对象取）。
`build` job 会校验自己拿到的 SHA 与 `prepare` 解析出的一致，分支在两次 clone 之间
推进时会直接报错，不会悄悄编错版本。

## 产物

解压后就是一个正常的前缀目录：

```
clang+llvm-23.1.4-x86_64-pc-windows-msvc/   # Windows
LLVM-23.1.4-Linux-X64/                      # Linux
├── bin/          clang、clang++、clang-cl、lld、lld-link、llvm-* 一堆工具
├── include/
├── lib/          含 lib/clang/<ver>/ 运行时头文件、cmake 包配置
└── share/
```

解压（`compress` 选什么就用什么；7-Zip 21+ 也能直接解 zst）：

```bash
zstd -d xxx.tar.zst && tar xf xxx.tar   # zstd
tar xzf xxx.tar.gz                      # gzip
tar xJf xxx.tar.xz                      # xz
```

Windows 解压后：

```powershell
$env:PATH = "C:\llvm\clang+llvm-23.1.4-x86_64-pc-windows-msvc\bin;$env:PATH"
clang++ --version
```

注意：这套东西只含编译器本身，**链接 MSVC 目标程序仍然需要装 Visual Studio
Build Tools**（Windows SDK 的 lib 和头文件不在这里面）。这也是官方包的做法。

Windows 上编译时用的是 runner 镜像自带的 `clang-cl` + `lld-link` 自举（不是 `cl.exe`）：
`cl.exe` 编不了 `compiler-rt`，而 Windows 版 clang 生成的产物里带
`/DEFAULTLIB:clang_rt.builtins-x86_64.lib`，缺了它在涉及 `__int128` 除法之类的地方
会链接失败。找不到 `clang-cl` 时会退回 `cl.exe` 并在日志里打 warning，此时产物里没有
`lib/clang/<ver>/lib/windows/*`。

## 每日定时构建

workflow 里带了一个 `schedule`：每天**北京时间 00:00**（UTC 16:00）用**官方那套参数**
（`main` + `preset=official` + `both` + `zstd`）编一次主线，**不发布 Release**，产物就在
Actions 的 artifact 里，保留 14 天。

定时触发没有 `inputs`，所以所有 `inputs.*` 都写了兜底默认值，其中 `preset` 的兜底是
`official`（手动触发时默认仍是 `simple`）；手改默认值时注意别只改 `workflow_dispatch` 那份。

两个坑：
- GitHub 的 cron 按 UTC 走，且高峰期可能延迟几分钟到几十分钟；
- 仓库连续 60 天没有任何活动时，GitHub 会自动停用定时任务，随便推一次提交就能恢复。

## 实测耗时与磁盘

免费 runner 是 4 核 / 16 GB 内存。下表是在 `llvmorg-23.1.4` 上跑出来的实测值：

| 配置 | 平台 | 编译 | 打包 | 总耗时 | 产物 |
|---|---|---|---|---|---|
| `simple` | Windows x64 | 57 min | ~10 min | ~1 h | 302 MB |
| `simple` | Linux x64 | 90–120 min | 5–15 min | 1.5–2 h | 393 MB |
| `official` | Windows x64 | 64 min | 17 min | 85 min | 524 MB |
| `official` | Linux x64 | ~2.5 h | — | 略慢于 simple | 待补 |

`official` 档里"准备第三方库"（现编 zlib/zstd/libxml2）只要 **半分钟**，基本可以忽略；
多出来的时间主要花在 clang-tools-extra 和另外 6 个后端上。单 job 硬上限是 6 小时，
workflow 设了 `timeout-minutes: 350`，实测两档都离上限很远。

真要再压时间，按这个顺序砍：

1. `targets` 只留 `X86`（别加 AArch64）；
2. `preset` 用 `simple`，或 `runtimes` 填 `none` 关掉 compiler-rt / OpenMP；
3. `projects` 去掉 `lld`（`clang` 单独能跑，只是没法用 `-fuse-ld=lld`）；
4. 换自托管 runner。

磁盘：build 目录 8–12 GB、stage 再加 3–5 GB，免费 runner 够用；同一台 runner 上
别并行跑两个 LLVM 编译。

## 和官方 release 包的区别

官方 `clang+llvm-23.1.4-x86_64-pc-windows-msvc.tar.zst` 是
`llvm/utils/release/build_llvm_release.bat` 产出的。实际拆开比对过，真正的差别只有
targets、clang-tools-extra、openmp 和第三方库这几项（官方包同样不含 FileCheck 这类
utils，也没有 PDB）：

| 项 | 官方包 | `simple` | `official` 预设 |
|---|---|---|---|
| MSI 安装包 | 有 | 无 | 无 |
| targets | 7 个后端 | `X86` | 同官方 |
| projects | `clang;clang-tools-extra;lld` | `clang;lld` | 同官方 |
| runtimes | `compiler-rt;openmp` | Windows 有 `compiler-rt`，Linux 无 | 同官方 |
| zlib / zstd / libxml2 | 开（自带源码编） | 关 | 现编同版本并静态链入 |
| curl / libedit / ffi / terminfo | 开 | 关 | 关 |
| rpmalloc 分配器 | 开 | 关 | 关 |
| FileCheck 等 utils | 不装 | 不装 | 不装 |
| 调试信息 | 无 PDB | Linux 侧 strip | 同左 |
| 签名 / attestation | `.jsonl` 证明 | 无 | 无 |
| 构建机 | 16 核 depot runner | 4 核免费 runner | 同左 |

`simple` 档因为不带这几个库，会损失具体功能：`ld.lld --compress-debug-sections=zlib/zstd`、
`llvm-objcopy --compress-debug-sections` 用不了，libxml2 相关的 clang XML 输出和 lldb 也没有。
要这些功能就用 `official` 档。

## 本地复现同样的产物

workflow 里就是一条普通 cmake 命令，本地照抄即可（Windows 先开
`x64 Native Tools Command Prompt`，并且把 `clang-cl`、`lld-link` 放进 PATH，
和 CI 一样自举）：

```powershell
git clone --depth 1 --branch llvmorg-23.1.4 https://github.com/llvm/llvm-project.git
cmake -S llvm-project/llvm -B build -G Ninja `
  -DCMAKE_BUILD_TYPE=Release `
  -DCMAKE_INSTALL_PREFIX="$PWD/stage/clang+llvm-23.1.4-x86_64-pc-windows-msvc" `
  -DCMAKE_C_COMPILER=clang-cl -DCMAKE_CXX_COMPILER=clang-cl `
  -DCMAKE_LINKER=lld-link -DLLVM_ENABLE_LLD=ON `
  -DLLVM_ENABLE_PROJECTS="clang;lld" `
  -DLLVM_ENABLE_RUNTIMES="compiler-rt" `
  -DLLVM_TARGETS_TO_BUILD="X86" `
  -DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBXML2=OFF `
  -DLLVM_ENABLE_CURL=OFF -DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_FFI=OFF `
  -DLLVM_ENABLE_BINDINGS=OFF -DLLVM_ENABLE_TERMINFO=OFF `
  -DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_DOCS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF `
  -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_UTILS=OFF -DLLVM_INCLUDE_GO_TESTS=OFF `
  -DLLVM_OPTIMIZED_TABLEGEN=ON -DLLVM_ENABLE_ASSERTIONS=OFF
ninja -C build install
```
