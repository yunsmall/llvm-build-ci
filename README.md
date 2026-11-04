# llvm_build

白嫖 GitHub Actions 编 LLVM 的自用流水线。按任意分支 / tag / commit 编一份
`clang + lld`，产物是解压即用的压缩包（默认 `.tar.zst`，可选 `.tar.gz` / `.tar.xz` / 不压缩）。

- workflow：[`.github/workflows/build-llvm.yml`](.github/workflows/build-llvm.yml)
- 脚本：[`scripts/`](scripts/)：拉源码、现编第三方库、配置、编译安装、打包，各一个
- 平台：Windows x64（clang-cl + lld-link 自举）、Linux x64（clang + lld，没有 clang 时退 gcc）
- 参考实现：[wasmerio/llvm-custom-builds](https://github.com/wasmerio/llvm-custom-builds)
  （产物形态一致，但那个项目版本写死在 matrix 里、只认 `release/N.x` 分支）

## 怎么用

1. 仓库 Settings → Actions → General，确认 Workflow permissions 允许
   `Read and write permissions`（只有勾了 `create_release` 才需要，否则只读就够）。
2. Actions 页面左侧选 **Build LLVM** → **Run workflow**，填参数。
3. 不想用网页就 `gh workflow run build-llvm.yml -f llvm_ref=llvmorg-23.1.4 -f preset=official`。

public 仓库跑 Actions 不花额度；private 仓库按分钟计费，Windows 分钟按 2 倍算。
脚本都是普通 bash，本地可以 `bash -n scripts/*.sh` 做语法检查，也能单独跑起来调试。

## 输入

| 输入 | 默认 | 说明 |
|---|---|---|
| `llvm_repo` | `llvm/llvm-project` | 换成自己的 fork 就能编带补丁的版本 |
| `llvm_ref` | `main` | 分支名、tag（`llvmorg-23.1.4`）、**完整** 40 位 commit SHA |
| `preset` | `simple` | 配置档下拉框：`simple` / `official` / `custom`，见下节 |
| `targets` | 空 | `LLVM_TARGETS_TO_BUILD`，留空=跟随 preset |
| `projects` | 空 | `LLVM_ENABLE_PROJECTS`，留空=跟随 preset |
| `runtimes` | 空 | `LLVM_ENABLE_RUNTIMES`，留空=跟随 preset；填 `none` 强制都不编 |
| `builtin_targets` | 空 | 额外交叉编 compiler-rt **builtins** 的目标 triple（`;` 分隔）；留空=默认列表；`none`=关；`all`=再加冷门架构，见下节 |
| `shared_llvm` | `false` | 编动态 LLVM 库：Windows 产 `LLVM.dll` + `LLVM-C.dll`，Linux 产 `libLLVM-<ver>.so`，工具也链到动态库上 |
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

`builtin_targets` 默认开启，它需要的后端会自动补进 `targets`（见“交叉编译 builtins”），
所以默认配置下 `simple` 也会带 ARM / AArch64 / RISC-V / WebAssembly 后端。

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
`build` job 按 `prepare` 解析出的 SHA 直接浅拉，不再拉分支名——否则两次 fetch 之间
上游推进会让两边版本对不上。只有在服务端不允许按 SHA 取时才退回按 ref 取，并保留
SHA 校验兜底。

## 交叉编译 builtins

除了宿主自己那份 compiler-rt，默认还会给一组常用目标额外编 **builtins**
（`libclang_rt.builtins-*`，提供 `__aeabi_*`、软浮点、64 位除法这类编译器辅助函数）。
用的是 `LLVM_BUILTIN_TARGETS`：只建 `compiler-rt/lib/builtins`，不配置 sanitizer，
所以不需要目标 sysroot 也能交叉编。为了让这套东西在 Windows 宿主机上也能跑：

- 所有非 Windows 目标都加 `-ffreestanding` 并打开 `COMPILER_RT_BAREMETAL_BUILD`。
  前者避免 clang 自带的 `limits.h`、`stdint.h` 去 `include_next` 宿主 glibc；
  后者去掉 builtins 里依赖目标 libc 的头和实现的 `emutls.c`、`eprintf.c`、
  `enable_execute_stack.c`（正常链接目标程序时这三样由目标 libc 提供，用不到
  builtins 里的份）。
- Linux 目标剩下少量代码还要 `assert.h`、`sys/auxv.h`、`sys/cachectl.h` 等头，
  构建时用一个只含声明的最小垫片目录顶上，真正的实现（`getauxval`、
  `_flush_cache`）留给目标 libc 在链接时解析。
- Windows 目标走 clang-cl，MSVC 头本来就在 runner 上，不用加这些。

因此非 Windows 目标的 builtins 里没有 `__emutls_*` 和 `__enable_execute_stack`，
其余算术符号完整。

`builtin_targets` 留空时的默认目标：

| 类别 | triple |
|---|---|
| Linux | `i686-unknown-linux-gnu`、`aarch64-unknown-linux-gnu`、`armv7-unknown-linux-gnueabi`（软浮点）、`armv7-unknown-linux-gnueabihf`（硬浮点）、`riscv64-unknown-linux-gnu` |
| 裸机 | `aarch64-none-elf`、`armv6m-none-eabi`、`armv7m-none-eabi`、`armv7em-none-eabi`、`riscv32-unknown-elf`、`riscv64-unknown-elf` |
| WebAssembly | `wasm32-unknown-unknown` |

`builtin_targets=all` 再追加 `loongarch64-unknown-linux-gnu`、
`powerpc64le-unknown-linux-gnu`、`s390x-unknown-linux-gnu`、`mips64el-unknown-linux-gnuabi64`、
`sparcv9-unknown-linux-gnu`、`aarch64_be-unknown-linux-gnu`；Windows 宿主再加
`i686-pc-windows-msvc`、`aarch64-pc-windows-msvc`、`x86_64-unknown-linux-gnu`。
也可以自己填任意 triple，空格、换行、逗号、分号分隔都行。

两个自动行为：

- 对应后端会自动补进 `LLVM_TARGETS_TO_BUILD`。builtins 由刚编出来的 clang 编译，
  后端不在 clang 里会直接报 unknown target。
- 安装后有一个校验步骤，用产物里的 clang 查每个 triple 的运行时目录，
  找不到 `*clang_rt.builtins-*` 就把 job 判失败，避免配置成功却静默漏编。

产物在 `lib/clang/<ver>/lib/<triple>/` 下，clang 用 `--target=<triple>` 时自动能找到。

代价：每个 triple 一次配置加少量编译，1～3 分钟；默认 12 个大约多 15～30 分钟，
`all` 再多 15～20 分钟，每个 triple 的产物只有几 MB。交叉编的**只有 builtins**；
wasm 目标额外关掉 `crtbegin/crtend`（wasm 没有 init/fini 机制，crtbegin.c 会直接
报错），其余目标在 Linux 宿主上照常编 crt，Windows 宿主本来就不编 crt；
sanitizer / profile 仍然只编宿主那一份（交叉它们需要目标 libc 和 crt）。

## 动态 LLVM 库

`shared_llvm=true` 时额外编动态库，自己写测试链接它就不用每个 exe 静态塞一份 LLVM：

- 只支持 LLVM 24 及以后：23 及更早的导出注解不完整（`VPlan.h` 里成员重复标注、
  缺 `IntrusiveRefCntPtrInfo<vfs::FileSystem>` 特化），Windows 上编不出可用的
  `LLVM.dll`，`shared_llvm=true` 遇到这些版本会直接报错，请改用静态构建。
- Linux：`libLLVM-<ver>.so` 和 `libclang-cpp.so`，`clang` 等工具通过
  `LLVM_LINK_LLVM_DYLIB` 链到它们上面。
- Windows：同时产 `LLVM-<主版本><版本后缀>.dll`（C++ API，主线现在是
  `LLVM-24git.dll`，导入库 `LLVM-24git.lib`）和 `LLVM-C.dll`（C API，
  导入库 `LLVM-C.lib`）。`LLVM-C.dll` 链接前者，链接器只会生成转发桩，
  不会复制第二份 LLVM；实测 129 KB 对 96 MB。上游在 MSVC/clang-cl 上不设
  `LLVM_BUILD_LLVM_DYLIB_VIS=ON` 会直接报 `Generating libLLVM is not supported
  on MSVC`，所以 Windows 上必须开。
  CRT 同时切成动态 `/MD`（`CMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL`），避免
  跨 DLL 传递分配过的内存时出现两套堆。PCH 同时禁用
  （`CMAKE_DISABLE_PRECOMPILE_HEADERS=ON`）：PCH 对象里的 inline 模板实例会和
  DLL 导出撞车，lld-link 会报 `duplicate symbol`（`basic_parser<T>` 等），
  代价是 Windows 动态构建慢一些。`CLANG_ENABLE_CIR` 也关掉：它默认开启并自动
  拉入 MLIR，而 MLIR 工具会同时链静态 LLVM 库和 `LLVM.dll`，COFF 下同样报
  `duplicate symbol`。CIR 是实验特性，关掉不影响正常 C/C++ 编译。
- Windows 的 `clang-cpp` 不参与动态链接：clang 的 C++ 头只有少量 `CLANG_ABI`
  注解，`clang-cpp.dll` 导不出完整 API。工具静态链 clang 自己的库，LLVM 部分仍走
  `LLVM-24git.dll`。运行时会顺带装一个与 `clang.exe` 字节完全相同的
  `clang-cpp.exe`，那只是驱动的一份拷贝，不是库。
  静态链 clang 库时 C++ 标准库仍是动态的：整个构建用 `/MD`，运行时依赖
  `msvcp140.dll` / `vcruntime140.dll`。

静态库照常安装，需要静态链接时还能用；`shared_llvm` 只是额外多出动态库，
并让工具链到动态库上。compiler-rt 的 builtins 不受影响。

注意：

- 用 C++ API 时，调用方编译要加 `-DLLVM_BUILD_STATIC`（CMake 里
  `target_compile_definitions(... PRIVATE LLVM_BUILD_STATIC)`），链接参数仍用
  `LLVM-24git.lib`、运行时仍依赖 `LLVM-24git.dll`。不加的话头文件会把整个类标成
  `dllimport`，类里那些 inline 成员（比如 `raw_ostream::operator<<(const char *)`）
  一旦没被内联就会去找 `__imp_` 符号，而这些 inline 成员 DLL 里本来就没有。
  C API（`LLVM-C.lib`）不需要这个宏。
- `LLVM_BUILD_LLVM_DYLIB_VIS` 上游仍标注为“用于测试”，Windows 上的导出依赖
  `LLVM_ABI` 注解，可能有个别符号没导出；遇到链接错误先确认是不是缺导出。
  实测这份 `LLVM-24git.dll` 导出 28274 个 C++ 符号、`LLVM-C.dll` 导出 1273 个 C 符号。
- C++ API 没有 ABI 稳定保证。调用方要和构建时用同一套 ABI 和 CRT（Windows 上
  同一 MSVC 运行时、同一个 `_ITERATOR_DEBUG_LEVEL`），不要混用 MSVC 和 MinGW。
- Windows 上因为改用动态 CRT，产物运行时依赖 VC++ 运行库
  （`vcruntime140.dll` / `msvcp140.dll`），目标机器没装 redist 时要一并带上。
- 代价是多一次巨型链接，Windows 上大约多 5～15 分钟；包会比纯静态模式大一些
  （多出 DLL），但每个测试 exe 会从几十/上百 MB 降到几 MB。
- 默认不开，保持原来“纯静态、解压即用”的形态。

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

workflow 里带了一个 `schedule`：每天**北京时间 00:17**（UTC 16:17）用**发布时那套最全参数**
（`main` + `preset=official` + 全部后端 + 全部交叉 builtins + 动态库 + `both` + `zstd`）
编一次主线，等于每天把发布配置完整验证一遍，**不发布 Release**，产物就在
Actions 的 artifact 里，保留 14 天。

分钟位不写 0 是有原因的：整点是 GitHub 调度器最挤的刻度，实测 `0 16 * * *` 一整个时段
都没被派发过；挪到 17 分后正常触发。

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
