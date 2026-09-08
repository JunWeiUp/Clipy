import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppLanguage {
  zh('zh', '中文'),
  en('en', 'English');

  const AppLanguage(this.code, this.displayName);

  final String code;
  final String displayName;

  static AppLanguage fromCode(String? code) {
    return AppLanguage.values.firstWhere(
      (language) => language.code == code,
      orElse: () => systemDefault,
    );
  }

  static AppLanguage get systemDefault {
    return PlatformDispatcher.instance.locale.languageCode == 'zh'
        ? AppLanguage.zh
        : AppLanguage.en;
  }
}

class AppLanguageController extends ChangeNotifier {
  AppLanguageController._();

  static final instance = AppLanguageController._();
  static const _prefsKey = 'appLanguage';

  AppLanguage _language = AppLanguage.systemDefault;

  AppLanguage get language => _language;
  AppStrings get strings => AppStrings(_language);
  Locale get locale => _language == AppLanguage.zh
      ? const Locale('zh', 'CN')
      : const Locale('en', 'US');

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _language = AppLanguage.fromCode(prefs.getString(_prefsKey));
  }

  Future<void> setLanguage(AppLanguage language) async {
    if (_language == language) return;
    _language = language;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, language.code);
    notifyListeners();
  }
}

extension AppStringsContext on BuildContext {
  AppStrings get l10n => AppLanguageController.instance.strings;
}

class AppStrings {
  AppStrings(this.language);

  final AppLanguage language;

  String get appTitle => 'Clipy';
  String get languageLabel => _t('语言', 'Language');
  String get history => _t('历史记录', 'History');
  String get preferences => _t('偏好设置', 'Preferences');
  String get settings => _t('设置', 'Settings');
  String get status => _t('状态', 'Status');
  String get permissions => _t('权限', 'Permissions');
  String get advancedFeatures => _t('高级功能', 'Advanced');
  String get syncEnabled => _t('局域网同步', 'LAN Sync');
  String get connectedMac => _t('已连接 Mac', 'Connected Mac');
  String get notConnected => _t('未连接', 'Not Connected');
  String get enabled => _t('已启用', 'Enabled');
  String get disabled => _t('已停用', 'Disabled');
  String get permissionNotificationListener =>
      _t('通知监听', 'Notification Listener');
  String get permissionPostNotifications => _t('通知权限', 'Post Notifications');
  String get granted => _t('已授权', 'Granted');
  String get notGranted => _t('未授权', 'Not Granted');
  String get grant => _t('授权', 'Grant');
  String get openAppSettings => _t('打开设置', 'Open Settings');
  String get refreshPermissions => _t('刷新权限状态', 'Refresh Permissions');
  String get notificationListenerIssueTitle =>
      _t('通知同步异常', 'Notification Sync Issue');
  String get notificationListenerPermissionDenied => _t(
    '未授予通知监听权限，无法同步系统通知。请重新授权 Clipy Android。',
    'Notification listener permission is missing. Re-authorize Clipy Android to sync notifications.',
  );
  String get notificationListenerNotConnected => _t(
    '通知监听服务未连接（小米等机型常见）。可先点「重新授权」自动重连；若仍失败，请到系统设置关闭再打开 Clipy 的通知使用权，并允许自启动。',
    'Notification listener disconnected (common on Xiaomi). Tap Re-authorize to force reconnect; if that fails, toggle notification access OFF/ON and allow autostart.',
  );
  String get notificationListenerNotReceiving => _t(
    '手机上有通知但长时间未同步到数据。请重新授权通知监听权限。',
    'Notifications are present on the phone but none have been synced recently. Re-authorize notification access.',
  );
  String get notificationListenerBatteryOptimization => _t(
    '系统省电策略可能已限制后台通知监听。请允许 Clipy Android 后台运行（电池优化白名单）以保证持续同步。',
    'Battery optimization may be killing the background notification listener. Allow Clipy Android to run unrestricted to keep syncing.',
  );
  String get requestBatteryOptimizationExemption =>
      _t('允许后台运行', 'Allow Background');
  String get reauthorizeNotificationListener => _t('重新授权', 'Re-authorize');
  String get notificationListenerRecovered =>
      _t('通知监听已恢复', 'Notification listener recovered');
  String get notificationListenerStillUnavailable => _t(
    '通知监听仍未恢复，请在系统设置中手动开启',
    'Notification listener is still unavailable. Enable it manually in system settings.',
  );
  String get showAdvancedFeatures => _t('显示高级功能', 'Show Advanced Features');
  String get clearHistory => _t('清空历史记录', 'Clear History');
  String get appLogs => _t('应用日志', 'App Logs');
  String get clearLogs => _t('清空日志', 'Clear Logs');
  String get clearLogsConfirm => _t(
    '删除本机全部运行日志？此操作无法撤销。',
    'Delete all runtime logs on this device? This cannot be undone.',
  );
  String get logsCopied => _t('日志已复制到剪贴板', 'Logs copied to clipboard');
  String get copyAll => _t('复制全部', 'Copy All');
  String get noLogs => _t('暂无日志。', 'No logs recorded yet.');
  String get noClipboardHistory => _t('暂无剪贴板历史', 'No clipboard history yet');
  String historyRange(int start, int end) =>
      _t('历史 $start-$end', 'History $start-$end');
  String sourceAndDate(String? source, String date) =>
      '${source ?? unknown} • $date';
  String get unknown => _t('未知', 'Unknown');
  String get copiedToClipboard => _t('已复制到剪贴板', 'Copied to clipboard');
  String get cancel => _t('取消', 'Cancel');
  String get save => _t('保存', 'Save');
  String get delete => _t('删除', 'Delete');
  String get historyLimit => _t('历史数量', 'History Limit');
  String keepRecentItems(int count) =>
      _t('保留最近 $count 条', 'Keep the most recent $count items');
  String get excludedApps =>
      _t('排除的应用（Bundle ID，每行一个）', 'Excluded Apps (bundle IDs, one per line)');
  String get saveExcludedApps => _t('保存排除应用', 'Save Excluded Apps');
  String get enableLanSync => _t('启用局域网同步', 'Enable LAN Sync');
  String get myIPAddress => _t('本机 IP', 'My IP');
  String get syncPort => _t('同步端口', 'Sync Port');
  String get authorizedDevicesComma =>
      _t('授权设备（用逗号分隔）', 'Authorized Devices (comma separated)');
  String get about => _t('关于', 'About');
  String receivedFile(String fileName) =>
      _t('已接收文件：$fileName', 'Received file: $fileName');
  String get view => _t('查看', 'View');
  String couldNotOpenFolder(Object error) =>
      _t('无法打开文件夹：$error', 'Could not open folder: $error');
  String get fileNotFound =>
      _t('文件不存在或已被删除', 'File not found or already deleted');
  String get noFileManager => _t('未找到可用的文件管理器', 'No file manager available');
  String get clipyHistory => _t('Clipy 历史', 'Clipy History');
  String get receivedFiles => _t('已接收文件', 'Received Files');
  String get viewLogs => _t('查看日志', 'View Logs');
  String receiving(String fileName) =>
      _t('正在接收：$fileName', 'Receiving: $fileName');
  String sending(String fileName) => _t('正在发送：$fileName', 'Sending: $fileName');
  String get deviceNameForSync => _t('设备名称（用于同步）', 'Device Name (for Sync)');
  String get enterDeviceName => _t('输入设备名称', 'Enter device name');
  String get deviceNameUpdated =>
      _t('设备名称已更新，同步已重启', 'Device name updated and sync restarted');
  String get syncPairingSecret => _t('同步配对密钥', 'Sync Pairing Secret');
  String get syncPairingSecretHint => _t(
    '所有设备必须填写完全相同的密钥；留空则使用内置默认密钥（局域网内不安全）。',
    'All devices must use the exact same secret. Leave empty to fall back to the built-in default (not safe on a shared LAN).',
  );
  String get syncPairingSecretUpdated =>
      _t('配对密钥已更新，同步已重启', 'Pairing secret updated and sync restarted');
  String get authorizedDevices => _t('授权设备', 'Authorized Devices');
  String get syncTargetsSummary => _t(
    '选择每台设备接收的内容，也可以只发送一次文本或文件。',
    'Choose what each device receives, or send a text or file just once.',
  );
  String get syncTargetsHint => _t(
    '分别勾选要向哪些设备同步剪贴板 / 通知。只需本机授权即可发送，对方无需勾选也能接收。设备列表「发送文本 / 发送文件」连本机授权也不需要。',
    'Choose which devices receive clipboard and/or notifications. Authorization is one-sided: authorize on this device to send; the peer can receive without authorizing you. Device-list Send Text / Send File needs no authorization at all.',
  );
  String get syncClipboardToDevice => _t('同步剪贴板', 'Sync clipboard');
  String get syncNotificationsToDevice => _t('同步通知', 'Sync notifications');
  String get offlineAuthorizedDevices =>
      _t('离线已授权设备（可删除）', 'Offline authorized devices (tap to remove)');
  String get deviceOnline => _t('在线', 'Online');
  String get deviceOffline => _t('离线', 'Offline');
  String get syncLocalNameHint => _t(
    '本机名称：%s，设备 ID：%s…。勾选后即向该设备推送对应内容，对方无需勾选即可接收。',
    'Device: %s (ID: %s…). Check a capability to push; they can receive without checking you.',
  );
  String syncLocalNameHintFor(String displayName, String peerIdShort) =>
      syncLocalNameHint
          .replaceFirst('%s', displayName)
          .replaceFirst('%s', peerIdShort);
  String get lanDevices => _t('局域网设备', 'Devices on Network');
  String get sendFile => _t('发送文件…', 'Send File…');
  String get sendText => _t('发送文本…', 'Send Text…');
  String sendTextTo(String deviceName) =>
      _t('发送文本到 $deviceName', 'Send text to $deviceName');
  String get enterTextToSend => _t('输入要发送的文本', 'Enter text to send');
  String get send => _t('发送', 'Send');
  String textSentTo(String deviceName) =>
      _t('文本已发送至 $deviceName', 'Text sent to $deviceName');
  String fileSentTo(String deviceName) =>
      _t('已发送至 $deviceName', 'Sent to $deviceName');
  String get sendFailed => _t(
    '发送失败，目标设备可能离线或网络异常',
    'Send failed. The target device may be offline or the network is unstable',
  );
  String get noDevicesFound => _t('未发现设备', 'No devices found');
  String get sameWifiHint =>
      _t('请确认其他设备连接到同一个 Wi-Fi', 'Ensure other devices are on the same WiFi');
  String get refreshDevices => _t('刷新设备', 'Refresh Devices');
  String get refreshingDevices => _t('正在刷新…', 'Refreshing…');
  String get devicesRefreshed => _t('已刷新局域网设备', 'LAN devices refreshed');
  String get appRuntimeLogs =>
      _t('用于排查问题的应用运行日志', 'App runtime logs for troubleshooting');
  String get noFilesReceived => _t('暂无已接收文件', 'No files received yet');
  String fromSender(String senderName) =>
      _t('来自：$senderName', 'From: $senderName');

  // Notification Sync
  String get notificationSync => _t('通知同步', 'Notification Sync');
  String get enableNotificationSync => _t('启用通知同步', 'Enable Notification Sync');
  String get notificationPermissionRequired =>
      _t('需要通知监听权限', 'Notification listener permission required');
  String get grantPermission => _t('去授权', 'Grant Permission');
  String get syncNotificationsFrom =>
      _t('同步以下应用的通知', 'Sync notifications from these apps');
  String get syncThisApp => _t('同步此应用', 'Sync this app');
  String get stopSyncingThisApp => _t('停止同步此应用', 'Stop syncing this app');
  String get appSyncEnabled => _t('已开启同步', 'Sync enabled');
  String get appSyncDisabled => _t('未同步', 'Not syncing');
  String get noAppsAvailable => _t('暂无可用应用', 'No apps available');
  String get phoneNotifications => _t('手机通知', 'Phone Notifications');
  String get noNotifications => _t('暂无通知', 'No notifications');
  String get clearAllNotifications => _t('清空通知', 'Clear Notifications');
  String get notificationSettings => _t('通知设置', 'Notification Settings');
  String get dismissOnPhone => _t('在手机上清除', 'Dismiss on Phone');
  String get notificationArchivedBadge => _t('历史', 'History');
  String get notificationListenerPermission =>
      _t('通知监听权限', 'Notification Listener Permission');
  String get permissionGranted => _t('已授权', 'Permission Granted');
  String get permissionNotGranted => _t('未授权', 'Not Granted');
  String notificationFrom(String appName) => _t('来自 $appName', 'From $appName');
  String get searchApps => _t('搜索应用...', 'Search apps...');
  String get selectedAppsCount => _t('已选择应用', 'Selected apps');
  String get notificationHistory => _t('通知历史', 'Notification History');
  String get noNotificationHistory =>
      _t('暂无通知历史记录', 'No notification history yet');
  String get clearNotificationHistory =>
      _t('清空通知历史', 'Clear Notification History');
  String get clearNotificationHistoryConfirm =>
      _t('确定要清空所有通知历史吗？', 'Clear all notification history?');
  String get openNotificationSettings =>
      _t('打开系统通知设置', 'Open System Notification Settings');
  String get permissionGuide => _t(
    '授权后才能监听手机通知并同步到其他设备',
    'Grant permission to listen for and sync phone notifications',
  );
  String notificationsCount(int count) =>
      _t('$count 条通知', '$count notifications');
  String get selectAll => _t('全选', 'Select All');
  String get deselectAll => _t('全部取消', 'Deselect All');
  String get userApps => _t('用户应用', 'User Apps');
  String get systemApps => _t('系统应用', 'System Apps');
  String appCount(int count) => _t('$count 个应用', '$count apps');

  // Notification Sync - two-layer filtering
  String get collect => _t('收集', 'Collect');
  String get sync => _t('同步', 'Sync');
  String get collectAll => _t('收集全部', 'Collect All');
  String get syncAll => _t('同步全部', 'Sync All');
  String get syncing => _t('正在同步', 'Syncing');
  String get paused => _t('已暂停', 'Paused');
  String get syncedSection => _t('可同步', 'Syncable');
  String get collectedSection => _t('可收集', 'Collected');
  String get notCollectedSection => _t('不可收集', 'Not Collected');

  String get clearAll => _t('清空', 'Clear All');
  String get copyContent => _t('复制内容', 'Copy Content');

  // Sync diagnostics card
  String get syncDiagnostics => _t('同步诊断', 'Sync Diagnostics');
  String get diagPeerId => _t('设备 ID', 'Peer ID');
  String get diagServerStatus => _t('服务状态', 'Server');
  String get diagRunning => _t('运行中', 'Running');
  String get diagStopped => _t('已停止', 'Stopped');
  String get diagAuthorizedTargets =>
      _t('已授权剪贴板目标', 'Authorized clipboard targets');
  String get diagConnectedPeers => _t('已连接设备', 'Connected peers');
  String get diagSyncOff => _t('局域网同步未开启', 'LAN sync is off');
  String get diagServerNotBound =>
      _t('服务端口未绑定，请尝试重启同步', 'Server socket not bound — try restarting sync');
  String get diagNoPairingSecret => _t(
    '未设置配对密钥（两端都留空可工作，但只要一端设了密钥就会全部失败）',
    'No pairing secret set (both empty works, but if one side sets a secret all sync fails silently)',
  );
  String get diagNoAuthTargets => _t(
    '未授权任何剪贴板目标——请在上方勾选设备，否则历史不会被投递',
    'No authorized clipboard target — check a device above or history will never be delivered',
  );
  String get diagNoConnection => _t(
    '暂无设备连接，请确认对端已开启同步且在同一局域网',
    'No device connected — make sure the peer has sync on and is on the same LAN',
  );
  String get diagAllGood => _t('同步状态正常', 'Sync looks healthy');

  // Timer home-screen widget
  String get homeWidgetSection => _t('桌面小部件', 'Home-Screen Widget');
  String get timerWidgetTitle => _t('计时部件', 'Timer Widget');
  String get timerWidgetDesc => _t(
    '最长 23:59:59 的桌面倒计时。点击读数打开时、分、秒滚轮，随时开始或暂停。',
    'A home-screen countdown up to 23:59:59. Tap the readout to set hours, minutes and seconds, then start or pause.',
  );
  String get addToHomeScreen => _t('添加到桌面', 'Add to Home Screen');
  String get timerWidgetPinRequested =>
      _t('已请求添加，请在桌面弹窗中确认', 'Pin requested — confirm on the home screen');
  String get timerWidgetPinFailed => _t(
    '无法自动添加：请长按桌面空白处 → 小部件 → Clipy Android 手动添加',
    'Could not pin automatically: long-press an empty area of the home screen → Widgets → Clipy Android',
  );
  String get timerWidgetAdded => _t('已添加到桌面', 'Added to home screen');

  // Mobile design and interaction.
  String get devices => _t('设备', 'Devices');
  String get notifications => _t('通知', 'Notifications');
  String get historyTagline =>
      _t('复制过的，随时找回来。', 'Everything you copied. Within reach.');
  String get devicesTagline =>
      _t('让内容，在设备之间流动。', 'Your devices. Working together.');
  String get settingsTagline =>
      _t('按你的习惯，使用 Clipy。', 'Make Clipy feel like yours.');
  String get searchHistory => _t('搜索内容或来源应用', 'Search content or source app');
  String get allItems => _t('全部', 'All');
  String get textItems => _t('文本', 'Text');
  String get linkItems => _t('链接', 'Links');
  String get fileItems => _t('文件', 'Files');
  String get imageItems => _t('图片', 'Images');
  String get today => _t('今天', 'Today');
  String get yesterday => _t('昨天', 'Yesterday');
  String get older => _t('更早', 'Earlier');
  String get nothingFound => _t('没有匹配的内容', 'No matches yet');
  String get changeSearchHint =>
      _t('换个关键词，或试试其他类型。', 'Try another keyword or a different filter.');
  String get historyEmptyHint => _t(
    '在 Clipy 打开时复制文字，或从已连接的设备同步内容，历史会出现在这里。',
    'Copy text while Clipy is open, or sync it from a connected device. Your history appears here.',
  );
  String get loadFailed => _t('暂时无法加载', 'Could not load content');
  String get retryHint =>
      _t('请重试。已有内容会保留。', 'Try again. Your saved content is still there.');
  String get retry => _t('重试', 'Try again');
  String get clearSearch => _t('清除搜索', 'Clear search');
  String get clearHistoryConfirm => _t(
    '这会删除本机的全部剪贴板历史，无法撤销。',
    'This permanently deletes all clipboard history on this device.',
  );
  String get historyCleared => _t('历史记录已清空', 'History cleared');
  String get operationFailed =>
      _t('操作未完成，请重试', 'Could not complete the action. Try again.');
  String get tapToCopy => _t('点击复制 · 长按查看', 'Tap to copy · Hold to preview');
  String get preview => _t('查看内容', 'Preview');
  String get localNetwork => _t('局域网连接', 'Local connection');
  String get syncReady => _t('同步已开启', 'Sync is on');
  String get syncPaused => _t('同步已关闭', 'Sync is off');
  String get connectionHint => _t(
    '连接同一 Wi-Fi，设置相同配对密钥，再选择共享的设备。',
    'Join the same Wi-Fi, use a matching pairing secret, then choose a device to share with.',
  );
  String get connectionSettings => _t('连接设置', 'Connection settings');
  String get advancedConnection => _t('高级连接设置', 'Advanced connection');
  String get deviceIdentity => _t('本机信息', 'This device');
  String get appearance => _t('外观', 'Appearance');
  String get systemTheme => _t('跟随系统', 'System');
  String get lightTheme => _t('浅色', 'Light');
  String get darkTheme => _t('深色', 'Dark');
  String get personalize => _t('个性化', 'Personalize');
  String get toolsAndSupport => _t('工具与支持', 'Tools & support');
  String get aboutClipy => _t(
    '连接 Mac 与 Android 的剪贴板工具。',
    'A clipboard companion for Mac and Android.',
  );
  String get invalidPort =>
      _t('请输入 1–65535 之间的端口', 'Enter a port between 1 and 65535');
  String get portUpdated => _t('同步端口已更新', 'Sync port updated');
  String get nameRequired => _t('请输入设备名称', 'Enter a device name');
  String get addDevice => _t('添加设备', 'Add device');
  String get add => _t('添加', 'Add');
  String get ipAddress => _t('IP 地址', 'IP address');
  String get invalidIP => _t('请输入合法 IPv4 地址', 'Enter a valid IPv4 address');
  String get manualDevices => _t('手动连接', 'Connect manually');
  String get manualDevicesHint => _t(
    '找不到设备？输入对端 IP 地址，连接其他子网中的设备。',
    'Device missing? Enter its IP address to connect across subnets.',
  );
  String get filesEmptyHint => _t(
    '从 Mac 发送文件后，在这里查看并打开所在文件夹。',
    'Send a file from your Mac, then find it here and open its folder.',
  );
  String get deleteFileConfirm => _t(
    '这会删除已接收的文件及本机记录，无法撤销。',
    'This permanently deletes the received file and its record from this device.',
  );
  String get fileDeleteFailed => _t(
    '文件未能删除，记录已保留。请在文件管理器中检查权限。',
    'The file could not be deleted. Its record was kept. Check access in your file manager.',
  );
  String get notificationEmptyHint => _t(
    '允许通知访问并选择应用后，在这里查看收到的通知。',
    'Allow notification access and choose your apps to see their notifications here.',
  );
  String get notificationIntro => _t(
    '重要消息，在 Mac 上也能看到。',
    'Keep your phone notifications within reach on Mac.',
  );
  String get removeDeviceConfirm => _t(
    '停止向这台设备自动同步剪贴板和通知？',
    'Stop automatically sharing clipboard and notifications with this device?',
  );
  String get settingsSaved => _t('设置已保存', 'Settings saved');
  String get showSecret => _t('显示密钥', 'Show secret');
  String get hideSecret => _t('隐藏密钥', 'Hide secret');
  String get moreActions => _t('更多操作', 'More actions');
  String get filesHint => _t('接收的文件，一处整理。', 'Your received files, together.');
  String packageSelection(int collected, int synced) => _t(
    '收集 ${collected == 0 ? "全部" : collected} · 同步 ${synced == 0 ? "全部" : synced}',
    'Collect ${collected == 0 ? "all" : collected} · Sync ${synced == 0 ? "all" : synced}',
  );

  String _t(String zh, String en) => language == AppLanguage.zh ? zh : en;
}
