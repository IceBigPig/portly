import 'dart:async';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portly/core/models.dart';
import 'package:portly/platform/compare_window.dart';
import 'package:portly/platform/desktop_window.dart';
import 'package:portly/state/app_model.dart';
import 'package:portly/state/session.dart';

const _desktop = MethodChannel('mixin.one/desktop_multi_window');
const _channels = MethodChannel('mixin.one/desktop_multi_window/channels');

Future<void> _until(bool Function() condition) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > const Duration(seconds: 2)) {
      throw TimeoutException('window condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void _mockRegistry(
  List<String> windows, {
  Future<dynamic> Function(MethodCall)? onClose,
  Future<dynamic> Function()? onRead,
}) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(_desktop, (call) async {
    expect(call.method, 'getAllWindows');
    if (onRead != null) return onRead();
    return [
      for (final id in windows) {'windowId': id, 'windowArgument': ''},
    ];
  });
  messenger.setMockMethodCallHandler(_channels, (call) async {
    expect(call.method, 'invokeMethod');
    expect(call.arguments['method'], 'close');
    return onClose == null ? true : await onClose(call);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('window_manager');
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_desktop, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channels, null);
  });
  test(
    'Windows releases the close guard before requesting this HWND close',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await closeDesktopWindow();
      expect(calls.map((call) => call.method), ['setPreventClose', 'close']);
      expect(calls.first.arguments, {'isPreventClose': false});
    },
  );
  for (final platform in [TargetPlatform.macOS, TargetPlatform.linux]) {
    test('$platform retains its platform-specific destruction path', () async {
      debugDefaultTargetPlatformOverride = platform;
      await closeDesktopWindow();
      expect(calls.map((call) => call.method), ['destroy']);
    });
  }
  for (final failed in ['setPreventClose', 'close']) {
    test(
      'Windows propagates $failed failure without quitting the process',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              if (call.method == failed) {
                throw PlatformException(code: 'close-failed');
              }
              return true;
            });
        await expectLater(
          closeDesktopWindow(),
          throwsA(isA<PlatformException>()),
        );
        expect(calls.any((call) => call.method == 'destroy'), false);
        expect(calls.last.method, failed);
      },
    );
  }
  test('Host waits for every acknowledged child engine to leave the native registry', () async {
    final windows = ['host', 'first', 'second'], requests = <String>[];
    _mockRegistry(
      windows,
      onClose: (call) async {
        requests.add(call.arguments['channel'] as String);
        return true;
      },
    );
    var done = false;
    final closing = closeComparisonWindows(
      'host',
      pollInterval: const Duration(milliseconds: 2),
    ).then((_) => done = true);
    await Future<void>.delayed(const Duration(milliseconds: 15));
    expect(done, false);
    expect(requests.toSet(), {
      'mixin.one/window_controller/first',
      'mixin.one/window_controller/second',
    });
    windows.remove('first');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(done, false);
    windows.remove('second');
    await closing;
    expect(done, true);
    expect(calls, isEmpty);
  });
  test(
    'A child that disappeared during an RPC failure is successfully closed',
    () async {
      final windows = ['host', 'child'];
      _mockRegistry(
        windows,
        onClose: (_) async {
          windows.remove('child');
          throw PlatformException(code: 'ENGINE_STOPPED');
        },
      );
      await closeComparisonWindows('host');
      expect(windows, ['host']);
    },
  );
  test('An RPC failure with a live child propagates instead of permitting host exit', () async {
    _mockRegistry(
      ['host', 'child'],
      onClose: (_) async {
        throw PlatformException(code: 'CLOSE_FAILED');
      },
    );
    await expectLater(
      closeComparisonWindows('host'),
      throwsA(isA<StateError>()),
    );
    expect(calls, isEmpty);
  });
  test(
    'An acknowledged child that never stops reaches a bounded timeout',
    () async {
      _mockRegistry(['host', 'child']);
      await expectLater(
        closeComparisonWindows(
          'host',
          timeout: const Duration(milliseconds: 30),
          pollInterval: const Duration(milliseconds: 2),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(calls, isEmpty);
    },
  );
  test(
    'Native registry queries are also bounded and errors are not swallowed',
    () async {
      _mockRegistry(['host'], onRead: () => Completer<dynamic>().future);
      await expectLater(
        closeComparisonWindows(
          'host',
          timeout: const Duration(milliseconds: 20),
        ),
        throwsA(isA<TimeoutException>()),
      );
      _mockRegistry(
        ['host'],
        onRead: () async {
          throw PlatformException(code: 'REGISTRY_FAILED');
        },
      );
      await expectLater(
        closeComparisonWindows('host'),
        throwsA(isA<PlatformException>()),
      );
    },
  );
  for (final failCreation in [false, true]) {
    test(
      failCreation
          ? 'Creation failure is reported during close and a later close can retry'
          : 'Close waits for admitted creation, suppresses its late show, then waits for engine removal',
      () async {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        final creation = Completer<String>(), createStarted = Completer<void>();
        final registered = ['host'];
        var shows = 0, registryReads = 0, closeRequests = 0;
        messenger.setMockMethodCallHandler(_desktop, (call) async {
          switch (call.method) {
            case 'getWindowDefinition':
              return {'windowId': 'host', 'windowArgument': ''};
            case 'createWindow':
              createStarted.complete();
              final id = await creation.future;
              registered.add(id);
              return id;
            case 'getAllWindows':
              registryReads++;
              return [
                for (final id in registered)
                  {'windowId': id, 'windowArgument': ''},
              ];
            case 'window_show':
              shows++;
              return null;
            default:
              throw StateError('Unexpected method ${call.method}');
          }
        });
        messenger.setMockMethodCallHandler(_channels, (call) async {
          if (call.method == 'invokeMethod') {
            expect(call.arguments['method'], 'close');
            closeRequests++;
          }
          return null;
        });
        final model = AppModel()..externalView = true;
        model.sessions.add(Session(config: ConnectionConfig()));
        model.currentId = model.sessions.first.id;
        final controller = WindowController.fromWindowId('host');
        try {
          await installCompareHost(model, controller);
          final opening = model.openCompareWindow!();
          final openResult = failCreation
              ? expectLater(opening, throwsA(isA<PlatformException>()))
              : opening;
          await createStarted.future;
          model.closing = true;
          var done = false;
          final closing = model.closeCompareWindows!().then((_) => done = true);
          final closeResult = failCreation
              ? expectLater(closing, throwsA(isA<PlatformException>()))
              : closing;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          expect(done, false);
          expect(registryReads, 0);
          if (failCreation) {
            creation.completeError(PlatformException(code: 'CREATE_FAILED'));
            await openResult;
            await closeResult;
            model.closing = false;
            await model.closeCompareWindows!();
            expect(registryReads, 1);
          } else {
            creation.complete('late-child');
            await openResult;
            await _until(() => closeRequests == 1);
            expect(done, false);
            expect(shows, 0);
            registered.remove('late-child');
            await closeResult;
            expect(done, true);
          }
        } finally {
          await controller.setWindowMethodHandler(null);
          await Future<void>.delayed(Duration.zero);
          model.dispose();
        }
      },
    );
  }
  testWidgets(
    'Comparison close RPC closes only its HWND instead of posting process quit',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      const desktop = MethodChannel('mixin.one/desktop_multi_window');
      const channels = MethodChannel('mixin.one/desktop_multi_window/channels');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(desktop, (call) async {
        if (call.method == 'getWindowDefinition') {
          return {'windowId': 'comparison', 'windowArgument': ''};
        }
        throw StateError('Unexpected desktop method: ${call.method}');
      });
      messenger.setMockMethodCallHandler(channels, (_) async => null);
      final controller = WindowController.fromWindowId('comparison');
      try {
        await tester.pumpWidget(
          CompareWindow(
            controller: controller,
            arguments: const {
              'host': 'host',
              'first': 'first',
              'second': 'second',
            },
          ),
        );
        await tester.pump();
        const codec = StandardMethodCodec();
        final reply = Completer<ByteData?>();
        messenger.handlePlatformMessage(
          channels.name,
          codec.encodeMethodCall(
            const MethodCall('methodCall', {
              'channel': 'mixin.one/window_controller/comparison',
              'method': 'close',
              'arguments': null,
            }),
          ),
          reply.complete,
        );
        await tester.pump();
        expect(codec.decodeEnvelope((await reply.future)!), true);
        await tester.pump(const Duration(milliseconds: 1));
        expect(calls.map((call) => call.method), ['setPreventClose', 'close']);
        expect(calls.first.arguments, {'isPreventClose': false});
      } finally {
        await tester.pumpWidget(const SizedBox());
        await controller.setWindowMethodHandler(null);
        await tester.pump();
        messenger.setMockMethodCallHandler(desktop, null);
        messenger.setMockMethodCallHandler(channels, null);
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}
