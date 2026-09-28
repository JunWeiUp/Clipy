#ifndef RUNNER_CLIPBOARD_BRIDGE_H_
#define RUNNER_CLIPBOARD_BRIDGE_H_

#include <flutter/encodable_value.h>
#include <shlobj.h>
#include <windows.h>

#include <cstdint>
#include <string>
#include <vector>

// Clipboard access stays in the Windows host. Dart owns history, persistence,
// deduplication and the LAN protocol.
flutter::EncodableMap ReadClipboardSnapshot(HWND owner);
bool WriteClipboardImage(HWND owner, const std::vector<uint8_t>& png);
bool WriteClipboardText(HWND owner, const std::string& text);
bool WriteClipboardFiles(HWND owner, const std::vector<std::string>& paths);
std::string KnownFolderPath(REFKNOWNFOLDERID folder);
bool RevealFileInExplorer(const std::string& path);

#endif  // RUNNER_CLIPBOARD_BRIDGE_H_
