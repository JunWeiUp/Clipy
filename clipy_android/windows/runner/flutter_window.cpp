#include "flutter_window.h"

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
constexpr UINT kTrayId = 1;
constexpr UINT kShowCommand = 1001;
constexpr UINT kExitCommand = 1002;

const flutter::EncodableValue* MapValue(const flutter::EncodableValue* value,
                                        const char* key) {
  const auto* map = value ? std::get_if<flutter::EncodableMap>(value) : nullptr;
  if (!map) return nullptr;
  const auto item = map->find(flutter::EncodableValue(key));
  return item == map->end() ? nullptr : &item->second;
}
}  // namespace

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
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  Gdiplus::GdiplusStartupInput gdiplus_input;
  Gdiplus::GdiplusStartup(&gdiplus_token_, &gdiplus_input, nullptr);
  InstallPlatformChannels();
  AddClipboardFormatListener(GetHandle());
  taskbar_created_message_ = RegisterWindowMessageW(L"TaskbarCreated");
  AddTrayIcon();

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (screenshot_capture_) screenshot_capture_->Cancel();
  screenshot_capture_.reset();
  if (GetHandle()) RemoveClipboardFormatListener(GetHandle());
  RemoveTrayIcon();
  if (clipboard_channel_) clipboard_channel_->SetMethodCallHandler(nullptr);
  if (screenshot_channel_) screenshot_channel_->SetMethodCallHandler(nullptr);
  if (storage_channel_) storage_channel_->SetMethodCallHandler(nullptr);
  if (open_folder_channel_) open_folder_channel_->SetMethodCallHandler(nullptr);
  clipboard_channel_.reset();
  screenshot_channel_.reset();
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
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  if (message == taskbar_created_message_ && taskbar_created_message_ != 0) {
    tray_added_ = false;
    AddTrayIcon();
    return 0;
  }

  switch (message) {
    case WM_CLOSE:
      ShowWindow(hwnd, SW_HIDE);
      return 0;
    case WM_CLIPBOARDUPDATE:
      if (clipboard_channel_) {
        clipboard_channel_->InvokeMethod("onClipboardChanged", nullptr);
      }
      return 0;
    case kTrayMessage:
      if (LOWORD(lparam) == WM_LBUTTONUP ||
          LOWORD(lparam) == WM_LBUTTONDBLCLK ||
          LOWORD(lparam) == NIN_SELECT) {
        ShowFromTray();
      } else if (LOWORD(lparam) == WM_RBUTTONUP ||
                 LOWORD(lparam) == WM_CONTEXTMENU) {
        ShowTrayMenu();
      }
      return 0;
    case WM_FONTCHANGE:
      if (flutter_controller_) flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::InstallPlatformChannels() {
  auto* messenger = flutter_controller_->engine()->messenger();
  const auto* codec = &flutter::StandardMethodCodec::GetInstance();
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
        screenshot_capture_.reset();
        screenshot_result_ = std::move(result);
        screenshot_capture_ = std::make_unique<ScreenshotCapture>(
            GetHandle(),
            [this](std::vector<uint8_t> png, std::string error) {
              auto pending = std::move(screenshot_result_);
              if (!pending) return;
              if (!error.empty()) {
                pending->Error(error, "The selected content could not be captured.");
              } else if (png.empty()) {
                pending->Success();  // Esc/right-click cancellation.
              } else {
                pending->Success(flutter::EncodableValue(std::move(png)));
              }
            });
        if (!screenshot_capture_->Start(mode)) {
          screenshot_capture_.reset();
          auto pending = std::move(screenshot_result_);
          pending->Error("CAPTURE_UNAVAILABLE",
                         "The desktop could not be captured on this display setup.");
        }
      });

  storage_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "com.clipyclone.clipy_android/storage", codec);
  storage_channel_->SetMethodCallHandler(
      [](const auto& call, auto result) {
        if (call.method_name() == "getAppStorageDirectory") {
          auto base = KnownFolderPath(FOLDERID_RoamingAppData);
          result->Success(flutter::EncodableValue(base.empty() ? base : base + "\\ClipyClone"));
        } else if (call.method_name() == "getDownloadsDirectory") {
          result->Success(flutter::EncodableValue(KnownFolderPath(FOLDERID_Downloads)));
        } else {
          result->NotImplemented();
        }
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
    Shell_NotifyIconW(NIM_SETVERSION, &icon);
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
}

void FlutterWindow::ShowFromTray() {
  ShowWindow(GetHandle(), SW_RESTORE);
  SetForegroundWindow(GetHandle());
}

void FlutterWindow::ShowTrayMenu() {
  HMENU menu = CreatePopupMenu();
  if (!menu) return;
  AppendMenuW(menu, MF_STRING, kShowCommand, L"Open / 打开");
  AppendMenuW(menu, MF_STRING, kExitCommand, L"Exit / 退出");
  POINT point{};
  GetCursorPos(&point);
  SetForegroundWindow(GetHandle());
  const UINT command = TrackPopupMenu(menu,
                                      TPM_RETURNCMD | TPM_RIGHTBUTTON,
                                      point.x, point.y, 0, GetHandle(), nullptr);
  DestroyMenu(menu);
  if (command == kShowCommand) ShowFromTray();
  if (command == kExitCommand) {
    RemoveTrayIcon();
    RemoveClipboardFormatListener(GetHandle());
    DestroyWindow(GetHandle());
  } else {
    PostMessage(GetHandle(), WM_NULL, 0, 0);
  }
}
