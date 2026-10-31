#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  HANDLE singleton = CreateMutexW(nullptr, TRUE, L"Local\\ClipyClone.MainWindow");
  if (!singleton) return EXIT_FAILURE;
  if (GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND existing = FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"ClipyClone");
    if (existing) {
      // The owner restores normal geometry and Flutter content together.
      // ShowWindow alone can expose the full app in a frameless tray rectangle.
      PostMessageW(existing, RegisterWindowMessageW(L"ClipyClone.OpenMainWindow"), 0, 0);
    }
    CloseHandle(singleton);
    return EXIT_SUCCESS;
  }
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  const bool start_hidden = std::wstring(command_line).find(L"--startup") != std::wstring::npos;
  FlutterWindow window(project, start_hidden);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1088, 680);
  if (!window.Create(L"ClipyClone", origin, size)) {
    ::CoUninitialize();
    CloseHandle(singleton);
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  CloseHandle(singleton);
  return EXIT_SUCCESS;
}
