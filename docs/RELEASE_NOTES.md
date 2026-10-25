Portly 0.5.1 修复 Windows 串口设备名称及界面中文显示问题。

- Windows 串口列表改用 Unicode 系统接口读取设备名称，直接从 UTF-16 转为 Dart 字符串，避免依赖系统 ANSI 代码页。设备扫描继续在后台执行。
- Windows 原生串口错误提示通过 Unicode 系统消息读取，保留原始错误码。
- Windows 界面优先使用本机中文字体，等宽区域补齐中文字体回退；保留 macOS 和 Linux 对应的平台字体。
- 界面文字处理与串口报文编码分离，保留原有 HEX、二进制、文本和原始文件收发行为，无需修改 Windows 全局 UTF-8 设置。

附件包括 Windows x64 / ARM64 安装器与便携 ZIP、macOS 13+ M 系列 ARM64 DMG / ZIP、完整源码、SHA-256 校验文件及构建/安装验证报告。

源码采用 Apache-2.0。第三方许可与 LGPL 对应源码随包提供，请将完整 `source.zip` 与二进制一并保留。macOS 使用 ad-hoc 签名且未公证；Windows 未做 Authenticode 签名。

Windows x64 / ARM64 在对应原生 CI 环境执行回归、构建及安装/启动/正常退出/卸载验证。真实 USB 串口、不同厂商驱动和系统语言组合仍需实机验收；本次不恢复长时间压力测试。
