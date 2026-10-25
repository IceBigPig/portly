import 'dart:ui' show AppExitResponse;
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:window_manager/window_manager.dart';
import 'package:portly/core/library_import.dart';
import 'package:portly/core/models.dart';
import 'package:portly/platform/storage.dart';
import 'package:portly/state/app_model.dart';
import 'package:portly/state/session.dart';
import 'package:portly/platform/transport.dart';
import 'package:portly/ui/shell.dart';
import 'package:portly/ui/theme.dart';

class _ShutdownStorage extends AppStorage {
  int saves = 0, flushes = 0, closes = 0, commits = 0;
  bool failSave = false,
      failFlush = false,
      failCommit = false,
      failClose = false;
  Completer<void>? saveGate, flushGate, closeGate, commitGate;
  Completer<void>? _closed;
  Map<String, dynamic>? saved;
  @override
  Future<Map<String, dynamic>?> open({String? path}) async => null;
  @override
  Future<void> save(Map<String, dynamic> data) async {
    saves++;
    await saveGate?.future;
    if (failSave) throw StateError('配置磁盘写入失败');
    saved = data;
  }

  @override
  Future<void> flushHistory() async {
    flushes++;
    await flushGate?.future;
    if (failFlush) {
      historyDropped++;
      historyError = '历史磁盘写入失败';
    }
  }

  @override
  Future<String> commitLibraryImport({
    required String expectedFingerprint,
    required Map<String, dynamic> state,
  }) async {
    commits++;
    await commitGate?.future;
    if (failCommit) throw StateError('导入磁盘写入失败');
    saved = state;
    return 'backup';
  }

  @override
  Future<void> get closed => _closed?.future ?? Future<void>.value();
  @override
  void close() {
    if (_closed != null) return;
    closes++;
    final done = Completer<void>();
    _closed = done;
    unawaited(() async {
      await closeGate?.future;
      if (failClose) closeError = '数据库句柄关闭失败';
      done.complete();
    }());
  }
}

class _ClosingTransport implements Transport {
  final controller = StreamController<TransportEvent>.broadcast(sync: true);
  final gate = Completer<void>();
  bool started = false, closing = false;
  Completer<void>? closeGate;
  @override
  Stream<TransportEvent> get events => controller.stream;
  @override
  List<Peer> get peers => [];
  @override
  String get localEndpoint => 'test';
  @override
  Future<void> send(Uint8List bytes, {String? target}) async {
    started = true;
    await gate.future;
  }

  @override
  Future<void> disconnectPeer(String id) async {}
  @override
  Future<void> close() async {
    closing = true;
    if (!gate.isCompleted) gate.complete();
    await closeGate?.future;
    await controller.close();
  }
}

String _library() => jsonEncode({
  'format': commandLibraryFormat,
  'schemaVersion': 1,
  'groups': [
    {'id': 'default', 'name': '默认分组'},
  ],
  'commands': [
    SavedCommand(
      id: 'new',
      name: '读取',
      draft: Draft(body: 'AA'),
    ).toJson(),
  ],
});
Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 1000; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  throw TimeoutException('condition');
}

void main() {
  test('Shutdown waits for history and owner release, gates new work and is idempotent', () async {
    final store = _ShutdownStorage()
      ..flushGate = Completer<void>()
      ..closeGate = Completer<void>();
    final model = AppModel(storage: store);
    await model.initialize();
    var childCloses = 0;
    model.closeCompareWindows = () async {
      childCloses++;
    };
    final plan = (await model.previewLibraryImport(_library())).buildPlan();
    var completed = false;
    final first = model.shutdown().then((_) {
      completed = true;
    });
    final duplicate = model.shutdown();
    await _until(() => store.flushes == 1);
    expect(model.closing, true);
    expect(completed, false);
    expect(store.closes, 0);
    expect(() => model.newSession(ConnectionKind.serial), throwsStateError);
    await expectLater(model.current.send(Draft(body: 'AA')), throwsStateError);
    await expectLater(model.current.connect(), throwsStateError);
    await expectLater(model.applyLibraryImport(plan), throwsStateError);
    store.flushGate!.complete();
    await _until(() => store.closes == 1);
    expect(completed, false);
    store.closeGate!.complete();
    await Future.wait([first, duplicate]);
    expect(model.shutdownComplete, true);
    expect(childCloses, 1);
    await model.shutdown();
    expect(store.closes, 1);
    model.dispose();
    model.dispose();
  });
  test('Shutdown waits for the full import including preparation before a save transaction exists', () async {
    final store = _ShutdownStorage(), prepare = Completer<List<SavedCommand>>();
    var preparing = false;
    final model = AppModel(
      storage: store,
      prepareImport: (plan) {
        preparing = true;
        return prepare.future;
      },
    );
    await model.initialize();
    final plan = (await model.previewLibraryImport(_library())).buildPlan();
    final importing = model.applyLibraryImport(plan);
    await _until(() => preparing);
    final closing = model.shutdown();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(store.closes, 0);
    expect(store.commits, 0);
    expect(model.closing, true);
    prepare.complete(plan.commands);
    await importing;
    await closing;
    expect(store.commits, 1);
    expect((store.saved!['commands'] as List).single['id'], 'new');
    expect(store.closes, 1);
    model.dispose();
  });
  test(
    'Shutdown waits for commit and import failure leaves the database open',
    () async {
      final store = _ShutdownStorage()
        ..commitGate = Completer<void>()
        ..failCommit = true;
      final model = AppModel(storage: store);
      await model.initialize();
      final plan = (await model.previewLibraryImport(_library())).buildPlan();
      final importing = model.applyLibraryImport(plan);
      final importFailure = expectLater(importing, throwsStateError);
      await _until(() => store.commits == 1);
      final closing = model.shutdown();
      final closeFailure = expectLater(closing, throwsStateError);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(store.closes, 0);
      store.commitGate!.complete();
      await Future.wait([importFailure, closeFailure]);
      expect(model.shutdownComplete, false);
      expect(model.closing, false);
      expect(store.closes, 0);
      await expectLater(model.shutdown(), throwsStateError);
      expect(store.closes, 0);
      await model.shutdown(discardUnsavedChanges: true);
      expect(store.closes, 1);
      model.dispose();
    },
  );
  test(
    'A failed configuration save keeps the database open and can be retried',
    () async {
      final store = _ShutdownStorage()..failSave = true;
      final model = AppModel(storage: store);
      await model.initialize();
      model.current.draft.body = 'AA';
      model.saveSoon();
      await expectLater(model.shutdown(), throwsStateError);
      expect(store.closes, 0);
      expect(model.shutdownComplete, false);
      expect(model.closing, false);
      store.failSave = false;
      await model.shutdown();
      expect(store.closes, 1);
      expect(model.shutdownComplete, true);
      model.dispose();
    },
  );
  test('New or previously reported history loss requires explicit discard rather than a successful exit claim', () async {
    for (final previous in [false, true]) {
      final store = _ShutdownStorage()..failFlush = !previous;
      final model = AppModel(storage: store);
      await model.initialize();
      if (previous) {
        store.historyDropped = 2;
        store.historyError = '此前队列拒绝2条更新';
      }
      await expectLater(model.shutdown(), throwsStateError);
      expect(store.closes, 0);
      expect(model.closing, false);
      store.failFlush = false;
      await model.shutdown(discardUnsavedChanges: true);
      expect(store.historyDropped, greaterThan(0));
      expect(store.closes, 1);
      model.dispose();
    }
  });
  test('Archive stop status errors block database close until explicitly discarded', () async {
    final store = _ShutdownStorage();
    final app = AppModel(storage: store);
    await app.initialize();
    app.current.recorder.status = const LogRecordingStatus(
      error: '归档磁盘空间不足，2条未落盘',
    );
    await expectLater(
      app.shutdown(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'error',
          contains('此前已有未保存日志'),
        ),
      ),
    );
    expect(store.closes, 0);
    expect(app.shutdownComplete, false);
    expect(app.closing, false);
    expect(store.flushes, 1);
    await app.shutdown(discardUnsavedChanges: true);
    expect(store.closes, 1);
    app.dispose();
  });

  test(
    'A failed storage close is reported even though closed completed',
    () async {
      final store = _ShutdownStorage()..failClose = true;
      final model = AppModel(storage: store);
      await model.initialize();
      await expectLater(model.shutdown(), throwsStateError);
      expect(model.shutdownComplete, false);
      expect(store.closeError, isNotEmpty);
      await model.shutdown(discardUnsavedChanges: true);
      expect(model.shutdownComplete, true);
      model.dispose();
    },
  );
  test(
    'A comparison model never shuts down or disposes the host repository',
    () async {
      final store = _ShutdownStorage(),
          model = AppModel(storage: _ShutdownStorage());
      model.dispose();
      final child = AppModel(storage: store)..externalView = true;
      await expectLater(child.shutdown(), throwsStateError);
      child.dispose();
      expect(store.closes, 0);
    },
  );
  test('Real shutdown persists accepted history and releases the owner before returning', () async {
    final temp = await Directory.systemTemp.createTemp('portly-shutdown-'),
        path = '${temp.path}/app.sqlite';
    final model = AppModel();
    await model.initialize(storagePath: path);
    model.current.draft.body = 'AA';
    model.saveSoon();
    model.storage.recordHistory(
      HistoryRecord(
        kind: 'send',
        sessionId: model.current.id,
        runtimeId: model.current.runtimeId,
        status: 'submitted',
        finalBytes: [170],
        draft: Draft(body: 'AA'),
      ),
    );
    await model.shutdown();
    final next = AppStorage();
    expect(
      (await next.open(path: path))!['sessions'][0]['draft']['body'],
      'AA',
    );
    expect((await next.queryHistory()).count, 1);
    next.close();
    await next.closed;
    model.dispose();
    await temp.delete(recursive: true);
  });
  test('Shutdown audits the last accepted transport write before closing history storage', () async {
    final temp = await Directory.systemTemp.createTemp('portly-shutdown-send-');
    final path = '${temp.path}/app.sqlite', model = AppModel();
    await model.initialize(storagePath: path);
    final transport = _ClosingTransport();
    final session = Session(
      config: ConnectionConfig(kind: ConnectionKind.tcpClient),
      opener: (_) async => transport,
    );
    for (final old in model.sessions) {
      old.dispose();
    }
    model.sessions
      ..clear()
      ..add(session);
    model.currentId = session.id;
    session.onHistory = model.storage.recordHistory;
    await session.connect();
    final sending = session.send(Draft(body: 'AA'));
    await _until(() => transport.started);
    await model.shutdown();
    await sending;
    final next = AppStorage();
    await next.open(path: path);
    final history = await next.queryHistory();
    expect(history.records.single.status, 'submitted');
    expect(history.records.single.submittedBytes, 1);
    expect(model.storage.historyError, isEmpty);
    next.close();
    await next.closed;
    model.dispose();
    await temp.delete(recursive: true);
  });

  test('An in-flight session close is awaited and cannot remove sessions after shutdown begins', () async {
    final store = _ShutdownStorage();
    final app = AppModel(storage: store);
    await app.initialize();
    final transport = _ClosingTransport()..closeGate = Completer<void>();
    final session = Session(
      config: ConnectionConfig(kind: ConnectionKind.tcpClient),
      opener: (_) async => transport,
    );
    for (final old in app.sessions) {
      old.dispose();
    }
    app.sessions
      ..clear()
      ..add(session);
    app.currentId = session.id;
    await session.connect();
    final sessionClose = app.closeSession(session);
    await _until(() => transport.closing);
    final shutdown = app.shutdown();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(store.closes, 0);
    expect(app.sessions.single, session);
    transport.closeGate!.complete();
    await sessionClose;
    await shutdown;
    expect(app.sessions.single, session);
    expect(store.closes, 1);
    app.dispose();
  });

  testWidgets(
    'Native close retains the window on save failure, and retry destroys only after storage closes',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final store = _ShutdownStorage()..failSave = true;
      final model = AppModel(storage: store);
      await model.initialize();
      var destroys = 0;
      await tester.binding.setSurfaceSize(const Size(1100, 700));
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(false),
          home: AppShell(
            model: model,
            closeWindow: () async {
              destroys++;
            },
          ),
        ),
      );
      final listener = tester.state(find.byType(AppShell)) as WindowListener;
      listener.onWindowClose();
      listener.onWindowClose();
      await tester.pumpAndSettle();
      expect(find.text('未能完成关闭'), findsOneWidget);
      expect(destroys, 0);
      expect(store.closes, 0);
      store.failSave = false;
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(destroys, 1);
      expect(store.closes, 1);
      expect(model.shutdownComplete, true);
      await tester.pumpWidget(const SizedBox());
      await tester.binding.setSurfaceSize(null);
      model.dispose();
      debugDefaultTargetPlatformOverride = null;
    },
  );
  testWidgets(
    'Native close does not destroy until the history queue and database close complete',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final store = _ShutdownStorage()
        ..flushGate = Completer<void>()
        ..closeGate = Completer<void>();
      final model = AppModel(storage: store);
      await model.initialize();
      var destroys = 0;
      await tester.binding.setSurfaceSize(const Size(1100, 700));
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(false),
          home: AppShell(
            model: model,
            closeWindow: () async {
              destroys++;
            },
          ),
        ),
      );
      (tester.state(find.byType(AppShell)) as WindowListener).onWindowClose();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('正在关闭'), findsOneWidget);
      expect(destroys, 0);
      expect(store.closes, 0);
      store.flushGate!.complete();
      await tester.pump();
      await tester.pump();
      expect(store.closes, 1);
      expect(destroys, 0);
      store.closeGate!.complete();
      await tester.pumpAndSettle();
      expect(destroys, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.binding.setSurfaceSize(null);
      model.dispose();
      debugDefaultTargetPlatformOverride = null;
    },
  );
  testWidgets(
    'Application exit requests cancel until common shutdown drains and then allow exit',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final store = _ShutdownStorage()
        ..flushGate = Completer<void>()
        ..closeGate = Completer<void>();
      final model = AppModel(storage: store);
      await model.initialize();
      var destroys = 0;
      await tester.binding.setSurfaceSize(const Size(1100, 700));
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(false),
          home: AppShell(
            model: model,
            closeWindow: () async {
              destroys++;
            },
          ),
        ),
      );
      expect(
        await tester.binding.handleRequestAppExit(),
        AppExitResponse.cancel,
      );
      expect(
        await tester.binding.handleRequestAppExit(),
        AppExitResponse.cancel,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('正在关闭'), findsOneWidget);
      expect(destroys, 0);
      expect(store.flushes, 1);
      expect(store.closes, 0);
      store.flushGate!.complete();
      await tester.pump();
      await tester.pump();
      expect(store.closes, 1);
      expect(destroys, 0);
      store.closeGate!.complete();
      await tester.pumpAndSettle();
      expect(destroys, 1);
      expect(model.shutdownComplete, true);
      expect(await tester.binding.handleRequestAppExit(), AppExitResponse.exit);
      await tester.pumpWidget(const SizedBox());
      expect(await tester.binding.handleRequestAppExit(), AppExitResponse.exit);
      await tester.binding.setSurfaceSize(null);
      model.dispose();
      debugDefaultTargetPlatformOverride = null;
    },
  );
}
