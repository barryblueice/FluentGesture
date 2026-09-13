#include "touchpad_input.h"
#include <flutter/standard_method_codec.h>
#include <algorithm>
#include <cstddef>
#include <set>
#include <string>

namespace {
using Value = flutter::EncodableValue;
using Map = flutter::EncodableMap;
using List = flutter::EncodableList;
bool HasUsage(const HIDP_VALUE_CAPS& cap, USAGE page, USAGE usage) {
  return cap.UsagePage == page && (cap.IsRange
      ? cap.Range.UsageMin <= usage && usage <= cap.Range.UsageMax
      : cap.NotRange.Usage == usage);
}
bool HasButton(const HIDP_BUTTON_CAPS& cap, USAGE page, USAGE usage) {
  return cap.UsagePage == page && (cap.IsRange
      ? cap.Range.UsageMin <= usage && usage <= cap.Range.UsageMax
      : cap.NotRange.Usage == usage);
}
}

TouchpadInput::TouchpadInput(HWND window, flutter::BinaryMessenger* messenger)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<Value>>(
      messenger, "dev.fluentgesture/input", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "start") {
      RAWINPUTDEVICE device{0x0D, 0x05, RIDEV_DEVNOTIFY, window_};
      if (!RegisterRawInputDevices(&device, 1, sizeof(device))) {
        result->Error("registration_failed", "Raw Input error " + std::to_string(GetLastError()));
        return;
      }
      registered_ = true;
      result->Success(Value("Touchpad ready: waiting for compatible HID reports"));
    } else if (call.method_name() == "stop") {
      Stop(); result->Success();
    } else {
      result->NotImplemented();
    }
  });
}

TouchpadInput::~TouchpadInput() {
  Stop();
  channel_->SetMethodCallHandler(nullptr);
}

void TouchpadInput::Stop() {
  if (registered_) {
    RAWINPUTDEVICE device{0x0D, 0x05, RIDEV_REMOVE, nullptr};
    RegisterRawInputDevices(&device, 1, sizeof(device));
  }
  registered_ = false;
  devices_.clear();
  active_device_ = nullptr;
}

void TouchpadInput::Status(const char* message) {
  channel_->InvokeMethod("status", std::make_unique<Value>(message));
}

void TouchpadInput::Cancel() {
  for (auto& entry : devices_) {
    entry.second.pending.clear(); entry.second.expected = 0;
  }
  active_device_ = nullptr;
  channel_->InvokeMethod("cancel", nullptr);
}

void TouchpadInput::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam) {
  if (!registered_) return;
  if (message == WM_INPUT) {
    ReadInput(reinterpret_cast<HRAWINPUT>(lparam));
  } else if (message == WM_INPUT_DEVICE_CHANGE && wparam == GIDC_REMOVAL) {
    const auto handle = reinterpret_cast<HANDLE>(lparam);
    if (active_device_ == handle) Cancel();
    devices_.erase(handle);
    Status("Touchpad disconnected; reconnect a compatible device");
  } else if (message == WM_ACTIVATEAPP && !wparam) {
    Cancel();
  }
}

TouchpadInput::Device* TouchpadInput::GetDevice(HANDLE handle) {
  const auto found = devices_.find(handle);
  if (found != devices_.end()) return &found->second;
  UINT size = 0;
  if (GetRawInputDeviceInfo(handle, RIDI_PREPARSEDDATA, nullptr, &size) == UINT(-1) || size == 0 || size > 1024 * 1024) return nullptr;
  Device device;
  device.descriptor.resize(size);
  if (GetRawInputDeviceInfo(handle, RIDI_PREPARSEDDATA, device.descriptor.data(), &size) == UINT(-1)) return nullptr;
  auto data = reinterpret_cast<PHIDP_PREPARSED_DATA>(device.descriptor.data());
  HIDP_CAPS caps{};
  if (HidP_GetCaps(data, &caps) != HIDP_STATUS_SUCCESS || caps.UsagePage != 0x0D || caps.Usage != 0x05) return nullptr;
  USHORT count = caps.NumberInputValueCaps;
  device.values.resize(count);
  if (count == 0 || HidP_GetValueCaps(HidP_Input, device.values.data(), &count, data) != HIDP_STATUS_SUCCESS) return nullptr;
  device.values.resize(count);
  count = caps.NumberInputButtonCaps;
  device.buttons.resize(count);
  if (count != 0 && HidP_GetButtonCaps(HidP_Input, device.buttons.data(), &count, data) != HIDP_STATUS_SUCCESS) return nullptr;
  device.buttons.resize(count);
  Status("Receiving precision touchpad input");
  return &devices_.emplace(handle, std::move(device)).first->second;
}

void TouchpadInput::ReadInput(HRAWINPUT input) {
  UINT size = 0;
  if (GetRawInputData(input, RID_INPUT, nullptr, &size, sizeof(RAWINPUTHEADER)) == UINT(-1) || size < sizeof(RAWINPUTHEADER) || size > 1024 * 1024) return;
  std::vector<BYTE> bytes(size);
  const UINT received = GetRawInputData(input, RID_INPUT, bytes.data(), &size, sizeof(RAWINPUTHEADER));
  if (received == UINT(-1) || received != size) return;
  const auto raw = reinterpret_cast<RAWINPUT*>(bytes.data());
  constexpr size_t offset = offsetof(RAWINPUT, data) + offsetof(RAWHID, bRawData);
  if (raw->header.dwType != RIM_TYPEHID || size < offset) return;
  const auto& hid = raw->data.hid;
  if (hid.dwSizeHid == 0 || hid.dwCount > (size - offset) / hid.dwSizeHid) return;
  auto device = GetDevice(raw->header.hDevice);
  if (!device) { Status("Unsupported HID descriptor; a compatible precision touchpad is required"); return; }
  // Keep separate device sessions; never merge contacts from two touchpads.
  if (active_device_ != nullptr && active_device_ != raw->header.hDevice) Cancel();
  active_device_ = raw->header.hDevice;
  for (DWORD i = 0; i < hid.dwCount; ++i) {
    ReadReport(*device, reinterpret_cast<char*>(raw->data.hid.bRawData + i * hid.dwSizeHid), hid.dwSizeHid);
  }
}

void TouchpadInput::ReadReport(Device& device, char* report, ULONG length) {
  auto data = reinterpret_cast<PHIDP_PREPARSED_DATA>(device.descriptor.data());
  const auto report_id = static_cast<UCHAR>(report[0]);
  auto value = [&](USAGE page, USAGE usage, USHORT collection, ULONG* output, const HIDP_VALUE_CAPS** out_cap = nullptr) {
    for (const auto& cap : device.values) {
      if (cap.ReportID != report_id || cap.LinkCollection != collection || !HasUsage(cap, page, usage)) continue;
      if (out_cap) *out_cap = &cap;
      return HidP_GetUsageValue(HidP_Input, page, collection, usage, output, data, report, length) == HIDP_STATUS_SUCCESS;
    }
    return false;
  };
  auto button = [&](USAGE usage, USHORT collection, bool optional) {
    for (const auto& cap : device.buttons) {
      if (cap.ReportID != report_id || cap.LinkCollection != collection || !HasButton(cap, 0x0D, usage)) continue;
      ULONG count = HidP_MaxUsageListLength(HidP_Input, 0x0D, data);
      if (count == 0 || count > 1024) return false;
      std::vector<USAGE> usages(count);
      if (HidP_GetUsages(HidP_Input, 0x0D, collection, usages.data(), &count, data, report, length) != HIDP_STATUS_SUCCESS) return false;
      return std::find(usages.begin(), usages.begin() + count, usage) != usages.begin() + count;
    }
    return optional;
  };
  ULONG count = 0, scan = 0;
  if (!value(0x0D, 0x54, 0, &count) || !value(0x0D, 0x56, 0, &scan)) return;
  if (count > 5) { Cancel(); Status("Invalid contact count; frame discarded"); return; }
  const auto now = GetTickCount64();
  if (device.expected != 0 && (scan != device.scan || now - device.last_report > 100)) {
    Cancel();  // An incomplete hybrid frame must never lift missing fingers.
  }
  device.last_report = now;
  if (count > 0) {
    if (device.expected != 0) Cancel();
    device.pending.clear(); device.expected = count; device.scan = scan;
  } else if (device.expected == 0) {
    channel_->InvokeMethod("frame", std::make_unique<Value>(List{}));
    return;
  }
  std::set<USHORT> collections;
  for (const auto& cap : device.values) {
    if (cap.ReportID == report_id && HasUsage(cap, 0x0D, 0x51)) collections.insert(cap.LinkCollection);
  }
  for (const auto collection : collections) {
    if (device.pending.size() >= device.expected) break;
    ULONG id = 0, x = 0, y = 0;
    const HIDP_VALUE_CAPS* xcap = nullptr;
    const HIDP_VALUE_CAPS* ycap = nullptr;
    if (!value(0x0D, 0x51, collection, &id) ||
        !value(0x01, 0x30, collection, &x, &xcap) ||
        !value(0x01, 0x31, collection, &y, &ycap)) { Cancel(); return; }
    if (xcap->LogicalMax <= xcap->LogicalMin || ycap->LogicalMax <= ycap->LogicalMin) { Cancel(); return; }
    if (std::any_of(device.pending.begin(), device.pending.end(), [id](const Contact& c) { return c.id == id; })) { Cancel(); return; }
    auto coordinate = [](ULONG raw, const HIDP_VALUE_CAPS& cap) {
      // Sign-extend signed HID values before applying the descriptor range.
      int64_t v = raw;
      if (cap.LogicalMin < 0 && cap.BitSize > 0 && cap.BitSize <= 32) {
        const int64_t sign = int64_t{1} << (cap.BitSize - 1);
        v = (v ^ sign) - sign;
      }
      return std::clamp((static_cast<double>(v) - cap.LogicalMin) /
          (static_cast<double>(cap.LogicalMax) - cap.LogicalMin), 0.0, 1.0);
    };
    device.pending.push_back(Contact{id, coordinate(x, *xcap), coordinate(y, *ycap),
        button(0x42, collection, false) && button(0x47, collection, true)});
  }
  if (device.pending.size() == device.expected) {
    List contacts;
    for (const auto& contact : device.pending) {
      if (contact.active) contacts.emplace_back(Map{
          {Value("id"), Value(static_cast<int64_t>(contact.id))},
          {Value("x"), Value(contact.x)}, {Value("y"), Value(contact.y)}});
    }
    channel_->InvokeMethod("frame", std::make_unique<Value>(contacts));
    device.pending.clear(); device.expected = 0;
  }
}
