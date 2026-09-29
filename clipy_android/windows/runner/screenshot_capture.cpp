#include "screenshot_capture.h"

#include <dwmapi.h>
#include <gdiplus.h>
#include <windowsx.h>

#include <algorithm>
#include <cstdint>
#include <utility>

#include "clipboard_bridge.h"

namespace {

constexpr wchar_t kOverlayClass[] = L"ClipyCloneScreenshotOverlay";
constexpr int64_t kMaximumPixels = 64'000'000;
constexpr UINT kPrintWindowRenderFullContent = 0x00000002;

int Width(const RECT& rect) { return rect.right - rect.left; }
int Height(const RECT& rect) { return rect.bottom - rect.top; }

bool SameRect(const RECT& a, const RECT& b) {
  return a.left == b.left && a.top == b.top && a.right == b.right &&
         a.bottom == b.bottom;
}

RECT NormalizedRect(POINT a, POINT b) {
  return RECT{std::min(a.x, b.x), std::min(a.y, b.y),
              std::max(a.x, b.x), std::max(a.y, b.y)};
}

bool ValidSize(int width, int height) {
  return width > 0 && height > 0 &&
         static_cast<int64_t>(width) * height <= kMaximumPixels;
}

}  // namespace

ScreenshotCapture::ScreenshotCapture(HWND owner, Completion completion)
    : owner_(owner), completion_(std::move(completion)) {}

ScreenshotCapture::~ScreenshotCapture() {
  // The Flutter window cancels an active session before destroying its engine.
  if (overlay_) DestroyWindow(overlay_);
  ReleaseDesktop();
}

bool ScreenshotCapture::Start(ScreenshotMode mode) {
  if (overlay_ || completed_ || !IsWindow(owner_)) return false;
  mode_ = mode;
  if (!CaptureDesktop()) return false;
  if (mode_ == ScreenshotMode::kWindow) CollectWindows();

  WNDCLASSW window_class{};
  window_class.lpfnWndProc = WindowProc;
  window_class.hInstance = GetModuleHandleW(nullptr);
  window_class.hCursor = LoadCursorW(nullptr, IDC_CROSS);
  window_class.lpszClassName = kOverlayClass;
  if (!RegisterClassW(&window_class) &&
      GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
    ReleaseDesktop();
    return false;
  }

  overlay_ = CreateWindowExW(
      WS_EX_TOPMOST | WS_EX_TOOLWINDOW, kOverlayClass, L"Clipy screenshot",
      WS_POPUP, virtual_bounds_.left, virtual_bounds_.top,
      Width(virtual_bounds_), Height(virtual_bounds_), owner_, nullptr,
      GetModuleHandleW(nullptr), this);
  if (!overlay_) {
    ReleaseDesktop();
    return false;
  }
  ShowWindow(overlay_, SW_SHOW);
  SetWindowPos(overlay_, HWND_TOPMOST, virtual_bounds_.left,
               virtual_bounds_.top, Width(virtual_bounds_),
               Height(virtual_bounds_), SWP_SHOWWINDOW);
  SetForegroundWindow(overlay_);
  SetFocus(overlay_);
  POINT cursor{};
  GetCursorPos(&cursor);
  UpdateHighlight(POINT{cursor.x - virtual_bounds_.left,
                        cursor.y - virtual_bounds_.top});
  return true;
}

void ScreenshotCapture::Cancel() {
  if (!completed_) Complete();
}

bool ScreenshotCapture::CaptureDesktop() {
  virtual_bounds_ = RECT{
      GetSystemMetrics(SM_XVIRTUALSCREEN), GetSystemMetrics(SM_YVIRTUALSCREEN),
      GetSystemMetrics(SM_XVIRTUALSCREEN) +
          GetSystemMetrics(SM_CXVIRTUALSCREEN),
      GetSystemMetrics(SM_YVIRTUALSCREEN) +
          GetSystemMetrics(SM_CYVIRTUALSCREEN)};
  const int width = Width(virtual_bounds_);
  const int height = Height(virtual_bounds_);
  if (!ValidSize(width, height)) return false;

  HDC screen = GetDC(nullptr);
  if (!screen) return false;
  desktop_dc_ = CreateCompatibleDC(screen);
  desktop_bitmap_ = desktop_dc_ ? CreateCompatibleBitmap(screen, width, height)
                                : nullptr;
  if (!desktop_dc_ || !desktop_bitmap_) {
    ReleaseDC(nullptr, screen);
    ReleaseDesktop();
    return false;
  }
  previous_bitmap_ = SelectObject(desktop_dc_, desktop_bitmap_);
  const bool captured = BitBlt(desktop_dc_, 0, 0, width, height, screen,
                               virtual_bounds_.left, virtual_bounds_.top,
                               SRCCOPY | CAPTUREBLT) != FALSE;
  ReleaseDC(nullptr, screen);
  if (!captured) ReleaseDesktop();
  return captured;
}

void ScreenshotCapture::CollectWindows() {
  windows_.clear();
  EnumWindows(
      [](HWND window, LPARAM context) -> BOOL {
        auto* self = reinterpret_cast<ScreenshotCapture*>(context);
        if (window == self->owner_ || window == GetShellWindow() ||
            !IsWindowVisible(window) ||
            IsIconic(window) || GetAncestor(window, GA_ROOT) != window ||
            (GetWindowLongPtrW(window, GWL_EXSTYLE) & WS_EX_TOOLWINDOW)) {
          return TRUE;
        }
        DWORD cloaked = 0;
        if (SUCCEEDED(DwmGetWindowAttribute(window, DWMWA_CLOAKED, &cloaked,
                                             sizeof(cloaked))) &&
            cloaked != 0) {
          return TRUE;
        }
        RECT bounds{};
        if (!GetWindowRect(window, &bounds) || Width(bounds) < 32 ||
            Height(bounds) < 32 ||
            !ValidSize(Width(bounds), Height(bounds))) {
          return TRUE;
        }
        RECT visible{};
        if (!IntersectRect(&visible, &bounds, &self->virtual_bounds_)) {
          return TRUE;
        }
        self->windows_.push_back(WindowCandidate{window, bounds});
        return TRUE;
      },
      reinterpret_cast<LPARAM>(this));
}

RECT ScreenshotCapture::MonitorAt(POINT screen_point) const {
  const HMONITOR monitor = MonitorFromPoint(screen_point, MONITOR_DEFAULTTONEAREST);
  MONITORINFO info{};
  info.cbSize = sizeof(info);
  return monitor && GetMonitorInfoW(monitor, &info) ? info.rcMonitor
                                                     : virtual_bounds_;
}

HWND ScreenshotCapture::WindowAt(POINT screen_point, RECT* bounds) const {
  for (const auto& candidate : windows_) {
    if (IsWindow(candidate.handle) && PtInRect(&candidate.bounds, screen_point)) {
      if (bounds) *bounds = candidate.bounds;
      return candidate.handle;
    }
  }
  return nullptr;
}

void ScreenshotCapture::UpdateHighlight(POINT client_point) {
  if (!overlay_ || dragging_) return;
  RECT next{};
  const POINT screen_point{client_point.x + virtual_bounds_.left,
                           client_point.y + virtual_bounds_.top};
  if (mode_ == ScreenshotMode::kFullscreen) {
    next = MonitorAt(screen_point);
  } else if (mode_ == ScreenshotMode::kWindow) {
    selected_window_ = WindowAt(screen_point, &next);
  } else {
    return;
  }
  next.left -= virtual_bounds_.left;
  next.right -= virtual_bounds_.left;
  next.top -= virtual_bounds_.top;
  next.bottom -= virtual_bounds_.top;
  if (!SameRect(next, highlighted_)) {
    highlighted_ = next;
    InvalidateRect(overlay_, nullptr, FALSE);
  }
}

void ScreenshotCapture::Paint(HWND window) {
  PAINTSTRUCT paint{};
  HDC target = BeginPaint(window, &paint);
  if (!target) return;
  const int width = Width(virtual_bounds_);
  const int height = Height(virtual_bounds_);
  BitBlt(target, 0, 0, width, height, desktop_dc_, 0, 0, SRCCOPY);
  {
    Gdiplus::Graphics graphics(target);
    Gdiplus::SolidBrush shade(Gdiplus::Color(125, 0, 0, 0));
    graphics.FillRectangle(&shade, 0, 0, width, height);
    graphics.Flush(Gdiplus::FlushIntentionSync);
  }
  if (Width(highlighted_) > 0 && Height(highlighted_) > 0) {
    const int left = std::max(0, static_cast<int>(highlighted_.left));
    const int top = std::max(0, static_cast<int>(highlighted_.top));
    const int right = std::min(width, static_cast<int>(highlighted_.right));
    const int bottom = std::min(height, static_cast<int>(highlighted_.bottom));
    if (right > left && bottom > top) {
      BitBlt(target, left, top, right - left, bottom - top, desktop_dc_,
             left, top, SRCCOPY);
      HPEN outline = CreatePen(PS_SOLID, 2, RGB(42, 136, 255));
      HGDIOBJ old_pen = SelectObject(target, outline);
      HGDIOBJ old_brush = SelectObject(target, GetStockObject(NULL_BRUSH));
      Rectangle(target, left, top, right, bottom);
      SelectObject(target, old_brush);
      SelectObject(target, old_pen);
      DeleteObject(outline);
    }
  }
  SetBkMode(target, TRANSPARENT);
  SetTextColor(target, RGB(255, 255, 255));
  HGDIOBJ old_font = SelectObject(target, GetStockObject(DEFAULT_GUI_FONT));
  const wchar_t* hint = mode_ == ScreenshotMode::kRegion
      ? L"Drag to capture / 拖动选区截图    Esc: Cancel / 取消"
      : mode_ == ScreenshotMode::kWindow
            ? L"Click a window / 点击窗口截图    Esc: Cancel / 取消"
            : L"Click a display / 点击屏幕截图    Esc: Cancel / 取消";
  RECT text_bounds{18, 18, std::min(width - 18, 800), 58};
  DrawTextW(target, hint, -1, &text_bounds, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
  SelectObject(target, old_font);
  EndPaint(window, &paint);
}

std::vector<uint8_t> ScreenshotCapture::CaptureRect(RECT screen_rect) const {
  RECT cropped{};
  if (!IntersectRect(&cropped, &screen_rect, &virtual_bounds_)) return {};
  const int width = Width(cropped);
  const int height = Height(cropped);
  if (!ValidSize(width, height)) return {};
  HDC output = CreateCompatibleDC(desktop_dc_);
  HBITMAP bitmap = output
      ? CreateCompatibleBitmap(desktop_dc_, width, height) : nullptr;
  if (!output || !bitmap) {
    if (bitmap) DeleteObject(bitmap);
    if (output) DeleteDC(output);
    return {};
  }
  HGDIOBJ previous = SelectObject(output, bitmap);
  const BOOL copied = BitBlt(output, 0, 0, width, height, desktop_dc_,
                            cropped.left - virtual_bounds_.left,
                            cropped.top - virtual_bounds_.top, SRCCOPY);
  SelectObject(output, previous);
  DeleteDC(output);
  auto png = copied ? EncodeBitmapToPng(bitmap) : std::vector<uint8_t>{};
  DeleteObject(bitmap);
  return png;
}

std::vector<uint8_t> ScreenshotCapture::CaptureWindow(HWND window) const {
  if (!IsWindow(window) || IsHungAppWindow(window)) return {};
  RECT bounds{};
  if (!GetWindowRect(window, &bounds) ||
      !ValidSize(Width(bounds), Height(bounds))) return {};
  HDC screen = GetDC(nullptr);
  if (!screen) return {};
  HDC output = CreateCompatibleDC(screen);
  HBITMAP bitmap = output ? CreateCompatibleBitmap(
      screen, Width(bounds), Height(bounds)) : nullptr;
  ReleaseDC(nullptr, screen);
  if (!output || !bitmap) {
    if (bitmap) DeleteObject(bitmap);
    if (output) DeleteDC(output);
    return {};
  }
  HGDIOBJ previous = SelectObject(output, bitmap);
  PatBlt(output, 0, 0, Width(bounds), Height(bounds), BLACKNESS);
  const BOOL rendered = PrintWindow(window, output, kPrintWindowRenderFullContent);
  SelectObject(output, previous);
  DeleteDC(output);
  auto png = rendered ? EncodeBitmapToPng(bitmap) : std::vector<uint8_t>{};
  DeleteObject(bitmap);
  return png;
}

void ScreenshotCapture::ReleaseDesktop() {
  if (desktop_dc_) {
    if (previous_bitmap_) SelectObject(desktop_dc_, previous_bitmap_);
    previous_bitmap_ = nullptr;
    DeleteDC(desktop_dc_);
    desktop_dc_ = nullptr;
  }
  if (desktop_bitmap_) {
    DeleteObject(desktop_bitmap_);
    desktop_bitmap_ = nullptr;
  }
  windows_.clear();
}

void ScreenshotCapture::Complete(std::vector<uint8_t> png,
                                 std::string error) {
  if (completed_) return;
  completed_ = true;
  if (GetCapture() == overlay_) ReleaseCapture();
  HWND window = overlay_;
  overlay_ = nullptr;
  if (window) DestroyWindow(window);
  ReleaseDesktop();
  if (IsWindow(owner_)) SetForegroundWindow(owner_);
  if (completion_) {
    auto completion = std::move(completion_);
    completion(std::move(png), std::move(error));
  }
}

LRESULT CALLBACK ScreenshotCapture::WindowProc(
    HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  if (message == WM_NCCREATE) {
    const auto* created = reinterpret_cast<CREATESTRUCTW*>(lparam);
    SetWindowLongPtrW(window, GWLP_USERDATA,
                      reinterpret_cast<LONG_PTR>(created->lpCreateParams));
  }
  auto* self = reinterpret_cast<ScreenshotCapture*>(
      GetWindowLongPtrW(window, GWLP_USERDATA));
  return self ? self->HandleMessage(window, message, wparam, lparam)
              : DefWindowProcW(window, message, wparam, lparam);
}

LRESULT ScreenshotCapture::HandleMessage(
    HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  switch (message) {
    case WM_ERASEBKGND:
      return 1;
    case WM_PAINT:
      Paint(window);
      return 0;
    case WM_SETCURSOR:
      SetCursor(LoadCursorW(nullptr, IDC_CROSS));
      return TRUE;
    case WM_MOUSEMOVE: {
      POINT point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      if (dragging_) {
        RECT next = NormalizedRect(drag_start_, point);
        if (!SameRect(next, highlighted_)) {
          highlighted_ = next;
          InvalidateRect(window, nullptr, FALSE);
        }
      } else {
        UpdateHighlight(point);
      }
      return 0;
    }
    case WM_LBUTTONDOWN: {
      const POINT point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      if (mode_ == ScreenshotMode::kRegion) {
        dragging_ = true;
        drag_start_ = point;
        highlighted_ = RECT{};
        SetCapture(window);
      } else {
        UpdateHighlight(point);
      }
      return 0;
    }
    case WM_LBUTTONUP: {
      const POINT point{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      if (mode_ == ScreenshotMode::kRegion) {
        if (!dragging_) return 0;
        dragging_ = false;
        ReleaseCapture();
        highlighted_ = NormalizedRect(drag_start_, point);
        if (Width(highlighted_) < 6 || Height(highlighted_) < 6) {
          highlighted_ = RECT{};
          InvalidateRect(window, nullptr, FALSE);
          return 0;
        }
      } else {
        UpdateHighlight(point);
        if (mode_ == ScreenshotMode::kWindow && !selected_window_) return 0;
      }
      std::vector<uint8_t> png;
      if (mode_ == ScreenshotMode::kWindow) {
        ShowWindow(window, SW_HIDE);
        png = CaptureWindow(selected_window_);
      } else {
        RECT chosen = highlighted_;
        OffsetRect(&chosen, virtual_bounds_.left, virtual_bounds_.top);
        png = CaptureRect(chosen);
      }
      const bool captured = !png.empty();
      Complete(std::move(png), captured ? "" : "CAPTURE_FAILED");
      return 0;
    }
    case WM_KEYDOWN:
      if (wparam == VK_ESCAPE) {
        Cancel();
        return 0;
      }
      break;
    case WM_RBUTTONDOWN:
      Cancel();
      return 0;
    case WM_NCDESTROY:
      SetWindowLongPtrW(window, GWLP_USERDATA, 0);
      return DefWindowProcW(window, message, wparam, lparam);
  }
  return DefWindowProcW(window, message, wparam, lparam);
}
