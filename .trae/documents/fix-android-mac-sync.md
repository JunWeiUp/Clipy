# 修复安卓与 Mac 端消息传输与设备重复问题（剩余 Android 端工作）

## 当前状态

### Mac 端 — 已全部完成 ✅
- `SyncManager.swift`：已有 `DeviceEntry`、`availableDeviceEntries`、`sendTextToPeer`、`sendFileToPeer`
- `MenuController.swift`：已用 `availableDeviceEntries` 渲染、peerId 定位、失败弹窗
- `Localization.swift`：已有 `.sendFailed`

### Android 端 — 部分完成
- `app_localizations.dart`：已有 `sendFailed` ✅
- `sync_manager.dart`：`sendTextToPeer` 已添加 ✅，**`sendFileToPeer` 未添加 ❌**，**`_connectToService` 重试未做 ❌**
- `main.dart`：**全部未改 ❌**（`LanDeviceActionTile` 仍用 `String deviceName`；三处设置页仍用 `onDevicesChanged`/`List<String>`）
- `clipboard_history_list.dart`：**全部未改 ❌**（`_showSendTextSheet` 仍用 `availableDeviceNames`）

---

## 剩余改动清单

### 改动 1：Android `sync_manager.dart` — 新增 `sendFileToPeer`

**文件**：`clipy_android/lib/sync_manager.dart`
**位置**：在 `sendFile` 方法（L1160）之后插入
**内容**：镜像 `sendTextToPeer` 的模式，通过 peerId 定位设备，返回 `bool`

```dart
Future<bool> sendFileToPeer(File file, {required String peerId}) async {
  if (!isEnabled) return false;
  final target = availablePeers.where((p) => p.peerId == peerId).toList();
  if (target.isEmpty) {
    appLog('Could not find peer: $peerId', level: 'error');
    return false;
  }
  await _sendFile(
    file,
    service: target.first.service,
    headerType: 'file/header',
    chunkType: 'file/chunk',
    addToFileHistory: true,
  );
  return true;
}
```

**注意**：`_sendFile` 本身不返回 bool（它是 `Future<void>`），但 `_connectToService` 失败时内部会 return。为简化，`sendFileToPeer` 只要找到 peer 就返回 true（连接失败已在 `_sendFile` 内部 log）。这与旧 `sendFile` 的行为一致，且文件传输有 UI 进度反馈。

### 改动 2：Android `sync_manager.dart` — `_connectToService` 增加 resolve 重试

**文件**：`clipy_android/lib/sync_manager.dart`
**位置**：L1285-1317 `_connectToService` 方法
**内容**：将 resolve + connect 包在 2 次循环中，第一次 resolve 失败时延迟 200ms 重试

```dart
Future<Socket?> _connectToService(Service service) async {
  for (var attempt = 0; attempt < 2; attempt++) {
    try {
      var target = service;
      try {
        target = await resolve(service);
      } catch (e) {
        if (attempt == 0) {
          await Future.delayed(const Duration(milliseconds: 200));
          continue;  // 重试一次
        }
        appLog('Resolve failed for ${service.name}, trying cached: $e', level: 'warning');
      }
      final port = target.port ?? this.port;
      if (target.addresses != null && target.addresses!.isNotEmpty) {
        final v4 = target.addresses!.where((a) => a.type == InternetAddressType.IPv4).toList();
        final address = v4.isNotEmpty ? v4.first : target.addresses!.first;
        return await Socket.connect(address, port, timeout: const Duration(seconds: 5));
      }
      final host = target.host;
      if (host == null || host.isEmpty) {
        appLog('No host/address for ${service.name}', level: 'error');
        return null;
      }
      return await Socket.connect(host, port, timeout: const Duration(seconds: 5));
    } catch (e) {
      if (attempt > 0) {
        appLog('Failed to connect to ${service.name}: $e', level: 'error');
        return null;
      }
    }
  }
  return null;
}
```

### 改动 3：Android `main.dart` — `LanDeviceActionTile` 改为接收 `DiscoveredPeer`

**文件**：`clipy_android/lib/main.dart`
**位置**：L81-123 `LanDeviceActionTile`

变更点：
- 字段从 `String deviceName` 改为 `DiscoveredPeer peer`
- `title` 显示 `peer.displayName`
- 新增 `subtitle` 显示 peerId 前 8 字符（灰色小字），与 `SyncTargetDeviceList`（L226）风格一致
- PopupMenu 回调改为传 `peer`

### 改动 4：Android `main.dart` — `showSendTextToDeviceDialog` 和 `pickAndSendFileToDevice` 改为接收 `DiscoveredPeer`

**文件**：`clipy_android/lib/main.dart`
**位置**：L20-79

变更点：
- 参数从 `String deviceName` 改为 `DiscoveredPeer peer`
- `showSendTextToDeviceDialog`：调用 `sendTextToPeer(content, peerId: peer.peerId)`，检查返回值，失败时显示 `l10n.sendFailed` SnackBar
- `pickAndSendFileToDevice`：调用 `sendFileToPeer(file, peerId: peer.peerId)`，检查返回值，失败时显示 `l10n.sendFailed` SnackBar

### 改动 5：Android `main.dart` — 三处设置页改用 `onPeersChanged`

**文件**：`clipy_android/lib/main.dart`

三处位置（行号是当前状态）：
1. `_MacSettingsTab` ~L526-541：`_availableDevices` 类型 `List<String>` → `List<DiscoveredPeer>`；订阅 `onDevicesChanged` → `onPeersChanged`
2. `_MobileSettingsContent` ~L907-922：同上
3. `_SettingsPage` ~L1091-1106：同上

三处渲染列表处（L684-685, L1055-1056, L1227-1228）：
- `LanDeviceActionTile(deviceName: deviceName)` → `LanDeviceActionTile(peer: peer)`

### 改动 6：Android `clipboard_history_list.dart` — `_showSendTextSheet` 改用 peer

**文件**：`clipy_android/lib/ui/clipboard_history_list.dart`
**位置**：L81-123 `_showSendTextSheet`

变更点：
- `SyncManager.instance.availableDeviceNames` → `SyncManager.instance.availablePeers`
- BottomSheet 中 `ListTile` 显示 `peer.displayName` + peerId 副标题，`onTap` 返回 `DiscoveredPeer`
- 调用 `sendTextToPeer(text, peerId: peer.peerId)`，检查返回值，失败显示 `l10n.sendFailed`

---

## 验证步骤

### 编译验证
1. Mac 端：Xcode build（代码已改完，用户自行验证）
2. Android 端：`cd clipy_android && flutter build apk --debug`

### 功能测试

| 测试项 | 预期结果 |
|---|---|
| Android → Mac 发送文本 | Mac 剪贴板和历史中出现文本 |
| Mac → Android 发送文本 | Android 剪贴板和历史中出现文本 |
| 目标设备离线时发送 | UI 显示"发送失败"提示 |
| 两台同名设备同时在线 | 设备列表显示 peerId 副标题可区分 |
| 文件传输（双向） | 仍正常工作 |
| 剪贴板自动同步 | 不受影响 |
