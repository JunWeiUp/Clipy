#include <windows.h>
#include <gdiplus.h>
#include <iostream>
#include <stdexcept>
#include "runner/screenshot_capture.h"

void Check(bool value, const char* label) {
  if (!value) throw std::runtime_error(label);
}
int main() {
  Gdiplus::GdiplusStartupInput input;
  ULONG_PTR token = 0;
  Check(Gdiplus::GdiplusStartup(&token, &input, nullptr) == Gdiplus::Ok, "GDI startup");
  HWND owner = CreateWindowW(L"STATIC", L"Clipy capture test owner", WS_OVERLAPPEDWINDOW,
                            0, 0, 100, 100, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
  HWND candidate = CreateWindowW(L"STATIC", L"Clipy capture test target", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                                200, 200, 360, 240, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
  try {
    for (const auto mode : {ScreenshotMode::kRegion, ScreenshotMode::kWindow, ScreenshotMode::kFullscreen}) {
      for (const bool cancel : {true, false}) {
        int callbacks = 0;
        bool valid_result = false;
        ScreenshotCapture capture(owner, [&](std::vector<uint8_t> png, std::string error) {
          ++callbacks;
          valid_result = error.empty() && (cancel ? png.empty() :
              png.size() > 8 && png[0] == 137 && png[1] == 80 && png[2] == 78);
        });
        Check(capture.Start(mode), "start capture");
        HWND overlay = FindWindowW(L"ClipyCloneScreenshotOverlay", nullptr);
        Check(overlay != nullptr, "overlay exists");
        const ULONGLONG paint_start = GetTickCount64();
        UpdateWindow(overlay); // cover the real paint path, not only window creation
        Check(GetTickCount64() - paint_start < 5000, "overlay paint blocked input");
        if (cancel) {
          SendMessageW(overlay, WM_KEYDOWN, VK_ESCAPE, 0);
          capture.Cancel(); // idempotence, including after the HWND is destroyed
        } else {
          POINT point{300, 300};
          ScreenToClient(overlay, &point);
          SendMessageW(overlay, WM_MOUSEMOVE, 0, MAKELPARAM(point.x, point.y));
          SendMessageW(overlay, WM_LBUTTONDOWN, MK_LBUTTON, MAKELPARAM(point.x, point.y));
          if (mode == ScreenshotMode::kRegion) { point.x += 120; point.y += 80; }
          SendMessageW(overlay, WM_LBUTTONUP, 0, MAKELPARAM(point.x, point.y));
        }
        Check(valid_result, "PNG result or cancellation mismatch");
        Check(callbacks == 1 && !capture.active(), "single completion and overlay released");
      }
    }
    for (int i = 0; i < 10; ++i) {
      ScreenshotCapture capture(owner, [](auto, auto) {});
      Check(capture.Start(ScreenshotMode::kRegion), "repeat start");
      capture.Cancel();
    }
    std::cout << "PASS: region/window/display PNG, Esc/cancel, single completion, 10 repeated sessions\n";
  } catch (const std::exception& error) {
    std::cerr << "FAIL: " << error.what() << '\n';
    DestroyWindow(candidate); DestroyWindow(owner); Gdiplus::GdiplusShutdown(token);
    return 1;
  }
  DestroyWindow(candidate); DestroyWindow(owner); Gdiplus::GdiplusShutdown(token);
  return 0;
}
