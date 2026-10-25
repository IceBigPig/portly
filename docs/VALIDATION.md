# 0.5.0验证范围

本地环境：Apple M4、24GiB、macOS26.6.2、Flutter3.47.7/Dart3.13.5、Xcode27.1。所有结论限定其已测范围。

- 226项自动化测试全部通过，覆盖串口生命周期/控制线、8通道映射、有界缓存、文件发送、命令/响应、历史、导入冲突、owner锁及退出排空。
- dart静态分析无问题，macOS与Web Release构建成功。Web不提供原生串口，不能替代桌面验收。
- macOS ARM64包的7个Mach-O全部为arm64；应用/框架签名严格检查、ZIP解压、DMG挂载、Applications拖放入口、105项许可SHA均通过。实际最低系统声明13.0；未Developer ID签名和公证。
- Windows脚本在macOS原生PowerShell运行39项语法/PE/ELF/运行库目录校验及11项崩溃事件关联检查；真实Flutter3.47.7与sqlite3两种架构的官方原生资产已经核对SHA和架构。这不代替Windows应用编译、安装或启动；这些由GitHub原生runner记录，实际结果以相应workflow和随包smoke报告为准。
- [压力测量状态](performance/STATUS.md)：只有短时间校准及提前停止的观察，没有30分钟/2小时通过结论。

原生本地界面检查包括历史入口、导入预览/冲突选项/取消保留原库、第二主实例拒写与Cmd-Q错误保护。未向默认产品加入测试命令或演示数据。

真实USB转串口适配器的电平、拔插、驱动/流控矩阵、Windows ARM64设备驱动、睡眠唤醒、冷启动20次P95、长期内存增幅与Linux实机均未由上述检查证明。文件发送是原始字节分块，不提供X/Y/ZMODEM或断点续传。
