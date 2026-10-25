# Windows x64 / ARM64 构建与分发

这两种发行包必须在 Windows 构建。当前 macOS 工作区只完成了打包脚本、二进制校验器和依赖资产核对，没有生成或验证过 Portly 的 Windows 安装包。CI 的成功构建及安装验收结果应另行保留，不能把脚本测试当成 Windows 应用验收。

## 构建环境

| 目标 | 原生运行环境 | GitHub Actions runner | Flutter 命令 |
| --- | --- | --- | --- |
| x64 | Windows x64、x64 PowerShell 7.2+ | `windows-2022` | `flutter build windows --release` |
| ARM64 | Windows ARM64、ARM64 PowerShell 7.2+ | `windows-11-arm` | `flutter build windows --release` |

还需要 Visual Studio C++ 桌面工作负载、CMake、Windows SDK、目标架构的 MSVC 工具与可再分发 CRT，以及 Inno Setup 6.3+。当前 GitHub 官方镜像清单列有 Inno Setup；脚本会发现 `ISCC.exe`，缺失时明确失败。自托管环境可以通过 `-InnoSetupCompiler` 和 `-VCRuntimeDirectory` 显式指定。

Flutter 3.47.7 的 `build windows` 按运行 Dart 的主机 ABI 选择目标，未提供 `--target-platform` 参数。ARM64 Windows 上运行 x64 Dart 会构建 x64，因此不能把目录改名后当作 ARM64 分发。打包脚本会同时检查 OS、PowerShell、Dart、应用、Flutter 引擎、所有插件 DLL 和 AOT 架构。

官方 Windows SDK 发行索引中的 3.47.7 归档携带 x64 Dart。`tool/setup-windows-flutter.ps1` 使用版本标签的全新源码检出，由该版本的 `update_dart_sdk.ps1` 在原生 ARM64 进程中引导下载 ARM64 Dart。如果 SDK 回退为 x64，脚本会在打包前拒绝继续。不要复用另一架构的 Flutter cache。

## 原生构建

从仓库根目录，在目标架构的 Windows PowerShell 7 执行：

```powershell
$arch = 'x64' # 在原生 ARM64 Windows 上改为 arm64
$sdk = Join-Path $env:TEMP "portly-flutter-$arch-3.47.7"
./tool/setup-windows-flutter.ps1 -Architecture $arch -Destination $sdk
./tool/windows/test-packaging.ps1
./tool/package-windows.ps1 -Architecture $arch `
  -Flutter (Join-Path $sdk 'bin/flutter.bat') `
  -OutputDirectory "dist/windows/$arch"
```

SDK 目标目录必须不存在，输出目录也不能存在同名发行文件。脚本失败时不保留一半生成的发行文件。`-SkipBuild` 只适用于明确知道来源的已有 Release bundle，仍执行完整架构、依赖和 ZIP 内容校验；发行 CI 应使用默认构建模式。

GitHub Actions 中把 SDK 目标目录放到 `$env:RUNNER_TEMP`。setup 脚本写入 `GITHUB_PATH`，随后步骤即可直接调用 `flutter`。以 x64、ARM64 两个独立 job 运行，最后上传各自 `dist/windows/<arch>/`。不要在 macOS job 中调用这两个脚本构建 Windows。

## 产物及校验

以版本 0.5.0 为例，每个目标产生四个文件：

- `Portly-0.5.0-windows-x64-portable.zip`，包含完整 `Portly/` 运行目录。
- `Portly-0.5.0-windows-x64-setup.exe`，Inno Setup 按架构安装包。
- `Portly-0.5.0-windows-x64-manifest.json`，版本、Flutter revision、Git commit、逐文件 SHA-256、PE 架构和导入依赖。
- `Portly-0.5.0-windows-x64-SHA256SUMS.txt`，前三个文件的 SHA-256。

ARM64 使用对应的 `arm64` 文件名。ZIP 解压后直接运行 `Portly/portly.exe`，不能只复制 EXE。安装包使用当前用户目录，不要求管理员权限；卸载不删除用户配置、历史或归档。x64 安装包只允许 x64 Windows，ARM64 安装包只允许 ARM64 Windows，避免在 ARM64 机器上误装 x64 版本。

脚本按 DLL 的实际 PE 架构，从 Visual Studio 可再分发目录复制匹配的 app-local CRT，供便携版及安装版使用；不从 `System32` 复制开发机器 DLL。app-local CRT 的后续安全更新随应用发行维护。微软 ARM64 CRT 发行目录也会附带 x64 的 `vcruntime140_1.dll`，脚本排除这类兼容库；如果原生应用实际导入了未打包的 DLL，依赖闭包检查仍会拒绝分发。完整目录中每个 EXE/DLL 必须具有目标 PE 架构，静态和延迟导入必须能在包内或明确的 Windows 系统 DLL 集合中解析。`data/app.so` 是 Flutter ELF64 AOT 快照，另按 ELF machine 校验。脚本强制检查动态加载的 `serialport.dll` 和 SQLite 原生资产，避免仅检查静态依赖而漏掉 FFI DLL。

当前脚本不执行 Authenticode 签名，manifest 会明确记录 `signed: false`。正式发布者可在受控 Windows 签名流程中签署应用和安装器，再重新生成哈希；签名后旧哈希无效。SHA-256 校验不等同于发行者身份认证。

## 插件边界

- `flutter_libserialport 0.6.0` 的 Windows CMake 从 C 源码构建 `serialport.dll`，链接 Windows `cfgmgr32` 和 `SetupAPI`，未固定为 x64 预编译库。ARM64 USB 串口仍需要设备供应商提供匹配的 Windows ARM64 驱动。
- `sqlite3 3.8.0` 的 native-assets hook 提供 x64、ARM64 Windows DLL，并校验包中固定的 SHA-256。两个实际下载文件已在 macOS 上检查 PE machine；这不代替在 Windows 执行 SQL 和全文检索测试。
- `desktop_multi_window`、`file_selector_windows`、`screen_retriever_windows`、`window_manager` 使用 C++ 源码构建，最终仍以 Windows CI 结果为准。
- `jni 1.1.0` 由 Android 路径提供器间接引入，Portly Windows 不使用 Java。顶层 Windows CMake 在插件配置期间禁用可选 JNI 发现，避免 CI 的 JDK 导致额外 JVM 依赖或不匹配架构；没有改动生成插件文件。

## 本地已验证与待验证

2026-10-25 在 macOS ARM64 上使用官方 PowerShell 7.5.4 运行 29 项检查，覆盖脚本 AST 语法、PE32+ 和 ELF64 两架构识别、错误架构拒绝、截断 PE、普通和延迟导入、缺失 FFI/依赖拒绝，以及非 Windows 主机拒绝打包。另实际下载官方 Flutter 3.47.7 两架构引擎和 sqlite3 3.8.0 两架构 DLL，核对 PE 架构及 SQLite 固定哈希。独立 CMake 配置也确认禁用 JNI 后不生成/捆绑 JVM bridge。

尚未完成的 Windows 验收包括：MSVC 编译及链接、Inno 脚本实际编译、安装/卸载、原生界面启动、配置与历史/归档落盘、SQLite FTS5/trigram 查询、串口设备/DTR/RTS/自动重连、文件发送、多窗口退出。这些必须在相应 Windows 架构的 runner 或设备上执行，不能标记为已通过。

## 一手参考

- [Flutter Windows 分发说明](https://docs.flutter.dev/deployment/windows)
- [Flutter 官方 SDK 发行索引](https://storage.googleapis.com/flutter_infra_release/releases/releases_windows.json)
- [Flutter 3.47.7 Windows 构建命令源码](https://github.com/flutter/flutter/blob/3.47.7/packages/flutter_tools/lib/src/commands/build_windows.dart)
- [Flutter 3.47.7 Windows Dart 引导源码](https://github.com/flutter/flutter/blob/3.47.7/bin/internal/update_dart_sdk.ps1)
- [GitHub runner 标签](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
- [Windows 2022 官方镜像清单](https://github.com/actions/runner-images/blob/main/images/windows/Windows2022-Readme.md)
- [Windows ARM64 官方镜像清单](https://github.com/actions/runner-images/blob/main/images/windows/Windows11-VS2026-Arm64-Readme.md)
- [Inno Setup 架构条件](https://jrsoftware.org/ishelp/topic_archidentifiers.htm)
- [Microsoft C++ 再分发文件](https://learn.microsoft.com/en-us/cpp/windows/redistributing-visual-cpp-files)
- [sqlite3.dart 3.8.0 二进制发行](https://github.com/simolus3/sqlite3.dart/releases/tag/sqlite3-3.8.0)
