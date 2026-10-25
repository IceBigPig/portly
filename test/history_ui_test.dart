import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portly/core/models.dart';
import 'package:portly/platform/storage.dart';
import 'package:portly/state/app_model.dart';
import 'package:portly/state/session.dart';
import 'package:portly/ui/history.dart';
import 'package:portly/ui/theme.dart';

class _HistoryStorage extends AppStorage {
  final records = <HistoryRecord>[];
  bool fail = false, paginated = false;
  int queries = 0;
  @override
  Future<Map<String, dynamic>?> open({String? path}) async => null;
  @override
  Future<void> save(Map<String, dynamic> data) async {}
  @override
  Future<HistoryPage> queryHistory({
    String sessionId = '',
    String taskId = '',
    String before = '',
    int limit = 100,
    List<String> kinds = const [],
  }) async {
    queries++;
    if (fail) throw StateError('历史数据库不可用');
    final filtered = records
        .where(
          (r) =>
              (sessionId.isEmpty || r.sessionId == sessionId) &&
              (taskId.isEmpty || r.taskId == taskId || r.id == taskId) &&
              (kinds.isEmpty || kinds.contains(r.kind)),
        )
        .toList();
    return HistoryPage(
      records: paginated
          ? filtered.skip(before.isEmpty ? 0 : 50).take(50).toList()
          : filtered,
      nextCursor: paginated && before.isEmpty && filtered.length > 50
          ? 'older'
          : '',
      count: filtered.length,
      bytes: 100,
    );
  }

  @override
  Future<HistoryRecord?> getHistory(String id) async {
    if (fail) throw StateError('历史数据库不可用');
    return records.where((r) => r.id == id).firstOrNull;
  }

  @override
  Future<void> clearHistory({String sessionId = ''}) async =>
      records.removeWhere((r) => sessionId.isEmpty || r.sessionId == sessionId);
  @override
  void close() {}
}

class _TaskSession extends Session {
  _TaskSession() : super(config: ConnectionConfig());
  int stops = 0;
  @override
  String get activeHistoryTaskId => 'live-task';
  @override
  void stop({String reason = ''}) {
    stops++;
    running = false;
  }
}

Future<AppModel> _host(
  WidgetTester tester,
  _HistoryStorage storage, {
  bool dark = false,
  Session? session,
}) async {
  tester.view.physicalSize = const Size(900, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final model = AppModel(storage: storage);
  await model.initialize();
  if (session != null) {
    for (final old in model.sessions) {
      old.dispose();
    }
    model.sessions
      ..clear()
      ..add(session);
    model.currentId = session.id;
  }
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme(dark),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showSendHistory(context, model, model.current),
            child: const Text('历史'),
          ),
        ),
      ),
    ),
  );
  return model;
}

Future<void> _finish(WidgetTester tester, AppModel model) async {
  await tester.pumpWidget(const SizedBox());
  model.dispose();
}

void main() {
  for (final dark in [false, true]) {
    testWidgets(
      'History restores body and CRC strategy without sending, 900x600 $dark',
      (tester) async {
        final storage = _HistoryStorage();
        final model = await _host(tester, storage, dark: dark);
        final store = model.storage as _HistoryStorage;
        final draft = Draft(body: '01 03 00 00 00 02', crc: true);
        store.records.add(
          HistoryRecord(
            kind: 'send',
            sessionId: model.current.id,
            runtimeId: 'runtime',
            name: '读取',
            targets: ['device:9000'],
            draft: draft,
            finalBytes: draft.build(),
            status: 'submitted',
          ),
        );
        await tester.tap(find.text('历史'));
        await tester.pumpAndSettle();
        expect(find.text('已提交'), findsOneWidget);
        await tester.tap(find.text('读取'));
        await tester.pumpAndSettle();
        expect(find.text('已提交'), findsNWidgets(2));
        await tester.tap(find.text('载入发送框'));
        await tester.pumpAndSettle();
        expect(model.current.draft.body, draft.body);
        expect(model.current.draft.crc, isTrue);
        expect(model.current.draft.build(), draft.build());
        expect(model.current.tx, 0);
        expect(tester.takeException(), isNull);
        await _finish(tester, model);
      },
    );
  }
  testWidgets('Final-only legacy history loads raw bytes exactly once', (
    tester,
  ) async {
    final store = _HistoryStorage();
    final model = await _host(tester, store);
    final storage = model.storage as _HistoryStorage;
    storage.records.add(
      HistoryRecord.fromJson({
        'id': 'old',
        'sessionId': model.current.id,
        'name': '旧记录',
        'finalBytes': '01 03 00 00 00 02 C4 0B',
      }),
    );
    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('旧记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('载入发送框'));
    await tester.pumpAndSettle();
    expect(model.current.draft.body, '01 03 00 00 00 02 C4 0B');
    expect(model.current.draft.crc, isFalse);
    expect(model.current.tx, 0);
    expect(tester.takeException(), isNull);
    await _finish(tester, model);
  });
  testWidgets('Truncated snapshot cannot load; file history is metadata only', (
    tester,
  ) async {
    final storage = _HistoryStorage();
    final model = await _host(tester, storage);
    final store = model.storage as _HistoryStorage;
    store.records.add(
      HistoryRecord(
        kind: 'send',
        sessionId: model.current.id,
        runtimeId: 'runtime',
        name: '大报文',
        finalBytes: List.filled(65537, 1),
        status: 'submitted',
      ),
    );
    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('大报文'));
    await tester.pumpAndSettle();
    expect(find.text('载入发送框'), findsNothing);
    expect(find.textContaining('保留前 65536 B'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _finish(tester, model);
  });
  testWidgets(
    'Stale pending task cannot stop a different live task; query errors are visible',
    (tester) async {
      final session = _TaskSession()..running = true;
      final model = await _host(tester, _HistoryStorage(), session: session),
          store = model.storage as _HistoryStorage;
      store.records.add(
        HistoryRecord(
          id: 'old-task',
          kind: 'task',
          sessionId: session.id,
          runtimeId: 'runtime',
          name: '旧任务',
          status: 'waiting',
        ),
      );
      await tester.tap(find.text('历史'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('旧任务'));
      await tester.pumpAndSettle();
      expect(find.text('停止任务'), findsNothing);
      expect(session.stops, 0);
      store.fail = true;
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.textContaining('历史数据库不可用'), findsWidgets);
      expect(tester.takeException(), isNull);
      await _finish(tester, model);
    },
  );
  testWidgets('History remains unloaded until explicitly opened', (
    tester,
  ) async {
    final store = _HistoryStorage();
    final model = await _host(tester, store);
    final storage = model.storage as _HistoryStorage;
    await tester.pump(const Duration(seconds: 5));
    expect(storage.queries, 0);
    await tester.tap(find.text('历史'));
    await tester.pumpAndSettle();
    expect(storage.queries, 1);
    expect(find.text('暂无历史'), findsOneWidget);
    await _finish(tester, model);
  });
  testWidgets(
    'Loading older history pages is not undone by pending-task refresh',
    (tester) async {
      final store = _HistoryStorage()..paginated = true;
      final model = await _host(tester, store);
      store.records.addAll(
        List.generate(
          51,
          (i) => HistoryRecord(
            kind: 'step',
            sessionId: model.current.id,
            runtimeId: 'runtime',
            name: '步骤$i',
            status: i == 0 ? 'waiting' : 'submitted',
          ),
        ),
      );
      await tester.tap(find.text('历史'));
      await tester.pumpAndSettle();
      expect(store.queries, 1);
      await tester.tap(find.text('加载更多'));
      await tester.pumpAndSettle();
      expect(store.queries, 2);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(store.queries, 2);
      expect(tester.takeException(), isNull);
      await _finish(tester, model);
    },
  );
  testWidgets(
    'First step and cycle are one-based and frozen response settings are available',
    (tester) async {
      final store = _HistoryStorage();
      final model = await _host(tester, store);
      final storage = model.storage as _HistoryStorage;
      storage.records.add(
        HistoryRecord(
          kind: 'step',
          sessionId: model.current.id,
          runtimeId: 'runtime',
          name: '执行步骤',
          stepIndex: 1,
          cycle: 1,
          finalBytes: [1],
          status: 'response',
          timeoutMs: 500,
          periodMs: 1000,
          stepDelayMs: 10,
          responseRule: {
            'type': 'bytes_exact',
            'framing': 'fixed',
            'length': 1,
            'patternHex': '01',
          },
        ),
      );
      await tester.tap(find.text('历史'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('执行步骤'));
      await tester.pumpAndSettle();
      expect(find.text('1 / 1'), findsOneWidget);
      expect(find.text('2 / 2'), findsNothing);
      await tester.ensureVisible(find.text('快照标识'));
      await tester.tap(find.text('快照标识'));
      await tester.pumpAndSettle();
      expect(find.text('响应超时'), findsOneWidget);
      expect(find.text('500 ms'), findsOneWidget);
      expect(find.text('完整字节'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _finish(tester, model);
    },
  );
  testWidgets(
    'A session closed while confirming history load is not selected or mutated',
    (tester) async {
      final store = _HistoryStorage();
      final model = await _host(tester, store);
      final storage = model.storage as _HistoryStorage, old = model.current;
      old.draft.body = 'AA';
      storage.records.add(
        HistoryRecord(
          kind: 'send',
          sessionId: old.id,
          runtimeId: 'runtime',
          name: '已提交记录',
          finalBytes: [1],
          status: 'submitted',
        ),
      );
      await tester.tap(find.text('历史'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('已提交记录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('载入发送框'));
      await tester.pumpAndSettle();
      expect(find.text('载入历史'), findsOneWidget);
      await model.closeSession(old);
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(model.sessions.contains(old), isFalse);
      expect(model.current.id, isNot(old.id));
      expect(old.draft.body, 'AA');
      expect(find.text('目标会话已关闭'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _finish(tester, model);
    },
  );
}
