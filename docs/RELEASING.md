# 构建与发布

当前版本0.5.1+6，源码Apache-2.0。第三方组件保持各自许可证，LGPL对应源码随安装包和源码包提供。

## 发行矩阵

| 目标 | 构建机 | 产物 | 实际签名 |
| --- | --- | --- | --- |
| macOS M系列 / ARM64，macOS13+ | Apple Silicon macOS，固定Flutter3.47.7 | DMG拖放安装、ZIP | ad-hoc，未Developer ID签名/公证 |
| Windows x64 | 原生Windows x64，`windows-2022` | Inno安装器、便携ZIP | 未Authenticode签名 |
| Windows ARM64 | 原生Windows ARM64，`windows-11-arm` | Inno安装器、便携ZIP | 未Authenticode签名 |

Linux及Intel macOS不属于本次发行矩阵。macOS13是所带objective_c与sqlite3原生框架的实际最低系统要求；构建工具会检查所有Mach-O，禁止将含x64切片的app标为纯ARM64。Windows同样检查OS/PowerShell/Dart/PE/AOT/FFI和MSVC CRT架构，不能在x64构建后改名为ARM64。

## 本地构建

macOS：

```sh
flutter pub get --enforce-lockfile
./tool/package-macos.sh --arch arm64 --version 0.5.1 --output-dir releases
python3 tool/package-source.py --output-dir releases
```

脚本局部传递`FLUTTER_XCODE_ARCHS=arm64`并固定main入口，薄化所有原生负载，加入许可/源码，逐层签名；验证ZIP解压副本、只读挂载DMG及Applications链接，然后卸载。已有审计main app可用`--source-app PATH`。禁止传入压力测试app。重复输出必须明确加`--overwrite`。

Windows详见[windows-build.md](windows-build.md)，在对应原生PowerShell7运行：

```powershell
$arch = 'x64' # ARM64原生机器改为arm64
./tool/setup-windows-flutter.ps1 -Architecture $arch -Destination "$env:TEMP/portly-flutter-$arch"
./tool/package-windows.ps1 -Architecture $arch -OutputDirectory "dist/windows/$arch"
```

Flutter3.47.7由原生Dart主机ABI选择Windows目标，不使用不存在的`--target-platform`参数。ARM64 SDK从固定源码标签启动，检查实际Dart PE，发生x64回退会失败。Inno6.3+及匹配目标的Visual Studio C++/CRT必须已安装。

## GitHub Actions

`Checks`负责每次main/master推送或PR的分析、单元/集成测试和打包工具校验。`Release packages`在main推送、版本标签或手工执行时生成三平台原生包及完整源码包；Windows job还会在干净CI账户实际安装、启动窗口、安全退出、检查数据库句柄关闭、卸载并确认用户数据保留。

1. 确认`pubspec.yaml`版本与构建号，推送源码至`main`，在Actions等待三平台任务通过。
2. main推送仅创建或更新对应版本的**草稿Release**，三平台构建、安装验证及校验和全部通过后才附加文件。手工任务默认只构建；勾选`create_draft_release`才建立草稿。
3. 如使用版本标签触发构建，标签必须与项目版本一致，如`v0.5.1`；该流程同样只创建草稿。已公开版本需要先递增项目版本，不会自动替换已公开附件。
4. 检查草稿中的DMG、两种Windows安装器/ZIP、同版本`source.zip`、原生验证报告和`SHA256SUMS`，再由发布者公开发布。已公开Release的附件不会被脚本覆盖。

GitHub草稿与Artifact不等同于面向访客的正式公开下载。签名状态在报告中如实保留，哈希只验证文件一致性，不替代发行者身份认证。

## 许可与对应源码

必须将`LICENSE`、`NOTICE`、`THIRD_PARTY_NOTICES.md`及`third_party_licenses/`放入每个包。后者包含83个已锁定包的许可、Flutter完整notice、JetBrainsMono OFL、GPL/LGPL全文及3份对应源码。原生C libserialport和Dart libserialport均含LGPL代码，因此同版本完整应用源码、锁文件、资源和构建脚本应与二进制同页提供，支持修改库后完整重建。

`source.zip`排除构建缓存、用户配置、日志、私钥和本机诊断数据，保留全部应用工程和构建输入，内含逐文件SHA清单。`third_party_licenses/**`在Git中禁用换行转换，保留上游许可原始字节与哈希。

MSVC app-local CRT从Visual Studio可再分发目录按架构复制，按Microsoft许可分发，不由项目Apache许可证重新许可。开发机System32的DLL不会被复制入包。后续CRT更新、Developer ID/公证及Windows签名需要受控发行配置，本次不会假称已签名。
