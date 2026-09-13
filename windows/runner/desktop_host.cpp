#include "desktop_host.h"
#include "scroll_spec.h"
#include "resource.h"
#include "execution_guard.h"
#include <flutter/standard_method_codec.h>
#include <shobjidl.h>
#include <wtsapi32.h>
#include <mmdeviceapi.h>
#include <endpointvolume.h>
#include <wrl/client.h>
#include <algorithm>
#include <set>
#include <vector>

namespace {
using V = flutter::EncodableValue;
using M = flutter::EncodableMap;
using L = flutter::EncodableList;
using Microsoft::WRL::ComPtr;
constexpr UINT kTrayMessage = WM_APP + 41;
constexpr UINT_PTR kTimer = 9041;
constexpr UINT kOpenCommand = 40001, kPauseCommand = 40002, kExitCommand = 40003;
DesktopHost* host = nullptr;
std::string Utf8(const std::wstring& text) {
  if (text.empty()) return {};
  int size = WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
  std::string result(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), result.data(), size, nullptr, nullptr);
  return result;
}
std::wstring Wide(const std::string& text) {
  if (text.empty()) return {};
  int size = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), nullptr, 0);
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()), result.data(), size);
  return result;
}
const V* Field(const M& map, const char* key) { auto it = map.find(V(key)); return it == map.end() ? nullptr : &it->second; }
std::string Text(const M& map, const char* key) { auto v = Field(map, key); return v && std::holds_alternative<std::string>(*v) ? std::get<std::string>(*v) : ""; }
int64_t Number(const M& map, const char* key, int64_t fallback = 0) {
  auto v = Field(map, key); if (!v) return fallback;
  if (std::holds_alternative<int32_t>(*v)) return std::get<int32_t>(*v);
  if (std::holds_alternative<int64_t>(*v)) return std::get<int64_t>(*v);
  return fallback;
}
V Outcome(bool success, const std::string& message) { return V(M{{V("success"), V(success)}, {V("message"), V(message)}}); }
std::wstring ProcessPath(HWND window, DWORD* process = nullptr) {
  DWORD pid = 0; GetWindowThreadProcessId(window, &pid);
  if (process) *process = pid;
  HANDLE handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!handle) return {};
  std::wstring result(32768, L'\0'); DWORD size = static_cast<DWORD>(result.size());
  bool ok = QueryFullProcessImageNameW(handle, 0, result.data(), &size) != FALSE;
  CloseHandle(handle);
  if (!ok) return {};
  result.resize(size); return result;
}
std::wstring ExecutablePath() {
  std::wstring path(32768, L'\0');
  DWORD length = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
  path.resize(length); return path;
}
bool AbsoluteExe(const std::wstring& path) {
  if (path.size() < 7 || path.find(L'"') != std::wstring::npos || path.find(L'\0') != std::wstring::npos) return false;
  bool absolute = (path.size() > 3 && path[1] == L':' && (path[2] == L'\\' || path[2] == L'/')) || path.rfind(L"\\\\", 0) == 0;
  DWORD attr = GetFileAttributesW(path.c_str());
  return absolute && _wcsicmp(path.c_str() + path.size() - 4, L".exe") == 0 && attr != INVALID_FILE_ATTRIBUTES && !(attr & FILE_ATTRIBUTE_DIRECTORY);
}
bool SetStartup(bool enabled, std::string* error) {
  HKEY key = nullptr;
  LONG status = RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Run", 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key, nullptr);
  if (status != ERROR_SUCCESS) { *error = "无法打开登录启动设置：" + std::to_string(status); return false; }
  if (enabled) {
    std::wstring command = L"\"" + ExecutablePath() + L"\" --startup";
    status = RegSetValueExW(key, L"FluentGesture", 0, REG_SZ, reinterpret_cast<const BYTE*>(command.c_str()), static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
  } else { status = RegDeleteValueW(key, L"FluentGesture"); if (status == ERROR_FILE_NOT_FOUND) status = ERROR_SUCCESS; }
  RegCloseKey(key);
  if (status != ERROR_SUCCESS) *error = "无法保存登录启动设置：" + std::to_string(status);
  return status == ERROR_SUCCESS;
}
V SendKeys(const std::vector<WORD>& keys) {
  if (keys.empty() || keys.size() > 8) return Outcome(false, "快捷键无效");
  // Never release physical modifiers held by the user or combine unexpected ones.
  for (int key : {VK_SHIFT, VK_CONTROL, VK_MENU, VK_LWIN, VK_RWIN}) {
    if (GetAsyncKeyState(key) & 0x8000) return Outcome(false, "请松开键盘修饰键后重试");
  }
  std::vector<INPUT> inputs;
  auto append = [&](WORD key, bool up) {
    INPUT input{}; input.type = INPUT_KEYBOARD; input.ki.wVk = key;
    input.ki.dwFlags = up ? KEYEVENTF_KEYUP : 0;
    if (key == VK_LWIN || key == VK_RWIN || (key >= VK_PRIOR && key <= VK_DOWN) || key == VK_INSERT || key == VK_DELETE) input.ki.dwFlags |= KEYEVENTF_EXTENDEDKEY;
    inputs.push_back(input);
  };
  for (auto key : keys) append(key, false);
  for (auto it = keys.rbegin(); it != keys.rend(); ++it) append(*it, true);
  const UINT sent = SendInput(static_cast<UINT>(inputs.size()), inputs.data(), sizeof(INPUT));
  if (sent != inputs.size()) {
    if (sent > 0) {
      std::vector<INPUT> releases;
      for (const auto& input : inputs) if (input.ki.dwFlags & KEYEVENTF_KEYUP) releases.push_back(input);
      SendInput(static_cast<UINT>(releases.size()), releases.data(), sizeof(INPUT));
    }
    return Outcome(false, "快捷键未完整发送；目标可能权限更高或阻止了输入");
  }
  return Outcome(true, "已发送快捷键");
}
V Volume(const std::string& kind, int step) {
  ComPtr<IMMDeviceEnumerator> enumerator;
  ComPtr<IMMDevice> device;
  ComPtr<IAudioEndpointVolume> volume;
  HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator));
  if (SUCCEEDED(hr)) hr = enumerator->GetDefaultAudioEndpoint(eRender, eMultimedia, &device);
  if (SUCCEEDED(hr)) hr = device->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_ALL, nullptr, reinterpret_cast<void**>(volume.GetAddressOf()));
  if (FAILED(hr)) return Outcome(false, "无法访问默认音频输出设备");
  if (kind == "mute") { BOOL muted = FALSE; hr = volume->GetMute(&muted); if (SUCCEEDED(hr)) hr = volume->SetMute(!muted, nullptr); }
  else {
    if (step < 1 || step > 100) return Outcome(false, "音量步长无效");
    float value = 0; hr = volume->GetMasterVolumeLevelScalar(&value);
    if (SUCCEEDED(hr)) hr = volume->SetMasterVolumeLevelScalar(std::clamp(value + (kind == "volumeUp" ? step : -step) / 100.0f, 0.0f, 1.0f), nullptr);
  }
  return Outcome(SUCCEEDED(hr), SUCCEEDED(hr) ? "已调整系统音量" : "调整音量失败");
}
}

DesktopHost::DesktopHost(HWND window, flutter::BinaryMessenger* messenger) : window_(window) {
  host = this;
  channel_ = std::make_unique<flutter::MethodChannel<V>>(messenger, "dev.fluentgesture/desktop", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const auto& method = call.method_name();
    if (method == "execute") {
      if (!call.arguments() || !std::holds_alternative<M>(*call.arguments())) { result->Error("invalid", "动作参数无效"); return; }
      result->Success(Execute(std::get<M>(*call.arguments()))); return;
    }
    if (method == "setMode") {
      if (!call.arguments() || !std::holds_alternative<std::string>(*call.arguments())) { result->Error("invalid", "模式无效"); return; }
      auto mode = std::get<std::string>(*call.arguments());
      if (mode != "monitor" && mode != "edit" && mode != "test") { result->Error("invalid", "模式无效"); return; }
      mode_ = mode; Invalidate("运行模式已切换"); UpdateTray(); result->Success(); return;
    }
    if (method == "setPaused" || method == "setStartAtLogin") {
      if (!call.arguments() || !std::holds_alternative<bool>(*call.arguments())) { result->Error("invalid", "设置参数无效"); return; }
      bool value = std::get<bool>(*call.arguments());
      if (method == "setPaused") SetPaused(value);
      else { std::string error; if (!SetStartup(value, &error)) { result->Error("startup_failed", error); return; } }
      result->Success(); return;
    }
    if (method == "quit") {
      Invalidate("程序退出"); result->Success(); PostQuitMessage(0); return;
    }
    if (method == "hide") {
      if (!tray_ready_) { result->Error("tray_unavailable", "托盘不可用，窗口将保持打开"); return; }
      ShowWindow(window_, SW_HIDE); result->Success(); return;
    }
    if (method == "openTouchpadSettings") {
      auto status = reinterpret_cast<INT_PTR>(ShellExecuteW(window_, L"open", L"ms-settings:devices-touchpad", nullptr, nullptr, SW_SHOWNORMAL));
      if (status <= 32) result->Error("settings_failed", "无法打开 Windows 触摸板设置"); else result->Success(); return;
    }
    if (method == "pickProgram") {
      ComPtr<IFileOpenDialog> dialog;
      HRESULT hr = CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog));
      if (SUCCEEDED(hr)) {
        COMDLG_FILTERSPEC filter{L"应用程序 (*.exe)", L"*.exe"};
        dialog->SetFileTypes(1, &filter);
        dialog->SetOptions(FOS_FILEMUSTEXIST | FOS_PATHMUSTEXIST | FOS_FORCEFILESYSTEM);
        hr = dialog->Show(window_);
      }
      if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) { result->Success(); return; }
      ComPtr<IShellItem> item; PWSTR path = nullptr;
      if (SUCCEEDED(hr)) hr = dialog->GetResult(&item);
      if (SUCCEEDED(hr)) hr = item->GetDisplayName(SIGDN_FILESYSPATH, &path);
      if (FAILED(hr)) { result->Error("picker_failed", "无法选择程序"); return; }
      result->Success(V(Utf8(path))); CoTaskMemFree(path); return;
    }
    if (method == "applications") {
      L applications;
      EnumWindows([](HWND window, LPARAM data) -> BOOL {
        if (!IsWindowVisible(window) || GetWindowTextLengthW(window) == 0) return TRUE;
        DWORD pid = 0; auto path = ProcessPath(window, &pid);
        if (path.empty() || pid == GetCurrentProcessId()) return TRUE;
        wchar_t title[512]{}; GetWindowTextW(window, title, 512);
        auto list = reinterpret_cast<L*>(data);
        list->emplace_back(M{{V("path"), V(Utf8(path))}, {V("title"), V(Utf8(title))}});
        return TRUE;
      }, reinterpret_cast<LPARAM>(&applications));
      result->Success(V(applications)); return;
    }
    result->NotImplemented();
  });
  taskbar_created_ = RegisterWindowMessageW(L"TaskbarCreated");
  AddTray();
  WTSRegisterSessionNotification(window_, NOTIFY_FOR_THIS_SESSION);
  foreground_hook_ = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, nullptr, ForegroundChanged, 0, 0, WINEVENT_OUTOFCONTEXT);
  SetTimer(window_, kTimer, 100, nullptr);
}

DesktopHost::~DesktopHost() {
  KillTimer(window_, kTimer); WTSUnRegisterSessionNotification(window_);
  if (foreground_hook_) UnhookWinEvent(foreground_hook_);
  Shell_NotifyIconW(NIM_DELETE, &tray_);
  channel_->SetMethodCallHandler(nullptr); host = nullptr;
}
bool DesktopHost::StartHidden() const { return tray_ready_ && wcsstr(GetCommandLineW(), L"--startup") != nullptr; }
bool DesktopHost::AddTray() {
  tray_ = {}; tray_.cbSize = sizeof(tray_); tray_.hWnd = window_; tray_.uID = 1;
  tray_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP; tray_.uCallbackMessage = kTrayMessage;
  tray_.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(tray_.szTip, L"FluentGesture");
  tray_ready_ = Shell_NotifyIconW(NIM_ADD, &tray_) != FALSE;
  if (tray_ready_) { tray_.uVersion = NOTIFYICON_VERSION_4; Shell_NotifyIconW(NIM_SETVERSION, &tray_); UpdateTray(); }
  return tray_ready_;
}
void DesktopHost::UpdateTray() {
  if (!tray_ready_) return;
  wcscpy_s(tray_.szTip, paused_ ? L"FluentGesture — 已暂停" : mode_ == "monitor" ? L"FluentGesture — 后台手势已启用" : L"FluentGesture — 编辑 / 测试中，动作已暂停");
  tray_.uFlags = NIF_TIP; Shell_NotifyIconW(NIM_MODIFY, &tray_);
}
void DesktopHost::Open(bool settings) {
  const int command = IsIconic(window_) ? SW_RESTORE : SW_SHOW;
  ShowWindow(window_, command);
  // On the first ShowWindow call Windows can honor the launcher's SW_HIDE
  // instead of our command (e.g. a hidden login-startup process).
  if (!IsWindowVisible(window_)) ShowWindow(window_, command);
  SetForegroundWindow(window_);
  if (settings) channel_->InvokeMethod("openSettings", nullptr);
}
void DesktopHost::SetPaused(bool value) {
  paused_ = value; Invalidate(value ? "后台手势已暂停" : "后台手势已恢复"); UpdateTray();
  channel_->InvokeMethod("paused", std::make_unique<V>(value));
}
void DesktopHost::CancelSession() {
  wait_release_ = wait_release_ || touching_; touching_ = false;
  valid_ = false; consumed_ = true; ++session_;
}
void DesktopHost::Invalidate(const std::string& reason) { CancelSession(); if (on_cancel) on_cancel(reason); }
void CALLBACK DesktopHost::ForegroundChanged(HWINEVENTHOOK, DWORD, HWND window, LONG, LONG, DWORD, DWORD) {
  if (host && host->target_ != window) {
    host->valid_ = false;
  }
}
bool DesktopHost::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == taskbar_created_) { if (!AddTray()) Open(); return true; }
  if (message == WM_CLOSE) {
    if (tray_ready_) channel_->InvokeMethod("closeRequested", nullptr);
    else channel_->InvokeMethod("status", std::make_unique<V>("托盘不可用，窗口保持打开；可在设置中退出程序"));
    return true;
  }
  if (message == WM_APP + 42) { Open(); return true; }
  if (message == WM_COMMAND && HIWORD(wparam) == 0 && lparam == 0) {
    switch (LOWORD(wparam)) {
      case kOpenCommand: Open(true); return true;
      case kPauseCommand: SetPaused(!paused_); return true;
      case kExitCommand: Open(); channel_->InvokeMethod("exitRequested", nullptr); return true;
    }
  }
  if (message == WM_TIMER && wparam == kTimer) {
    if (touching_ && GetTickCount64() - last_frame_ > 700) Invalidate("触摸板数据中断，本次手势已取消");
    return true;
  }
  if (message == WM_WTSSESSION_CHANGE) {
    if (wparam == WTS_SESSION_LOCK || wparam == WTS_SESSION_LOGOFF || wparam == WTS_REMOTE_DISCONNECT || wparam == WTS_CONSOLE_DISCONNECT) { session_blocked_ = true; blocked_ = true; Invalidate("会话已锁定或断开"); }
    if (wparam == WTS_SESSION_UNLOCK || wparam == WTS_CONSOLE_CONNECT || wparam == WTS_REMOTE_CONNECT) { session_blocked_ = false; blocked_ = power_blocked_; Invalidate("会话恢复，等待新的手势"); }
  }
  if (message == WM_POWERBROADCAST) {
    if (wparam == PBT_APMSUSPEND) { power_blocked_ = true; blocked_ = true; Invalidate("系统休眠，手势已取消"); }
    if (wparam == PBT_APMRESUMEAUTOMATIC || wparam == PBT_APMRESUMESUSPEND) { power_blocked_ = false; blocked_ = session_blocked_; Invalidate("系统恢复，等待新的手势"); }
  }
  if (message == kTrayMessage) {
    auto event = LOWORD(lparam);
    if (event == NIN_SELECT || event == WM_LBUTTONDBLCLK) Open();
    if (event == WM_CONTEXTMENU || event == WM_RBUTTONUP) {
      HMENU menu = CreatePopupMenu();
      AppendMenuW(menu, MF_STRING, kOpenCommand, L"打开设置");
      AppendMenuW(menu, MF_STRING, kPauseCommand, paused_ ? L"恢复手势" : L"暂停手势");
      AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
      AppendMenuW(menu, MF_STRING, kExitCommand, L"退出");
      POINT point{}; GetCursorPos(&point); SetForegroundWindow(window_);
      TrackPopupMenu(menu, TPM_RIGHTBUTTON, point.x, point.y, 0, window_, nullptr);
      DestroyMenu(menu);
      PostMessage(window_, WM_NULL, 0, 0);
    }
    return true;
  }
  return false;
}

std::unique_ptr<DesktopHost::Value> DesktopHost::Frame(const L& contacts, HANDLE device) {
  const auto now = GetTickCount64();
  const bool active = !contacts.empty();
  if (blocked_) return nullptr;
  if (wait_release_) {
    if (active) return nullptr;
    wait_release_ = false;
    // The Dart collector also waits for release after cancellation.
    return std::make_unique<V>(M{
      {V("device"), V(device_)}, {V("timeMs"), V(static_cast<int64_t>(now))},
      {V("session"), V(session_)}, {V("application"), V(Utf8(target_path_))},
      {V("isSelf"), V(target_pid_ == GetCurrentProcessId())}, {V("valid"), V(false)}, {V("contacts"), V(contacts)}});
  }
  if (active && !touching_) {
    ++session_; target_ = GetForegroundWindow(); target_path_ = ProcessPath(target_, &target_pid_);
    device_ = std::to_string(reinterpret_cast<uintptr_t>(device));
    started_ = now; completed_ = 0; valid_ = IsWindow(target_) != FALSE; consumed_ = false;
  }
  if (!active && !touching_) return nullptr;
  if (GetForegroundWindow() != target_ || now - started_ > 15000) valid_ = false;
  touching_ = active; last_frame_ = now;
  if (!active) completed_ = now;
  return std::make_unique<V>(M{
    {V("device"), V(device_)}, {V("timeMs"), V(static_cast<int64_t>(now))},
    {V("session"), V(session_)}, {V("application"), V(Utf8(target_path_))},
    {V("isSelf"), V(target_pid_ == GetCurrentProcessId())}, {V("valid"), V(valid_)}, {V("contacts"), V(contacts)}});
}

DesktopHost::Value DesktopHost::Execute(const M& args) {
  if (mode_ != "monitor" || paused_ || blocked_) return Outcome(false, "当前模式禁止执行动作");
  if (!foreground_hook_) return Outcome(false, "无法监测前台窗口变化，未执行动作");
  DWORD pid = 0; auto path = ProcessPath(target_, &pid);
  const bool unchanged = IsWindow(target_) && GetForegroundWindow() == target_ &&
      pid == target_pid_ && pid != GetCurrentProcessId() && !path.empty() && path == target_path_;
  const ExecutionSession session{session_, device_, completed_, touching_, valid_};
  if (!ConsumeExecution(session, Number(args, "session", -1), Text(args, "device"),
      GetTickCount64(), mode_ == "monitor" && !paused_ && !blocked_, unchanged, consumed_)) {
    return Outcome(false, unchanged ? "手势会话已失效或已执行" : "目标窗口已变化，未执行动作");
  }
  auto value = Field(args, "action");
  if (!value || !std::holds_alternative<M>(*value)) return Outcome(false, "动作参数无效");
  const auto& action = std::get<M>(*value); auto kind = Text(action, "kind");
  if (kind == "shortcut") {
    auto keys_value = Field(action, "keys");
    if (!keys_value || !std::holds_alternative<L>(*keys_value)) return Outcome(false, "快捷键参数无效");
    std::vector<WORD> keys;
    for (const auto& key : std::get<L>(*keys_value)) {
      int64_t number = std::holds_alternative<int32_t>(key) ? std::get<int32_t>(key) : std::holds_alternative<int64_t>(key) ? std::get<int64_t>(key) : -1;
      if (number < 8 || number > 254 || std::find(keys.begin(), keys.end(), static_cast<WORD>(number)) != keys.end()) return Outcome(false, "快捷键无效");
      keys.push_back(static_cast<WORD>(number));
    }
    return SendKeys(keys);
  }
  if (kind == "desktop") return SendKeys({VK_LWIN, 'D'});
  if (kind == "scrollLeft" || kind == "scrollRight" || kind == "scrollUp" || kind == "scrollDown") {
    const int64_t step = Number(action, "scrollStep", 3);
    if (step < 1 || step > 20) return Outcome(false, "滚动量须为 1–20 格");
    const auto spec = MakeScrollSpec(kind, static_cast<int>(step));
    if (!spec) return Outcome(false, "滚动量须为 1–20 格");
    POINT cursor{};
    if (!GetCursorPos(&cursor) || GetAncestor(WindowFromPoint(cursor), GA_ROOT) != target_) {
      return Outcome(false, "请将指针放在目标窗口的可滚动区域");
    }
    for (int key : {VK_SHIFT, VK_CONTROL, VK_MENU, VK_LWIN, VK_RWIN}) {
      if (GetAsyncKeyState(key) & 0x8000) return Outcome(false, "请松开键盘修饰键后滚动");
    }
    INPUT input{}; input.type = INPUT_MOUSE;
    input.mi.dwFlags = spec->horizontal ? MOUSEEVENTF_HWHEEL : MOUSEEVENTF_WHEEL;
    input.mi.mouseData = static_cast<DWORD>(spec->delta);
    const bool ok = SendInput(1, &input, sizeof(INPUT)) == 1;
    return Outcome(ok, ok ? "已发送滚动输入" : "滚动输入失败；目标可能权限更高或阻止了输入");
  }
  if (kind == "volumeUp" || kind == "volumeDown" || kind == "mute") return Volume(kind, static_cast<int>(Number(action, "volumeStep", 10)));
  if (kind == "launch") {
    auto program = Wide(Text(action, "program")); auto arguments = Wide(Text(action, "arguments")); auto directory = Wide(Text(action, "directory"));
    if (!AbsoluteExe(program)) return Outcome(false, "程序不存在或不是有效的 .exe 路径");
    if (!directory.empty()) { DWORD attr = GetFileAttributesW(directory.c_str()); if (attr == INVALID_FILE_ATTRIBUTES || !(attr & FILE_ATTRIBUTE_DIRECTORY)) return Outcome(false, "工作目录不存在"); }
    SHELLEXECUTEINFOW info{}; info.cbSize = sizeof(info); info.fMask = SEE_MASK_FLAG_NO_UI;
    info.hwnd = window_; info.lpVerb = L"open"; info.lpFile = program.c_str(); info.lpParameters = arguments.c_str(); info.lpDirectory = directory.empty() ? nullptr : directory.c_str(); info.nShow = SW_SHOWNORMAL;
    return ShellExecuteExW(&info) ? Outcome(true, "已启动程序") : Outcome(false, "启动失败：" + std::to_string(GetLastError()));
  }
  if (kind == "minimize" || kind == "maximize") {
    bool ok = ShowWindowAsync(target_, kind == "minimize" ? SW_MINIMIZE : IsZoomed(target_) ? SW_RESTORE : SW_MAXIMIZE) != FALSE;
    return Outcome(ok, ok ? "已提交窗口操作" : "窗口操作失败");
  }
  if (kind == "close") { bool ok = PostMessageW(target_, WM_CLOSE, 0, 0) != FALSE; return Outcome(ok, ok ? "已请求关闭窗口" : "目标窗口拒绝关闭请求"); }
  if (kind == "topmost") {
    bool topmost = (GetWindowLongPtr(target_, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0;
    bool ok = SetWindowPos(target_, topmost ? HWND_NOTOPMOST : HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE) != FALSE;
    return Outcome(ok, ok ? "已切换窗口置顶" : "置顶操作失败");
  }
  return Outcome(false, "不支持的动作类型");
}
