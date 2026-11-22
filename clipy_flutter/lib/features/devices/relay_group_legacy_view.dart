import 'package:flutter/material.dart';

class RelayGroupLegacyView extends StatelessWidget {
  const RelayGroupLegacyView({
    super.key,
    required this.group,
    required this.device,
    required this.trustedDevices,
    required this.zh,
    this.isV2 = false,
    this.onlineDevices = const {},
    this.peerNames = const {},
    this.presenceKnown = false,
    this.selfName = '',
    this.busy = false,
    this.onEditSettings,
    this.onLeave,
  });
  final String group, device, selfName;
  final List<String> trustedDevices;
  final bool zh, isV2, presenceKnown, busy;
  final Set<String> onlineDevices;
  final Map<String, String> peerNames;
  final VoidCallback? onEditSettings;
  final VoidCallback? onLeave;
  String t(String cn, String en) => zh ? cn : en;

  List<String> get _allDevices {
    final list = <String>[];
    if (device.isNotEmpty) list.add(device);
    for (final id in trustedDevices) {
      if (!list.contains(id)) list.add(id);
    }
    for (final id in onlineDevices.toList()..sort()) {
      if (!list.contains(id)) list.add(id);
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final devices = _allDevices;
    final onlineCount = devices.where((id) => onlineDevices.contains(id)).length;
    if (isV2) {
      final trustedSet = trustedDevices.toSet();
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Icon(Icons.group, color: theme.colorScheme.onPrimaryContainer),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(group.isEmpty ? 'clipy' : group, style: theme.textTheme.titleLarge),
                    Text(
                      [
                        t('${devices.length} 台设备', '${devices.length} devices'),
                        t('v2 加密空间', 'v2 Encrypted Space'),
                        presenceKnown
                            ? t('$onlineCount 台在线', '$onlineCount online')
                            : t('连接中', 'Connecting'),
                      ].join(' · '),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(t('成员', 'Members'), style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Card(
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < devices.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  Builder(builder: (context) {
                    final id = devices[i];
                    final isSelf = id == device;
                    final isOnline = onlineDevices.contains(id);
                    final isTrusted = isSelf || trustedSet.contains(id);
                    final label = isSelf
                        ? (selfName.isNotEmpty ? selfName : id)
                        : (peerNames[id] ?? id);
                    final status = !presenceKnown
                        ? t('状态未刷新', 'Status not refreshed')
                        : (isOnline ? t('在线', 'Online') : t('离线', 'Offline'));
                    final isPhone = id.toLowerCase().contains('android') ||
                        id.toLowerCase().contains('phone') ||
                        id.toLowerCase().contains('ios');
                    return ListTile(
                      leading: Icon(
                        isPhone ? Icons.smartphone : Icons.computer,
                        color: isOnline ? theme.colorScheme.primary : theme.disabledColor,
                      ),
                      title: Text(
                        '$label${isSelf ? t('（本机）', ' (this device)') : ''}',
                      ),
                      subtitle: Row(
                        children: [
                          Icon(
                            Icons.circle,
                            size: 8,
                            color: isOnline ? Colors.green : theme.disabledColor,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '$id · $status',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      trailing: Chip(
                        visualDensity: VisualDensity.compact,
                        label: Text(
                          isSelf
                              ? t('本机', 'This device')
                              : isTrusted
                                  ? t('可信设备', 'Trusted')
                                  : t('未信任', 'Untrusted'),
                        ),
                      ),
                    );
                  }),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              if (onEditSettings != null)
                OutlinedButton.icon(
                  onPressed: busy ? null : onEditSettings,
                  icon: const Icon(Icons.tune),
                  label: Text(t('编辑中继配置', 'Edit relay config')),
                ),
              if (onLeave != null)
                OutlinedButton.icon(
                  onPressed: busy ? null : onLeave,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                  icon: const Icon(Icons.logout),
                  label: Text(t('退出当前组', 'Leave group')),
                ),
            ],
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.check_circle_outline),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                t('已接入设备组', 'Already enrolled'),
                style: theme.textTheme.titleLarge,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SelectableText(group, style: theme.textTheme.titleMedium),
        SelectableText('${t('本机设备 ID', 'This device')}: $device'),
        const Divider(height: 32),
        Text(
          t('组管理待启用', 'Group management pending'),
          style: theme.textTheme.titleMedium,
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
            style: theme.textTheme.titleSmall,
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
        if (onLeave != null) ...[
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: busy ? null : onLeave,
            style: OutlinedButton.styleFrom(
              foregroundColor: theme.colorScheme.error,
            ),
            icon: const Icon(Icons.logout),
            label: Text(t('退出当前组', 'Leave group')),
          ),
        ],
      ],
    );
  }
}
