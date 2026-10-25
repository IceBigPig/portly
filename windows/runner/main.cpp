#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  const HRESULT com_result =
      ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  int exit_code = EXIT_SUCCESS;
  {
    // Flutter views and plugin COM resources must die before CoUninitialize.
    flutter::DartProject project(L"data");

    std::vector<std::string> command_line_arguments =
        GetCommandLineArguments();

    project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

    FlutterWindow window(project);
    Win32Window::Point origin(10, 10);
    Win32Window::Size size(1280, 720);
    if (!window.Create(L"Portly", origin, size)) {
      exit_code = EXIT_FAILURE;
    } else {
      window.SetQuitOnClose(true);

      ::MSG msg{};
      BOOL message_result;
      while ((message_result = ::GetMessage(&msg, nullptr, 0, 0)) > 0) {
        ::TranslateMessage(&msg);
        ::DispatchMessage(&msg);
      }
      if (message_result == -1) {
        exit_code = EXIT_FAILURE;
      }
    }
    // Also handles a plugin posting WM_QUIT without destroying the native HWND.
    // Destroy is idempotent after the normal WM_CLOSE/WM_DESTROY path.
    window.Destroy();
  }

  if (SUCCEEDED(com_result)) {
    ::CoUninitialize();
  }
  return exit_code;
}
