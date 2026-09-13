#include "shortcut_capture.h"
#include <flutter/standard_method_codec.h>

namespace {
using V = flutter::EncodableValue;
using M = flutter::EncodableMap;
using L = flutter::EncodableList;
constexpr UINT kShortcutEvent = WM_APP + 65;
ShortcutCapture* active = nullptr;
}

ShortcutCapture::ShortcutCapture(HWND window, flutter::BinaryMessenger* messenger)
    : window_(window) {
  active = this;
  channel_ = std::make_unique<flutter::MethodChannel<V>>(
      messenger, "dev.fluentgesture/shortcut", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "end") {
      Stop(); result->Success(); return;
    }
    if (call.method_name() != "begin") { result->NotImplemented(); return; }
    Stop();
    if (!call.arguments() || !std::holds_alternative<int32_t>(*call.arguments())) {
      result->Error("invalid", "录制会话无效"); return;
    }
    generation_ = std::get<int32_t>(*call.arguments());
    if (GetForegroundWindow() != window_) {
      result->Error("inactive", "请先激活录制窗口"); return;
    }
    for (int key = 8; key <= 254; ++key) {
      if (GetAsyncKeyState(key) & 0x8000) {
        result->Error("keys_held", "请松开按键后点击重新录制"); return;
      }
    }
    state_ = ShortcutKeys{};
    hook_ = SetWindowsHookExW(WH_KEYBOARD_LL, Hook, GetModuleHandleW(nullptr), 0);
    if (!hook_) { result->Error("hook_failed", "无法启动 Windows 快捷键录制"); return; }
    result->Success(V(true));
  });
}

ShortcutCapture::~ShortcutCapture() {
  Stop();
  channel_->SetMethodCallHandler(nullptr);
  active = nullptr;
}
void ShortcutCapture::Stop() {
  if (hook_) { UnhookWindowsHookEx(hook_); hook_ = nullptr; }
  state_ = ShortcutKeys{};
  events_.clear();
}
void ShortcutCapture::Queue(bool cancelled) {
  L keys;
  for (int key : state_.keys) keys.emplace_back(key);
  // Keep hook work bounded; the window message sends the latest snapshot.
  events_.clear();
  events_.emplace_back(M{{V("generation"), V(generation_)}, {V("keys"), V(keys)},
      {V("complete"), V(state_.complete && state_.down.empty())},
      {V("cancelled"), V(cancelled)}});
  PostMessageW(window_, kShortcutEvent, 0, 0);
}
void ShortcutCapture::Cancel() {
  if (!hook_) return;
  Stop(); Queue(true);
}
LRESULT CALLBACK ShortcutCapture::Hook(int code, WPARAM wp, LPARAM lp) {
  if (code < 0 || !active || !active->hook_) return CallNextHookEx(nullptr, code, wp, lp);
  if (GetForegroundWindow() != active->window_) {
    active->Cancel();
    return CallNextHookEx(nullptr, code, wp, lp);
  }
  if (wp != WM_KEYDOWN && wp != WM_SYSKEYDOWN && wp != WM_KEYUP && wp != WM_SYSKEYUP) {
    return CallNextHookEx(nullptr, code, wp, lp);
  }
  const auto* key = reinterpret_cast<KBDLLHOOKSTRUCT*>(lp);
  const bool pressed = wp == WM_KEYDOWN || wp == WM_SYSKEYDOWN;
  if (!active->state_.Feed(static_cast<int>(key->vkCode), pressed)) {
    return CallNextHookEx(nullptr, code, wp, lp);
  }
  active->Queue();
  return 1;
}
void ShortcutCapture::HandleMessage(UINT message, WPARAM wp) {
  if (message == kShortcutEvent) {
    while (!events_.empty()) {
      auto event = std::make_unique<V>(events_.front()); events_.pop_front();
      channel_->InvokeMethod("keys", std::move(event));
    }
  }
  if ((message == WM_ACTIVATEAPP && !wp) || message == WM_CLOSE ||
      message == WM_POWERBROADCAST || message == WM_WTSSESSION_CHANGE) Cancel();
}
