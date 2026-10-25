import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../core/models.dart';
import '../core/modbus.dart';
import '../core/wave.dart';
import '../platform/transport.dart';
import '../platform/storage.dart';

class Session extends ChangeNotifier {
  final String id;
  String runtimeId = newId();
  ConnectionConfig config;
  Draft draft;
  final logs = ListQueue<LogEntry>();
  void Function()? enforceBudget;
  int sequence = 0;
  void Function(HistoryRecord)? onHistory;
  String historyError = '';
  String _responseLogId = '';
  _HistoryRun? _historyRun;
  bool _shuttingDown = false;
  void beginShutdown() {
    _shuttingDown = true;
    _wantReconnect = reconnecting = false;
    _reconnectTimer?.cancel();
    stop();
  }

  void cancelShutdown() {
    _shuttingDown = false;
  }

  Future<void> drainSends() async {
    await _queue;
  }

  void _acceptNewAction() {
    if (_shuttingDown || _disposed) throw StateError('应用正在关闭');
  }

  String get activeHistoryTaskId => _historyRun?.record.id ?? '';

  void _recordHistory(HistoryRecord record) {
    try {
      onHistory?.call(record);
    } catch (e) {
      historyError = '历史保存失败：$e';
      scheduleNotify();
    }
  }

  List<String> _historyTargets(List<String?> targets) => targets
      .map((target) {
        if (config.kind == ConnectionKind.tcpServer) {
          final endpoint = transport?.peers
              .where((p) => p.id == target)
              .firstOrNull
              ?.endpoint;
          return '$target${endpoint == null ? '' : ' ($endpoint)'}';
        }
        return target ?? config.summary;
      })
      .toList(growable: false);
  void _updateTaskHistory(_HistoryRun run, Map<String, dynamic> changes) {
    run.record = run.record.update({
      ...changes,
      'elapsedMs': run.watch.elapsedMilliseconds,
    });
    _recordHistory(run.record);
  }

  final selectedCommands = <String>{};
  final recorder = LogRecorder();
  final waveform = WaveEngine();
  final Future<Transport> Function(ConnectionConfig) _opener;
  final Future<List<PortInfo>> Function() _scanPorts;
  Timer? _reconnectTimer, _waveWatch;
  bool reconnecting = false, _wantReconnect = false;
  int reconnectAttempt = 0;
  PortInfo? _device;
  ConnectionConfig? _reconnectConfig;
  SerialStatus serialStatus = const SerialStatus();
  bool controlBusy = false;
  int fileSent = 0, fileSize = 0;
  String fileName = '';
  bool fileSending = false;
  String controlError = '';
  bool get parametersLocked => connected || busy || reconnecting;
  Transport? transport;
  StreamSubscription<TransportEvent>? _subscription;
  int _generation = 0,
      _taskGeneration = 0,
      rx = 0,
      tx = 0,
      dropped = 0,
      rawBytes = 0;
  String focusLogId = '';
  String state = '未连接',
      task = '',
      error = '',
      selectedPeer = '',
      recentSource = '';
  bool busy = false,
      running = false,
      paused = false,
      hexDisplay = true,
      timestamps = true,
      autoScroll = true,
      commandsMode = false,
      waitResponse = true,
      loop = false;
  int periodMs = 1000;
  Timer? _notification;
  Completer<void> _stopSignal = Completer<void>();
  bool _disposed = false;
  Future<void> _queue = Future.value();
  int _queued = 0;
  void Function(TransportEvent)? _responseReceiver;
  final _framers = <String, RtuFramer>{};
  Session({
    String? id,
    required this.config,
    Draft? draft,
    Future<Transport> Function(ConnectionConfig)? opener,
    List<PortInfo> Function()? ports,
  }) : id = id ?? newId(),
       draft = draft ?? Draft(),
       _opener = opener ?? openTransport,
       _scanPorts = ports == null ? enumeratePortsAsync : (() async => ports());
  factory Session.fromJson(Map<String, dynamic> j) {
    final session = Session(
      id: j['id'],
      config: ConnectionConfig.fromJson(Map<String, dynamic>.from(j['config'])),
      draft: Draft.fromJson(Map<String, dynamic>.from(j['draft'])),
    );
    session.commandsMode = j['commandsMode'] ?? false;
    for (final value in (j['waveMappings'] as List? ?? []).take(8)) {
      session.waveform.upsert(
        WaveMapping.fromJson(Map<String, dynamic>.from(value)),
      );
    }
    return session;
  }
  bool? mirroredConnected, mirroredCanSend;
  bool get connected => mirroredConnected ?? (transport != null && !busy);
  bool get canSend =>
      mirroredCanSend ??
      (connected &&
          (config.kind != ConnectionKind.tcpServer ||
              (selectedPeer == '*'
                  ? transport!.peers.isNotEmpty
                  : transport!.peers.any((p) => p.id == selectedPeer))) &&
          (config.kind != ConnectionKind.udp ||
              config.targetHost.trim().isNotEmpty));
  String get targetSummary => config.kind == ConnectionKind.udp
      ? '${config.targetHost}:${config.targetPort}'
      : config.kind == ConnectionKind.tcpServer
      ? selectedPeer == '*'
            ? '全部在线客户端（${transport?.peers.length ?? 0}）'
            : transport?.peers
                      .where((p) => p.id == selectedPeer)
                      .firstOrNull
                      ?.endpoint ??
                  '请主动选择客户端'
      : config.summary;
  List<String?> freezeTargets() {
    if (!canSend) throw StateError('连接或发送目标尚未就绪');
    return config.kind == ConnectionKind.tcpServer
        ? selectedPeer == '*'
              ? transport!.peers.map((p) => p.id).toList()
              : [selectedPeer]
        : config.kind == ConnectionKind.udp
        ? ['${config.targetHost}:${config.targetPort}']
        : [null];
  }

  void changed() => notifyListeners();
  void scheduleNotify() {
    if (_disposed) return;
    _notification ??= Timer(const Duration(milliseconds: 40), () {
      _notification = null;
      notifyListeners();
    });
  }

  void addLog(LogEntry entry) {
    entry.sequence = ++sequence;
    logs.add(entry);
    rawBytes += entry.bytes.length;
    while (logs.length > 20000 || rawBytes > 16 * 1024 * 1024) {
      rawBytes -= logs.removeFirst().bytes.length;
      dropped++;
    }
    enforceBudget?.call();
    if (recorder.active) recorder.writeEntry(entry, runtimeId: runtimeId);
    scheduleNotify();
  }

  void system(String message) => addLog(LogEntry('SYS', [], message: message));
  Future<void> connect() async {
    _acceptNewAction();
    if (parametersLocked || _disposed) return;
    reconnectAttempt = 0;
    _device = null;
    final preparation = ++_generation;
    if (config.kind == ConnectionKind.serial) {
      busy = true;
      state = '连接中';
      notifyListeners();
      try {
        _device = (await _scanPorts())
            .where((p) => p.path == config.port)
            .firstOrNull;
      } catch (_) {}
      if (_disposed || preparation != _generation) return;
      busy = false;
    }
    _reconnectConfig = config.copy();
    _wantReconnect =
        config.kind == ConnectionKind.serial && config.autoReconnect;
    await _open(config.copy());
  }

  Future<void> _open(ConnectionConfig snapshot, {bool retry = false}) async {
    final generation = ++_generation;
    busy = true;
    state = retry
        ? '重连 $reconnectAttempt / ${snapshot.reconnectMaxAttempts}'
        : '连接中';
    error = '';
    notifyListeners();
    var succeeded = false;
    try {
      final opened = await _opener(snapshot);
      if (_disposed || generation != _generation) {
        await opened.close();
        return;
      }
      transport = opened;
      runtimeId = newId();
      _waveWatch?.cancel();
      _waveWatch = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (_disposed) return;
        if (waveform.expire(DateTime.now())) enforceBudget?.call();
        if (waveform.channels.any((c) => c.mapping.enabled)) scheduleNotify();
      });
      if (snapshot.kind == ConnectionKind.serial && opened is SerialControl) {
        serialStatus = (opened as SerialControl).serialStatus;
      }
      controlError = '';
      _subscription = opened.events.listen((event) {
        if (generation != _generation || _disposed) return;
        if (event.serialStatus != null) serialStatus = event.serialStatus!;
        if (event.bytes.isNotEmpty) {
          rx += event.bytes.length;
          recentSource = event.endpoint;
          final peer = opened.peers
              .where((p) => p.id == event.endpoint)
              .firstOrNull;
          final entry = LogEntry(
            'RX',
            event.bytes,
            endpoint: peer?.endpoint ?? event.endpoint,
          );
          addLog(entry);
          _responseLogId = entry.id;
          _responseReceiver?.call(event);
          waveform.receive(
            entry,
            datagram: snapshot.kind == ConnectionKind.udp,
          );
          if (waveform.channels.any(
            (c) => c.mapping.enabled && c.mapping.mode == 'Modbus 寄存器',
          )) {
            try {
              final RtuFramer framer;
              if (snapshot.kind == ConnectionKind.udp) {
                framer = RtuFramer();
              } else {
                if (!_framers.containsKey(event.endpoint) &&
                    _framers.length >= 32) {
                  _framers.remove(_framers.keys.first);
                }
                framer = _framers[event.endpoint] ??= RtuFramer();
              }
              final frames = framer.add(event.bytes);
              for (final frame in frames) {
                waveform.receive(entry, rtuFrame: frame);
              }
            } catch (e) {
              system('$e');
            }
          } else {
            _framers.clear();
          }
        }
        if (event.message.isNotEmpty) system(event.message);
        if (event.closed) unawaited(_lost(generation, event.message));
        enforceBudget?.call();
        scheduleNotify();
      }, onError: (Object e) => unawaited(_lost(generation, '$e')));
      config.port = snapshot.port;
      reconnecting = false;
      succeeded = true;
      state = snapshot.kind == ConnectionKind.tcpServer
          ? '正在监听'
          : snapshot.kind == ConnectionKind.udp
          ? '已绑定'
          : '已连接';
      system('$state · ${opened.localEndpoint}');
    } catch (e) {
      if (generation == _generation && !_disposed) {
        error = e.toString();
        state = '连接失败';
        system(error);
      }
    } finally {
      if (generation == _generation && !_disposed) {
        busy = false;
        if (!succeeded) {
          if (retry) {
            _scheduleReconnect();
          } else {
            _wantReconnect = false;
          }
        }
        notifyListeners();
      }
    }
  }

  Future<void> _lost(int generation, String reason) async {
    if (_disposed || generation != _generation) return;
    final token = ++_generation;
    stop(reason: reason.isEmpty ? '连接中断' : reason);
    _waveWatch?.cancel();
    final old = transport;
    transport = null;
    final sub = _subscription;
    _subscription = null;
    busy = false;
    state = reason.isEmpty ? '连接中断' : reason;
    serialStatus = const SerialStatus();
    _framers.clear();
    waveform.boundary();
    selectedPeer = '';
    // Reserve the retry state before awaiting close, so parameter edits stay locked.
    reconnecting = _wantReconnect;
    notifyListeners();
    await sub?.cancel();
    await old?.close();
    if (_disposed || token != _generation) return;
    reconnectAttempt = 0;
    if (_wantReconnect) _scheduleReconnect();
    notifyListeners();
  }

  void _scheduleReconnect() {
    if (!_wantReconnect || _disposed) return;
    final snapshot = _reconnectConfig!;
    if (_device == null || _device!.identity.isEmpty) {
      _wantReconnect = reconnecting = false;
      error = '设备缺少唯一标识，请重新选择串口后连接';
      state = '重连已停止';
      system(error);
      return;
    }
    if (reconnectAttempt >= snapshot.reconnectMaxAttempts.clamp(1, 1000)) {
      _wantReconnect = reconnecting = false;
      state = '重连次数已用完';
      system(state);
      return;
    }
    reconnecting = true;
    state = '等待重连 · $reconnectAttempt / ${snapshot.reconnectMaxAttempts}';
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(
      Duration(milliseconds: snapshot.reconnectIntervalMs.clamp(100, 3600000)),
      () async {
        if (!_wantReconnect || _disposed) return;
        reconnectAttempt++;
        try {
          final matches = (await _scanPorts())
              .where((p) => p.identity == _device!.identity)
              .toList();
          if (!_wantReconnect || _disposed) return;
          if (matches.length != 1) {
            error = matches.isEmpty ? '等待原设备接入' : '设备标识不唯一，请手动选择';
            _scheduleReconnect();
            notifyListeners();
            return;
          }
          final retryConfig = snapshot.copy()..port = matches.single.path;
          await _open(retryConfig, retry: true);
        } catch (e) {
          error = '$e';
          _scheduleReconnect();
          notifyListeners();
        }
      },
    );
  }

  Future<void> disconnect({String reason = '已断开'}) async {
    _wantReconnect = reconnecting = false;
    _reconnectTimer?.cancel();
    ++_generation;
    stop();
    busy = false;
    _waveWatch?.cancel();
    final old = transport;
    transport = null;
    final sub = _subscription;
    _subscription = null;
    state = reason.isEmpty ? '已断开' : reason;
    serialStatus = const SerialStatus();
    _framers.clear();
    waveform.boundary();
    selectedPeer = '';
    notifyListeners();
    await sub?.cancel();
    await old?.close();
    if (!_disposed) system('连接已关闭');
  }

  Future<void> setControlLines({bool? dtr, bool? rts}) async {
    _acceptNewAction();
    final opened = transport;
    if (!connected || opened is! SerialControl || controlBusy) return;
    if (rts != null && config.flowControl == 'RTS/CTS') {
      controlError = 'RTS 由硬件流控管理';
      notifyListeners();
      return;
    }
    final generation = _generation;
    controlBusy = true;
    controlError = '';
    notifyListeners();
    try {
      await (opened as SerialControl).setControlLines(dtr: dtr, rts: rts);
      if (generation != _generation || _disposed) return;
      if (dtr != null) config.dtr = dtr;
      if (rts != null) config.rts = rts;
      serialStatus = (opened as SerialControl).serialStatus;
      system('${dtr != null ? 'DTR' : 'RTS'} → ${(dtr ?? rts)! ? '高' : '低'}');
    } catch (e) {
      if (generation == _generation) controlError = '控制线设置失败：$e';
    } finally {
      controlBusy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> send(
    Draft input, {
    bool remember = false,
    bool fromTask = false,
  }) async {
    _acceptNewAction();
    if (running && !fromTask) throw StateError("当前正在执行任务，请先停止");
    final snapshot = input.copy(), bytes = snapshot.build();
    final targets = freezeTargets();
    var record = HistoryRecord(
      kind: 'send',
      sessionId: id,
      runtimeId: runtimeId,
      sessionName: config.name,
      name: '单条发送',
      targets: _historyTargets(targets),
      draft: snapshot,
      finalBytes: bytes,
    );
    final watch = Stopwatch()..start();
    var submitted = 0;
    final logIds = <String>[];
    if (!fromTask) _recordHistory(record);
    try {
      await _sendBytes(
        bytes,
        fromTask: fromTask,
        frozenTargets: targets,
        onSubmitted: (entry) {
          submitted += entry.bytes.length;
          if (logIds.length < 64) logIds.add(entry.id);
        },
      );
      record = record.update({'status': 'submitted'});
    } catch (e) {
      record = record.update({'status': 'failed', 'error': '$e'});
      rethrow;
    } finally {
      if (!fromTask) {
        _recordHistory(
          record.update({
            'submittedBytes': submitted,
            'submittedLogIds': logIds,
            'elapsedMs': watch.elapsedMilliseconds,
          }),
        );
      }
    }
  }

  Future<void> _sendBytes(
    Uint8List input, {
    bool fromTask = false,
    void Function()? beforeWrite,
    void Function(LogEntry)? onSubmitted,
    List<String?>? frozenTargets,
  }) async {
    if (running && !fromTask) throw StateError('当前正在执行任务，请先停止');
    final bytes = Uint8List.fromList(input);
    final targets = List<String?>.of(frozenTargets ?? freezeTargets());
    final generation = _generation, taskGeneration = _taskGeneration;
    final transportSnapshot = transport!;
    if (_queued >= 1000) throw StateError('发送队列已满（1000）');
    _queued++;
    final done = Completer<void>();
    _queue = _queue.catchError((Object _) {}).then((_) async {
      try {
        if (_generation != generation ||
            _taskGeneration != taskGeneration ||
            !identical(transport, transportSnapshot)) {
          throw StateError('任务已取消或连接实例已改变');
        }
        for (final target in targets) {
          if (_taskGeneration != taskGeneration) throw StateError('任务已停止');
          final endpoint = config.kind == ConnectionKind.tcpServer
              ? transportSnapshot.peers
                        .where((p) => p.id == target)
                        .firstOrNull
                        ?.endpoint ??
                    target ??
                    ''
              : target ?? config.summary;
          waveform.recordRequest(
            bytes,
            config.kind == ConnectionKind.serial
                ? config.port
                : config.kind == ConnectionKind.tcpClient
                ? ''
                : endpoint,
          );
          try {
            beforeWrite?.call();
            await transportSnapshot.send(bytes, target: target);
          } catch (e) {
            if (config.kind == ConnectionKind.serial) {
              unawaited(_lost(generation, '$e'));
            }
            rethrow;
          }
          tx += bytes.length;

          final entry = LogEntry('TX', bytes, endpoint: endpoint);
          addLog(entry);
          onSubmitted?.call(entry);
        }
        done.complete();
      } catch (e, stack) {
        done.completeError(e, stack);
      } finally {
        _queued--;
        scheduleNotify();
      }
    });
    return done.future;
  }

  Future<void> sendFile(
    Stream<List<int>> input, {
    required int length,
    required String name,
    int chunkSize = 256,
    int delayMs = 20,
  }) async {
    _acceptNewAction();
    if (running) throw StateError('请先停止当前任务');
    if (length < 1 || chunkSize < 1 || chunkSize > 65507 || delayMs < 0) {
      throw const FormatException('文件长度、分块大小或间隔无效');
    }
    final targets = freezeTargets();
    if (targets.length != 1) throw StateError('文件发送请选择单个目标');
    final generation = _generation, token = ++_taskGeneration;
    _stopSignal = Completer<void>();
    final signal = _stopSignal;
    final iterator = StreamIterator<List<int>>(input);
    running = fileSending = true;
    fileName = name;
    fileSent = 0;
    fileSize = length;
    error = '';
    task = '文件发送 · $name';
    final historyRun = _HistoryRun(
      HistoryRecord(
        kind: 'file',
        sessionId: id,
        runtimeId: runtimeId,
        sessionName: config.name,
        name: name,
        targets: _historyTargets(targets),
        file: {
          'name': name,
          'length': length,
          'chunkSize': chunkSize,
          'delayMs': delayMs,
        },
      ),
    );
    _historyRun = historyRun;
    _recordHistory(historyRun.record);
    var historyAt = 0, submittedFile = 0;
    String historyStatus = 'submitted', historyFailure = '';
    notifyListeners();
    try {
      while (await _cancellable(iterator.moveNext(), signal, null)) {
        final data = iterator.current;
        for (var offset = 0; offset < data.length; offset += chunkSize) {
          if (token != _taskGeneration || generation != _generation) {
            historyStatus = historyRun.cancelStatus;
            return;
          }
          if (!listEquals(targets, freezeTargets())) {
            throw StateError('发送目标已变化');
          }
          final end = (offset + chunkSize).clamp(0, data.length);
          if (submittedFile + end - offset > length) {
            throw StateError('文件长度发生变化');
          }
          await _sendBytes(
            Uint8List.fromList(data.sublist(offset, end)),
            fromTask: true,
            frozenTargets: targets,
          );
          submittedFile += end - offset;
          if (token == _taskGeneration) {
            fileSent = submittedFile;
            task = '文件发送 · $fileSent / $fileSize B';
            scheduleNotify();
          }
          if (historyRun.watch.elapsedMilliseconds - historyAt >= 500) {
            historyAt = historyRun.watch.elapsedMilliseconds;
            _updateTaskHistory(historyRun, {
              'status': token == _taskGeneration
                  ? 'submitting'
                  : historyRun.cancelStatus,
              'submittedBytes': submittedFile,
            });
          }
          if (delayMs > 0) {
            await _cancellable(
              Future<void>.delayed(Duration(milliseconds: delayMs)),
              signal,
              null,
            );
          }
        }
      }
      if (submittedFile != length) throw StateError('文件长度发生变化');
      if (token == _taskGeneration) {
        task = '文件发送完成 · $submittedFile B';
        system('$name · $task');
      }
    } catch (e) {
      historyStatus = token == _taskGeneration
          ? 'failed'
          : historyRun.cancelStatus;
      historyFailure = '$e';
      if (token == _taskGeneration && !_disposed) {
        error = '$e';
        task = '文件发送失败';
        system(error);
      }
    } finally {
      if (token != _taskGeneration) {
        historyStatus = historyRun.cancelStatus;
        if (historyFailure.isEmpty) historyFailure = historyRun.cancelError;
      }
      _updateTaskHistory(historyRun, {
        'status': historyStatus,
        'error': historyFailure,
        'submittedBytes': submittedFile,
      });
      if (identical(_historyRun, historyRun)) _historyRun = null;
      await iterator.cancel();
      if (token == _taskGeneration) {
        running = fileSending = false;
      }
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> execute(
    List<SavedCommand> commands, {
    bool repeat = false,
    Map<String, Map<String, String>> parameterValues = const {},
  }) async {
    _acceptNewAction();
    if (running || commands.isEmpty) return;
    final autoWait = waitResponse, cycleMs = periodMs;
    // Resolve values and checksums once, before scheduling the first write.
    final snapshots = commands
        .map((c) {
          final command = SavedCommand.fromJson(c.toJson());
          final values = <String, String>{
            for (final p in command.parameters) p.name: p.defaultValue,
            ...?parameterValues[c.id],
          };
          final resolvedDraft = command.buildDraft(values);
          final bytes = resolvedDraft.build();
          final rule =
              command.responseRule ??
              (autoWait &&
                      bytes.length >= 8 &&
                      validRequest(bytes) &&
                      bytes[0] != 0
                  ? const ResponseRule()
                  : const ResponseRule(kind: 'none'));
          if (rule.kind != 'none') ResponseMatcher(rule, bytes);
          return (
            command: command,
            bytes: bytes,
            rule: rule,
            draft: resolvedDraft,
            values: values,
          );
        })
        .toList(growable: false);
    final targets = freezeTargets();
    // Freeze destination configuration for the complete run.
    final peer = selectedPeer,
        host = config.targetHost,
        port = config.targetPort;
    final kind = config.kind;
    final expectsAnyReply = snapshots.any(
      (s) =>
          s.rule.kind != 'none' &&
          !(s.rule.kind == 'modbus_rtu' && s.bytes[0] == 0),
    );
    for (final snapshot in snapshots) {
      final needsReply =
          snapshot.rule.kind != 'none' &&
          !(snapshot.rule.kind == 'modbus_rtu' && snapshot.bytes[0] == 0);
      if (needsReply && targets.length != 1) {
        throw StateError('等待响应时请选择单个目标');
      }
      if (needsReply &&
          snapshot.rule.framing == 'datagram' &&
          kind != ConnectionKind.udp) {
        throw const FormatException('数据报分帧仅适用于 UDP');
      }
    }
    final generation = _generation, token = ++_taskGeneration;
    final transportSnapshot = transport!;
    final resolveTimeout = Duration(milliseconds: config.timeoutMs);
    _stopSignal = Completer<void>();
    final signal = _stopSignal;
    running = true;
    error = '';
    final taskId = newId();
    final historyRun = _HistoryRun(
      HistoryRecord(
        id: taskId,
        kind: 'task',
        taskId: taskId,
        sessionId: id,
        runtimeId: runtimeId,
        sessionName: config.name,
        name: snapshots.length == 1
            ? snapshots.first.command.name
            : '${snapshots.length} 条命令',
        targets: _historyTargets(targets),
        periodMs: repeat ? cycleMs : 0,
      ),
    );
    _historyRun = historyRun;
    _recordHistory(historyRun.record);
    var cycle = 0, completedSteps = 0, startedSteps = 0, submittedTotal = 0;
    String historyStatus = 'submitted', historyFailure = '';
    notifyListeners();
    try {
      var writeTargets = List<String?>.of(targets);
      if (kind == ConnectionKind.udp &&
          transportSnapshot is DatagramTargetResolver) {
        final resolved = await _cancellable(
          (transportSnapshot as DatagramTargetResolver).resolveDatagramTarget(
            targets.single!,
          ),
          signal,
          resolveTimeout,
        );
        if (generation != _generation || token != _taskGeneration) return;
        writeTargets = [resolved];
      }
      do {
        cycle++;
        final watch = Stopwatch()..start();
        for (var i = 0; i < snapshots.length; i++) {
          if (token != _taskGeneration || generation != _generation) {
            historyStatus = historyRun.cancelStatus;
            return;
          }
          if (peer != selectedPeer ||
              host != config.targetHost ||
              port != config.targetPort ||
              !listEquals(targets, freezeTargets())) {
            throw StateError('发送目标发生变化，任务已停止');
          }
          final snapshot = snapshots[i];
          final command = snapshot.command, bytes = snapshot.bytes;
          startedSteps++;
          var stepRecord = HistoryRecord(
            kind: 'step',
            taskId: taskId,
            sessionId: id,
            runtimeId: runtimeId,
            sessionName: config.name,
            name: command.name,
            targets: _historyTargets(writeTargets),
            draft: snapshot.draft,
            finalBytes: bytes,
            commandId: command.id,
            revision: command.revision,
            parameters: snapshot.values,
            responseRule: snapshot.rule.toJson(),
            timeoutMs: command.timeoutMs,
            periodMs: repeat ? cycleMs : 0,
            stepDelayMs: command.stepDelayMs,
            stepIndex: i + 1,
            cycle: cycle,
          );
          historyRun.step = stepRecord;
          _recordHistory(stepRecord);
          final stepWatch = Stopwatch()..start();
          var stepSubmitted = 0;
          final stepLogIds = <String>[];
          String responseLogId = '';
          ResponseMatch? responseMatch;
          String stepStatus = 'submitted', stepError = '';
          var stepFinalized = false;
          task = '${i + 1}/${snapshots.length} · ${command.name}';
          notifyListeners();
          final needsReply =
              snapshot.rule.kind != 'none' &&
              !(snapshot.rule.kind == 'modbus_rtu' && bytes[0] == 0);
          if (needsReply && targets.length != 1) {
            throw StateError('等待响应时请选择单个目标');
          }
          if (needsReply &&
              snapshot.rule.framing == 'datagram' &&
              kind != ConnectionKind.udp) {
            throw const FormatException('数据报分帧仅适用于 UDP');
          }
          final reply = Completer<({ResponseMatch? match, Object? error})>();
          void Function(TransportEvent)? receive;
          if (needsReply) {
            final matcher = ResponseMatcher(snapshot.rule, bytes);
            receive = (event) {
              if (generation != _generation ||
                  token != _taskGeneration ||
                  reply.isCompleted) {
                return;
              }
              if ((kind == ConnectionKind.tcpServer ||
                      kind == ConnectionKind.udp) &&
                  event.endpoint != writeTargets.first) {
                return;
              }
              try {
                final match = matcher.add(
                  event.bytes,
                  datagram: kind == ConnectionKind.udp,
                );
                if (match != null) {
                  responseLogId = _responseLogId;
                  reply.complete((match: match, error: null));
                }
              } catch (e) {
                reply.complete((match: null, error: e));
              }
            };
          }
          try {
            await _cancellable(
              _sendBytes(
                bytes,
                fromTask: true,
                frozenTargets: writeTargets,
                beforeWrite: needsReply
                    ? () => _responseReceiver = receive
                    : null,
                onSubmitted: (entry) {
                  stepSubmitted += entry.bytes.length;
                  submittedTotal += entry.bytes.length;
                  if (stepLogIds.length < 64) stepLogIds.add(entry.id);
                  if (stepFinalized) {
                    stepRecord = stepRecord.update({
                      'submittedBytes': stepSubmitted,
                      'submittedLogIds': stepLogIds,
                    });
                    _recordHistory(stepRecord);
                    _updateTaskHistory(historyRun, {
                      'submittedBytes': submittedTotal,
                    });
                  }
                },
              ),
              signal,
              null,
            );
            if (needsReply) {
              task = '等待响应 · ${command.name}';
              stepRecord = stepRecord.update({
                'status': 'waiting',
                'submittedBytes': stepSubmitted,
                'submittedLogIds': stepLogIds,
              });
              historyRun.step = stepRecord;
              _recordHistory(stepRecord);
              notifyListeners();
              final response = await _cancellable(
                reply.future,
                signal,
                Duration(milliseconds: command.timeoutMs),
              );
              if (response.error != null) throw response.error!;
              responseMatch = response.match;
              if (response.match!.exceptionCode != null) {
                stepStatus = 'device_exception';
                final description = snapshot.rule.allowException
                    ? '设备异常'
                    : '设备返回未允许的异常响应';
                throw StateError(
                  '$description：${response.match!.exceptionCode}',
                );
              }
              stepStatus = 'response';
            }
            completedSteps++;
          } catch (e) {
            if (stepStatus != 'device_exception') {
              stepStatus = token != _taskGeneration
                  ? historyRun.cancelStatus
                  : e is TimeoutException
                  ? 'timeout'
                  : 'failed';
            }
            stepError = historyRun.cancelError.isEmpty
                ? '$e'
                : historyRun.cancelError;
            historyStatus = stepStatus;
            rethrow;
          } finally {
            if (token != _taskGeneration) stepStatus = historyRun.cancelStatus;
            stepRecord = stepRecord.update({
              'status': stepStatus,
              'error': stepError,
              'submittedBytes': stepSubmitted,
              'submittedLogIds': stepLogIds,
              'responseBytes': responseMatch?.bytes ?? <int>[],
              'responseLength': responseMatch?.bytes.length ?? 0,
              'responseLogId': responseLogId,
              'elapsedMs': stepWatch.elapsedMilliseconds,
            });
            stepFinalized = true;
            _recordHistory(stepRecord);
            historyRun.step = null;
            _updateTaskHistory(historyRun, {
              'status': 'submitting',
              'stepsStarted': startedSteps,
              'stepsCompleted': completedSteps,
              'submittedBytes': submittedTotal,
              'cycle': cycle,
            });
            if (identical(_responseReceiver, receive)) _responseReceiver = null;
          }
          if (i < snapshots.length - 1) {
            await _cancellable(
              Future<void>.delayed(Duration(milliseconds: command.stepDelayMs)),
              signal,
              null,
            );
          }
        }
        if (repeat && token == _taskGeneration) {
          final remaining = cycleMs - watch.elapsedMilliseconds;
          if (remaining > 0) {
            await _cancellable(
              Future<void>.delayed(Duration(milliseconds: remaining)),
              signal,
              null,
            );
          }
        }
      } while (repeat && token == _taskGeneration && generation == _generation);
      historyStatus = expectsAnyReply ? 'response' : 'submitted';
      if (token == _taskGeneration) task = expectsAnyReply ? '执行完成' : '字节已提交';
    } catch (e) {
      historyFailure = '$e';
      if (historyStatus == 'submitted') {
        historyStatus = token != _taskGeneration
            ? historyRun.cancelStatus
            : e is TimeoutException
            ? 'timeout'
            : 'failed';
      }
      if (token == _taskGeneration) {
        error = e is TimeoutException ? '等待匹配响应超时，已停止' : e.toString();
        task = '执行停止';
        system(error);
      }
    } finally {
      if (token != _taskGeneration) {
        historyStatus = historyRun.cancelStatus;
        if (historyFailure.isEmpty) historyFailure = historyRun.cancelError;
      }
      _updateTaskHistory(historyRun, {
        'status': historyStatus,
        'error': historyFailure,
        'stepsStarted': startedSteps,
        'stepsCompleted': completedSteps,
        'submittedBytes': submittedTotal,
        'cycle': cycle,
      });
      if (identical(_historyRun, historyRun)) _historyRun = null;
      if (!signal.isCompleted) signal.complete();
      if (token == _taskGeneration && !_disposed) {
        running = false;
        notifyListeners();
      }
    }
  }

  Future<T> _cancellable<T>(
    Future<T> work,
    Completer<void> signal,
    Duration? timeout,
  ) async {
    final result = Completer<T>();
    Timer? timer;
    if (timeout != null) {
      timer = Timer(timeout, () {
        if (!result.isCompleted) {
          result.completeError(TimeoutException('等待匹配响应超时'));
        }
      });
    }
    work.then(
      (value) {
        if (!result.isCompleted) result.complete(value);
      },
      onError: (Object e, StackTrace stack) {
        if (!result.isCompleted) result.completeError(e, stack);
      },
    );
    signal.future.then((_) {
      if (!result.isCompleted) result.completeError(StateError('任务已停止'));
    });
    try {
      return await result.future;
    } finally {
      timer?.cancel();
    }
  }

  bool validRequest(List<int> bytes) {
    try {
      if (bytes.length < 8 ||
          bytes[0] > 247 ||
          ![1, 2, 3, 4, 5, 6, 15, 16].contains(bytes[1])) {
        return false;
      }
      parseRtu(bytes);
      return true;
    } catch (_) {
      return false;
    }
  }

  void stop({String reason = ''}) {
    final run = _historyRun;
    if (run != null && reason.isNotEmpty) {
      run.cancelStatus = 'failed';
      run.cancelError = reason;
    }
    if (run != null) {
      if (run.step != null) {
        run.step = run.step!.update({
          'status': run.cancelStatus,
          'error': run.cancelError,
        });
        _recordHistory(run.step!);
      }
      _updateTaskHistory(run, {
        'status': run.cancelStatus,
        'error': run.cancelError,
      });
    }
    if (!_stopSignal.isCompleted) _stopSignal.complete();
    final pendingWrites = transport;
    if (pendingWrites is PendingWriteCancellation) {
      (pendingWrites as PendingWriteCancellation).cancelPendingWrites();
    }
    ++_taskGeneration;
    _responseReceiver = null;
    running = fileSending = false;
    task = '已停止';
    notifyListeners();
  }

  void clearLogs() {
    logs.clear();
    rawBytes = 0;
    dropped = 0;
    notifyListeners();
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'config': config.toJson(),
    'draft': draft.toJson(),
    'commandsMode': commandsMode,
    'waveMappings': waveform.channels.map((c) => c.mapping.toJson()).toList(),
  };
  @override
  void dispose() {
    if (_historyRun != null) {
      final run = _historyRun!;
      if (run.step != null) {
        _recordHistory(run.step!.update({'status': 'stopped'}));
      }
      _updateTaskHistory(run, {'status': 'stopped'});
    }
    _disposed = true;
    _waveWatch?.cancel();
    _wantReconnect = false;
    _reconnectTimer?.cancel();
    ++_generation;
    ++_taskGeneration;
    if (!_stopSignal.isCompleted) _stopSignal.complete();
    _notification?.cancel();
    _subscription?.cancel();
    transport?.close();
    recorder.stop();
    _responseReceiver = null;
    super.dispose();
  }
}

class _HistoryRun {
  HistoryRecord record;
  HistoryRecord? step;
  String cancelStatus = 'stopped', cancelError = '';
  final watch = Stopwatch()..start();
  _HistoryRun(this.record);
}
