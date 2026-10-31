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

ScreenshotCapture::ScreenshotCapture(HWND owner, Completion completion,
                                     std::function<void(const char*)> trace)
    : owner_(owner), trace_(std::move(trace)), completion_(std::move(completion)) {}

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
  const RECT monitor = MonitorAt(cursor);
  const int scale = std::max(96u, GetDpiForWindow(overlay_));
  toolbar_item_width_ = MulDiv(92, scale, 96);
  const int toolbar_width = toolbar_item_width_ * 4;
  const int toolbar_height = MulDiv(44, scale, 96);
  const int left = monitor.left - virtual_bounds_.left +
                   std::max(0, (Width(monitor) - toolbar_width) / 2);
  const int top = monitor.top - virtual_bounds_.top + MulDiv(18, scale, 96);
  toolbar_ = RECT{left, top, left + toolbar_width, top + toolbar_height};
  InvalidateRect(overlay_, nullptr, FALSE);
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
  if (!captured) { ReleaseDesktop(); return false; }
  // Build the opaque dimmed frame once. GDI+ alpha fill against a display DC
  // performs costly readback on virtual/translated GPUs and blocks input.
  BITMAPINFO info{};
  info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  info.bmiHeader.biWidth = width;
  info.bmiHeader.biHeight = -height;
  info.bmiHeader.biPlanes = 1;
  info.bmiHeader.biBitCount = 32;
  info.bmiHeader.biCompression = BI_RGB;
  void* pixels = nullptr;
  dimmed_dc_ = CreateCompatibleDC(desktop_dc_);
  dimmed_bitmap_ = CreateDIBSection(desktop_dc_, &info, DIB_RGB_COLORS, &pixels, nullptr, 0);
  if (!dimmed_dc_ || !dimmed_bitmap_ || !pixels) { ReleaseDesktop(); return false; }
  previous_dimmed_ = SelectObject(dimmed_dc_, dimmed_bitmap_);
  if (!BitBlt(dimmed_dc_, 0, 0, width, height, desktop_dc_, 0, 0, SRCCOPY)) {
    ReleaseDesktop(); return false;
  }
  GdiFlush();
  auto* data = static_cast<uint32_t*>(pixels);
  const size_t count = static_cast<size_t>(width) * height;
  for (size_t i = 0; i < count; ++i) data[i] = ((data[i] & 0x00FEFEFEu) >> 1) | 0xFF000000u;
  return true;
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

void ScreenshotCapture::SetMode(ScreenshotMode mode) {
  if (dragging_) {
    dragging_ = false;
    if (GetCapture() == overlay_) ReleaseCapture();
  }
  mode_ = mode;
  highlighted_ = RECT{};
  selected_window_ = nullptr;
  if (mode_ == ScreenshotMode::kWindow && windows_.empty()) CollectWindows();
  POINT cursor{};
  GetCursorPos(&cursor);
  UpdateHighlight(POINT{cursor.x - virtual_bounds_.left,
                        cursor.y - virtual_bounds_.top});
  InvalidateRect(overlay_, nullptr, FALSE);
}

int ScreenshotCapture::ToolbarItemAt(POINT point) const {
  if (!PtInRect(&toolbar_, point)) return -1;
  return std::min(3, static_cast<int>((point.x - toolbar_.left) / toolbar_item_width_));
}

void ScreenshotCapture::Paint(HWND window) {
  PAINTSTRUCT paint{};
  HDC target = BeginPaint(window, &paint);
  if (!target) return;
  const int width = Width(virtual_bounds_);
  const int height = Height(virtual_bounds_);
  if (first_paint_ && trace_) trace_("first-paint-begin");
  BitBlt(target, 0, 0, width, height, dimmed_dc_, 0, 0, SRCCOPY);
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
  // Compact mode switcher remains outside the captured frozen bitmap.
  HBRUSH bar_brush = CreateSolidBrush(RGB(245, 245, 245));
  HPEN bar_pen = CreatePen(PS_SOLID, 1, RGB(205, 205, 205));
  HGDIOBJ old_pen = SelectObject(target, bar_pen);
  HGDIOBJ old_brush = SelectObject(target, bar_brush);
  RoundRect(target, toolbar_.left, toolbar_.top, toolbar_.right,
            toolbar_.bottom, 8, 8);
  SelectObject(target, old_brush);
  SelectObject(target, old_pen);
  DeleteObject(bar_brush);
  DeleteObject(bar_pen);
  SetBkMode(target, TRANSPARENT);
  HGDIOBJ old_font = SelectObject(target, GetStockObject(DEFAULT_GUI_FONT));
  const wchar_t* labels[] = {L"Region / 区域", L"Window / 窗口",
                             L"Display / 屏幕", L"Esc / 取消"};
  const int active = mode_ == ScreenshotMode::kRegion ? 0 :
                     mode_ == ScreenshotMode::kWindow ? 1 : 2;
  for (int i = 0; i < 4; ++i) {
    RECT item{toolbar_.left + i * toolbar_item_width_, toolbar_.top + 4,
              toolbar_.left + (i + 1) * toolbar_item_width_, toolbar_.bottom - 4};
    if (i == active) {
      HBRUSH selected = CreateSolidBrush(RGB(225, 234, 249));
      FillRect(target, &item, selected);
      DeleteObject(selected);
    }
    SetTextColor(target, i == active ? RGB(0, 85, 214) : RGB(35, 35, 35));
    DrawTextW(target, labels[i], -1, &item,
              DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
  }
  if (Width(highlighted_) > 0 && Height(highlighted_) > 0) {
    wchar_t dimensions[64]{};
    swprintf_s(dimensions, L"%d × %d", Width(highlighted_), Height(highlighted_));
    RECT hud{highlighted_.left, std::max(0L, highlighted_.top - 26),
             highlighted_.left + 140, std::max(0L, highlighted_.top - 2)};
    HBRUSH hud_brush = CreateSolidBrush(RGB(35, 35, 35));
    FillRect(target, &hud, hud_brush);
    DeleteObject(hud_brush);
    SetTextColor(target, RGB(255, 255, 255));
    DrawTextW(target, dimensions, -1, &hud, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  }
  SelectObject(target, old_font);
  EndPaint(window, &paint);
  if (first_paint_ && trace_) trace_("first-paint-end");
  first_paint_ = false;
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
  if (dimmed_dc_) {
    if (previous_dimmed_) SelectObject(dimmed_dc_, previous_dimmed_);
    previous_dimmed_ = nullptr;
    DeleteDC(dimmed_dc_); dimmed_dc_ = nullptr;
  }
  if (dimmed_bitmap_) { DeleteObject(dimmed_bitmap_); dimmed_bitmap_ = nullptr; }
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
  // The owner restores focus after this overlay callback has unwound.
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
      const int item = ToolbarItemAt(point);
      if (item >= 0) {
        toolbar_click_ = true;
        if (item == 3) { Cancel(); return 0; }
        SetMode(item == 0 ? ScreenshotMode::kRegion :
                item == 1 ? ScreenshotMode::kWindow : ScreenshotMode::kFullscreen);
        return 0;
      }
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
      if (toolbar_click_) { toolbar_click_ = false; return 0; }
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
      if (wparam == VK_TAB) {
        SetMode(mode_ == ScreenshotMode::kRegion ? ScreenshotMode::kWindow :
                mode_ == ScreenshotMode::kWindow ? ScreenshotMode::kFullscreen : ScreenshotMode::kRegion);
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
