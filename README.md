# llvm_build

手动触发的 LLVM 编译流水线。给自己仓库加一个 workflow，就能在 GitHub Actions 上
按任意分支 / tag / commit 编一份 `clang + lld`，产物是解压即用的 `.tar.zst`。

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
| `create_release` | `false` | 勾上则发布到本仓库 Release，tag 为 `build/<版本>-<sha7>` |

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

官方那套 `LLVM_ENABLE_LIBXML2/ZLIB/ZSTD=FORCE_ON`（自带 libxml2/zlib/zstd 源码）和
`LLVM_ENABLE_RPMALLOC=ON` 没有跟，这几个依赖保持关闭，产物不绑第三方库。

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

## 预期耗时与磁盘

免费 runner 是 4 核 / 16 GB 内存，`targets=X86` 的情况下大概：

| 平台 | 编译 | 打包 | 磁盘峰值 |
|---|---|---|---|
| Linux x64 | 1.5–2.5 h | 5–10 min | build ~8 GB + stage ~3 GB |
| Windows x64 | 3.5–5.5 h | 10–20 min | build ~12 GB + stage ~5 GB |

单 job 硬上限 6 小时，workflow 里设了 `timeout-minutes: 350`。Windows 上 MSVC 编
LLVM 很慢，如果贴着上限跑，按下面顺序砍：

1. `projects` 去掉 `lld`（`clang` 单独能跑，只是没法用 `-fuse-ld=lld`）；
2. `runtimes` 填 `none` 关掉 compiler-rt（只损失 sanitizer 和极少数内建函数，
   想保留 builtins 就别动）；
3. `targets` 保持 `X86`，别加 AArch64；
4. 换自托管 runner。

磁盘不够时（Windows 报 `No space left on device`）把 `targets` 砍到 `X86`、`projects`
砍到 `clang`，或者别在同一台 runner 上同时跑两个 LLVM 编译。

## 和官方 release 包的区别

官方 `clang+llvm-23.1.4-x86_64-pc-windows-msvc.tar.zst` 是
`llvm/utils/release/build_llvm_release.bat` 产出的，包含 MSI 那套完整工具链、开
了 zlib/zstd/libxml2、带 `compiler-rt` 和 `openmp` 运行时、X86 + AArch64 两个后端。
本 workflow 是"够用的工具链"路线：

| 项 | 官方包 | 本 workflow |
|---|---|---|
| MSI 安装包 | 有 | 无 |
| compiler-rt | 有 | Windows 有（builtins + sanitizer），Linux 无（走 libgcc） |
| OpenMP | 有 | 无 |
| zlib / zstd / libxml2 | 开 | 关 |
| targets | X86 + AArch64 | 默认 X86 |
| 调试信息 | 保留 PDB | strip |
| 签名 / attestation | `.jsonl` 证明 | 无 |
| 构建机 | LLVM 自己的 16 核 depot runner | 免费 4 核 runner |

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
