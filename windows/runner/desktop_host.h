#ifndef RUNNER_DESKTOP_HOST_H_
#define RUNNER_DESKTOP_HOST_H_
#include <windows.h>
#include <shellapi.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <functional>
#include <memory>
#include <string>

class DesktopHost {
 public:
  using Value = flutter::EncodableValue;
  DesktopHost(HWND window, flutter::BinaryMessenger* messenger);
  ~DesktopHost();
  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);
  bool StartHidden() const;
  std::unique_ptr<Value> Frame(const flutter::EncodableList& contacts, HANDLE device);
  void CancelSession();
  std::function<void(const std::string&)> on_cancel;
 private:
  static void CALLBACK ForegroundChanged(HWINEVENTHOOK, DWORD, HWND, LONG, LONG, DWORD, DWORD);
  void Invalidate(const std::string& reason);
  bool AddTray();
  void UpdateTray();
  void Open(bool settings = false);
  void SetPaused(bool value);
  Value Execute(const flutter::EncodableMap& args);
  HWND window_;
  NOTIFYICONDATAW tray_{};
  bool tray_ready_ = false, paused_ = false, blocked_ = false;
  bool session_blocked_ = false, power_blocked_ = false;
  bool touching_ = false, wait_release_ = false, valid_ = false, consumed_ = true;
  std::string mode_ = "monitor", device_;
  int64_t session_ = 0;
  HWND target_ = nullptr;
  DWORD target_pid_ = 0;
  std::wstring target_path_;
  ULONGLONG started_ = 0, last_frame_ = 0, completed_ = 0;
  HWINEVENTHOOK foreground_hook_ = nullptr;
  UINT taskbar_created_ = 0;
  std::unique_ptr<flutter::MethodChannel<Value>> channel_;
};
#endif
