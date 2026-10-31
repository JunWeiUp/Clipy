#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>
#include <gdiplus.h>

#include <memory>
#include <optional>
#include <utility>
#include <map>
#include <string>

#include "win32_window.h"
#include "screenshot_capture.h"

// Flutter view plus the native clipboard and tray surfaces.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project, bool start_hidden = false);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  enum class WindowMode { kMain, kQuick, kCaptureResult };
  bool IsPanelOpen() const { return window_mode_ != WindowMode::kMain; }
  bool IsCaptureResult() const { return window_mode_ == WindowMode::kCaptureResult; }
  void PublishWindowMode();
  void InstallPlatformChannels();
  void AddTrayIcon();
  void RemoveTrayIcon();
  void ShowFromTray();
  void ShowTrayMenu();
  void DispatchTrayAction(const char* action);
  void StartPendingScreenshot();
  bool ShowQuickPanel(bool capture_result = false);
  void LeaveQuickPanel(bool show_main);
  bool PasteQuickPanel();
  bool ConfigureHotkey(bool history, UINT modifiers, UINT key);
  bool NotifyReceivedFile(const std::string& path, const std::string& name);
  void RemoveReceipt(UINT id);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> clipboard_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> screenshot_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> tray_channel_;
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> screenshot_result_;
  // Only a capture started from the visible main window brings it back;
  // tray, hotkey and quick-panel captures finish in the result flyout.
  bool screenshot_restore_window_ = true;
  std::unique_ptr<ScreenshotCapture> screenshot_capture_;
  std::optional<std::pair<std::vector<uint8_t>, std::string>> screenshot_completion_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> storage_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> open_folder_channel_;
  ULONG_PTR gdiplus_token_ = 0;
  UINT taskbar_created_message_ = 0;
  UINT open_main_message_ = 0;
  bool tray_added_ = false;
  bool tray_version4_ = false;
  bool start_hidden_ = false;
  bool shutting_down_ = false;
  WindowMode window_mode_ = WindowMode::kMain;
  bool window_transition_ = false;
  bool quick_panel_pinned_ = false;
  bool quick_panel_pasting_ = false;
  HWND quick_target_ = nullptr;
  DWORD quick_target_process_ = 0;
  LONG_PTR saved_window_style_ = 0;
  WINDOWPLACEMENT saved_window_placement_{sizeof(WINDOWPLACEMENT)};
  bool history_hotkey_registered_ = false;
  bool screenshot_hotkey_registered_ = false;
  int history_hotkey_id_ = 1;
  int screenshot_hotkey_id_ = 2;
  UINT history_hotkey_modifiers_ = MOD_CONTROL | MOD_SHIFT;
  UINT screenshot_hotkey_modifiers_ = MOD_CONTROL | MOD_SHIFT;
  UINT history_hotkey_key_ = 'V';
  UINT screenshot_hotkey_key_ = 'A';
  ScreenshotMode pending_screenshot_mode_ = ScreenshotMode::kRegion;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> receipt_channel_;
  // Separate native icon IDs prevent a later receipt changing an earlier tap.
  std::map<UINT, std::string> receipt_paths_;
  UINT next_receipt_id_ = 10;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
