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

  String get appTitle => 'ClipyClone';
  String get languageLabel => _t('语言', 'Language');
  String get history => _t('历史记录', 'History');
  String get snippets => _t('片段', 'Snippets');
  String get preferences => _t('偏好设置', 'Preferences');
  String get settings => _t('设置', 'Settings');
  String get clearHistory => _t('清空历史记录', 'Clear History');
  String get appLogs => _t('应用日志', 'App Logs');
  String get clearLogs => _t('清空日志', 'Clear Logs');
  String get logsCopied => _t('日志已复制到剪贴板', 'Logs copied to clipboard');
  String get copyAll => _t('复制全部', 'Copy All');
  String get noLogs => _t('暂无日志。', 'No logs recorded yet.');
  String get noClipboardHistory => _t('暂无剪贴板历史', 'No clipboard history yet');
  String get noSnippetsYet => _t('暂无片段', 'No snippets yet');
  String historyRange(int start, int end) => _t('历史 $start-$end', 'History $start-$end');
  String sourceAndDate(String? source, String date) => '${source ?? unknown} • $date';
  String get unknown => _t('未知', 'Unknown');
  String get copiedToClipboard => _t('已复制到剪贴板', 'Copied to clipboard');
  String get addSnippetFolder => _t('添加片段文件夹', 'Add Snippet Folder');
  String get importXml => _t('导入 XML', 'Import XML');
  String get snippetFolders => _t('片段文件夹', 'Snippet Folders');
  String get addFolder => _t('添加文件夹', 'Add Folder');
  String get edit => _t('编辑', 'Edit');
  String get disable => _t('停用', 'Disable');
  String get enable => _t('启用', 'Enable');
  String get delete => _t('删除', 'Delete');
  String get snippetCopied => _t('片段已复制到剪贴板', 'Snippet copied to clipboard');
  String get addSnippet => _t('添加片段', 'Add Snippet');
  String get newFolder => _t('新文件夹', 'New Folder');
  String get folderName => _t('文件夹名称', 'Folder Name');
  String get cancel => _t('取消', 'Cancel');
  String get create => _t('创建', 'Create');
  String get importSnippetsXml => _t('导入片段 XML', 'Import Snippets XML');
  String get pasteXmlContent => _t('粘贴 XML 内容', 'Paste XML content');
  String get import => _t('导入', 'Import');
  String get editFolder => _t('编辑文件夹', 'Edit Folder');
  String get save => _t('保存', 'Save');
  String get deleteFolder => _t('删除文件夹', 'Delete Folder');
  String deleteFolderMessage(String folderTitle) =>
      _t('删除“$folderTitle”和所有片段？', 'Delete "$folderTitle" and all snippets?');
  String get newSnippet => _t('新片段', 'New Snippet');
  String get title => _t('标题', 'Title');
  String get content => _t('内容', 'Content');
  String get editSnippet => _t('编辑片段', 'Edit Snippet');
  String get deleteSnippet => _t('删除片段', 'Delete Snippet');
  String deleteSnippetMessage(String snippetTitle) =>
      _t('删除“$snippetTitle”？', 'Delete "$snippetTitle"?');
  String get historyLimit => _t('历史数量', 'History Limit');
  String keepRecentItems(int count) => _t('保留最近 $count 条', 'Keep the most recent $count items');
  String get excludedApps => _t('排除的应用（Bundle ID，每行一个）', 'Excluded Apps (bundle IDs, one per line)');
  String get saveExcludedApps => _t('保存排除应用', 'Save Excluded Apps');
  String get enableLanSync => _t('启用局域网同步', 'Enable LAN Sync');
  String get syncPort => _t('同步端口', 'Sync Port');
  String get authorizedDevicesComma => _t('授权设备（用逗号分隔）', 'Authorized Devices (comma separated)');
  String get about => _t('关于', 'About');
  String receivedFile(String fileName) => _t('已接收文件：$fileName', 'Received file: $fileName');
  String get view => _t('查看', 'View');
  String couldNotOpenFolder(Object error) => _t('无法打开文件夹：$error', 'Could not open folder: $error');
  String get clipyHistory => _t('Clipy 历史', 'Clipy History');
  String get receivedFiles => _t('已接收文件', 'Received Files');
  String get viewLogs => _t('查看日志', 'View Logs');
  String receiving(String fileName) => _t('正在接收：$fileName', 'Receiving: $fileName');
  String get deviceNameForSync => _t('设备名称（用于同步）', 'Device Name (for Sync)');
  String get enterDeviceName => _t('输入设备名称', 'Enter device name');
  String get deviceNameUpdated => _t('设备名称已更新，同步已重启', 'Device name updated and sync restarted');
  String get authorizedDevices => _t('授权设备', 'Authorized Devices');
  String get noDevicesFound => _t('未发现设备', 'No devices found');
  String get sameWifiHint => _t('请确认其他设备连接到同一个 Wi-Fi', 'Ensure other devices are on the same WiFi');
  String get appRuntimeLogs => _t('用于排查问题的应用运行日志', 'App runtime logs for troubleshooting');
  String get noFilesReceived => _t('暂无已接收文件', 'No files received yet');
  String fromSender(String senderName) => _t('来自：$senderName', 'From: $senderName');

  // Notification Sync
  String get notificationSync => _t('通知同步', 'Notification Sync');
  String get enableNotificationSync => _t('启用通知同步', 'Enable Notification Sync');
  String get notificationPermissionRequired => _t('需要通知监听权限', 'Notification listener permission required');
  String get grantPermission => _t('去授权', 'Grant Permission');
  String get syncNotificationsFrom => _t('同步以下应用的通知', 'Sync notifications from these apps');
  String get noAppsAvailable => _t('暂无可用应用', 'No apps available');
  String get phoneNotifications => _t('手机通知', 'Phone Notifications');
  String get noNotifications => _t('暂无通知', 'No notifications');
  String get clearAllNotifications => _t('清空通知', 'Clear Notifications');
  String get notificationSettings => _t('通知设置', 'Notification Settings');
  String get dismissOnPhone => _t('在手机上清除', 'Dismiss on Phone');
  String get notificationListenerPermission => _t('通知监听权限', 'Notification Listener Permission');
  String get permissionGranted => _t('已授权', 'Permission Granted');
  String get permissionNotGranted => _t('未授权', 'Not Granted');
  String notificationFrom(String appName) => _t('来自 $appName', 'From $appName');
  String get searchApps => _t('搜索应用...', 'Search apps...');
  String get selectedAppsCount => _t('已选择应用', 'Selected apps');
  String get notificationHistory => _t('通知历史', 'Notification History');
  String get noNotificationHistory => _t('暂无通知历史记录', 'No notification history yet');
  String get clearNotificationHistory => _t('清空通知历史', 'Clear Notification History');
  String get clearNotificationHistoryConfirm => _t('确定要清空所有通知历史吗？', 'Clear all notification history?');
  String get openNotificationSettings => _t('打开系统通知设置', 'Open System Notification Settings');
  String get permissionGuide => _t('授权后才能监听手机通知并同步到其他设备', 'Grant permission to listen for and sync phone notifications');
  String notificationsCount(int count) => _t('$count 条通知', '$count notifications');
  String get selectAll => _t('全选', 'Select All');
  String get deselectAll => _t('全部取消', 'Deselect All');
  String get userApps => _t('用户应用', 'User Apps');
  String get systemApps => _t('系统应用', 'System Apps');
  String appCount(int count) => _t('$count 个应用', '$count apps');

  // Transfer Station
  String get transferStation => _t('超级中转站', 'Transfer Station');
  String get addText => _t('添加文本', 'Add Text');
  String get addFile => _t('添加文件', 'Add File');
  String get clearAll => _t('清空', 'Clear All');
  String get dragOrAddToTransfer => _t('拖拽或点击添加内容', 'Drag or tap to add content');
  String get enterTextContent => _t('输入要添加到中转站的文本', 'Enter text to add to transfer station');
  String get add => _t('添加', 'Add');
  String get clearAllTransfer => _t('清空中转站', 'Clear Transfer Station');
  String get clearAllTransferConfirm => _t('确定要清空所有中转站内容吗？', 'Clear all transfer station content?');
  String get copyContent => _t('复制内容', 'Copy Content');
  String get setTemporary => _t('设为临时', 'Set Temporary');
  String get setPermanent => _t('设为永久', 'Set Permanent');
  String get permanent => _t('永久', 'Permanent');
  String get temporary => _t('临时', 'Temporary');
  String get openFile => _t('打开文件', 'Open File');
  String get saveFile => _t('另存为', 'Save As');
  String get fileSaved => _t('文件已保存', 'File saved');
  String get fileOpenFailed => _t('无法打开文件', 'Could not open file');
  String get saveToLocation => _t('选择保存位置', 'Choose save location');
  String itemCount(int total, int permanent) =>
      _t('$total 条 ($permanent 永久)', '$total items ($permanent permanent)');

  String _t(String zh, String en) => language == AppLanguage.zh ? zh : en;
}
