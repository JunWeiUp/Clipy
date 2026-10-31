import 'package:flutter/material.dart';

/// The caller owns destructive confirmation and server authorization.
class RelayGroupMemberTile extends StatelessWidget {
  const RelayGroupMemberTile({
    super.key,
    required this.member,
    required this.self,
    required this.online,
    required this.canManage,
    required this.busy,
    required this.zh,
    required this.onRemove,
    this.onlineKnown = true,
    this.onRename,
  });
  final Map member;
  final String self;
  final bool online, canManage, busy, zh, onlineKnown;
  final VoidCallback onRemove;
  final VoidCallback? onRename;
  String t(String cn, String en) => zh ? cn : en;
  @override
  Widget build(BuildContext context) => Card(
    child: ListTile(
      title: Text(
        '${member['name']}${member['device'] == self ? t('（本机）', ' (this device)') : ''}',
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${member['manager'] == true ? t('管理员', 'Manager') : t('成员', 'Member')} · ${!onlineKnown
                  ? t('状态未刷新', 'Status not refreshed')
                  : online
                  ? t('在线', 'Online')
                  : t('离线', 'Offline')}',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 6),
            Tooltip(
              message: member['device'] as String,
              child: Text(
                member['device'] as String,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
      trailing: onRename != null && (canManage || member['device'] == self)
          ? PopupMenuButton<String>(
              tooltip: t('设备操作', 'Device actions'),
              enabled: !busy,
              onSelected: (action) {
                if (action == 'rename') {
                  onRename!();
                } else {
                  onRemove();
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'rename',
                  child: Text(t('修改设备名称', 'Rename device')),
                ),
                if (canManage && member['device'] != self)
                  PopupMenuItem(
                    value: 'remove',
                    child: Text(t('移除设备', 'Remove device')),
                  ),
              ],
            )
          : canManage && member['device'] != self
          ? IconButton(
              tooltip: t('移除设备', 'Remove device'),
              onPressed: busy ? null : onRemove,
              icon: const Icon(Icons.person_remove_outlined),
            )
          : null,
    ),
  );
}
