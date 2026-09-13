#pragma once
#include <windows.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <deque>
#include <memory>
#include "shortcut_keys.h"

class ShortcutCapture {
 public:
  ShortcutCapture(HWND window, flutter::BinaryMessenger* messenger);
  ~ShortcutCapture();
  void HandleMessage(UINT message, WPARAM wp);
  bool IsRecording() const { return hook_ != nullptr && state_.armed; }
 private:
  static LRESULT CALLBACK Hook(int code, WPARAM wp, LPARAM lp);
  void Stop();
  void Cancel();
  void Queue(bool cancelled = false);
  HWND window_;
  HHOOK hook_ = nullptr;
  int64_t generation_ = 0;
  ShortcutKeys state_;
  std::deque<flutter::EncodableValue> events_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};
