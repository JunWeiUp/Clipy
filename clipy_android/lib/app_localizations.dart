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
  String get preferences => _t('偏好设置', 'Preferences');
  String get settings => _t('设置', 'Settings');
  String get status => _t('状态', 'Status');
  String get collector => _t('采集', 'Collector');
  String get permissions => _t('权限', 'Permissions');
  String get advancedFeatures => _t('高级功能', 'Advanced');
  String get collectorServiceStatus => _t('采集服务状态', 'Collector Service Status');
  String get collectorEnabled => _t('采集服务', 'Collector Service');
  String get syncEnabled => _t('局域网同步', 'LAN Sync');
  String get connectedMac => _t('已连接 Mac', 'Connected Mac');
  String get notConnected => _t('未连接', 'Not Connected');
  String get enabled => _t('已启用', 'Enabled');
  String get disabled => _t('已停用', 'Disabled');
  String get collectorCategoryToggles => _t('采集类型', 'Collector Categories');
  String get recentCollectorEvents => _t('最近采集', 'Recent Events');
  String get noCollectorEvents => _t('暂无采集数据', 'No collected events yet');
  String get collectorPermissionsIntro =>
      _t('请逐项授权以下权限，确保数据能实时同步到 Mac。', 'Grant the permissions below so data can sync to your Mac in real time.');
  String get permissionNotificationListener => _t('通知监听', 'Notification Listener');
  String get permissionSms => _t('短信', 'SMS');
  String get permissionPhone => _t('电话状态', 'Phone State');
  String get permissionCallLog => _t('通话记录', 'Call Log');
  String get permissionLocation => _t('定位', 'Location');
  String get permissionPostNotifications => _t('通知权限', 'Post Notifications');
  String get permissionBatteryOptimization => _t('电池优化白名单', 'Battery Optimization');
  String get granted => _t('已授权', 'Granted');
  String get notGranted => _t('未授权', 'Not Granted');
  String get grant => _t('授权', 'Grant');
  String get startCollectorService => _t('启动采集服务', 'Start Collector Service');
  String get collectorServiceStarted => _t('采集服务已启动', 'Collector service started');
  String get refreshPermissions => _t('刷新权限状态', 'Refresh Permissions');
  String get notificationListenerIssueTitle =>
      _t('通知采集异常', 'Notification Collection Issue');
  String get notificationListenerPermissionDenied => _t(
        '未授予通知监听权限，无法采集系统通知。请重新授权 Clipy Android。',
        'Notification listener permission is missing. Re-authorize Clipy Android to collect notifications.',
      );
  String get notificationListenerNotConnected => _t(
        '通知监听服务未连接。请点击重新授权，并在系统设置中确认 Clipy Android 的通知使用权已开启。',
        'The notification listener service is not connected. Tap Re-authorize and ensure Clipy Android notification access is enabled.',
      );
  String get notificationListenerNotReceiving => _t(
        '手机上有通知但长时间未采集到数据。请重新授权通知监听权限，或重启采集服务。',
        'Notifications are present on the phone but none have been collected recently. Re-authorize notification access or restart the collector service.',
      );
  String get reauthorizeNotificationListener => _t('重新授权', 'Re-authorize');
  String get notificationListenerRecovered =>
      _t('通知监听已恢复', 'Notification listener recovered');
  String get notificationListenerStillUnavailable => _t(
        '通知监听仍未恢复，请在系统设置中手动开启',
        'Notification listener is still unavailable. Enable it manually in system settings.',
      );
  String get collectorClipboardOnly => _t('剪贴板仅上报到 Mac', 'Clipboard collector only (no legacy sync)');
  String get showAdvancedFeatures => _t('显示高级功能', 'Show Advanced Features');
  String collectorCategoryLabel(String category) {
    switch (category) {
      case 'notification':
        return _t('通知', 'Notifications');
      case 'sms':
        return _t('短信', 'SMS');
      case 'call':
        return _t('通话', 'Calls');
      case 'call_log':
        return _t('通话记录', 'Call Log');
      case 'clipboard':
        return _t('剪贴板', 'Clipboard');
      case 'location':
        return _t('位置', 'Location');
      case 'system':
        return _t('系统状态', 'System');
      default:
        return category;
    }
  }
  String get clearHistory => _t('清空历史记录', 'Clear History');
  String get appLogs => _t('应用日志', 'App Logs');
  String get clearLogs => _t('清空日志', 'Clear Logs');
  String get logsCopied => _t('日志已复制到剪贴板', 'Logs copied to clipboard');
  String get copyAll => _t('复制全部', 'Copy All');
  String get noLogs => _t('暂无日志。', 'No logs recorded yet.');
  String get noClipboardHistory => _t('暂无剪贴板历史', 'No clipboard history yet');
  String historyRange(int start, int end) => _t('历史 $start-$end', 'History $start-$end');
  String sourceAndDate(String? source, String date) => '${source ?? unknown} • $date';
  String get unknown => _t('未知', 'Unknown');
  String get copiedToClipboard => _t('已复制到剪贴板', 'Copied to clipboard');
  String get cancel => _t('取消', 'Cancel');
  String get save => _t('保存', 'Save');
  String get delete => _t('删除', 'Delete');
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
  String get syncTargetsHint => _t(
        '勾选需要同步剪贴板的设备。仅需在本机授权，对方无需勾选即可接收。',
        'Select devices to sync clipboard to. Only this device needs to authorize; the other side can receive without checking you.',
      );
  String get lanDevices => _t('局域网设备', 'Devices on Network');
  String get sendFile => _t('发送文件…', 'Send File…');
  String fileSentTo(String deviceName) =>
      _t('已发送至 $deviceName', 'Sent to $deviceName');
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

  String get clearAll => _t('清空', 'Clear All');
  String get copyContent => _t('复制内容', 'Copy Content');

  String _t(String zh, String en) => language == AppLanguage.zh ? zh : en;
}
