# Release性能测量

当前结论见 [STATUS.md](STATUS.md)：长测按用户要求提前停止，不能宣称30分钟或2小时通过。

`tool/stress_main.dart` 是独立测试入口，使用临时库、真实本机UDP和生产UI/模型路径。正常应用不含预置测试会话或演示数据。复现示例：

```sh
./tool/stress_run.sh 60 calibration /tmp/portly-pressure-new-calibration
./tool/stress_run.sh 7200 acceptance /tmp/portly-pressure-new-acceptance
```

目录必须不存在。构建使用Release并保留源码与二进制SHA；测试副本采用独立应用标识Portly Pressure，阻止误点改变固定会话，主程序及用户配置不变。测试结束后应正常重新构建`lib/main.dart`，不要将压力入口的默认build产物作为正式发行包。源码压测入口与原始数据均不属于已通过的长期认证。

负载为8会话/2000事件每秒/128B，8波形通道，100000日志缓存，开启文件记录与索引；穿插输入、切换、暂停、发送执行和连接重开。归档上限测试时临时提高到192GiB，每分钟核对磁盘，低于30GiB可用时中止。正常默认额度不因测试而修改。

逐10秒采集RSS、CPU、帧时、事件循环、录制队列、原始序号与内核IO；30分钟及2小时仅在真实时长达到后核对。独立进程源/文件/SQLite/历史排空及总数比较，不能以短校准或加速测试时钟替代。
