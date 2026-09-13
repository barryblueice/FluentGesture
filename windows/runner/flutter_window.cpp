#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  shortcut_capture_ = std::make_unique<ShortcutCapture>(GetHandle(), flutter_controller_->engine()->messenger());
  desktop_ = std::make_unique<DesktopHost>(GetHandle(), flutter_controller_->engine()->messenger());
  touchpad_input_ = std::make_unique<TouchpadInput>(
      GetHandle(), flutter_controller_->engine()->messenger(), *desktop_);
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    if (!desktop_->StartHidden()) this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  // The HWND exists before the engine and desktop message handler are ready.
  SetPropW(GetHandle(), L"FluentGesture.Ready", reinterpret_cast<HANDLE>(1));

  return true;
}

void FlutterWindow::OnDestroy() {
  RemovePropW(GetHandle(), L"FluentGesture.Ready");
  shortcut_capture_.reset();
  touchpad_input_.reset();
  desktop_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (shortcut_capture_) shortcut_capture_->HandleMessage(message, wparam);
  if (message == WM_GETMINMAXINFO) {
    auto bounds = reinterpret_cast<MINMAXINFO*>(lparam);
    const auto dpi = GetDpiForWindow(hwnd);
    bounds->ptMinTrackSize = {MulDiv(540, dpi, 96), MulDiv(480, dpi, 96)};
    return 0;
  }
  if (desktop_ && desktop_->HandleMessage(message, wparam, lparam)) return 0;
  if (touchpad_input_) {
    touchpad_input_->HandleMessage(message, wparam, lparam);
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
