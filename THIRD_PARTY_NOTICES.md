# Third-party notices

Portly 原创代码版权为 **Copyright 2026 Portly contributors**，采用 [Apache License 2.0](LICENSE)。第三方组件保持各自的版权、许可和使用条件；根目录的 Apache-2.0 不会替代它们的许可证。

完整文本与对应源码随发行包一起提供于 `third_party_licenses/`。机器可读清单是 [dependency-manifest.json](third_party_licenses/dependency-manifest.json)，全部已解析依赖的版本与许可索引是 [DEPENDENCIES.md](third_party_licenses/DEPENDENCIES.md)。该清单包含开发、构建和平台备选包，是保守的锁定依赖清单；不表示每个平台二进制都包含其中每一个包。具体版权及条款以目录中未经改写的原文为准。

仓库中保存完整许可通用基线。打包时先核对实际 `pubspec.lock`、已解析依赖和 Flutter／Dart SDK 同版，再仅在 staging 副本中将 Flutter notice 文本更新为该 app 实际 `NOTICES.Z` 的解压原文，同时更新其 manifest 哈希和 `SHA256SUMS` 中对应两项。其他原始许可证及对应源码保持逐字节不变，仓库基线不被覆盖。发行报告的 `asBuiltNotices` 记录实际压缩／解压 notice SHA、锁文件和 SDK 信息；ZIP／DMG 中继续严格核对实际 notice 与全部许可材料校验值。该处理不对不同机器生成文本的差异原因作推断。

| 组件 | 版本／来源 | 许可与材料 |
| --- | --- | --- |
| Flutter / Dart 及引擎依赖 | Flutter 3.47.7 / Dart 3.13.5；本次实际 Release 生成 | [完整 Flutter notices](third_party_licenses/FLUTTER-NOTICES.txt)，保留引擎和依赖的多种许可证 |
| flutter_libserialport 插件外层 | pub 0.6.0 | MIT；其 `third_party/libserialport` C 库另用 LGPL-3.0-or-later，不能将整个组件视为只有 MIT |
| Dart libserialport 包 | pub 0.3.0+1 | LGPL-3.0-or-later，进入 Dart AOT 的封装和绑定也适用该许可 |
| macOS 原生 libserialport | CocoaPods 0.1.1，官方 `libserialport-0.1.1` 标签 | LGPL-3.0-or-later；提供该标签完整源码、实际 Pod 构建配方、生成头文件和编译输入对照 |
| Windows 原生 libserialport | flutter_libserialport 0.6.0 内附版本 | LGPL-3.0-or-later；提供该版本完整插件源码，包括 C 源、头文件、CMake 和 Windows 构建配置；不以 macOS 的源码包替代 |
| sqlite3 Dart 包 | pub 3.8.0 | MIT；实际默认原生 SQLite 为公共领域软件，参见 [SQLite 官方说明](https://www.sqlite.org/copyright.html) |
| JetBrains Mono 字体 | `assets/fonts/JetBrainsMono-Regular.ttf` | SIL Open Font License 1.1；[完整版权和许可](third_party_licenses/fonts/JetBrainsMono-OFL.txt) |
| 其他锁定 Dart／Flutter 包 | 以 `pubspec.lock` 为准 | 各包原始 LICENSE／NOTICE 已复制至 `third_party_licenses/packages/` |

## LGPL 组件及对应源码

本软件使用 GNU Lesser General Public License version 3 or later 的组件。副本中提供 [LGPL v3 全文](third_party_licenses/licenses/LGPL-3.0.txt) 和它所引用的 [GPL v3 全文](third_party_licenses/licenses/GPL-3.0.txt)。Portly 不限制用户修改这些库，也不限制为调试此类修改而进行的逆向工程。

以下三个源码档案随本软件发行，SHA-256、公开上游位置及匹配依据保存在 [dependency-manifest.json](third_party_licenses/dependency-manifest.json) 和 [SHA256SUMS](third_party_licenses/SHA256SUMS)：

- `sources/libserialport-0.1.1-upstream.tar.gz`：macOS 原生库对应的官方完整源码，标签提交为 `348a6d353af8ac142f68fbf9fe0f4d070448d945`。
- `sources/flutter_libserialport-0.6.0-resolved-source.tar.gz`：实际解析的完整插件源码，包括 Windows 使用的 LGPL C 源、构建胶水，以及 MIT 插件代码。
- `sources/libserialport-0.3.0+1-resolved-source.tar.gz`：实际解析的完整 LGPL Dart 包源码。

两个 pub 包的原始发布档案已按 `pubspec.lock` 中的 SHA-256 核对，并逐文件与实际解析的缓存源码比较，记录见 [published-source-verification.json](third_party_licenses/sources/published-source-verification.json)。macOS C 源及头文件模板与官方标签逐字节比较的记录见 [source-verification.json](third_party_licenses/native/macos/source-verification.json)。Portly 未修改上述库源码；CocoaPods 自动生成的 `config.h`／`libserialport.h` 与原始 Podspec 另附于 `native/macos/`。

同版本 Portly 应用源码、锁文件、资源和构建脚本应与二进制一同提供，或在同一发行页面提供可下载的对应源码归档。这样可以在修改 LGPL Dart 代码后完整重编译应用。重建、动态库替换及本地签名步骤见 [REBUILDING-LGPL.md](third_party_licenses/REBUILDING-LGPL.md)。

## 材料再生成

先执行项目使用的 `flutter pub get`，再以相应 Release 的 `flutter_assets/NOTICES.Z` 为输入：

```sh
python3 tool/collect_licenses.py \
  --notices /path/to/Release/flutter_assets/NOTICES.Z \
  --verify-published-sources
```

macOS 安装好项目的 Pods 后，可加 `--verify-macos-pod` 核对原生库实际输入。脚本只复制文本及源码，不执行下载的第三方代码；源码归档的成员顺序、时间、用户和组元数据已规范化，不包含收集机器的缓存绝对路径。更换依赖、引擎或构建平台后，应使用新发行物重新生成并随包保留材料。

同锁文件及 SDK 的二进制打包使用 `tool/sync_release_notices.py`，由 macOS／Windows 打包器自动调用；它只允许更新 staging 中上述三个文件，不能修改仓库许可目录，也不会把损坏或缺失的原许可证重新计算摘要以掩盖错误。依赖或 SDK 换版会明确失败，必须先重新收集完整许可基线。纯 Python 验证可运行 `python3 tool/test_sync_release_notices.py`，无需启动 Flutter。

官方条款参考：[Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0.txt)、[GNU LGPL v3](https://www.gnu.org/licenses/lgpl-3.0.html)、[GNU GPL v3](https://www.gnu.org/licenses/gpl-3.0.html)、[libserialport 上游许可说明](https://sigrok.org/wiki/Libserialport)。所附 GNU 全文也与 GNU 官方 GCC 源库的 `COPYING3`／`COPYING3.LIB` 副本逐字节核对。
