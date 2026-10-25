import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

/// Close this window after its owner has finished draining persistent work.
Future<void> closeDesktopWindow() async {
  if (defaultTargetPlatform == TargetPlatform.windows) {
    // window_manager's Windows destroy() posts WM_QUIT for the entire thread.
    // A normal close instead lets the HWND/engine tear down inside the message
    // loop, and closing a comparison window cannot terminate the host process.
    await windowManager.setPreventClose(false);
    await windowManager.close();
  } else {
    await windowManager.destroy();
  }
}
