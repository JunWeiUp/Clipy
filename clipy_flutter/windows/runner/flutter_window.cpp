#include "flutter_window.h"

#include <dwmapi.h>
#include <netfw.h>
#include <algorithm>
#include <cstdio>
#include <optional>
#include <shellapi.h>
#include <variant>
#include <vector>

#include "clipboard_bridge.h"
#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

#include <flutter/standard_method_codec.h>

namespace {
constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kScreenshotCompletedMessage = WM_APP + 2;
constexpr UINT kTrayId = 1;
constexpr UINT kShowCommand = 1001;
constexpr UINT kExitCommand = 1002;
constexpr UINT kCaptureCommand = 1003;
constexpr UINT kDevicesCommand = 1004;
constexpr UINT kSettingsCommand = 1005;
constexpr UINT kCancelCaptureCommand = 1006;
constexpr UINT_PTR kPanelDismissTimer = 0x43505950;
constexpr UINT_PTR kScreenshotDelayTimer = 0x434C4950;
constexpr int kHistoryHotkey = 1;
constexpr int kScreenshotHotkey = 2;
constexpr wchar_t kRunKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";

// Bounded metadata-only diagnostics for user-initiated capture sessions.
void CaptureTrace(const char* stage) {
  wchar_t base[32768]{};
  const DWORD length = GetEnvironmentVariableW(L"APPDATA", base, 32768);
  if (length == 0 || length >= 32768) return;
  std::wstring folder = std::wstring(base) + L"\\ClipyClone";
  CreateDirectoryW(folder.c_str(), nullptr);
  HANDLE file = CreateFileW((folder + L"\\capture-trace.log").c_str(), GENERIC_WRITE,
      FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return;
  LARGE_INTEGER size{}, zero{};
  GetFileSizeEx(file, &size);
  if (size.QuadPart > 65536) { SetFilePointerEx(file, zero, nullptr, FILE_BEGIN); SetEndOfFile(file); }
  SetFilePointerEx(file, zero, nullptr, FILE_END);
  char line[256]{};
  const int count = sprintf_s(line, "%llu %s\r\n", GetTickCount64(), stage);
  DWORD written = 0;
  if (count > 0) WriteFile(file, line, static_cast<DWORD>(count), &written, nullptr);
  CloseHandle(file);
}

bool StartupEnabled() {
  DWORD size = 0;
  return RegGetValueW(HKEY_CURRENT_USER, kRunKey, L"ClipyClone", RRF_RT_REG_SZ,
                      nullptr, nullptr, &size) == ERROR_SUCCESS;
}
bool SetStartup(bool enabled) {
  HKEY key;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0, KEY_SET_VALUE, &key) != ERROR_SUCCESS) return false;
  LONG status;
  if (enabled) {
    wchar_t path[32768];
    const DWORD length = GetModuleFileNameW(nullptr, path, 32768);
    if (!length || length >= 32768) { RegCloseKey(key); return false; }
    const std::wstring command = L"\"" + std::wstring(path, length) + L"\" --startup";
    status = RegSetValueExW(key, L"ClipyClone", 0, REG_SZ,
        reinterpret_cast<const BYTE*>(command.c_str()), static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
  } else {
    status = RegDeleteValueW(key, L"ClipyClone");
    if (status == ERROR_FILE_NOT_FOUND) status = ERROR_SUCCESS;
  }
  RegCloseKey(key);
  return status == ERROR_SUCCESS;
}
// -1 means that Windows did not provide a reliable state.
int FirewallStatus() {
  CLSID clsid;
  if (FAILED(CLSIDFromProgID(L"HNetCfg.FwPolicy2", &clsid))) return -1;
  const GUID policy_iid = {0x98325047, 0xc671, 0x4174,
                           {0x8d, 0x81, 0xde, 0xfc, 0xd3, 0xf0, 0x31, 0x86}};
  INetFwPolicy2* policy = nullptr;
  if (FAILED(CoCreateInstance(clsid, nullptr, CLSCTX_INPROC_SERVER,
                              policy_iid, reinterpret_cast<void**>(&policy)))) return -1;
  long profiles = 0;
  if (FAILED(policy->get_CurrentProfileTypes(&profiles))) { policy->Release(); return -1; }
  bool enabled = true;
  for (const long profile : {NET_FW_PROFILE2_DOMAIN, NET_FW_PROFILE2_PRIVATE, NET_FW_PROFILE2_PUBLIC}) {
    if (!(profiles & profile)) continue;
    VARIANT_BOOL value = VARIANT_FALSE;
    if (FAILED(policy->get_FirewallEnabled(static_cast<NET_FW_PROFILE_TYPE2>(profile), &value))) {
      policy->Release();
      return -1;
    }
    if (value == VARIANT_FALSE) enabled = false;
  }
  policy->Release();
  return profiles == 0 ? -1 : enabled ? 1 : 0;
}

const flutter::EncodableValue* MapValue(const flutter::EncodableValue* value,
                                        const char* key) {
  const auto* map = value ? std::get_if<flutter::EncodableMap>(value) : nullptr;
  if (!map) return nullptr;
  const auto item = map->find(flutter::EncodableValue(key));
  return item == map->end() ? nullptr : &item->second;
}
bool ValidHotkey(int32_t modifiers, int32_t key) {
  return modifiers > 0 && modifiers <= 15 &&
      ((key >= 'A' && key <= 'Z') || (key >= '0' && key <= '9') || (key >= VK_F1 && key <= VK_F12)) &&
      !((modifiers & MOD_WIN) && key == 'V');
}
}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project, bool start_hidden)
    : project_(project), start_hidden_(start_hidden) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  // Win32Window::Create calls virtual OnDestroy even before first creation.
  // A fresh HWND must leave that teardown state before accepting capture/tray work.
  shutting_down_ = false;
  window_mode_ = WindowMode::kMain;
  window_transition_ = false;
  CaptureTrace("window-created-ready");
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
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  Gdiplus::GdiplusStartupInput gdiplus_input;
  Gdiplus::GdiplusStartup(&gdiplus_token_, &gdiplus_input, nullptr);
  InstallPlatformChannels();
  AddClipboardFormatListener(GetHandle());
  taskbar_created_message_ = RegisterWindowMessageW(L"TaskbarCreated");
  open_main_message_ = RegisterWindowMessageW(L"ClipyClone.OpenMainWindow");
  AddTrayIcon();
  history_hotkey_registered_ = RegisterHotKey(
      GetHandle(), history_hotkey_id_, history_hotkey_modifiers_ | MOD_NOREPEAT, history_hotkey_key_) != FALSE;
  screenshot_hotkey_registered_ = RegisterHotKey(
      GetHandle(), screenshot_hotkey_id_, screenshot_hotkey_modifiers_ | MOD_NOREPEAT, screenshot_hotkey_key_) != FALSE;

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    if (!start_hidden_) this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  shutting_down_ = true;
  KillTimer(GetHandle(), kScreenshotDelayTimer);
  KillTimer(GetHandle(), kPanelDismissTimer);
  if (history_hotkey_registered_) UnregisterHotKey(GetHandle(), history_hotkey_id_);
  if (screenshot_hotkey_registered_) UnregisterHotKey(GetHandle(), screenshot_hotkey_id_);
  if (screenshot_capture_) screenshot_capture_->Cancel();
  screenshot_capture_.reset();
  screenshot_completion_.reset();
  if (GetHandle()) RemoveClipboardFormatListener(GetHandle());
  RemoveTrayIcon();
  if (clipboard_channel_) clipboard_channel_->SetMethodCallHandler(nullptr);
  if (screenshot_channel_) screenshot_channel_->SetMethodCallHandler(nullptr);
  if (storage_channel_) storage_channel_->SetMethodCallHandler(nullptr);
  if (tray_channel_) tray_channel_->SetMethodCallHandler(nullptr);
  while (!receipt_paths_.empty()) RemoveReceipt(receipt_paths_.begin()->first);
  if (receipt_channel_) receipt_channel_->SetMethodCallHandler(nullptr);
  receipt_channel_.reset();
  if (open_folder_channel_) open_folder_channel_->SetMethodCallHandler(nullptr);
  clipboard_channel_.reset();
  screenshot_channel_.reset();
  tray_channel_.reset();
  screenshot_result_.reset();
  storage_channel_.reset();
  open_folder_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  if (gdiplus_token_) {
    Gdiplus::GdiplusShutdown(gdiplus_token_);
    gdiplus_token_ = 0;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Close means hide for both UI surfaces. Only the explicit Exit command
  // destroys the application; do not let Flutter convert WM_CLOSE into Quit.
  if (message == WM_CLOSE && !shutting_down_) {
    if (IsPanelOpen()) LeaveQuickPanel(false);
    else ShowWindow(hwnd, SW_HIDE);
    return 0;
  }
  if (message == WM_GETMINMAXINFO && !IsPanelOpen()) {
    auto* limits = reinterpret_cast<MINMAXINFO*>(lparam);
    const UINT dpi = std::max(96u, GetDpiForWindow(hwnd));
    limits->ptMinTrackSize = POINT{MulDiv(900, dpi, 96), MulDiv(580, dpi, 96)};
    return 0;
  }
  const bool capture_message = (message == WM_TIMER && wparam == kScreenshotDelayTimer) || message == kScreenshotCompletedMessage;
  if (capture_message) CaptureTrace(message == WM_TIMER ? "timer-received" : "completion-received");
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      if (capture_message) CaptureTrace("message-consumed-by-flutter");
      return *result;
    }
  }

  if (message == open_main_message_ && open_main_message_ != 0) {
    DispatchTrayAction("main");
    return 0;
  }

  if (message == taskbar_created_message_ && taskbar_created_message_ != 0) {
    receipt_paths_.clear();
    tray_added_ = false;
    AddTrayIcon();
    return 0;
  }

  switch (message) {
    case kScreenshotCompletedMessage: {
      // Complete on the owning window's next message turn, after the overlay
      // has unwound and all native destroy/activation callbacks have returned.
      auto completion = std::move(screenshot_completion_);
      screenshot_completion_.reset();
      if (!completion || shutting_down_) return 0;
      screenshot_capture_.reset();
      auto pending = std::move(screenshot_result_);
      if (!pending) return 0;
      ShowFromTray();
      if (!completion->second.empty()) {
        pending->Error(completion->second, "The selected content could not be captured.");
      } else if (completion->first.empty()) {
        pending->Success();
      } else {
        pending->Success(flutter::EncodableValue(std::move(completion->first)));
      }
      return 0;
    }
    case WM_TIMER:
      if (wparam == kPanelDismissTimer) {
        KillTimer(hwnd, kPanelDismissTimer);
        if (!window_transition_ && IsPanelOpen() && !quick_panel_pinned_ && !quick_panel_pasting_ &&
            GetForegroundWindow() != hwnd) LeaveQuickPanel(false);
        return 0;
      }
      if (wparam == kScreenshotDelayTimer) {
        KillTimer(hwnd, kScreenshotDelayTimer);
        StartPendingScreenshot();
        return 0;
      }
      break;
    case WM_HOTKEY:
      if ((history_hotkey_registered_ && wparam == static_cast<WPARAM>(history_hotkey_id_)) ||
          (screenshot_hotkey_registered_ && wparam == static_cast<WPARAM>(screenshot_hotkey_id_))) {
        if (wparam == static_cast<WPARAM>(history_hotkey_id_)) ShowQuickPanel();
        else DispatchTrayAction("capture");
        return 0;
      }
      break;
    case WM_ACTIVATE:
      if (!window_transition_ && IsPanelOpen() && !quick_panel_pinned_ && !quick_panel_pasting_ && LOWORD(wparam) == WA_INACTIVE) {
        // Allow the same tray click to toggle the still-open panel first.
        // A delayed focus check avoids swallowing the next legitimate click.
        SetTimer(hwnd, kPanelDismissTimer, 120, nullptr);
        return 0;
      }
      break;
    case WM_CLIPBOARDUPDATE:
      if (clipboard_channel_) {
        clipboard_channel_->InvokeMethod("onClipboardChanged", nullptr);
      }
      return 0;
    case kTrayMessage: {
      const UINT event = tray_version4_ ? LOWORD(lparam) : static_cast<UINT>(lparam);
      const UINT id = tray_version4_ ? HIWORD(lparam) : static_cast<UINT>(wparam);
      if (id == kTrayId && (event == WM_LBUTTONUP || event == WM_LBUTTONDBLCLK ||
                           event == NIN_SELECT || event == NIN_KEYSELECT)) {
        char stage[128]{};
        sprintf_s(stage, "tray-event=%u v4=%d panel=%d", event, tray_version4_, IsPanelOpen());
        CaptureTrace(stage);
      }
      if (id != kTrayId) {
        auto receipt = receipt_paths_.find(id);
        if (receipt != receipt_paths_.end()) {
          if (event == NIN_BALLOONUSERCLICK || event == NIN_SELECT) {
            if (!RevealFileInExplorer(receipt->second)) {
              const auto separator = receipt->second.find_last_of("/\\");
              if (separator != std::string::npos) {
                const auto folder = receipt->second.substr(0, separator);
                const int length = MultiByteToWideChar(CP_UTF8, 0, folder.data(), static_cast<int>(folder.size()), nullptr, 0);
                std::wstring wide(static_cast<size_t>(length), L'\0');
                if (length > 0) {
                  MultiByteToWideChar(CP_UTF8, 0, folder.data(), static_cast<int>(folder.size()), wide.data(), length);
                  ShellExecuteW(nullptr, L"open", wide.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
                }
              }
            }
            RemoveReceipt(id);
          } else if (event == NIN_BALLOONTIMEOUT) {
            RemoveReceipt(id);
          }
        }
        return 0;
      }
      // v4 sends NIN_SELECT in addition to mouse notifications on current
      // Explorer builds. Handling both toggles twice for a single click.
      if ((tray_version4_ && (event == NIN_SELECT || event == NIN_KEYSELECT)) ||
          (!tray_version4_ && event == WM_LBUTTONUP)) {
        if (!screenshot_result_) {
          ShowQuickPanel();
        }
      } else if ((tray_version4_ && event == WM_CONTEXTMENU) ||
                 (!tray_version4_ && event == WM_RBUTTONUP)) {
        ShowTrayMenu();
      }
      return 0;
    }
    case WM_FONTCHANGE:
      if (flutter_controller_) flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::InstallPlatformChannels() {
  auto* messenger = flutter_controller_->engine()->messenger();
  const auto* codec = &flutter::StandardMethodCodec::GetInstance();
  tray_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "com.clipyclone.clipy_android/tray", codec);
  tray_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "getWindowsBehavior") {
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("startup"), flutter::EncodableValue(StartupEnabled())},
      }));
      return;
    }
    if (call.method_name() == "getFirewallStatus") {
      result->Success(flutter::EncodableValue(FirewallStatus()));
      return;
    }
    if (call.method_name() == "setWindowsBehavior") {
      const auto* name_value = MapValue(call.arguments(), "name");
      const auto* value_value = MapValue(call.arguments(), "value");
      const auto* name = name_value ? std::get_if<std::string>(name_value) : nullptr;
      const auto* value = value_value ? std::get_if<bool>(value_value) : nullptr;
      bool ok = false;
      if (name && value) {
        if (*name == "startup") ok = SetStartup(*value);
      }
      result->Success(flutter::EncodableValue(ok));
      return;
    }
    if (call.method_name() == "restoreHotkeys") {
      const auto* hm_value = MapValue(call.arguments(), "historyModifiers");
      const auto* hk_value = MapValue(call.arguments(), "historyKey");
      const auto* sm_value = MapValue(call.arguments(), "screenshotModifiers");
      const auto* sk_value = MapValue(call.arguments(), "screenshotKey");
      const auto* hm = hm_value ? std::get_if<int32_t>(hm_value) : nullptr;
      const auto* hk = hk_value ? std::get_if<int32_t>(hk_value) : nullptr;
      const auto* sm = sm_value ? std::get_if<int32_t>(sm_value) : nullptr;
      const auto* sk = sk_value ? std::get_if<int32_t>(sk_value) : nullptr;
      if (!hm || !hk || !sm || !sk || !ValidHotkey(*hm, *hk) || !ValidHotkey(*sm, *sk) || (*hm == *sm && *hk == *sk)) {
        result->Error("INVALID_HOTKEY", "Invalid or duplicate shortcuts.");
        return;
      }
      const UINT old_hm = history_hotkey_modifiers_, old_hk = history_hotkey_key_;
      const UINT old_sm = screenshot_hotkey_modifiers_, old_sk = screenshot_hotkey_key_;
      if (history_hotkey_registered_) UnregisterHotKey(GetHandle(), history_hotkey_id_);
      if (screenshot_hotkey_registered_) UnregisterHotKey(GetHandle(), screenshot_hotkey_id_);
      history_hotkey_id_ = kHistoryHotkey;
      screenshot_hotkey_id_ = kScreenshotHotkey;
      history_hotkey_modifiers_ = *hm; history_hotkey_key_ = *hk;
      screenshot_hotkey_modifiers_ = *sm; screenshot_hotkey_key_ = *sk;
      history_hotkey_registered_ = RegisterHotKey(GetHandle(), history_hotkey_id_, *hm | MOD_NOREPEAT, *hk) != FALSE;
      screenshot_hotkey_registered_ = RegisterHotKey(GetHandle(), screenshot_hotkey_id_, *sm | MOD_NOREPEAT, *sk) != FALSE;
      if (!history_hotkey_registered_) {
        history_hotkey_modifiers_ = old_hm; history_hotkey_key_ = old_hk;
        history_hotkey_registered_ = RegisterHotKey(GetHandle(), history_hotkey_id_, old_hm | MOD_NOREPEAT, old_hk) != FALSE;
      }
      if (!screenshot_hotkey_registered_) {
        screenshot_hotkey_modifiers_ = old_sm; screenshot_hotkey_key_ = old_sk;
        screenshot_hotkey_registered_ = RegisterHotKey(GetHandle(), screenshot_hotkey_id_, old_sm | MOD_NOREPEAT, old_sk) != FALSE;
      }
      result->Success();
      return;
    }
    if (call.method_name() == "setHotkey") {
      const auto* kind_value = MapValue(call.arguments(), "kind");
      const auto* mod_value = MapValue(call.arguments(), "modifiers");
      const auto* key_value = MapValue(call.arguments(), "key");
      const auto* kind = kind_value ? std::get_if<std::string>(kind_value) : nullptr;
      const auto* modifiers = mod_value ? std::get_if<int32_t>(mod_value) : nullptr;
      const auto* key = key_value ? std::get_if<int32_t>(key_value) : nullptr;
      if (!kind || (*kind != "history" && *kind != "screenshot") || !modifiers || !key ||
          !ValidHotkey(*modifiers, *key)) {
        result->Error("INVALID_HOTKEY", "Invalid or reserved shortcut.");
        return;
      }
      result->Success(flutter::EncodableValue(ConfigureHotkey(*kind == "history", *modifiers, *key)));
      return;
    }
    if (call.method_name() == "getHotkeys") {
      result->Success(flutter::EncodableValue(flutter::EncodableMap{
          {flutter::EncodableValue("historyModifiers"), flutter::EncodableValue(static_cast<int32_t>(history_hotkey_modifiers_))},
          {flutter::EncodableValue("historyKey"), flutter::EncodableValue(static_cast<int32_t>(history_hotkey_key_))},
          {flutter::EncodableValue("history"), flutter::EncodableValue(history_hotkey_registered_)},
          {flutter::EncodableValue("screenshotModifiers"), flutter::EncodableValue(static_cast<int32_t>(screenshot_hotkey_modifiers_))},
          {flutter::EncodableValue("screenshotKey"), flutter::EncodableValue(static_cast<int32_t>(screenshot_hotkey_key_))},
          {flutter::EncodableValue("screenshot"), flutter::EncodableValue(screenshot_hotkey_registered_)},
      }));
      return;
    }
    if (call.method_name() == "showCaptureResult") {
      if (ShowQuickPanel(true)) result->Success();
      else result->Error("PANEL_UNAVAILABLE", "Could not open screenshot result.");
      return;
    }
    if (call.method_name() == "dismissCaptureResult") {
      if (IsCaptureResult()) LeaveQuickPanel(false);
      result->Success();
      return;
    }
    if (call.method_name() == "setQuickPinned") {
      const auto* pinned = call.arguments() ? std::get_if<bool>(call.arguments()) : nullptr;
      if (!IsPanelOpen() || IsCaptureResult() || !pinned) {
        result->Error("PANEL_UNAVAILABLE", "Quick panel is not open.");
      } else {
        quick_panel_pinned_ = *pinned;
        result->Success();
      }
      return;
    }
    if (call.method_name() == "pasteQuick") {
      result->Success(flutter::EncodableValue(PasteQuickPanel()));
      return;
    }
    if (call.method_name() == "getWindowMode") {
      result->Success(flutter::EncodableValue(std::string(
          IsCaptureResult() ? "capture" : IsPanelOpen() ? "quick" : "main")));
      return;
    }
    if (call.method_name() == "dismissQuickPanel") {
      if (IsPanelOpen() && !IsCaptureResult()) LeaveQuickPanel(false);
      result->Success();
      return;
    }
    if (call.method_name() == "openFullHistory" || call.method_name() == "openMainWindow") {
      DispatchTrayAction("main");
      result->Success();
      return;
    }
    if (call.method_name() != "getHotkeyStatus") {
      result->NotImplemented();
      return;
    }
    result->Success(flutter::EncodableValue(flutter::EncodableMap{
        {flutter::EncodableValue("history"), flutter::EncodableValue(history_hotkey_registered_)},
        {flutter::EncodableValue("screenshot"), flutter::EncodableValue(screenshot_hotkey_registered_)},
    }));
  });
  clipboard_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "com.clipyclone.clipy_android/clipboard", codec);
  clipboard_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() == "getSnapshot") {
          result->Success(flutter::EncodableValue(ReadClipboardSnapshot(GetHandle())));
          return;
        }
        if (call.method_name() == "setImage") {
          const auto* value = MapValue(call.arguments(), "bytes");
          const auto* bytes = value ? std::get_if<std::vector<uint8_t>>(value) : nullptr;
          result->Success(flutter::EncodableValue(
              bytes && WriteClipboardImage(GetHandle(), *bytes)));
          return;
        }
        if (call.method_name() == "setText") {
          const auto* value = MapValue(call.arguments(), "text");
          const auto* content = value ? std::get_if<std::string>(value) : nullptr;
          result->Success(flutter::EncodableValue(
              content && WriteClipboardText(GetHandle(), *content)));
          return;
        }
        if (call.method_name() == "setFiles") {
          const auto* value = MapValue(call.arguments(), "paths");
          const auto* list = value ? std::get_if<flutter::EncodableList>(value) : nullptr;
          std::vector<std::string> paths;
          if (list) {
            for (const auto& item : *list) {
              if (const auto* path = std::get_if<std::string>(&item)) {
                paths.push_back(*path);
              }
            }
          }
          result->Success(flutter::EncodableValue(
              WriteClipboardFiles(GetHandle(), paths)));
          return;
        }
        result->NotImplemented();
      });

  screenshot_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "com.clipyclone.clipy_android/screenshot", codec);
  screenshot_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() != "capture") {
          result->NotImplemented();
          return;
        }
        CaptureTrace("capture-request");
        if (shutting_down_) {
          result->Error("CAPTURE_UNAVAILABLE", "The application window is closing.");
          return;
        }
        if (screenshot_result_) {
          result->Error("CAPTURE_BUSY", "A screenshot selection is already active.");
          return;
        }
        const auto* value = MapValue(call.arguments(), "mode");
        const auto* requested = value ? std::get_if<std::string>(value) : nullptr;
        ScreenshotMode mode;
        if (requested && *requested == "region") {
          mode = ScreenshotMode::kRegion;
        } else if (requested && *requested == "window") {
          mode = ScreenshotMode::kWindow;
        } else if (requested && *requested == "fullscreen") {
          mode = ScreenshotMode::kFullscreen;
        } else {
          result->Error("INVALID_MODE", "Unknown screenshot mode.");
          return;
        }
        int32_t delay_seconds = 0;
        if (const auto* delay_value = MapValue(call.arguments(), "delaySeconds")) {
          if (const auto* delay = std::get_if<int32_t>(delay_value)) delay_seconds = *delay;
        }
        if (delay_seconds != 0 && delay_seconds != 3 && delay_seconds != 5) {
          result->Error("INVALID_DELAY", "Screenshot delay must be 0, 3 or 5 seconds.");
          return;
        }
        pending_screenshot_mode_ = mode;
        screenshot_capture_.reset();
        // Exclude Clipy's own window from the frozen desktop. Restore it when
        // selection completes or fails, including cancellation.
        screenshot_result_ = std::move(result);
        screenshot_capture_ = std::make_unique<ScreenshotCapture>(
            GetHandle(),
            [this](std::vector<uint8_t> png, std::string error) {
              if (shutting_down_) return;
              CaptureTrace("overlay-complete");
              screenshot_completion_.emplace(std::move(png), std::move(error));
              PostMessageW(GetHandle(), kScreenshotCompletedMessage, 0, 0);
            }, CaptureTrace);
        CaptureTrace("arm-timer");
        // Do not hide/show native windows inside Flutter's platform-message
        // callback: activation and resize synchronously re-enter the engine.
        if (!SetTimer(GetHandle(), kScreenshotDelayTimer,
                      delay_seconds == 0 ? 1 : delay_seconds * 1000, nullptr)) {
          screenshot_capture_.reset();
          ShowFromTray();
          auto pending = std::move(screenshot_result_);
          pending->Error("CAPTURE_UNAVAILABLE", "Could not start screenshot timer.");
        }
      });

  storage_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "com.clipyclone.clipy_android/storage", codec);
  storage_channel_->SetMethodCallHandler(
      [](const auto& call, auto result) {
        if (call.method_name() == "getAppVersion") {
          const auto version = std::to_string(FLUTTER_VERSION_MAJOR) + "." +
              std::to_string(FLUTTER_VERSION_MINOR) + "." + std::to_string(FLUTTER_VERSION_PATCH);
          result->Success(flutter::EncodableValue(flutter::EncodableMap{
              {flutter::EncodableValue("version"), flutter::EncodableValue(version)},
              {flutter::EncodableValue("build"), flutter::EncodableValue(std::to_string(FLUTTER_VERSION_BUILD))},
          }));
        } else if (call.method_name() == "getAppStorageDirectory") {
          auto base = KnownFolderPath(FOLDERID_RoamingAppData);
          result->Success(flutter::EncodableValue(base.empty() ? base : base + "\\ClipyClone"));
        } else if (call.method_name() == "getDownloadsDirectory") {
          result->Success(flutter::EncodableValue(KnownFolderPath(FOLDERID_Downloads)));
        } else {
          result->NotImplemented();
        }
      });

  receipt_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "com.clipyclone.clipy_android/transfer_notifications", codec);
  receipt_channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "initialize") { result->Success(); return; }
    if (call.method_name() != "received") { result->NotImplemented(); return; }
    const auto* path_value = MapValue(call.arguments(), "path");
    const auto* name_value = MapValue(call.arguments(), "name");
    const auto* path = path_value ? std::get_if<std::string>(path_value) : nullptr;
    const auto* name = name_value ? std::get_if<std::string>(name_value) : nullptr;
    if (path && name && NotifyReceivedFile(*path, *name)) result->Success();
    else result->Error("NOTIFICATION", "Could not post file receipt");
  });

  open_folder_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "com.clipyclone.clipy_android/open_folder", codec);
  open_folder_channel_->SetMethodCallHandler(
      [](const auto& call, auto result) {
        if (call.method_name() != "openFolder") {
          result->NotImplemented();
          return;
        }
        const auto* value = MapValue(call.arguments(), "path");
        const auto* path = value ? std::get_if<std::string>(value) : nullptr;
        result->Success(flutter::EncodableValue(path && RevealFileInExplorer(*path)));
      });
}

void FlutterWindow::AddTrayIcon() {
  if (tray_added_ || !GetHandle()) return;
  NOTIFYICONDATAW icon{};
  icon.cbSize = sizeof(icon);
  icon.hWnd = GetHandle();
  icon.uID = kTrayId;
  icon.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  icon.uCallbackMessage = kTrayMessage;
  icon.hIcon = LoadIconW(GetModuleHandle(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON));
  if (!icon.hIcon) icon.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
  wcscpy_s(icon.szTip, _countof(icon.szTip), L"ClipyClone");
  tray_added_ = Shell_NotifyIconW(NIM_ADD, &icon) == TRUE;
  if (tray_added_) {
    icon.uVersion = NOTIFYICON_VERSION_4;
    tray_version4_ = Shell_NotifyIconW(NIM_SETVERSION, &icon) == TRUE;
  }
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_added_) return;
  NOTIFYICONDATAW icon{};
  icon.cbSize = sizeof(icon);
  icon.hWnd = GetHandle();
  icon.uID = kTrayId;
  Shell_NotifyIconW(NIM_DELETE, &icon);
  tray_added_ = false;
  tray_version4_ = false;
}

void FlutterWindow::ShowFromTray() {
  ShowWindow(GetHandle(), SW_RESTORE);
  SetForegroundWindow(GetHandle());
}

void FlutterWindow::StartPendingScreenshot() {
  CaptureTrace("start-pending");
  if (!screenshot_capture_ || !screenshot_result_ || shutting_down_) {
    CaptureTrace("start-skipped");
    auto pending = std::move(screenshot_result_);
    if (pending && !shutting_down_) pending->Error("CAPTURE_UNAVAILABLE", "Screenshot session is unavailable.");
    return;
  }
  if (IsPanelOpen()) LeaveQuickPanel(false);
  CaptureTrace("hide-main");
  ShowWindow(GetHandle(), SW_HIDE);
  CaptureTrace("flush-desktop");
  DwmFlush();
  CaptureTrace("start-overlay");
  if (!screenshot_capture_->Start(pending_screenshot_mode_)) {
    screenshot_capture_.reset();
    ShowFromTray();
    auto pending = std::move(screenshot_result_);
    CaptureTrace("overlay-failed");
    pending->Error("CAPTURE_UNAVAILABLE",
                   "The desktop could not be captured on this display setup.");
  } else { CaptureTrace("overlay-ready"); }
}

bool FlutterWindow::ShowQuickPanel(bool capture_result) {
  if (screenshot_result_ || shutting_down_) return false;
  if (IsPanelOpen()) {
    LeaveQuickPanel(false);
    if (!capture_result) return true;
  }
  HWND window = GetHandle();
  quick_target_ = GetForegroundWindow();
  DWORD target_process = 0;
  wchar_t target_class[128]{};
  if (quick_target_) {
    GetWindowThreadProcessId(quick_target_, &target_process);
    GetClassNameW(quick_target_, target_class, static_cast<int>(sizeof(target_class) / sizeof(target_class[0])));
  }
  if (target_process == GetCurrentProcessId() || quick_target_ == GetShellWindow() ||
      wcscmp(target_class, L"Shell_TrayWnd") == 0 ||
      wcscmp(target_class, L"Shell_SecondaryTrayWnd") == 0 ||
      wcscmp(target_class, L"NotifyIconOverflowWindow") == 0) {
    quick_target_ = nullptr;
  }
  quick_target_process_ = target_process;
  saved_window_placement_.length = sizeof(WINDOWPLACEMENT);
  if (!GetWindowPlacement(window, &saved_window_placement_)) return false;
  saved_window_style_ = GetWindowLongPtrW(window, GWL_STYLE);
  POINT cursor{};
  GetCursorPos(&cursor);
  MONITORINFO monitor{};
  monitor.cbSize = sizeof(monitor);
  const HMONITOR display = MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST);
  if (!display || !GetMonitorInfoW(display, &monitor)) {
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &monitor.rcWork, 0);
  }
  const int dpi = std::max(96u, GetDpiForWindow(window));
  const int width = std::min(MulDiv(capture_result ? 360 : 400, dpi, 96), static_cast<int>(monitor.rcWork.right - monitor.rcWork.left));
  const int height = std::min(MulDiv(capture_result ? 320 : 640, dpi, 96), static_cast<int>(monitor.rcWork.bottom - monitor.rcWork.top));
  const int margin = MulDiv(12, dpi, 96);
  window_transition_ = true;
  window_mode_ = capture_result ? WindowMode::kCaptureResult : WindowMode::kQuick;
  quick_panel_pinned_ = capture_result;
  PublishWindowMode();
  SetWindowLongPtrW(window, GWL_STYLE, WS_POPUP | WS_CLIPCHILDREN | WS_CLIPSIBLINGS);
  if (!SetWindowPos(window, HWND_TOPMOST, std::max(monitor.rcWork.left, monitor.rcWork.right - width - margin),
                    std::max(monitor.rcWork.top, monitor.rcWork.bottom - height - margin),
                    width, height, SWP_FRAMECHANGED | SWP_SHOWWINDOW)) {
    SetWindowLongPtrW(window, GWL_STYLE, saved_window_style_);
    SetWindowPlacement(window, &saved_window_placement_);
    window_mode_ = WindowMode::kMain;
    window_transition_ = false;
    PublishWindowMode();
    return false;
  }
  SetForegroundWindow(window);
  window_transition_ = false;
  return true;
}

void FlutterWindow::LeaveQuickPanel(bool show_main) {
  KillTimer(GetHandle(), kPanelDismissTimer);
  if (!IsPanelOpen()) {
    if (show_main) ShowFromTray();
    return;
  }
  window_transition_ = true;
  window_mode_ = WindowMode::kMain;
  quick_panel_pinned_ = false;
  HWND window = GetHandle();
  ShowWindow(window, SW_HIDE);
  SetWindowLongPtrW(window, GWL_STYLE, saved_window_style_);
  SetWindowPos(window, HWND_NOTOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_FRAMECHANGED);
  SetWindowPlacement(window, &saved_window_placement_);
  if (show_main) ShowFromTray();
  else ShowWindow(window, SW_HIDE);
  window_transition_ = false;
  PublishWindowMode();
}

void FlutterWindow::PublishWindowMode() {
  if (tray_channel_) {
    const char* mode = IsCaptureResult() ? "capture" : IsPanelOpen() ? "quick" : "main";
    tray_channel_->InvokeMethod("windowMode", std::make_unique<flutter::EncodableValue>(std::string(mode)));
  }
}

bool FlutterWindow::ConfigureHotkey(bool history, UINT modifiers, UINT key) {
  UINT& current_modifiers = history ? history_hotkey_modifiers_ : screenshot_hotkey_modifiers_;
  UINT& current_key = history ? history_hotkey_key_ : screenshot_hotkey_key_;
  int& current_id = history ? history_hotkey_id_ : screenshot_hotkey_id_;
  bool& registered = history ? history_hotkey_registered_ : screenshot_hotkey_registered_;
  const UINT other_modifiers = history ? screenshot_hotkey_modifiers_ : history_hotkey_modifiers_;
  const UINT other_key = history ? screenshot_hotkey_key_ : history_hotkey_key_;
  const bool other_registered = history ? screenshot_hotkey_registered_ : history_hotkey_registered_;
  if (other_registered && modifiers == other_modifiers && key == other_key) return false;
  if (registered && modifiers == current_modifiers && key == current_key) return true;
  const int base = history ? kHistoryHotkey : kScreenshotHotkey;
  const int next_id = current_id == base ? base + 2 : base;
  // Register first so failure leaves the old shortcut active.
  if (!RegisterHotKey(GetHandle(), next_id, modifiers | MOD_NOREPEAT, key)) return false;
  if (registered) UnregisterHotKey(GetHandle(), current_id);
  current_id = next_id;
  current_modifiers = modifiers;
  current_key = key;
  registered = true;
  return true;
}

bool FlutterWindow::PasteQuickPanel() {
  if (!IsPanelOpen() || !quick_target_ || !IsWindow(quick_target_) ||
      !IsWindowVisible(quick_target_) || IsIconic(quick_target_) ||
      (GetAsyncKeyState(VK_CONTROL) & 0x8000) ||
      (GetAsyncKeyState(VK_SHIFT) & 0x8000) ||
      (GetAsyncKeyState(VK_MENU) & 0x8000)) return false;
  const HWND target = quick_target_;
  DWORD current_process = 0;
  GetWindowThreadProcessId(target, &current_process);
  if (!current_process || current_process != quick_target_process_) return false;
  quick_panel_pasting_ = true;
  SetForegroundWindow(target);
  const bool focused = GetForegroundWindow() == target;
  if (!focused) {
    quick_panel_pasting_ = false;
    return false;
  }
  INPUT input[4]{};
  for (auto& event : input) event.type = INPUT_KEYBOARD;
  input[0].ki.wVk = VK_CONTROL;
  input[1].ki.wVk = 'V';
  input[2].ki.wVk = 'V';
  input[2].ki.dwFlags = KEYEVENTF_KEYUP;
  input[3].ki.wVk = VK_CONTROL;
  input[3].ki.dwFlags = KEYEVENTF_KEYUP;
  const bool sent = SendInput(4, input, sizeof(INPUT)) == 4;
  if (!sent) {
    INPUT releases[2]{};
    for (auto& event : releases) { event.type = INPUT_KEYBOARD; event.ki.dwFlags = KEYEVENTF_KEYUP; }
    releases[0].ki.wVk = 'V';
    releases[1].ki.wVk = VK_CONTROL;
    SendInput(2, releases, sizeof(INPUT));
  }
  quick_panel_pasting_ = false;
  if (sent && !quick_panel_pinned_) LeaveQuickPanel(false);
  return sent;
}

void FlutterWindow::DispatchTrayAction(const char* action) {
  if (screenshot_result_) return;
  if (IsPanelOpen()) LeaveQuickPanel(true);
  else ShowFromTray();
  PublishWindowMode();
  if (tray_channel_) {
    tray_channel_->InvokeMethod("action",
        std::make_unique<flutter::EncodableValue>(std::string(action)));
  }
}

void FlutterWindow::ShowTrayMenu() {
  HMENU menu = CreatePopupMenu();
  if (!menu) return;
  const UINT action_flags = MF_STRING | (screenshot_result_ ? MF_GRAYED : 0);
  AppendMenuW(menu, action_flags, kShowCommand, L"Open main window / 打开主窗口");
  AppendMenuW(menu, action_flags, kCaptureCommand, L"Screenshot / 截图");
  AppendMenuW(menu, action_flags, kDevicesCommand, L"Devices and file transfer / 设备与文件传输");
  AppendMenuW(menu, action_flags, kSettingsCommand, L"Settings / 设置");
  if (screenshot_result_) {
    AppendMenuW(menu, MF_STRING, kCancelCaptureCommand, L"Cancel screenshot / 取消截图");
  }
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kExitCommand, L"Exit / 退出");
  POINT point{};
  GetCursorPos(&point);
  SetForegroundWindow(GetHandle());
  const UINT command = TrackPopupMenu(menu,
                                      TPM_RETURNCMD | TPM_RIGHTBUTTON,
                                      point.x, point.y, 0, GetHandle(), nullptr);
  DestroyMenu(menu);
  if (command == kCancelCaptureCommand && screenshot_capture_) {
    KillTimer(GetHandle(), kScreenshotDelayTimer);
    screenshot_capture_->Cancel();
  }
  if (command == kShowCommand || command == kCaptureCommand ||
      command == kDevicesCommand || command == kSettingsCommand) {
    const char* action = command == kShowCommand ? "main" :
                         command == kCaptureCommand ? "capture" :
                         command == kDevicesCommand ? "devices" : "settings";
    DispatchTrayAction(action);
  }
  if (command == kExitCommand) {
    RemoveTrayIcon();
    RemoveClipboardFormatListener(GetHandle());
    DestroyWindow(GetHandle());
  } else {
    PostMessage(GetHandle(), WM_NULL, 0, 0);
  }
}

void FlutterWindow::RemoveReceipt(UINT id) {
  NOTIFYICONDATAW icon{};
  icon.cbSize = sizeof(icon);
  icon.hWnd = GetHandle();
  icon.uID = id;
  Shell_NotifyIconW(NIM_DELETE, &icon);
  receipt_paths_.erase(id);
}

bool FlutterWindow::NotifyReceivedFile(const std::string& path, const std::string& name) {
  // Bounded native resources, released on tap, timeout, Explorer restart or exit.
  if (receipt_paths_.size() >= 32) RemoveReceipt(receipt_paths_.begin()->first);
  if (next_receipt_id_ > 65535) next_receipt_id_ = 10;
  const UINT id = next_receipt_id_++;
  if (receipt_paths_.count(id)) RemoveReceipt(id);
  NOTIFYICONDATAW icon{};
  icon.cbSize = sizeof(icon);
  icon.hWnd = GetHandle();
  icon.uID = id;
  icon.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  icon.uCallbackMessage = kTrayMessage;
  icon.hIcon = LoadIcon(GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON));
  wcscpy_s(icon.szTip, L"Clipy - Received file");
  if (!Shell_NotifyIconW(NIM_ADD, &icon)) return false;
  icon.uVersion = NOTIFYICON_VERSION_4;
  Shell_NotifyIconW(NIM_SETVERSION, &icon);
  const int length = MultiByteToWideChar(CP_UTF8, 0, name.data(), static_cast<int>(name.size()), nullptr, 0);
  std::wstring wide(static_cast<size_t>(length), L'\0');
  if (length > 0) MultiByteToWideChar(CP_UTF8, 0, name.data(), static_cast<int>(name.size()), wide.data(), length);
  const bool chinese = PRIMARYLANGID(GetUserDefaultUILanguage()) == LANG_CHINESE;
  const std::wstring title = chinese ? L"已接收文件" : L"File received";
  const std::wstring body = wide + (chinese ? L"\n点击在文件资源管理器中显示" : L"\nClick to show in Explorer");
  icon.uFlags = NIF_INFO;
  icon.dwInfoFlags = NIIF_INFO;
  wcsncpy_s(icon.szInfoTitle, title.c_str(), _TRUNCATE);
  wcsncpy_s(icon.szInfo, body.c_str(), _TRUNCATE);
  receipt_paths_[id] = path;
  if (Shell_NotifyIconW(NIM_MODIFY, &icon)) return true;
  RemoveReceipt(id);
  return false;
}
