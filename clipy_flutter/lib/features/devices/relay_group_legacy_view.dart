import 'package:flutter/material.dart';

class RelayGroupLegacyView extends StatelessWidget {
  const RelayGroupLegacyView({
    super.key,
    required this.group,
    required this.device,
    required this.trustedDevices,
    required this.zh,
  });
  final String group, device;
  final List<String> trustedDevices;
  final bool zh;
  String t(String cn, String en) => zh ? cn : en;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        children: [
          const Icon(Icons.check_circle_outline),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              t('已接入设备组', 'Already enrolled'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
        ],
      ),
      const SizedBox(height: 8),
      SelectableText(group, style: Theme.of(context).textTheme.titleMedium),
      SelectableText('${t('本机设备 ID', 'This device')}: $device'),
      const Divider(height: 32),
      Text(
        t('组管理待启用', 'Group management pending'),
        style: Theme.of(context).textTheme.titleMedium,
      ),
      Text(
        t(
          '原有设备组和同步配置已保留。新版添加、移除设备功能需要服务端升级，并为当前组启用管理权限；无需重新加入设备组。',
          'Your existing group and sync configuration are preserved. Adding and removing devices requires the server update and management activation for this group. You do not need to join again.',
        ),
      ),
      if (trustedDevices.isNotEmpty) ...[
        const SizedBox(height: 16),
        Text(
          t('本机已保存的可信设备', 'Trusted devices saved on this device'),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        for (final id in trustedDevices)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: SelectableText(id),
          ),
        Text(
          t(
            '这是本机保存的信任列表，并非服务器完整成员列表。',
            'This is the locally saved trust list, not the complete server membership list.',
          ),
        ),
      ],
    ],
  );
}
