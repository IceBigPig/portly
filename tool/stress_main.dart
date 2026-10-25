// Dedicated release-only stress runner. Never opens the user's configuration.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:window_manager/window_manager.dart';

import 'package:portly/main.dart' show PortlyApp;
import 'package:portly/core/models.dart';
import 'package:portly/core/wave.dart';
import 'package:portly/core/library_import.dart';
import 'package:portly/platform/storage.dart';
import 'package:portly/state/app_model.dart';
import 'package:portly/state/session.dart';
import 'package:portly/ui/send_panel.dart';
import 'package:portly/ui/theme.dart' show Pick;

const durationSeconds = int.fromEnvironment('STRESS_SECONDS', defaultValue: 60);
const runDirectory = String.fromEnvironment(
  'STRESS_DIRECTORY',
  defaultValue: '/tmp/portly-stress',
);
const udpBasePort = int.fromEnvironment('STRESS_PORT', defaultValue: 28710);
const runLabel = String.fromEnvironment(
  'STRESS_LABEL',
  defaultValue: 'calibration',
);

class _Histogram {
  static const resolution = 50;
  final buckets = List<int>.filled(20001, 0);
  int count = 0, maximum = 0;
  void add(int microseconds) {
    count++;
    if (microseconds > maximum) maximum = microseconds;
    buckets[(microseconds ~/ resolution).clamp(0, buckets.length - 1)]++;
  }

  int percentile(double fraction) {
    final target = (count * fraction).ceil();
    var accumulated = 0;
    for (var i = 0; i < buckets.length; i++) {
      accumulated += buckets[i];
      if (accumulated >= target) return (i + 1) * resolution;
    }
    return maximum;
  }

  Map<String, dynamic> summary() => {
    'n': count,
    'bucket_us': resolution,
    'p50_us': count == 0 ? 0 : percentile(.5),
    'p95_us': count == 0 ? 0 : percentile(.95),
    'max_us': maximum,
  };
}

String _libraryFixture(String id) {
  final groups = {
    for (var i = 0; i < 100; i++)
      i == 0 ? 'default' : 'pressure-group-$i': '压力组 $i',
  };
  final commands = List<SavedCommand>.generate(
    5000,
    (i) => SavedCommand(
      id: i == 0 ? id : 'pressure-command-$i',
      groupId: i % 100 == 0 ? 'default' : 'pressure-group-${i % 100}',
      name: '压力命令 ${i.toString().padLeft(4, '0')}',
      draft: Draft(body: '50 54 45 58'),
      responseRule: const ResponseRule(kind: 'none'),
      stepDelayMs: 10,
    ),
  );
  return exportCommandLibrary(
    LibrarySnapshot.capture(groups: groups, commands: commands),
  );
}

LibraryImportPlan _overwritePlan(LibraryImportPreview preview) =>
    preview.buildPlan(
      choices: {
        for (final conflict in preview.conflicts)
          conflict.key: ImportChoice.overwrite,
      },
    );
int _exportedCommandCount(String content) =>
    (jsonDecode(content) as Map)['commands'].length as int;

Future<SavedCommand> _exerciseLibrary(
  AppModel model,
  String fixtureId,
  void Function(Map<String, dynamic>) emit,
  Map<String, dynamic> Function(List<int>) latency,
) async {
  // Exercise the real library pipeline while RX, logging and drawing continue.

  final fixture = await compute(_libraryFixture, fixtureId);
  var libraryWatch = Stopwatch()..start();
  final preview = await model.previewLibraryImport(fixture);
  final previewUs = libraryWatch.elapsedMicroseconds;
  if (!preview.valid) {
    throw StateError(
      'Stress fixture import rejected: ${preview.issues.map((i) => i.reason).join(',')}',
    );
  }
  libraryWatch = Stopwatch()..start();
  final plan = await compute(_overwritePlan, preview);
  final planUs = libraryWatch.elapsedMicroseconds;
  libraryWatch = Stopwatch()..start();
  await model.applyLibraryImport(plan);
  final applyUs = libraryWatch.elapsedMicroseconds;
  final command = model.commands.firstWhere((c) => c.id == fixtureId);
  model.current.commandsMode = true;
  model.page = 0;
  model.refresh();
  await SchedulerBinding.instance.endOfFrame;
  final librarySearch = <int>[], libraryGroups = <int>[];
  for (var operation = 0; operation < 100; operation++) {
    EditableTextState? searchEditor;
    Pick<String>? groupPicker;
    void find(Element element) {
      if (element.widget is TextField &&
          (element.widget as TextField).decoration?.hintText == '搜索命令') {
        void editable(Element child) {
          if (child is StatefulElement && child.state is EditableTextState) {
            searchEditor = child.state as EditableTextState;
          }
          child.visitChildren(editable);
        }

        element.visitChildren(editable);
      }
      if (element.widget is Pick<String>) {
        final picker = element.widget as Pick<String>;
        if (picker.options.length == 100 &&
            picker.options.containsKey('pressure-group-99')) {
          groupPicker = picker;
        }
      }
      element.visitChildren(find);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(find);
    if (searchEditor == null || groupPicker == null) {
      emit({'event': 'library_ui_target_missing'});
      break;
    }
    final value = operation % 2 == 0
        ? '压力命令 ${operation.toString().padLeft(4, '0')}'
        : '';
    libraryWatch = Stopwatch()..start();
    searchEditor!.userUpdateTextEditingValue(
      TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      ),
      SelectionChangedCause.keyboard,
    );
    await SchedulerBinding.instance.endOfFrame;
    librarySearch.add(libraryWatch.elapsedMicroseconds);
    libraryWatch = Stopwatch()..start();
    groupPicker!.onChanged?.call(
      operation == 0 ? 'default' : 'pressure-group-$operation',
    );
    await SchedulerBinding.instance.endOfFrame;
    libraryGroups.add(libraryWatch.elapsedMicroseconds);
  }
  libraryWatch = Stopwatch()..start();
  final exported = await model.exportLibraryAsync();
  final exportUs = libraryWatch.elapsedMicroseconds;
  final exportedCount = await compute(_exportedCommandCount, exported);
  emit({
    'event': 'library_verification',
    'commands': model.commands.length,
    'groups': model.groups.length,
    'preview_us': previewUs,
    'plan_us': planUs,
    'apply_us': applyUs,
    'export_us': exportUs,
    'export_bytes': utf8.encode(exported).length,
    'exported_commands': exportedCount,
    'search_latency': latency(librarySearch),
    'group_latency': latency(libraryGroups),
  });
  model.current.commandsMode = false;
  model.refresh();
  await SchedulerBinding.instance.endOfFrame;
  return command;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kReleaseMode) throw StateError('Stress runner requires --release.');
  final directory = Directory(runDirectory)..createSync(recursive: true);
  final evidence = File('${directory.path}/events.jsonl').openWrite();
  var failureCount = 0;
  const failures = {
    'flutter_error',
    'uncaught_error',
    'action_error',
    'action_overlap',
    'input_not_committed',
    'input_target_missing',
    'pause_target_missing',
    'ui_stall',
    'recorder_error',
    'search_verification_error',
    'history_verification_error',
    'library_ui_target_missing',
    'background_query_error',
    'shutdown_error',
    'external_interference',
  };
  void emit(Map<String, dynamic> event) {
    if (failures.contains(event['event'])) failureCount++;
    evidence.writeln(
      jsonEncode({'at': DateTime.now().toUtc().toIso8601String(), ...event}),
    );
  }

  final watchdog = Timer(Duration(seconds: durationSeconds + 180), () async {
    emit({'event': 'watchdog_timeout'});
    await evidence.flush();
    exit(5);
  });
  FlutterError.onError = (details) {
    emit({
      'event': 'flutter_error',
      'error': details.exceptionAsString(),
      'stack': '${details.stack}',
    });
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    emit({'event': 'uncaught_error', 'error': '$error', 'stack': '$stack'});
    return true;
  };
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      size: const Size(1440, 900),
      minimumSize: const Size(900, 600),
      title: 'Portly · Release 压力测试 · 0/${(durationSeconds / 60).ceil()} min',
    ),
    () async {
      await windowManager.show();
    },
  );
  await windowManager.setClosable(false);
  final model = AppModel();
  await model.initialize(storagePath: '${directory.path}/config.sqlite');
  for (final old in model.sessions.toList()) {
    old.dispose();
  }
  model.sessions.clear();
  final sessions = <Session>[];
  for (var i = 0; i < 8; i++) {
    final session = model.newSession(ConnectionKind.udp, name: '压力 ${i + 1}');
    session.config
      ..bindAddress = '127.0.0.1'
      ..networkPort = udpBasePort + i
      ..targetHost = '127.0.0.1';
    sessions.add(session);
  }
  // Eight channels on one source, with every raw UDP packet retained as one event.
  for (var i = 0; i < 8; i++) {
    sessions.first.waveform.upsert(
      WaveMapping(
        name: 'CH${i + 1}',
        mode: '固定字节偏移',
        offset: 24 + i * 2,
        frameLength: 128,
        type: 'uint16',
        gapMs: 0,
        color: waveColors[i],
      ),
    );
  }
  model.waveSourceId = sessions.first.id;
  model.currentId = sessions.first.id;
  final frames = _Histogram(),
      buildTimes = _Histogram(),
      rasterTimes = _Histogram(),
      eventLoopDelays = _Histogram();
  SchedulerBinding.instance.addTimingsCallback((values) {
    for (final frame in values) {
      frames.add(frame.totalSpan.inMicroseconds);
      buildTimes.add(frame.buildDuration.inMicroseconds);
      rasterTimes.add(frame.rasterDuration.inMicroseconds);
    }
  });
  // Protect the isolated instrument from accidental human tab/keyboard input.
  // The workload below still invokes the production controls' real callbacks
  // and EditableTextState and awaits their actual frames.
  runApp(
    IgnorePointer(
      child: ExcludeFocus(child: PortlyApp(model: model)),
    ),
  );
  await SchedulerBinding.instance.endOfFrame;
  final sourceReplies = ReceivePort();
  final sourceReady = Completer<SendPort>();
  final acknowledgments = <int, Completer<void>>{};
  Map<String, dynamic> sourceStats = {};
  var controlId = 0;
  sourceReplies.listen((dynamic message) {
    final event = Map<String, dynamic>.from(message as Map);
    if (event['event'] == 'ready') {
      sourceReady.complete(event['control'] as SendPort);
      for (var i = 0; i < 8; i++) {
        sessions[i].config.targetPort = (event['ports'] as List)[i] as int;
      }
    } else if (event['event'] == 'ack') {
      acknowledgments.remove(event['id'])?.complete();
    } else if (event['event'] == 'source_stats') {
      sourceStats = event;
      emit(event);
    } else {
      emit(event);
    }
  });
  final source = await Isolate.spawn(_sourceMain, {
    'reply': sourceReplies.sendPort,
    'basePort': udpBasePort,
  });
  final control = await sourceReady.future;
  Future<void> sourceCommand(String operation, [int index = -1]) async {
    final id = ++controlId, done = Completer<void>();
    acknowledgments[id] = done;
    control.send({'id': id, 'operation': operation, 'index': index});
    await done.future.timeout(const Duration(seconds: 10));
  }

  var expectedShutdown = false, externalInterference = false;
  final expectedSessionIds = sessions.map((s) => s.id).toSet();
  void verifySessionSet() {
    if (expectedShutdown || externalInterference) return;
    final actualIds = model.sessions.map((s) => s.id).toSet();
    if (model.closing) {
      // A deliberate Cmd-Q/Dock Quit retains the production shutdown path.
      // Mark the run incomplete and stop load; never prevent the user's Quit.
      externalInterference = true;
      emit({'event': 'external_exit_request'});
      unawaited(sourceCommand('stop').then((_) => evidence.flush()));
    } else if (!setEquals(expectedSessionIds, actualIds)) {
      externalInterference = true;
      emit({
        'event': 'external_interference',
        'reason': 'session_set_changed',
        'expected_session_ids': expectedSessionIds.toList(),
        'actual_session_ids': actualIds.toList(),
        'current_id': model.currentId,
      });
      unawaited(() async {
        await sourceCommand('stop');
        await evidence.flush();
        exit(6);
      }());
    }
  }

  model.addListener(verifySessionSet);

  final received = List<int>.filled(8, 0),
      gaps = List<int>.filled(8, 0),
      duplicates = List<int>.filled(8, 0),
      corrupt = List<int>.filled(8, 0),
      last = List<int>.filled(8, -1);
  final validationSubs = <StreamSubscription<dynamic>>[];
  Future<void> attach(int index) async {
    final session = sessions[index];
    await session.connect();
    if (!session.connected) {
      throw StateError('UDP open failed: ${session.error}');
    }
    validationSubs.add(
      session.transport!.events.listen((event) {
        final bytes = event.bytes;
        if (bytes.isEmpty) return;
        if (bytes.length != 128 ||
            bytes[0] != 0x50 ||
            bytes[1] != 0x54 ||
            bytes[4] != index) {
          corrupt[index]++;
          return;
        }
        for (var byte = 0; byte < 128; byte++) {
          if (byte >= 8 && byte < 16) {
            continue; // Monotonic sequence, checked below.
          }
          final expected = byte == 0
              ? 0x50
              : byte == 1
              ? 0x54
              : byte == 4
              ? index
              : ((byte * 17 + index * 29) & 255);
          if (bytes[byte] != expected) {
            corrupt[index]++;
            return;
          }
        }
        final seq = ByteData.sublistView(bytes).getUint64(8, Endian.big);
        if (last[index] >= 0) {
          if (seq <= last[index]) {
            duplicates[index]++;
          } else if (seq > last[index] + 1) {
            gaps[index] += seq - last[index] - 1;
          }
        }
        last[index] = seq;
        received[index]++;
      }),
    );
  }

  for (var i = 0; i < 8; i++) {
    await attach(i);
  }
  final options = LogRecordingOptions(
    directory: '${directory.path}/archive',
    baseName: 'pressure',
    fileLimitBytes: 256 * 1024 * 1024,
    maxFiles: 128,
    maxTotalBytes: 192 * 1024 * 1024 * 1024,
    maxQueueRecords: 10000,
    maxQueueBytes: 8 * 1024 * 1024,
  );
  final recorderErrors = <String>[];
  for (final session in sessions) {
    await session.recorder.start(
      (error) {
        recorderErrors.add(error);
        emit({
          'event': 'recorder_error',
          'session': session.id,
          'error': error,
        });
      },
      options: options,
      sessionId: session.id,
      sessionName: session.config.name,
      runtimeId: session.runtimeId,
    );
    if (!session.recorder.active) throw StateError('Recorder did not start');
  }
  final archive = LogArchive();
  await archive.usage(
    options.directory,
  ); // Retain one worker for lifetime transaction diagnostics.
  final searches = <int>[], historyReads = <int>[];
  final recordingStartSequences = sessions.fold(0, (n, s) => n + s.sequence);
  var command = SavedCommand(
    name: 'pressure-command',
    draft: Draft(body: '50 54 45 58'),
    responseRule: const ResponseRule(kind: 'none'),
    stepDelayMs: 10,
  );
  model.commands.add(command);
  model.changed();
  final switches = <int>[], inputs = <int>[], pauses = <int>[], pages = <int>[];
  final clock = Stopwatch()..start();
  int sum(Iterable<int> values) => values.fold(0, (a, b) => a + b);
  int percentile(List<int> values, double fraction) {
    if (values.isEmpty) return 0;
    final sorted = List<int>.of(values)..sort();
    return sorted[((sorted.length - 1) * fraction).ceil()];
  }

  Map<String, dynamic> latency(List<int> values) => {
    'n': values.length,
    'p50_us': percentile(values, .50),
    'p95_us': percentile(values, .95),
    'max_us': values.isEmpty ? 0 : values.reduce((a, b) => a > b ? a : b),
  };
  Map<String, dynamic> snapshot(String event) => {
    'event': event,
    'label': runLabel,
    'model_session_ids': model.sessions.map((s) => s.id).toList(),
    'current_session_id': model.currentId,
    'model_closing': model.closing,
    'elapsed_us': clock.elapsedMicroseconds,
    'received': received,
    'total_received': sum(received),
    'gaps': gaps,
    'duplicates': duplicates,
    'corrupt': corrupt,
    'source': sourceStats,
    'rx_bytes': sessions.map((s) => s.rx).toList(),
    'tx_bytes': sessions.map((s) => s.tx).toList(),
    'cache_records': sum(sessions.map((s) => s.logs.length)),
    'cache_bytes': sum(sessions.map((s) => s.rawBytes)),
    'cache_evicted': sum(sessions.map((s) => s.dropped)),
    'wave_samples': sum(
      sessions.expand((s) => s.waveform.channels).map((c) => c.samples.length),
    ),
    'wave_errors': sessions
        .expand((s) => s.waveform.channels)
        .where((c) => c.lastError.isNotEmpty)
        .map((c) => c.lastError)
        .toList(),
    'wave_values': sessions.first.waveform.channels
        .map((c) => c.samples.isEmpty ? null : c.samples.last.value)
        .toList(),
    'wave_evicted': sum(
      sessions.expand((s) => s.waveform.channels).map((c) => c.dropped),
    ),
    'recorders': sessions
        .map(
          (s) => {
            'active': s.recorder.active,
            'queued': s.recorder.status.queued,
            'records': s.recorder.status.records,
            'archive_bytes': s.recorder.status.bytes,
            'files': s.recorder.status.files,
            'error': s.recorder.status.error,
          },
        )
        .toList(),
    'recorder_errors': recorderErrors,
    'instrumentation_failures': failureCount,
    'rss_bytes': ProcessInfo.currentRss,
    'max_rss_bytes': ProcessInfo.maxRss,
    'switch_latency': latency(switches),
    'input_latency': latency(inputs),
    'pause_latency': latency(pauses),
    'page_latency': latency(pages),
    'archive_search_latency': latency(searches),
    'history_query_latency': latency(historyReads),
    'frame_total': frames.summary(),
    'frame_build': buildTimes.summary(),
    'frame_raster': rasterTimes.summary(),
    'event_loop_delay': eventLoopDelays.summary(),
    'active_tasks': sessions
        .where((s) => s.running || s.fileSending || s.busy || s.reconnecting)
        .length,
    'history_error': model.storage.historyError,
    'history_dropped': model.storage.historyDropped,
  };
  await model.flushPendingSave();
  emit({
    'event': 'start',
    'label': runLabel,
    'pid': pid,
    'duration_seconds': durationSeconds,
    'base_port': udpBasePort,
    'sessions': 8,
    'event_bytes': 128,
    'target_events_per_second': 2000,
    'flutter_release': kReleaseMode,
    'platform': Platform.operatingSystemVersion,
    'processors': Platform.numberOfProcessors,
    'options': options.toJson(),
    'config': model.storage.location,
  });
  await sourceCommand('start');
  var lastProbe = clock.elapsedMicroseconds;
  final responsivenessProbe = Timer.periodic(const Duration(milliseconds: 25), (
    _,
  ) {
    final now = clock.elapsedMicroseconds;
    final delay = now - lastProbe - 25000;
    lastProbe = now;
    eventLoopDelays.add(delay < 0 ? 0 : delay);
    if (delay > 1000000) emit({'event': 'ui_stall', 'delay_us': delay});
  });
  command = await _exerciseLibrary(model, command.id, emit, latency);
  Future<void>? backgroundQuery;
  var actionBusy = false, actionNumber = 0;
  final actions = Timer.periodic(const Duration(seconds: 2), (_) async {
    verifySessionSet();
    if (externalInterference) return;
    if (actionBusy) {
      emit({'event': 'action_overlap'});
      return;
    }
    actionBusy = true;
    try {
      actionNumber++;
      var watch = Stopwatch()..start();
      model.selectSession(sessions[actionNumber % 8].id);
      await SchedulerBinding.instance.endOfFrame;
      switches.add(watch.elapsedMicroseconds);
      if (actionNumber % 3 == 0) {
        model.page = 0;
        model.refresh();
        await SchedulerBinding.instance.endOfFrame;
        EditableTextState? editor;
        void findEditor(Element element) {
          if (element.widget is EditableText) {
            final editable = element.widget as EditableText;
            if (editable.maxLines == null || (editable.maxLines ?? 1) >= 2) {
              if (element is StatefulElement &&
                  element.state is EditableTextState) {
                editor = element.state as EditableTextState;
              }
            }
          }
          element.visitChildren(findEditor);
        }

        void walk(Element element) {
          if (element.widget is SendPanel &&
              (element.widget as SendPanel).session.id == model.currentId) {
            element.visitChildren(findEditor);
            return;
          }
          element.visitChildren(walk);
        }

        WidgetsBinding.instance.rootElement?.visitChildren(walk);
        final input = editor;
        if (input != null) {
          watch = Stopwatch()..start();
          final text =
              '50 54 ${actionNumber.toRadixString(16).padLeft(8, '0').replaceAllMapped(RegExp('..'), (m) => '${m[0]} ').trim()}';
          input.userUpdateTextEditingValue(
            TextEditingValue(
              text: text,
              selection: TextSelection.collapsed(offset: text.length),
            ),
            SelectionChangedCause.keyboard,
          );
          await SchedulerBinding.instance.endOfFrame;
          inputs.add(watch.elapsedMicroseconds);
          if (model.current.draft.body != text) {
            emit({'event': 'input_not_committed'});
          }
        } else {
          emit({'event': 'input_target_missing'});
        }
      }
      if (actionNumber % 5 == 0) {
        if (model.page != 0) {
          model.page = 0;
          model.refresh();
          await SchedulerBinding.instance.endOfFrame;
        }
        VoidCallback? pause;
        void find(Element element) {
          if (element.widget is IconButton) {
            final button = element.widget as IconButton;
            if ((button.tooltip ?? '').contains('暂停显示') ||
                (button.tooltip ?? '').contains('恢复显示')) {
              pause = button.onPressed;
            }
          }
          element.visitChildren(find);
        }

        WidgetsBinding.instance.rootElement?.visitChildren(find);
        if (pause != null) {
          watch = Stopwatch()..start();
          pause!();
          await SchedulerBinding.instance.endOfFrame;
          pauses.add(watch.elapsedMicroseconds);
        } else {
          emit({'event': 'pause_target_missing'});
        }
      }
      if (actionNumber % 7 == 0) {
        watch = Stopwatch()..start();
        model.page = model.page == 0 ? 1 : 0;
        model.refresh();
        await SchedulerBinding.instance.endOfFrame;
        pages.add(watch.elapsedMicroseconds);
      }
      if (actionNumber % 5 == 0) {
        final session = sessions[actionNumber % 8];
        await session.send(
          Draft(body: '50 54 53 54', crc: false),
          remember: true,
        );
        await session.execute([command]);
      }
      if (actionNumber % 15 == 0 && backgroundQuery == null) {
        final operation = actionNumber;
        backgroundQuery = () async {
          try {
            final searchWatch = Stopwatch()..start();
            final result = await archive.search(
              LogSearchQuery(
                directory: options.directory,
                query: operation % 30 == 0 ? '50' : '50 54',
                hex: true,
                limit: 20,
              ),
            );
            searches.add(searchWatch.elapsedMicroseconds);
            if (result.hits.length != 20 || result.warnings.isNotEmpty) {
              emit({
                'event': 'search_verification_error',
                'hits': result.hits.length,
                'warnings': result.warnings,
              });
            }
            final historyWatch = Stopwatch()..start();
            final page = await model.storage.queryHistory(limit: 20);
            historyReads.add(historyWatch.elapsedMicroseconds);
            emit({
              'event': 'archive_usage_sample',
              'elapsed_us': clock.elapsedMicroseconds,
              'usage': await archive.usage(options.directory),
            });
            if (page.records.isEmpty) {
              emit({
                'event': 'history_verification_error',
                'reason': 'no records under actual sends',
              });
            }
          } catch (error, stack) {
            emit({
              'event': 'background_query_error',
              'error': '$error',
              'stack': '$stack',
            });
          }
        }().whenComplete(() => backgroundQuery = null);
      }
      if (actionNumber == 10 || actionNumber % 60 == 0) {
        final index = (actionNumber ~/ 60) % 8;
        command.draft.body =
            '50 54 ${(actionNumber & 255).toRadixString(16).padLeft(2, '0')} 58';
        command.revision++;
        command.updatedAt = DateTime.now().toUtc().toIso8601String();
        model.changed();
        await model.flushPendingSave();
        await sourceCommand('pause', index);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await sessions[index].disconnect();
        await attach(index);
        await sourceCommand('resume', index);
        emit({'event': 'reopen', 'session_index': index});
      }
    } catch (e, st) {
      emit({'event': 'action_error', 'error': '$e', 'stack': '$st'});
    } finally {
      actionBusy = false;
    }
  });
  Timer? checkpoint;
  if (durationSeconds >= 1800) {
    final untilCheckpoint = 1800000000 - clock.elapsedMicroseconds;
    checkpoint = Timer(
      Duration(microseconds: untilCheckpoint < 0 ? 0 : untilCheckpoint),
      () async {
        await sourceCommand('stats');
        final elapsed = (sourceStats['elapsed_us'] as int? ?? 0);
        if (elapsed < 1800000000) {
          await Future<void>.delayed(
            Duration(microseconds: 1800000000 - elapsed + 4000),
          );
          await sourceCommand('stats');
        }
        emit(snapshot('checkpoint_30m'));
        await evidence.flush();
      },
    );
  }
  final samples = Timer.periodic(const Duration(seconds: 10), (_) {
    emit(snapshot('sample'));
    unawaited(evidence.flush());
  });
  final safety = Timer.periodic(const Duration(minutes: 1), (_) async {
    await windowManager.setTitle(
      'Portly · Release 压力测试 · ${clock.elapsed.inMinutes}/${(durationSeconds / 60).ceil()} min',
    );
    final result = await Process.run('/bin/df', ['-k', directory.path]);
    final lines = '${result.stdout}'.trim().split('\n');
    final cells = lines.last.trim().split(RegExp(r'\s+'));
    final freeKiB = cells.length > 3 ? int.tryParse(cells[3]) : null;
    emit({'event': 'disk_safety', 'free_kib': freeKiB});
    if (freeKiB != null && freeKiB < 30 * 1024 * 1024) {
      emit({'event': 'disk_safety_abort'});
      await sourceCommand('stop');
      exit(3);
    }
  });
  final remaining = durationSeconds * 1000000 - clock.elapsedMicroseconds;
  await Future<void>.delayed(
    Duration(microseconds: remaining < 0 ? 0 : remaining),
  );
  actions.cancel();
  checkpoint?.cancel();
  samples.cancel();
  safety.cancel();
  responsivenessProbe.cancel();
  while (actionBusy) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  await sourceCommand('stats');
  final sourceRemaining =
      durationSeconds * 1000000 - (sourceStats['elapsed_us'] as int? ?? 0);
  if (sourceRemaining > 0) {
    await Future<void>.delayed(Duration(microseconds: sourceRemaining + 4000));
  }
  await sourceCommand('stop');
  await Future<void>.delayed(const Duration(seconds: 2));
  await backgroundQuery;
  for (final session in sessions) {
    await session.recorder.stop();
  }
  await sourceCommand('stats');
  await Future<void>.delayed(const Duration(milliseconds: 100));
  await model.storage.flushHistory();
  var history = await model.storage.queryHistory(limit: 100);
  final retainedHistory = <HistoryRecord>[...history.records];
  final expectedHistoryCount = history.count, historyBytes = history.bytes;
  while (history.nextCursor.isNotEmpty && retainedHistory.length <= 1000) {
    history = await model.storage.queryHistory(
      before: history.nextCursor,
      limit: 100,
    );
    retainedHistory.addAll(history.records);
  }
  final statuses = <String, int>{};
  for (final record in retainedHistory) {
    statuses.update(record.status, (n) => n + 1, ifAbsent: () => 1);
  }
  final nonterminal = retainedHistory
      .where((r) => ['pending', 'submitting', 'waiting'].contains(r.status))
      .length;
  final uniqueIds = retainedHistory.map((r) => r.id).toSet().length;
  if (retainedHistory.length != expectedHistoryCount ||
      uniqueIds != expectedHistoryCount ||
      nonterminal > 0) {
    emit({
      'event': 'history_verification_error',
      'expected': expectedHistoryCount,
      'received': retainedHistory.length,
      'unique_ids': uniqueIds,
      'nonterminal': nonterminal,
    });
  }
  emit({
    'event': 'history_verification',
    'retained_count': expectedHistoryCount,
    'retained_bytes': historyBytes,
    'verified_all_records': retainedHistory.length,
    'unique_ids': uniqueIds,
    'nonterminal': nonterminal,
    'status_counts': statuses,
    'error': model.storage.historyError,
    'dropped': model.storage.historyDropped,
    'revisions': retainedHistory
        .where((r) => r.commandId == command.id)
        .map((r) => r.revision)
        .toSet()
        .toList(),
  });
  emit(snapshot('final'));
  final files = await archive.listFiles(options.directory);
  final queryWatch = Stopwatch()..start();
  final found = await archive.search(
    LogSearchQuery(
      directory: options.directory,
      query: '50 54',
      hex: true,
      limit: 100,
    ),
  );
  emit({
    'event': 'archive_verification',
    'files': files.length,
    'records': files.fold(0, (n, f) => n + f.records),
    'raw_bytes': files.fold(0, (n, f) => n + f.bytes),
    'expected_records':
        sessions.fold(0, (n, s) => n + s.sequence) - recordingStartSequences,
    'search_hits': found.hits.length,
    'search_us': queryWatch.elapsedMicroseconds,
    'warnings': found.warnings,
    'usage': await archive.usage(options.directory),
  });
  await archive.close();
  for (final sub in validationSubs) {
    await sub.cancel();
  }
  final shutdownWatch = Stopwatch()..start();
  try {
    expectedShutdown = true;
    model.removeListener(verifySessionSet);
    await model.shutdown();
    emit({
      'event': 'shutdown_verification',
      'elapsed_us': shutdownWatch.elapsedMicroseconds,
      'shutdown_complete': model.shutdownComplete,
      'close_error': model.storage.closeError,
      'active_tasks': sessions
          .where((s) => s.running || s.fileSending || s.busy || s.reconnecting)
          .length,
    });
  } catch (error, stack) {
    emit({
      'event': 'shutdown_error',
      'error': '$error',
      'close_error': model.storage.closeError,
      'stack': '$stack',
    });
  }
  model.dispose();
  source.kill(priority: Isolate.immediate);
  sourceReplies.close();
  await evidence.flush();
  await evidence.close();
  watchdog.cancel();
  final sent = List<int>.from(sourceStats['sent'] as List? ?? []);
  final sourceFailed = List<int>.from(sourceStats['failed'] as List? ?? []);
  final sourceTxBytes = List<int>.from(sourceStats['tx_bytes'] as List? ?? []);
  final sourceTxCorrupt = List<int>.from(
    sourceStats['tx_corrupt'] as List? ?? [],
  );
  final exactTransmit =
      sourceTxBytes.length == 8 &&
      List.generate(
        8,
        (i) => sourceTxBytes[i] == sessions[i].tx,
      ).every((ok) => ok) &&
      sum(sourceTxCorrupt) == 0;
  final exactReceive =
      sent.length == 8 &&
      List.generate(8, (i) => sent[i] == received[i]).every((ok) => ok);
  exit(
    recorderErrors.isEmpty &&
            sum(gaps) == 0 &&
            sum(corrupt) == 0 &&
            sum(duplicates) == 0 &&
            failureCount == 0 &&
            exactReceive &&
            exactTransmit &&
            sum(sourceFailed) == 0 &&
            model.storage.historyError.isEmpty
        ? 0
        : 2,
  );
}

void _sourceMain(Map<String, dynamic> args) async {
  final reply = args['reply'] as SendPort, base = args['basePort'] as int;
  final input = ReceivePort();
  final sockets = <RawDatagramSocket>[];
  final buffers = <Uint8List>[];
  final sent = List<int>.filled(8, 0),
      failed = List<int>.filled(8, 0),
      echo = List<int>.filled(8, 0),
      txBytes = List<int>.filled(8, 0),
      txCorrupt = List<int>.filled(8, 0),
      enabled = List<bool>.filled(8, true);
  final watch = Stopwatch();
  var nextTick = 0;
  Timer? timer;
  void stats() {
    reply.send({
      'event': 'source_stats',
      'sent': List<int>.of(sent),
      'failed': List<int>.of(failed),
      'tx_received': List<int>.of(echo),
      'tx_bytes': List<int>.of(txBytes),
      'tx_corrupt': List<int>.of(txCorrupt),
      'elapsed_us': watch.elapsedMicroseconds,
      'late_ticks': nextTick == 0
          ? 0
          : watch.elapsedMicroseconds ~/ 4000 - nextTick,
    });
  }

  for (var i = 0; i < 8; i++) {
    final socket = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    socket.listen((event) {
      if (event == RawSocketEvent.read) {
        Datagram? datagram;
        while ((datagram = socket.receive()) != null) {
          final bytes = datagram!.data;
          echo[i]++;
          txBytes[i] += bytes.length;
          if (bytes.length != 4 ||
              bytes[0] != 0x50 ||
              bytes[1] != 0x54 ||
              !((bytes[2] == 0x53 && bytes[3] == 0x54) || bytes[3] == 0x58)) {
            txCorrupt[i]++;
          }
        }
      }
    });
    sockets.add(socket);
    final buffer = Uint8List(128);
    for (var j = 0; j < 128; j++) {
      buffer[j] = (j * 17 + i * 29) & 255;
    }
    buffer[0] = 0x50;
    buffer[1] = 0x54;
    buffer[4] = i;
    buffers.add(buffer);
  }
  reply.send({
    'event': 'ready',
    'control': input.sendPort,
    'ports': sockets.map((s) => s.port).toList(),
  });
  input.listen((dynamic message) {
    final operation = message['operation'];
    if (operation == 'start') {
      watch.start();
      timer = Timer.periodic(const Duration(milliseconds: 1), (_) {
        final target = watch.elapsedMicroseconds ~/ 4000;
        var budget = 16;
        while (nextTick < target && budget-- > 0) {
          nextTick++;
          for (var slot = 0; slot < 8; slot++) {
            var i = slot;
            // Reassign a maintenance slot, keeping the aggregate source at 2000/s.
            while (!enabled[i]) {
              i = (i + 1) % 8;
            }
            ByteData.sublistView(buffers[i]).setUint64(8, sent[i], Endian.big);
            final n = sockets[i].send(
              buffers[i],
              InternetAddress.loopbackIPv4,
              base + i,
            );
            if (n == 128) {
              sent[i]++;
            } else {
              failed[i]++;
            }
          }
        }
      });
    } else if (operation == 'pause') {
      enabled[message['index'] as int] = false;
    } else if (operation == 'resume') {
      enabled[message['index'] as int] = true;
    } else if (operation == 'stop') {
      timer?.cancel();
      watch.stop();
      stats();
    } else if (operation == 'stats') {
      stats();
    }
    reply.send({'event': 'ack', 'id': message['id']});
  });
  Timer.periodic(const Duration(seconds: 10), (_) {
    stats();
  });
}
