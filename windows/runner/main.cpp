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
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  HANDLE instance_mutex = CreateMutexW(nullptr, FALSE, L"Local\\FluentGesture.Instance");
  if (instance_mutex && GetLastError() == ERROR_ALREADY_EXISTS) {
    // A second launch only opens the first instance, never registers more input.
    for (int attempt = 0; attempt < 200; ++attempt) {
      HWND existing = FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"FluentGesture");
      if (existing && GetPropW(existing, L"FluentGesture.Ready")) {
        DWORD process = 0; GetWindowThreadProcessId(existing, &process);
        AllowSetForegroundWindow(process); PostMessage(existing, WM_APP + 42, 0, 0); break;
      }
      Sleep(100);
    }
    CloseHandle(instance_mutex); ::CoUninitialize(); return EXIT_SUCCESS;
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 900);
  if (!window.Create(L"FluentGesture", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  window.Destroy();
  ::CoUninitialize();
  if (instance_mutex) CloseHandle(instance_mutex);
  return EXIT_SUCCESS;
}
