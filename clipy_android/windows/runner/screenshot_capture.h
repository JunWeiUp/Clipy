#ifndef RUNNER_SCREENSHOT_CAPTURE_H_
#define RUNNER_SCREENSHOT_CAPTURE_H_

#include <windows.h>

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

enum class ScreenshotMode { kRegion, kWindow, kFullscreen };

// Owns one user-initiated native selection session. The desktop is frozen
// before the overlay appears, so the overlay never enters the result.
class ScreenshotCapture {
 public:
  using Completion =
      std::function<void(std::vector<uint8_t> png, std::string error)>;

  ScreenshotCapture(HWND owner, Completion completion);
  ~ScreenshotCapture();

  ScreenshotCapture(const ScreenshotCapture&) = delete;
  ScreenshotCapture& operator=(const ScreenshotCapture&) = delete;

  bool Start(ScreenshotMode mode);
  void Cancel();
  bool active() const { return overlay_ != nullptr; }

 private:
  struct WindowCandidate {
    HWND handle;
    RECT bounds;
  };

  static LRESULT CALLBACK WindowProc(HWND window, UINT message, WPARAM wparam,
                                     LPARAM lparam);
  LRESULT HandleMessage(HWND window, UINT message, WPARAM wparam,
                        LPARAM lparam);
  bool CaptureDesktop();
  void CollectWindows();
  RECT MonitorAt(POINT screen_point) const;
  HWND WindowAt(POINT screen_point, RECT* bounds) const;
  void UpdateHighlight(POINT client_point);
  void Paint(HWND window);
  std::vector<uint8_t> CaptureRect(RECT screen_rect) const;
  std::vector<uint8_t> CaptureWindow(HWND window) const;
  void Complete(std::vector<uint8_t> png = {}, std::string error = {});
  void ReleaseDesktop();

  HWND owner_ = nullptr;
  HWND overlay_ = nullptr;
  HDC desktop_dc_ = nullptr;
  HBITMAP desktop_bitmap_ = nullptr;
  HGDIOBJ previous_bitmap_ = nullptr;
  RECT virtual_bounds_{};
  RECT highlighted_{};
  POINT drag_start_{};
  bool dragging_ = false;
  bool completed_ = false;
  ScreenshotMode mode_ = ScreenshotMode::kRegion;
  HWND selected_window_ = nullptr;
  std::vector<WindowCandidate> windows_;
  Completion completion_;
};

#endif  // RUNNER_SCREENSHOT_CAPTURE_H_
