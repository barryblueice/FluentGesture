#ifndef RUNNER_TOUCHPAD_INPUT_H_
#define RUNNER_TOUCHPAD_INPUT_H_

#include <windows.h>
#include <hidsdi.h>
#include <hidpi.h>
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <map>
#include <memory>
#include <vector>

// HID descriptors determine report layout; no device-specific byte offsets.
class TouchpadInput {
 public:
  TouchpadInput(HWND window, flutter::BinaryMessenger* messenger);
  ~TouchpadInput();
  void HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);

 private:
  struct Contact { ULONG id; double x; double y; bool active; };
  struct Device {
    std::vector<BYTE> descriptor;
    std::vector<HIDP_VALUE_CAPS> values;
    std::vector<HIDP_BUTTON_CAPS> buttons;
    std::vector<Contact> pending;
    ULONG expected = 0;
    ULONG scan = 0;
    ULONGLONG last_report = 0;
  };
  Device* GetDevice(HANDLE handle);
  void ReadInput(HRAWINPUT input);
  void ReadReport(Device& device, char* report, ULONG length);
  void Cancel();
  void Stop();
  void Status(const char* message);
  HWND window_;
  bool registered_ = false;
  HANDLE active_device_ = nullptr;
  std::map<HANDLE, Device> devices_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};
#endif
