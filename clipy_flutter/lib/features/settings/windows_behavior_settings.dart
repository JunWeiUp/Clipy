import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_localizations.dart';
import '../../ui/windows_controls.dart';

/// Windows-only startup and tray preferences, owned by the native runner.
class WindowsBehaviorSettings extends StatefulWidget {
  const WindowsBehaviorSettings({super.key});
  @override
  State<WindowsBehaviorSettings> createState() =>
      _WindowsBehaviorSettingsState();
}

class _WindowsBehaviorSettingsState extends State<WindowsBehaviorSettings> {
  static const channel = MethodChannel('com.clipyclone.clipy_android/tray');
  Map<String, bool>? _values;
  bool _saving = false;
  bool _failed = false;
  int _firewall = -1;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final values = await channel.invokeMapMethod<String, bool>(
        'getWindowsBehavior',
      );
      final firewall = await channel.invokeMethod<int>('getFirewallStatus');
      if (mounted) {
        setState(() {
          _failed = false;
          _values = values ?? {};
          _firewall = firewall ?? -1;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _set(String name, bool value) async {
    setState(() {
      _saving = true;
      _failed = false;
    });
    try {
      final ok =
          await channel.invokeMethod<bool>('setWindowsBehavior', {
            'name': name,
            'value': value,
          }) ??
          false;
      if (mounted) {
        setState(() {
          if (ok) {
            _values![name] = value;
          } else {
            _failed = true;
          }
        });
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final zh = AppLanguageController.instance.language == AppLanguage.zh;
    String text(String chinese, String english) => zh ? chinese : english;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          text('启动与托盘', 'Startup and tray'),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 8),
        WindowsSettingRow(
          icon: Icons.power_settings_new,
          title: text('开机时启动 Clipy', 'Start Clipy when signing in'),
          subtitle: text('在系统托盘中静默运行', 'Start quietly in the system tray'),
          control: WindowsToggle(
            value: _values?['startup'] ?? false,
            label: text('开机时启动 Clipy', 'Start Clipy when signing in'),
            onChanged: _values == null || _saving
                ? null
                : (v) => _set('startup', v),
          ),
        ),
        WindowsSettingRow(
          icon: Icons.view_sidebar_outlined,
          title: text('托盘图标', 'Tray icon'),
          subtitle: text(
            '单击显示或收起快速面板；右键可打开主窗口',
            'Click to toggle the quick panel; right-click to open the main window',
          ),
          control: Text(text('单击切换', 'Click to toggle')),
        ),
        WindowsSettingRow(
          icon: Icons.close,
          title: text('关闭窗口', 'Close window'),
          subtitle: text(
            '收起到托盘并继续同步；彻底退出请使用托盘右键菜单',
            'Hide to tray and keep syncing; use Exit in the tray menu to quit',
          ),
          control: Text(text('收起到托盘', 'Hide to tray')),
        ),
        if (_failed)
          Text(
            text('无法更新设置', 'Could not update settings'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        Card(
          margin: const EdgeInsets.only(top: 12),
          child: ListTile(
            leading: const Icon(Icons.shield_outlined),
            title: Text(text('Windows 防火墙', 'Windows Firewall')),
            subtitle: Text(
              _firewall == 1
                  ? text(
                      '当前网络的防火墙已开启；应用放行需在 Windows 安全中心确认。',
                      'Firewall is enabled for active networks; check app access in Windows Security.',
                    )
                  : _firewall == 0
                  ? text(
                      '至少一个当前网络的防火墙已关闭。',
                      'Firewall is off for at least one active network.',
                    )
                  : text('无法获取当前防火墙状态。', 'Firewall status is unavailable.'),
            ),
            trailing: IconButton(
              tooltip: text('刷新', 'Refresh'),
              onPressed: _load,
              icon: const Icon(Icons.refresh),
            ),
          ),
        ),
      ],
    );
  }
}
