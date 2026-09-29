#include "clipboard_bridge.h"

#include <gdiplus.h>
#include <objidl.h>
#include <shellapi.h>
#include <shlobj.h>

#include <algorithm>
#include <cstring>
#include <cwchar>
#include <memory>

namespace {

constexpr SIZE_T kMaxDibBytes = 64 * 1024 * 1024;

std::string Utf8(const std::wstring& wide) {
  if (wide.empty()) return {};
  const int n = WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                                   static_cast<int>(wide.size()), nullptr, 0,
                                   nullptr, nullptr);
  if (n <= 0) return {};
  std::string result(n, '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                      result.data(), n, nullptr, nullptr);
  return result;
}

std::wstring Wide(const std::string& utf8) {
  if (utf8.empty()) return {};
  const int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                    utf8.data(), static_cast<int>(utf8.size()),
                                    nullptr, 0);
  if (n <= 0) return {};
  std::wstring result(n, L'\0');
  MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(),
                      static_cast<int>(utf8.size()), result.data(), n);
  return result;
}

std::string ClipboardOwnerProcess() {
  HWND clipboard_owner = GetClipboardOwner();
  if (!clipboard_owner) return {};
  DWORD pid = 0;
  GetWindowThreadProcessId(clipboard_owner, &pid);
  if (pid == 0) return {};
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!process) return {};
  std::wstring path(32768, L'\0');
  DWORD length = static_cast<DWORD>(path.size());
  const BOOL ok = QueryFullProcessImageNameW(process, 0, path.data(), &length);
  CloseHandle(process);
  if (!ok || length == 0) return {};
  path.resize(length);
  const auto separator = path.find_last_of(L"\\/");
  return Utf8(separator == std::wstring::npos ? path : path.substr(separator + 1));
}

bool PngEncoder(CLSID* out) {
  UINT count = 0;
  UINT bytes = 0;
  if (Gdiplus::GetImageEncodersSize(&count, &bytes) != Gdiplus::Ok ||
      bytes == 0) return false;
  std::vector<uint8_t> storage(bytes);
  auto* encoders = reinterpret_cast<Gdiplus::ImageCodecInfo*>(storage.data());
  if (Gdiplus::GetImageEncoders(count, bytes, encoders) != Gdiplus::Ok) {
    return false;
  }
  for (UINT i = 0; i < count; ++i) {
    if (wcscmp(encoders[i].MimeType, L"image/png") == 0) {
      *out = encoders[i].Clsid;
      return true;
    }
  }
  return false;
}

std::vector<uint8_t> EncodeBitmap(HBITMAP bitmap) {
  if (!bitmap) return {};
  Gdiplus::Bitmap image(bitmap, nullptr);
  if (image.GetLastStatus() != Gdiplus::Ok) return {};
  CLSID encoder{};
  if (!PngEncoder(&encoder)) return {};
  IStream* stream = nullptr;
  if (CreateStreamOnHGlobal(nullptr, TRUE, &stream) != S_OK) return {};
  std::vector<uint8_t> bytes;
  if (image.Save(stream, &encoder) == Gdiplus::Ok) {
    HGLOBAL memory = nullptr;
    if (GetHGlobalFromStream(stream, &memory) == S_OK && memory) {
      STATSTG stats{};
      const SIZE_T size = stream->Stat(&stats, STATFLAG_NONAME) == S_OK
          ? static_cast<SIZE_T>(stats.cbSize.QuadPart) : 0;
      if (size > 0 && size <= kMaxDibBytes && size <= GlobalSize(memory)) {
        const auto* data = static_cast<const uint8_t*>(GlobalLock(memory));
        if (data) {
          bytes.assign(data, data + size);
          GlobalUnlock(memory);
        }
      }
    }
  }
  stream->Release();
  return bytes;
}

std::vector<uint8_t> EncodeDib(HANDLE dib) {
  if (!dib) return {};
  const SIZE_T size = GlobalSize(dib);
  if (size < sizeof(BITMAPINFOHEADER) || size > kMaxDibBytes) return {};
  auto* info = static_cast<BITMAPINFO*>(GlobalLock(dib));
  if (!info) return {};
  const auto& header = info->bmiHeader;
  std::vector<uint8_t> bytes;
  if (header.biSize >= sizeof(BITMAPINFOHEADER) &&
      header.biWidth > 0 && header.biWidth <= 16384 &&
      header.biHeight != 0 && header.biHeight >= -16384 &&
      header.biHeight <= 16384 &&
      (header.biCompression == BI_RGB || header.biCompression == BI_BITFIELDS)) {
    const SIZE_T colors = header.biBitCount <= 8
        ? (header.biClrUsed != 0 ? header.biClrUsed : 1u << header.biBitCount)
        : 0;
    const SIZE_T masks = header.biCompression == BI_BITFIELDS &&
                                 header.biSize == sizeof(BITMAPINFOHEADER)
                             ? 3 * sizeof(DWORD) : 0;
    const SIZE_T offset = header.biSize + colors * sizeof(RGBQUAD) + masks;
    if (offset < size) {
      HDC dc = GetDC(nullptr);
      if (dc) {
        auto* pixels = reinterpret_cast<const uint8_t*>(info) + offset;
        HBITMAP bitmap = CreateDIBitmap(dc, &header, CBM_INIT, pixels, info,
                                       DIB_RGB_COLORS);
        if (bitmap) {
          bytes = EncodeBitmap(bitmap);
          DeleteObject(bitmap);
        }
        ReleaseDC(nullptr, dc);
      }
    }
  }
  GlobalUnlock(dib);
  return bytes;
}

}  // namespace

std::vector<uint8_t> EncodeBitmapToPng(HBITMAP bitmap) {
  return EncodeBitmap(bitmap);
}

flutter::EncodableMap ReadClipboardSnapshot(HWND owner) {
  flutter::EncodableMap snapshot{{flutter::EncodableValue("type"),
                                  flutter::EncodableValue("none")}};
  if (!OpenClipboard(owner)) return snapshot;
  snapshot[flutter::EncodableValue("ownedByClipy")] =
      flutter::EncodableValue(GetClipboardOwner() == owner);
  const std::string source_app = ClipboardOwnerProcess();
  if (!source_app.empty()) {
    snapshot[flutter::EncodableValue("sourceApp")] =
        flutter::EncodableValue(source_app);
  }

  if (IsClipboardFormatAvailable(CF_HDROP)) {
    HDROP drop = static_cast<HDROP>(GetClipboardData(CF_HDROP));
    if (drop) {
      flutter::EncodableList files;
      const UINT count = DragQueryFileW(drop, 0xFFFFFFFF, nullptr, 0);
      for (UINT i = 0; i < count && i < 256; ++i) {
        const UINT length = DragQueryFileW(drop, i, nullptr, 0);
        std::wstring path(length + 1, L'\0');
        DragQueryFileW(drop, i, path.data(), length + 1);
        path.resize(length);
        files.emplace_back(Utf8(path));
      }
      if (!files.empty()) {
        snapshot[flutter::EncodableValue("type")] =
            flutter::EncodableValue("files");
        snapshot[flutter::EncodableValue("paths")] =
            flutter::EncodableValue(std::move(files));
        CloseClipboard();
        return snapshot;
      }
    }
  }

  std::vector<uint8_t> image;
  const UINT png_format = RegisterClipboardFormatW(L"PNG");
  if (png_format && IsClipboardFormatAvailable(png_format)) {
    HANDLE memory = GetClipboardData(png_format);
    const SIZE_T size = memory ? GlobalSize(memory) : 0;
    if (size > 0 && size <= kMaxDibBytes) {
      const auto* bytes = static_cast<const uint8_t*>(GlobalLock(memory));
      if (bytes) {
        image.assign(bytes, bytes + size);
        GlobalUnlock(memory);
      }
    }
  }
  if (image.empty() && IsClipboardFormatAvailable(CF_DIBV5)) {
    image = EncodeDib(GetClipboardData(CF_DIBV5));
  }
  if (image.empty() && IsClipboardFormatAvailable(CF_DIB)) {
    image = EncodeDib(GetClipboardData(CF_DIB));
  }
  if (image.empty() && IsClipboardFormatAvailable(CF_BITMAP)) {
    image = EncodeBitmap(static_cast<HBITMAP>(GetClipboardData(CF_BITMAP)));
  }
  if (!image.empty()) {
    snapshot[flutter::EncodableValue("type")] =
        flutter::EncodableValue("image");
    snapshot[flutter::EncodableValue("bytes")] =
        flutter::EncodableValue(std::move(image));
    CloseClipboard();
    return snapshot;
  }

  if (IsClipboardFormatAvailable(CF_UNICODETEXT)) {
    HANDLE text = GetClipboardData(CF_UNICODETEXT);
    if (text) {
      const auto* value = static_cast<const wchar_t*>(GlobalLock(text));
      if (value) {
        snapshot[flutter::EncodableValue("type")] =
            flutter::EncodableValue("text");
        snapshot[flutter::EncodableValue("text")] =
            flutter::EncodableValue(Utf8(value));
        GlobalUnlock(text);
      }
    }
  }
  CloseClipboard();
  return snapshot;
}

bool WriteClipboardImage(HWND owner, const std::vector<uint8_t>& png) {
  if (png.empty() || png.size() > kMaxDibBytes) return false;
  HGLOBAL source = GlobalAlloc(GMEM_MOVEABLE, png.size());
  if (!source) return false;
  void* data = GlobalLock(source);
  if (!data) {
    GlobalFree(source);
    return false;
  }
  memcpy(data, png.data(), png.size());
  GlobalUnlock(source);

  IStream* stream = nullptr;
  if (CreateStreamOnHGlobal(source, TRUE, &stream) != S_OK) {
    GlobalFree(source);
    return false;
  }
  HBITMAP handle = nullptr;
  {
    Gdiplus::Bitmap bitmap(stream);
    if (bitmap.GetLastStatus() == Gdiplus::Ok) {
      bitmap.GetHBITMAP(Gdiplus::Color(255, 255, 255), &handle);
    }
  }
  stream->Release();  // Releases source HGLOBAL.
  if (!handle || !OpenClipboard(owner)) {
    if (handle) DeleteObject(handle);
    return false;
  }
  EmptyClipboard();
  const bool written = SetClipboardData(CF_BITMAP, handle) != nullptr;
  if (!written) DeleteObject(handle);
  CloseClipboard();
  return written;
}

bool WriteClipboardText(HWND owner, const std::string& text) {
  const std::wstring wide = Wide(text);
  if (wide.empty()) return false;
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, (wide.size() + 1) * sizeof(wchar_t));
  if (!memory) return false;
  void* data = GlobalLock(memory);
  if (!data) {
    GlobalFree(memory);
    return false;
  }
  memcpy(data, wide.c_str(), (wide.size() + 1) * sizeof(wchar_t));
  GlobalUnlock(memory);
  if (!OpenClipboard(owner)) {
    GlobalFree(memory);
    return false;
  }
  EmptyClipboard();
  const bool written = SetClipboardData(CF_UNICODETEXT, memory) != nullptr;
  if (!written) GlobalFree(memory);
  CloseClipboard();
  return written;
}

bool WriteClipboardFiles(HWND owner, const std::vector<std::string>& paths) {
  if (paths.empty() || paths.size() > 256) return false;
  std::vector<std::wstring> wide;
  SIZE_T characters = 1;
  for (const auto& path : paths) {
    auto item = Wide(path);
    if (item.empty() ||
        GetFileAttributesW(item.c_str()) == INVALID_FILE_ATTRIBUTES) return false;
    characters += item.size() + 1;
    wide.push_back(std::move(item));
  }
  const SIZE_T size = sizeof(DROPFILES) + characters * sizeof(wchar_t);
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT, size);
  if (!memory) return false;
  auto* drop = static_cast<DROPFILES*>(GlobalLock(memory));
  if (!drop) {
    GlobalFree(memory);
    return false;
  }
  drop->pFiles = sizeof(DROPFILES);
  drop->fWide = TRUE;
  auto* cursor = reinterpret_cast<wchar_t*>(reinterpret_cast<uint8_t*>(drop) + sizeof(DROPFILES));
  for (const auto& path : wide) {
    memcpy(cursor, path.c_str(), (path.size() + 1) * sizeof(wchar_t));
    cursor += path.size() + 1;
  }
  *cursor = L'\0';
  GlobalUnlock(memory);
  if (!OpenClipboard(owner)) {
    GlobalFree(memory);
    return false;
  }
  EmptyClipboard();
  const bool written = SetClipboardData(CF_HDROP, memory) != nullptr;
  if (!written) GlobalFree(memory);
  CloseClipboard();
  return written;
}

std::string KnownFolderPath(REFKNOWNFOLDERID folder) {
  PWSTR path = nullptr;
  if (SHGetKnownFolderPath(folder, KF_FLAG_CREATE, nullptr, &path) != S_OK ||
      !path) return {};
  const std::string utf8 = Utf8(path);
  CoTaskMemFree(path);
  return utf8;
}

bool RevealFileInExplorer(const std::string& path) {
  const std::wstring wide = Wide(path);
  if (wide.empty()) return false;
  if (GetFileAttributesW(wide.c_str()) == INVALID_FILE_ATTRIBUTES) return false;
  const std::wstring argument = L"/select,\"" + wide + L"\"";
  return reinterpret_cast<INT_PTR>(ShellExecuteW(
      nullptr, L"open", L"explorer.exe", argument.c_str(), nullptr,
      SW_SHOWNORMAL)) > 32;
}
