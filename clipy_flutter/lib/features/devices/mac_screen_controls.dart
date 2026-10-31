import 'package:flutter/material.dart';
import '../../sync_manager.dart';
import '../../ui/app_components.dart';

class MacScreenControls extends StatefulWidget {
  final String peerId;
  const MacScreenControls({super.key, required this.peerId});
  @override
  State<MacScreenControls> createState() => _MacScreenControlsState();
}

class _MacScreenControlsState extends State<MacScreenControls> {
  bool _busy = false;
  String t(String zh, String en) =>
      Localizations.localeOf(context).languageCode == 'zh' ? zh : en;
  @override
  void initState() {
    super.initState();
    SyncManager.instance.queryMacScreen(widget.peerId);
  }

  Future<void> _run(String action) async {
    setState(() => _busy = true);
    try {
      final result = await SyncManager.instance.controlMacScreen(
        widget.peerId,
        action,
      );
      if (!mounted) return;
      final text = switch (result) {
        'ok' => t('Mac 状态已确认', 'Mac state confirmed'),
        'helperMissing' => t(
          '请先更新 Mac 端解锁功能',
          'Update the Mac unlock implementation first',
        ),
        'permissionOrHelper' => t(
          'Mac 权限或辅助组件不可用',
          'Mac permission or helper unavailable',
        ),
        'busy' => t(
          'Mac 正在处理上一项操作，请稍后重试',
          'Mac is processing the previous action. Try again shortly',
        ),
        'cooldown' => t(
          '请等待 5 秒后再次尝试解锁',
          'Wait 5 seconds before trying to unlock again',
        ),
        'notConfigured' => t(
          '无法读取 Mac 已保存的登录密码，请在 Mac 检查配置',
          'Cannot read the saved Mac login credential. Check settings on Mac',
        ),
        'sessionUnavailable' => t(
          '当前 Mac 登录会话不可用，请在 Mac 检查登录状态',
          'The current Mac login session is unavailable',
        ),
        'stateTimeout' => t(
          '获取 Mac 状态超时，请检查连接',
          'Timed out reading Mac state. Check the connection',
        ),
        'accessibilityRequired' => t(
          '请在 Mac 系统设置中允许 Clipy 的辅助功能权限',
          'Allow Clipy Accessibility access in Mac System Settings',
        ),
        'secureFieldUnavailable' => t(
          '无法确认系统登录密码框，请在 Mac 显示当前账户的密码输入界面',
          'Cannot verify the system login field. Show the current account login prompt on Mac',
        ),
        'secureFieldWriteFailed' => t(
          '系统拒绝填写安全密码框，请检查 Mac 辅助功能权限',
          'The system refused the secure field write. Check Mac Accessibility permission',
        ),
        'secureConfirmFailed' => t(
          '系统登录确认失败，请检查 Mac 锁屏界面',
          'System login confirmation failed. Check the Mac lock screen',
        ),
        'credentialInvalid' => t(
          '已保存的 Mac 登录密码无效，请在 Mac 重新保存',
          'The saved Mac login credential is invalid. Save it again on Mac',
        ),
        'credentialUnavailable' => t(
          '无法读取 Mac 登录密码，请在 Mac 检查配置',
          'Cannot read the Mac login credential. Check Mac settings',
        ),
        'disconnected' => t('设备已断开', 'Device disconnected'),
        'updateMac' => t('请先更新 Mac 端', 'Update the Mac app first'),
        'notConfirmed' => t('未确认成功，请检查 Mac 状态', 'Not confirmed. Check the Mac'),
        _ => t('操作不可用，请稍后重试', 'Unavailable. Please retry later'),
      };
      showClipyMessage(context, text);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<Map<String, MacScreenState>>(
        valueListenable: SyncManager.instance.macScreens,
        builder: (context, states, _) {
          final state = states[widget.peerId];
          if (state == null) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  state.locked == null
                      ? t('Mac 锁屏状态未知', 'Mac lock state unknown')
                      : state.locked!
                      ? t('Mac 已锁定', 'Mac locked')
                      : t('Mac 已解锁', 'Mac unlocked'),
                ),
                if (state.configured)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed:
                            _busy ||
                                !state.directControl ||
                                state.locked != false
                            ? null
                            : () => _run('lock'),
                        icon: const Icon(Icons.lock_outline),
                        label: Text(t('锁屏', 'Lock')),
                      ),
                      OutlinedButton.icon(
                        onPressed:
                            _busy ||
                                !state.directControl ||
                                state.locked != true ||
                                !state.helper
                            ? null
                            : () => _run('unlock'),
                        icon: const Icon(Icons.lock_open),
                        label: Text(t('解锁', 'Unlock')),
                      ),
                    ],
                  ),
                if (state.configured && !state.directControl)
                  Text(t('请先更新 Mac 端', 'Update the Mac app first')),
                if (state.configured && !state.helper)
                  Text(
                    t(
                      '请在 Mac 系统设置中允许 Clipy 的辅助功能权限',
                      'Allow Clipy Accessibility access in Mac System Settings',
                    ),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                if (_busy) const LinearProgressIndicator(),
              ],
            ),
          );
        },
      );
}
