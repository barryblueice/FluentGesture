// Test-only Windows host: real Flutter AXTree, no background input or actions.
#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <flutter_windows.h>
#include <io.h>

#include <cstdio>
#include <memory>
#include <thread>
#include "runner/win32_window.h"
#include "runner/utils.h"
#include "runner/shortcut_capture.h"

class AccessibilityTestWindow : public Win32Window {
 public:
  explicit AccessibilityTestWindow(const flutter::DartProject& project)
      : project_(project) {}

 protected:
  bool OnCreate() override {
    if (!Win32Window::OnCreate()) return false;
    const RECT frame = GetClientArea();
    controller_ = std::make_unique<flutter::FlutterViewController>(
        frame.right - frame.left, frame.bottom - frame.top, project_);
    if (!controller_->engine() || !controller_->view()) return false;
    shortcut_ = std::make_unique<ShortcutCapture>(GetHandle(), controller_->engine()->messenger());
    channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
        controller_->engine()->messenger(), "fluentgesture/ax-test",
        &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler([this](const auto& call, auto result) {
      if (call.method_name() == "mark" && call.arguments()) {
        if (const auto* text = std::get_if<std::string>(call.arguments())) {
          std::fprintf(stderr, "AXSTEP: %s\n", text->c_str());
        }
        result->Success();
      } else if (call.method_name() == "focus") {
        const DWORD foreground_thread = GetWindowThreadProcessId(GetForegroundWindow(), nullptr);
        const DWORD thread = GetCurrentThreadId();
        const bool attached = foreground_thread != thread && AttachThreadInput(thread, foreground_thread, TRUE);
        Show(); SetForegroundWindow(GetHandle());
        if (attached) AttachThreadInput(thread, foreground_thread, FALSE);
        result->Success(flutter::EncodableValue(GetForegroundWindow() == GetHandle()));
      } else if (call.method_name() == "foreground") {
        result->Success(flutter::EncodableValue(GetForegroundWindow() == GetHandle()));
      } else if (call.method_name() == "recordWinTest") {
        if (!shortcut_->IsRecording() || GetForegroundWindow() != GetHandle()) {
          result->Error("not_recording", shortcut_->IsRecording() ? "Test window lost foreground" : "Test recording hook is not armed"); return;
        }
        const auto* variant = call.arguments() ? std::get_if<int32_t>(call.arguments()) : nullptr;
        if (!variant || *variant < 0 || *variant > 3) { result->Error("invalid", "Invalid test case"); return; }
        // Test-only, fixed combinations. The active recording hook consumes
        // every event; no production action executor exists in this host.
        const WORD win = *variant % 2 == 0 ? VK_LWIN : VK_RWIN;
        std::vector<WORD> keys{win};
        if (*variant >= 2) keys.push_back(VK_F13);
        std::vector<INPUT> input;
        for (WORD key : keys) {
          INPUT event{}; event.type = INPUT_KEYBOARD; event.ki.wVk = key;
          event.ki.dwFlags = key == VK_LWIN || key == VK_RWIN ? KEYEVENTF_EXTENDEDKEY : 0;
          input.push_back(event);
        }
        for (auto it = keys.rbegin(); it != keys.rend(); ++it) {
          INPUT event{}; event.type = INPUT_KEYBOARD; event.ki.wVk = *it;
          event.ki.dwFlags = KEYEVENTF_KEYUP | (*it == VK_LWIN || *it == VK_RWIN ? KEYEVENTF_EXTENDEDKEY : 0);
          input.push_back(event);
        }
        if (input_thread_.joinable() || input_result_) {
          result->Error("busy", "A test input is pending"); return;
        }
        input_result_ = std::move(result);
        // The hook runs on the window thread. Inject from another thread so
        // SendInput cannot block that thread's low-level keyboard hook pump.
        input_thread_ = std::thread([hwnd = GetHandle(), input = std::move(input)]() mutable {
          const UINT count = static_cast<UINT>(input.size());
          const bool ok = SendInput(count, input.data(), sizeof(INPUT)) == count;
          PostMessageW(hwnd, kInputComplete, ok, 0);
        });
      } else {
        result->NotImplemented();
      }
    });
    const HWND child = controller_->view()->GetNativeWindow();
    SetChildContent(child);
    // This is the same request sent by Windows screen readers. It enables
    // the native accessibility bridge, not just framework semantics.
    SendMessage(child, WM_GETOBJECT, 0, static_cast<LPARAM>(OBJID_CLIENT));
    std::fprintf(stderr, "AXTEST: native accessibility requested\n");
    controller_->engine()->SetNextFrameCallback([this]() { Show(); });
    controller_->ForceRedraw();
    return true;
  }

  void OnDestroy() override {
    if (input_thread_.joinable()) input_thread_.join();
    input_result_.reset();
    shortcut_.reset();
    channel_.reset();
    controller_.reset();
    Win32Window::OnDestroy();
  }

  LRESULT MessageHandler(HWND hwnd, UINT message, WPARAM wp,
                         LPARAM lp) noexcept override {
    if (message == WM_ACTIVATEAPP || message == WM_POWERBROADCAST || message == WM_WTSSESSION_CHANGE) {
      std::fprintf(stderr, "AXHOST: message=%u wp=%llu foreground=%d\n", message,
          static_cast<unsigned long long>(wp), GetForegroundWindow() == GetHandle());
    }
    if (shortcut_) shortcut_->HandleMessage(message, wp);
    if (message == kInputComplete) {
      if (input_thread_.joinable()) input_thread_.join();
      if (input_result_) {
        if (wp) input_result_->Success();
        else input_result_->Error("input_failed", "Test input failed");
        input_result_.reset();
      }
      return 0;
    }
    if (controller_) {
      const auto result = controller_->HandleTopLevelWindowProc(hwnd, message, wp, lp);
      if (result) return *result;
    }
    return Win32Window::MessageHandler(hwnd, message, wp, lp);
  }

 private:
  static constexpr UINT kInputComplete = WM_APP + 91;
  std::thread input_thread_;
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> input_result_;
  const flutter::DartProject& project_;
  std::unique_ptr<flutter::FlutterViewController> controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::unique_ptr<ShortcutCapture> shortcut_;
};

int APIENTRY wWinMain(HINSTANCE, HINSTANCE, wchar_t*, int) {
  if (!AttachConsole(ATTACH_PARENT_PROCESS) && IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }
  wchar_t path[MAX_PATH];
  GetModuleFileNameW(nullptr, path, MAX_PATH);
  std::wstring log_path(path);
  log_path = log_path.substr(0, log_path.find_last_of(L"\\/") + 1) +
      L"accessibility-native.log";
  FILE* log = nullptr;
  _wfreopen_s(&log, log_path.c_str(), L"w", stderr);
  SetStdHandle(STD_ERROR_HANDLE,
      reinterpret_cast<HANDLE>(_get_osfhandle(_fileno(stderr))));
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  flutter::DartProject project(L"data");
  project.set_dart_entrypoint_arguments(GetCommandLineArguments());
  AccessibilityTestWindow window(project);
  if (!window.Create(L"FluentGesture Accessibility Test", {40, 40}, {1280, 1000})) {
    CoUninitialize();
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);
  MSG message;
  while (GetMessage(&message, nullptr, 0, 0)) {
    TranslateMessage(&message);
    DispatchMessage(&message);
  }
  window.Destroy();
  CoUninitialize();
  return EXIT_SUCCESS;
}
