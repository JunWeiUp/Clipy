#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>
#include <gdiplus.h>

#include <memory>
#include <map>
#include <string>

#include "win32_window.h"
#include "screenshot_capture.h"

// Flutter view plus the native clipboard and tray surfaces.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void InstallPlatformChannels();
  void AddTrayIcon();
  void RemoveTrayIcon();
  void ShowFromTray();
  void ShowTrayMenu();
  bool NotifyReceivedFile(const std::string& path, const std::string& name);
  void RemoveReceipt(UINT id);

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> clipboard_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> screenshot_channel_;
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> screenshot_result_;
  std::unique_ptr<ScreenshotCapture> screenshot_capture_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> storage_channel_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> open_folder_channel_;
  ULONG_PTR gdiplus_token_ = 0;
  UINT taskbar_created_message_ = 0;
  bool tray_added_ = false;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> receipt_channel_;
  // Separate native icon IDs prevent a later receipt changing an earlier tap.
  std::map<UINT, std::string> receipt_paths_;
  UINT next_receipt_id_ = 10;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
