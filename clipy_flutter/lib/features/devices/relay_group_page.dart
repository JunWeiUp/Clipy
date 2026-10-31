import 'relay_group_legacy_view.dart';
import '../../sync/relay_configuration.dart';
import 'relay_group_member_tile.dart';
import 'dart:convert';
import 'dart:async';
import '../../sync/relay_identity.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:common_relay/common_relay.dart' as cr;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import '../../app_localizations.dart';
import '../../sync/relay_groups.dart';
import '../../sync_manager.dart';

class RelayGroupPage extends StatefulWidget {
  const RelayGroupPage({super.key});
  @override
  State<RelayGroupPage> createState() => _RelayGroupPageState();
}

class _RelayGroupPageState extends State<RelayGroupPage>
    with WidgetsBindingObserver {
  Timer? _watchTimer;
  bool _foreground = true;
  bool _watchStopped = false;
  final _groupName = TextEditingController(),
      _code = TextEditingController(),
      _name = TextEditingController(text: Platform.localHostname);
  Map<String, dynamic>? _state, _invitation, _request;
  Set<String> _online = {};
  String _self = '', _message = '', _group = '';
  bool _loaded = false,
      _legacy = false,
      _showUpgrade = false,
      _onlineKnown = false;
  List<String> _trustedDevices = [];
  bool _creating = true, _creationPending = false, _revoked = false;
  bool _automaticJoin = true, _pendingAutomatic = false;
  bool _busy = false, _grantManager = false, _pending = false;
  bool get zh => AppLanguageController.instance.language == AppLanguage.zh;
  String t(String cn, String en) => zh ? cn : en;
  bool get manager => (_state?['members'] as List? ?? []).any(
    (m) => m['device'] == _self && m['manager'] == true,
  );
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _work(_refresh);
  }

  @override
  void dispose() {
    _watchTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _groupName.dispose();
    _code.dispose();
    _name.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _scheduleWatch();
  }

  void _scheduleWatch() {
    _watchTimer?.cancel();
    if (!mounted ||
        !_foreground ||
        _busy ||
        _revoked ||
        _watchStopped ||
        (!_pending && _invitation == null)) {
      return;
    }
    _watchTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted || !_foreground) return;
      _work(() async {
        if (_pending) {
          await _finish();
        } else if (_invitation != null) {
          if ((_invitation!['expires'] as int) <=
              DateTime.now().millisecondsSinceEpoch ~/ 1000) {
            _watchStopped = true;
            setState(
              () => _message = t(
                '邀请已过期，请重新添加设备。',
                'Invitation expired. Add the device again.',
              ),
            );
            return;
          }
          await _check();
        }
      }, automatic: true);
    });
  }

  Future<void> _work(
    Future<void> Function() action, {
    bool automatic = false,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      if (!automatic) {
        _message = '';
        _watchStopped = false;
      }
    });
    try {
      await ClipyRelayGroups.run(action);
    } catch (e) {
      if (automatic &&
          [
            '401',
            '403',
            '404',
            '410',
          ].any((status) => e.toString().contains(status))) {
        _watchStopped = true;
      }
      if (_state != null && e.toString().contains('401')) _revoked = true;
      if (mounted) {
        setState(
          () => _message = _revoked
              ? t(
                  '当前设备的组接入已失效，请返回创建或加入。',
                  'This group access is no longer valid. Return to create or join a group.',
                )
              : e.toString().contains('429')
              ? t(
                  '创建暂时达到上限，请稍后重试。',
                  'Group creation limit reached. Please retry later.',
                )
              : t(
                  '操作失败，请检查网络、邀请有效期或管理权限。',
                  'Could not complete. Check connection, invitation expiry and permissions.',
                ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        _scheduleWatch();
      }
    }
  }

  Future<void> _refresh() async {
    final g = await ClipyRelayGroups.load();
    if (!mounted) return;
    final access = RelayConfiguration.groupAccess(g.config);
    setState(() {
      _loaded = true;
      _legacy = access == RelayGroupAccess.legacy;
      _onlineKnown = false;
      _self = g.config['device'] as String? ?? '';
      _group = g.config['group'] as String? ?? '';
      _trustedDevices =
          (g.config['trusted_peers'] as Map? ?? {}).keys
              .cast<String>()
              .where((id) => id != _self)
              .toList()
            ..sort();
      if (access == RelayGroupAccess.managed) {
        _state = cr.RelayGroups.unpack(
          g.config['group_entry'] as Map<String, dynamic>,
        );
      }
    });
    final pending = await ClipyRelayGroups.pending();
    _pendingAutomatic =
        pending?.config['enrollment_invitation']?['mode'] == 'auto';
    _creationPending = pending?.config['creation_draft'] == true;
    if (_creationPending) {
      _creating = true;
      final entry =
          pending!.config['pending_create'] ?? pending.config['group_entry'];
      if (entry is Map<String, dynamic>) {
        final draft = cr.RelayGroups.unpack(entry);
        _groupName.text = draft['name'] as String? ?? '';
        _name.text = (draft['members'] as List).first['name'] as String;
      }
    }
    if (pending != null &&
        _code.text.isEmpty &&
        pending.config['enrollment_invitation'] is Map<String, dynamic>) {
      _code.text = ClipyRelayGroups.encodeInvitation(
        pending.config['enrollment_invitation'] as Map<String, dynamic>,
      );
      _name.text = pending.config['enrollment_name'] as String? ?? _name.text;
    }
    final outgoing = await ClipyRelayIdentity.groupInvitation();
    if (outgoing.isNotEmpty) {
      final inv = jsonDecode(outgoing) as Map<String, dynamic>;
      if ((inv['expires'] as int) >
          DateTime.now().millisecondsSinceEpoch ~/ 1000) {
        _invitation = inv;
      } else {
        await ClipyRelayIdentity.saveGroupInvitation('');
        _invitation = null;
        _request = null;
      }
    }
    if (!mounted) return;
    if (g.config.containsKey('group_entry')) {
      final result = await g.refresh();
      await ClipyRelayGroups.persist(g);
      if (mounted) {
        setState(() {
          _state = result['state'] as Map<String, dynamic>;
          _revoked = false;
          _online = (result['online'] as List).cast<String>().toSet();
          _onlineKnown = true;
          _self = g.config['device'] as String;
        });
      }
    }
    if (mounted) {
      setState(
        () => _pending =
            pending?.config.containsKey('pending_join') == true &&
            !_creationPending,
      );
    }
  }

  Future<void> _activate(cr.RelayGroups g) async {
    await ClipyRelayGroups.persist(g);
    await SyncManager.instance.updateRelaySettings(
      enabled: true,
      url: g.config['url'] as String,
      deviceId: g.config['device'] as String,
      token: '',
      forceRelayRestart: true,
    );
    await ClipyRelayGroups.clearPending();
    if (mounted) {
      setState(() {
        _pending = false;
        _message = t('已加入，公网中继已启用。', 'Joined. Internet relay enabled.');
      });
    }
    await _refresh();
  }

  Future<void> _create() async {
    if (!_creationPending &&
        (_groupName.text.trim().isEmpty ||
            _name.text.trim().isEmpty ||
            utf8.encode(_groupName.text.trim()).length > 128 ||
            utf8.encode(_name.text.trim()).length > 128)) {
      setState(
        () => _message = t(
          '请填写简短的设备组名称和本机名称。',
          'Enter a short group name and device name.',
        ),
      );
      return;
    }
    final g = await ClipyRelayGroups.creationDraft(
      _groupName.text,
      _name.text,
      SyncManager.instance.peerId,
    );
    if (mounted) setState(() => _creationPending = true);
    if (!g.config.containsKey('group_entry')) {
      await g.create();
      await ClipyRelayGroups.savePending(g);
    }
    await _activate(g);
    if (mounted) {
      setState(() {
        _creationPending = false;
        _message = t(
          '设备组已创建，你是管理员。现在可以添加其他设备。',
          'Group created. You are the manager and can now add devices.',
        );
      });
    }
  }

  Future<void> _join() async {
    final code = await ClipyRelayGroups.resolveInvitation(_code.text);
    _pendingAutomatic = code['mode'] == 'auto';
    final g = await ClipyRelayGroups.draft(code, SyncManager.instance.peerId);
    g.config['enrollment_invitation'] = code;
    g.config.putIfAbsent('enrollment_name', () => _name.text.trim());
    await ClipyRelayGroups.savePending(g);
    if (code.containsKey('bootstrap')) {
      await g.bootstrap(code, g.config['enrollment_name'] as String);
      await _activate(g);
      return;
    }
    try {
      await g.join(code, g.config['enrollment_name'] as String);
    } finally {
      await ClipyRelayGroups.savePending(g);
    }
    if (mounted) {
      setState(() {
        _pending = true;
        _message = t(
          '请在邀请设备上核对配对码并批准。',
          'Verify the pairing code and approve on the inviting device.',
        );
      });
    }
    if (_pendingAutomatic) await _finish();
  }

  Future<void> _finish() async {
    final g = await ClipyRelayGroups.pending();
    if (g == null) return;
    if (!g.config.containsKey('pending_join')) {
      throw StateError('Retry invitation');
    }
    bool finished;
    try {
      finished = await g.finishJoin();
    } finally {
      await ClipyRelayGroups.savePending(g);
    }
    if (finished) {
      if (!mounted) return;
      await _activate(g);
    } else if (mounted) {
      setState(
        () => _message = t(
          _pendingAutomatic ? '正在自动加入…' : '正在等待邀请设备批准。',
          _pendingAutomatic
              ? 'Joining automatically…'
              : 'Waiting for approval on the inviting device.',
        ),
      );
    }
  }

  Future<void> _invite() async {
    final g = await ClipyRelayGroups.load();
    final inv = await g.invite(
      mode: _automaticJoin ? 'auto' : 'manual',
      compact: true,
    );
    await ClipyRelayGroups.persist(g);
    await ClipyRelayIdentity.saveGroupInvitation(jsonEncode(inv));
    if (mounted) {
      setState(() {
        _invitation = inv;
        _request = null;
        _grantManager = false;
        _message = '';
      });
    }
  }

  Future<void> _check() async {
    final g = await ClipyRelayGroups.load();
    final req = await g.pending(_invitation!);
    if (_invitation!['mode'] == 'auto') {
      await _refresh();
      if (req != null &&
          (_state?['members'] as List? ?? []).any(
            (m) =>
                m['device'] == cr.RelayGroups.unpack(req)['member']['device'],
          )) {
        await ClipyRelayIdentity.saveGroupInvitation('');
        if (mounted) {
          setState(() {
            _invitation = null;
            _request = null;
            _message = t('新设备已自动加入。', 'Device joined automatically.');
          });
        }
      }
      return;
    }
    if (mounted) {
      setState(() {
        _request = req;
        _message = req == null
            ? t('还没有设备申请加入。', 'No device has requested to join yet.')
            : '';
      });
    }
  }

  Future<void> _approve() async {
    final g = await ClipyRelayGroups.load();
    await g.approve(_invitation!, _request!, manager: _grantManager);
    await ClipyRelayGroups.persist(g);
    await ClipyRelayIdentity.saveGroupInvitation('');
    if (mounted) {
      setState(() {
        _invitation = null;
        _request = null;
        _message = t(
          '已批准，新设备将自动加入。',
          'Approved. The new device will join automatically.',
        );
      });
    }
    await _refresh();
  }

  Future<void> _remove(Map m) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(t('移除设备？', 'Remove device?')),
        content: Text(
          t(
            '移除 ${m['name']} 后，它将无法访问本组的公网中继。局域网连接与已收到的内容不受影响。',
            '${m['name']} will lose access to this relay group. LAN connections and previously received content are unaffected.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(t('取消', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(t('移除', 'Remove')),
          ),
        ],
      ),
    );
    if (yes == true && mounted) {
      await _work(() async {
        final g = await ClipyRelayGroups.load();
        await g.remove(m['device'] as String);
        await ClipyRelayGroups.persist(g);
        await _refresh();
      });
    }
  }

  Future<void> _rename(Map member) async {
    final value = await showDialog<String>(
      context: context,
      builder: (_) => _DeviceNameDialog(name: member['name'] as String, zh: zh),
    );
    if (value == null || !mounted) return;
    await _work(() async {
      final g = await ClipyRelayGroups.load();
      await g.rename(member['device'] as String, value);
      await ClipyRelayGroups.persist(g);
      await _refresh();
      if (mounted) {
        setState(() => _message = t('设备名称已更新。', 'Device name updated.'));
      }
    });
  }

  Future<void> _exitGroup(bool disband) async {
    final members = (_state?['members'] as List? ?? []);
    if (!disband &&
        !_revoked &&
        manager &&
        members.length > 1 &&
        members.where((m) => m['manager'] == true).length == 1) {
      setState(
        () => _message = t(
          '你是最后一位管理员。请让另一台管理设备加入，或选择解散设备组。',
          'You are the last manager. Invite another manager or disband the group.',
        ),
      );
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(
          _revoked
              ? t('清除失效的组配置？', 'Clear unavailable group configuration?')
              : disband
              ? t('解散整个设备组？', 'Disband this group?')
              : t('退出当前设备组？', 'Leave this group?'),
        ),
        content: Text(
          _revoked
              ? t(
                  '只清除本机已失效的公网组配置，保留历史记录和局域网设置。然后可创建或加入其他设备组。',
                  'Clear only this device’s unavailable relay configuration. Local history and LAN settings are preserved. You can then create or join another group.',
                )
              : disband
              ? t(
                  '所有设备将失去本组的公网访问权限，未使用的邀请也会失效。此操作不可撤销；本机历史记录和局域网配置会保留。',
                  'All devices will lose access to this relay group and invitations will expire. This cannot be undone. Local history and LAN settings are preserved.',
                )
              : t(
                  '仅本机离开；其他设备继续使用。若组内只剩本机，空组会同时关闭。本机历史记录和局域网配置会保留。',
                  'Only this device leaves; other devices continue using the group. A group with no remaining devices closes. Local history and LAN settings are preserved.',
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(t('取消', 'Cancel')),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(c).colorScheme.error,
              foregroundColor: Theme.of(c).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(c, true),
            child: Text(
              _revoked
                  ? t('清除并继续', 'Clear and continue')
                  : disband
                  ? t('确认解散', 'Disband group')
                  : t('确认退出', 'Leave group'),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _work(() async {
      try {
        if (!_revoked) {
          await ClipyRelayGroups.exitGroup(disband: disband);
        }
      } catch (e) {
        if (disband || !e.toString().contains('401')) rethrow;
      }
      await ClipyRelayGroups.clearEnrollment();
      await SyncManager.instance.updateRelaySettings(
        enabled: false,
        url: (await ClipyRelayGroups.load()).config['url'] as String,
        token: '',
        forceRelayRestart: true,
      );
      if (!mounted) return;
      setState(() {
        _state = null;
        _invitation = null;
        _request = null;
        _pending = false;
        _creationPending = false;
        _legacy = false;
        _creating = true;
        _revoked = false;
        _code.clear();
        _groupName.clear();
        _message = disband
            ? t(
                '设备组已解散，可以创建或加入其他组。',
                'Group disbanded. Create or join another group.',
              )
            : t(
                '已退出当前组，可以创建或加入其他组。',
                'You left the group. Create or join another group.',
              );
      });
      await _refresh();
    });
  }

  Future<void> _scan() async {
    final text = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => _InvitationScanner(zh: zh)),
    );
    if (text != null && mounted) {
      setState(() => _code.text = text);
      await _work(_join);
    }
  }

  Widget _section(String title, String subtitle, List<Widget> children) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          if (subtitle.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 24),
          ...children,
        ],
      ),
    ),
  );

  Widget _actions(List<Widget> children) =>
      Wrap(spacing: 12, runSpacing: 12, children: children);

  Widget get _enrollment => _section(
    _legacy
        ? t('启用组管理', 'Enable group management')
        : _creating
        ? t('创建你的设备组', 'Create your device group')
        : t('加入已有设备组', 'Join an existing group'),
    _legacy
        ? t(
            '导入管理员提供的升级邀请，保留当前设备身份。',
            'Import an upgrade invitation from your manager to keep your device identity.',
          )
        : _creating
        ? t(
            '创建后，你就是管理员，可以邀请手机和电脑加入。',
            'You become the manager and can invite phones and computers.',
          )
        : t(
            '在另一台设备上选择「添加设备」，然后扫描或粘贴邀请。',
            'Choose Add device on another device, then scan or paste its invitation.',
          ),
    [
      if (!_legacy && _creating) ...[
        TextField(
          controller: _groupName,
          enabled: !_busy && !_creationPending,
          decoration: InputDecoration(
            labelText: t('设备组名称', 'Group name'),
            hintText: t('例如：我的设备', 'For example: My devices'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 20),
      ],
      TextField(
        controller: _name,
        enabled: !_busy && !_creationPending,
        decoration: InputDecoration(
          labelText: t('本机名称', 'Device name'),
          border: const OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 20),
      if (!_legacy && _creating) ...[
        FilledButton.icon(
          onPressed: _busy ? null : () => _work(_create),
          icon: const Icon(Icons.add_circle_outline),
          label: Text(
            _creationPending
                ? t('继续创建', 'Continue creating')
                : t('创建设备组', 'Create group'),
          ),
        ),
        if (_creationPending) ...[
          const SizedBox(height: 12),
          Text(
            t(
              '已保存创建进度。网络恢复后可继续，不会重复建组。',
              'Progress saved. Retry after reconnecting without creating a duplicate.',
            ),
          ),
        ],
      ] else ...[
        TextField(
          controller: _code,
          enabled: !_busy,
          minLines: 3,
          maxLines: 5,
          decoration: InputDecoration(
            labelText: t('邀请链接', 'Invitation link'),
            border: const OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 24),
        _actions([
          if (Platform.isAndroid || Platform.isIOS)
            OutlinedButton.icon(
              onPressed: _busy ? null : _scan,
              icon: const Icon(Icons.qr_code_scanner),
              label: Text(t('扫码加入', 'Scan invitation')),
            ),
          FilledButton(
            onPressed: _busy ? null : () => _work(_join),
            child: Text(
              _legacy
                  ? t('升级当前组配置', 'Upgrade current group')
                  : t('申请加入', 'Request to join'),
            ),
          ),
        ]),
      ],
    ],
  );

  Widget get _pendingSection => _section(
    t(
      _pendingAutomatic ? '正在自动加入' : '等待批准',
      _pendingAutomatic ? 'Joining automatically' : 'Awaiting approval',
    ),
    t(
      _pendingAutomatic
          ? '正在验证邀请并加入设备组，无需邀请设备批准。'
          : '在邀请设备上核对下方配对码并批准，批准后将自动加入。',
      _pendingAutomatic
          ? 'Verifying the invitation and joining without manager approval.'
          : 'Compare this code on the inviting device and approve. Joining will complete automatically.',
    ),
    [
      if (!_pendingAutomatic)
        FutureBuilder<cr.RelayGroups?>(
          future: ClipyRelayGroups.pending(),
          builder: (context, snapshot) {
            final e = snapshot.data?.config['pending_join']?['request'];
            return e is Map<String, dynamic>
                ? SelectableText(
                    ClipyRelayGroups.verificationCode(e),
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontFamily: 'monospace',
                      letterSpacing: 3,
                    ),
                  )
                : const SizedBox.shrink();
          },
        ),
      const SizedBox(height: 24),
      _actions([
        Text(
          _pendingAutomatic
              ? t('正在自动加入…', 'Joining automatically…')
              : t('批准后自动加入', 'Joins automatically after approval'),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () => _work(() async {
                  await ClipyRelayGroups.clearPending();
                  if (mounted) setState(() => _pending = false);
                }),
          child: Text(t('放弃本次申请', 'Discard request')),
        ),
      ]),
    ],
  );

  Widget get _inviteSection => _section(
    t('邀请新设备', 'Invite a device'),
    t(
      '用新设备扫描二维码。邀请有效期为 10 分钟。',
      'Scan with the new device. Invitations expire after 10 minutes.',
    ),
    [
      Center(
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
          ),
          child: QrImageView(
            data: ClipyRelayGroups.encodeInvitation(_invitation!),
            size: 230,
            padding: const EdgeInsets.all(12),
          ),
        ),
      ),
      const SizedBox(height: 24),
      _actions([
        Text(
          _invitation!['mode'] == 'auto'
              ? t('扫码后自动加入（普通成员）', 'Joins automatically as a member')
              : t('加入申请会自动显示', 'Join requests appear automatically'),
        ),
        OutlinedButton(
          onPressed: _busy
              ? null
              : () => Clipboard.setData(
                  ClipboardData(
                    text: ClipyRelayGroups.encodeInvitation(_invitation!),
                  ),
                ),
          child: Text(t('复制邀请链接', 'Copy invitation link')),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () => _work(() async {
                  final g = await ClipyRelayGroups.load();
                  await g.cancel(_invitation!);
                  await ClipyRelayIdentity.saveGroupInvitation('');
                  if (mounted) {
                    setState(() {
                      _invitation = null;
                      _request = null;
                    });
                  }
                }),
          child: Text(t('取消邀请', 'Cancel invitation')),
        ),
      ]),
    ],
  );

  Widget get _approvalSection => _section(
    t('确认新设备', 'Confirm new device'),
    '${cr.RelayGroups.unpack(_request!)['member']['name']}',
    [
      Text(t('核对新设备上的配对码', 'Compare the code on the new device')),
      const SizedBox(height: 12),
      SelectableText(
        ClipyRelayGroups.verificationCode(_request!),
        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
          fontFamily: 'monospace',
          letterSpacing: 3,
        ),
      ),
      const SizedBox(height: 20),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: _grantManager,
        onChanged: _busy ? null : (v) => setState(() => _grantManager = v),
        title: Text(t('允许管理设备组', 'Allow group management')),
        subtitle: Text(
          t('可以邀请和移除其他设备。', 'Can invite and remove other devices.'),
        ),
      ),
      const SizedBox(height: 20),
      FilledButton(
        onPressed: _busy ? null : () => _work(_approve),
        child: Text(t('配对码一致，批准加入', 'Codes match — approve')),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: Platform.isIOS
        ? CupertinoNavigationBar(
            middle: Text(t('公网设备组', 'Relay device group')),
            trailing: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: _busy ? null : () => _work(_refresh),
              child: const Icon(CupertinoIcons.refresh),
            ),
          )
        : AppBar(
            title: Text(t('公网设备组', 'Relay device group')),
            actions: [
              IconButton(
                tooltip: t('刷新', 'Refresh'),
                onPressed: _busy ? null : () => _work(_refresh),
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            children: [
              if (_busy) ...[
                const LinearProgressIndicator(),
                const SizedBox(height: 20),
              ],
              if (_message.isNotEmpty) ...[
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(_message),
                ),
                const SizedBox(height: 20),
              ],
              if (_revoked)
                _section(
                  t('设备组不可用', 'Group unavailable'),
                  t(
                    '组可能已解散，或本机已被移除。旧名单不再代表当前成员，也不能用于添加设备。',
                    'The group may have been disbanded or this device removed. The saved roster is no longer current.',
                  ),
                  [
                    FilledButton.icon(
                      onPressed: _busy ? null : () => _exitGroup(false),
                      icon: const Icon(Icons.logout),
                      label: Text(t('返回创建或加入', 'Return to create or join')),
                    ),
                  ],
                )
              else if (_state != null)
                _section(
                  (_state!['name'] as String?) ?? _state!['group'] as String,
                  '${(_state!['members'] as List).length} ${t('台设备', 'devices')} · ${manager ? t('你是管理员', 'You are a manager') : t('你是成员', 'You are a member')}',
                  [
                    for (final m in _state!['members'] as List) ...[
                      RelayGroupMemberTile(
                        member: m as Map,
                        self: _self,
                        online: _online.contains(m['device']),
                        onlineKnown: _onlineKnown,
                        canManage: manager,
                        busy: _busy,
                        zh: zh,
                        onRemove: () => _remove(m),
                        onRename: () => _rename(m),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (manager && _invitation == null) ...[
                      const SizedBox(height: 8),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          t('扫码后自动加入', 'Join automatically after scanning'),
                        ),
                        subtitle: Text(
                          t(
                            '关闭后需核对配对码并手动批准。',
                            'Turn off to compare pairing codes and approve manually.',
                          ),
                        ),
                        value: _automaticJoin,
                        onChanged: _busy
                            ? null
                            : (value) => setState(() => _automaticJoin = value),
                      ),
                      FilledButton.icon(
                        onPressed: _busy ? null : () => _work(_invite),
                        icon: const Icon(Icons.add),
                        label: Text(t('添加设备', 'Add device')),
                      ),
                    ],
                    if (!manager)
                      Text(
                        t(
                          '请联系管理员添加或移除设备。',
                          'Ask a manager to add or remove devices.',
                        ),
                      ),
                  ],
                )
              else if (_loaded) ...[
                if (_legacy) ...[
                  RelayGroupLegacyView(
                    group: _group,
                    device: _self,
                    trustedDevices: _trustedDevices,
                    zh: zh,
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => setState(() => _showUpgrade = !_showUpgrade),
                    icon: Icon(
                      _showUpgrade ? Icons.expand_less : Icons.expand_more,
                    ),
                    label: Text(t('升级组管理配置', 'Upgrade group management')),
                  ),
                  const SizedBox(height: 20),
                ] else if (!_pending && !_creationPending) ...[
                  SegmentedButton<bool>(
                    segments: [
                      ButtonSegment(
                        value: true,
                        icon: const Icon(Icons.add_circle_outline),
                        label: Text(t('创建新组', 'Create group')),
                      ),
                      ButtonSegment(
                        value: false,
                        icon: const Icon(Icons.group_add_outlined),
                        label: Text(t('加入已有组', 'Join group')),
                      ),
                    ],
                    selected: {_creating},
                    onSelectionChanged: _busy
                        ? null
                        : (v) => setState(() => _creating = v.first),
                  ),
                  const SizedBox(height: 24),
                ],
                if (!_pending && (!_legacy || _showUpgrade)) _enrollment,
              ],
              if (_state != null && !_revoked) ...[
                const SizedBox(height: 24),
                _section(
                  t('离开设备组', 'Leave this group'),
                  t(
                    '退出仅影响本机；解散会撤销整个组的公网访问权限。',
                    'Leaving affects this device. Disbanding revokes access for the entire group.',
                  ),
                  [
                    _actions([
                      OutlinedButton.icon(
                        onPressed: _busy ? null : () => _exitGroup(false),
                        icon: const Icon(Icons.logout),
                        label: Text(t('退出当前组', 'Leave group')),
                      ),
                      if (manager && !_revoked)
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            foregroundColor: Theme.of(
                              context,
                            ).colorScheme.error,
                          ),
                          onPressed: _busy ? null : () => _exitGroup(true),
                          icon: const Icon(Icons.delete_outline),
                          label: Text(t('解散设备组', 'Disband group')),
                        ),
                    ]),
                  ],
                ),
              ],
              if (_pending && !_revoked) ...[
                const SizedBox(height: 24),
                _pendingSection,
              ],
              if (_request != null && !_revoked) ...[
                const SizedBox(height: 24),
                _approvalSection,
              ],
              if (_invitation != null && !_revoked) ...[
                const SizedBox(height: 24),
                _inviteSection,
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

class _InvitationScanner extends StatefulWidget {
  const _InvitationScanner({required this.zh});
  final bool zh;
  @override
  State<_InvitationScanner> createState() => _InvitationScannerState();
}

class _InvitationScannerState extends State<_InvitationScanner> {
  bool _done = false;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.zh ? '扫描邀请二维码' : 'Scan invitation')),
    body: MobileScanner(
      onDetect: (capture) {
        if (_done) return;
        for (final code in capture.barcodes) {
          final text = code.rawValue;
          if (text != null && text.startsWith('common-relay://')) {
            _done = true;
            Navigator.pop(context, text);
            break;
          }
        }
      },
    ),
  );
}

class _DeviceNameDialog extends StatefulWidget {
  const _DeviceNameDialog({required this.name, required this.zh});
  final String name;
  final bool zh;
  @override
  State<_DeviceNameDialog> createState() => _DeviceNameDialogState();
}

class _DeviceNameDialogState extends State<_DeviceNameDialog> {
  late final _controller = TextEditingController(text: widget.name);
  String? _error;
  String t(String cn, String en) => widget.zh ? cn : en;
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final name = _controller.text.trim();
    if (name.isEmpty || utf8.encode(name).length > 128) {
      setState(() => _error = t('请输入简短的设备名称', 'Enter a short device name'));
      return;
    }
    Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(t('修改设备名称', 'Rename device')),
    content: TextField(
      controller: _controller,
      autofocus: true,
      onSubmitted: (_) => _save(),
      decoration: InputDecoration(
        labelText: t('设备名称', 'Device name'),
        errorText: _error,
        border: const OutlineInputBorder(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(t('取消', 'Cancel')),
      ),
      FilledButton(onPressed: _save, child: Text(t('保存名称', 'Save name'))),
    ],
  );
}
