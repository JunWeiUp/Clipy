import 'relay_group_page.dart';
import 'dart:io';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/services.dart';
import '../../app_localizations.dart';
import '../../sync_manager.dart';
import '../../sync/relay_identity.dart';
import '../../sync/relay_configuration.dart';
import '../../ui/app_components.dart';

class RelaySettings extends StatefulWidget {
  const RelaySettings({
    super.key,
    this.onSettingsChanged,
    this.showGroupManagement = true,
  });
  final bool showGroupManagement;
  final VoidCallback? onSettingsChanged;
  @override
  State<RelaySettings> createState() => _RelaySettingsState();
}

class _RelaySettingsState extends State<RelaySettings> {
  final _url = TextEditingController();
  final _device = TextEditingController();
  final _key = TextEditingController();
  final _password = TextEditingController();
  bool _showPassword = false;
  bool _showKey = false;
  bool _showEnrollmentText = false;
  String _lastOrigin = '';
  final _enrollment = TextEditingController();
  bool _enabled = false, _loaded = false, _saving = false, _configured = false;
  bool _groupTab = false;
  String? _error;
  bool get zh => AppLanguageController.instance.language == AppLanguage.zh;
  String t(String cn, String en) => zh ? cn : en;

  static String _originOf(String raw) {
    final u = Uri.tryParse(raw.trim());
    if (u == null || u.host.isEmpty) return '';
    return '${u.scheme}://${u.host.toLowerCase()}:${u.hasPort ? u.port : 443}';
  }

  void _syncDeviceFromEnrollment(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return;
    try {
      final decoded = RelayConfiguration.decode(trimmed);
      final dev = decoded['device'];
      if (dev is String &&
          RelayConfiguration.validDevice(dev) &&
          _device.text != dev) {
        _device.text = dev;
      }
    } catch (_) {}
  }

  Future<void> _loadCurrentEnrollment() async {
    final raw = await ClipyRelayIdentity.config();
    if (!mounted) return;
    if (raw.trim().isEmpty) {
      showClipyMessage(context, t('本机尚未保存接入配置。', 'No saved enrollment yet.'));
      return;
    }
    setState(() {
      _enrollment.text = raw;
      _showEnrollmentText = true;
      _syncDeviceFromEnrollment(raw);
    });
  }

  Future<void> _pasteEnrollment() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (!mounted) return;
    if (text.isEmpty) {
      showClipyMessage(context, t('剪贴板为空。', 'Clipboard is empty.'));
      return;
    }
    setState(() {
      _enrollment.text = text;
      _showEnrollmentText = true;
      _syncDeviceFromEnrollment(text);
    });
  }

  Future<void> _toggleShowKey() async {
    if (!_showKey && _key.text.isEmpty) {
      final cfg = RelayConfiguration.decode(await ClipyRelayIdentity.config());
      final saved = cfg['token'];
      if (saved is String && saved.isNotEmpty && mounted) {
        _key.text = saved;
      }
    }
    if (mounted) setState(() => _showKey = !_showKey);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final config = RelayConfiguration.decode(
        await ClipyRelayIdentity.config(),
      );
      final url =
          prefs.getString('syncRelayURL') ??
          'wss://relay.example.test/relay/v1/ws';
      final accessPassword = await ClipyRelayIdentity.accessPassword(url);
      if (!mounted) return;
      setState(() {
        _password.text = accessPassword;
        _showPassword = false;
        _enabled = prefs.getBool('syncRelayEnabled') ?? false;
        _url.text =
            prefs.getString('syncRelayURL') ??
            'wss://relay.example.test/relay/v1/ws';
        _lastOrigin = _originOf(_url.text);
        _device.text =
            prefs.getString('syncRelayDeviceId') ??
            config['device'] as String? ??
            SyncManager.instance.peerId;
        _configured = config.isNotEmpty;
        _loaded = true;
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = t(
            '读取配置失败，请重新打开此页面。',
            'Could not load settings. Reopen this page.',
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _device.dispose();
    _key.dispose();
    _password.dispose();
    _enrollment.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_loaded || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      _syncDeviceFromEnrollment(_enrollment.text);
      await SyncManager.instance.updateRelaySettings(
        enabled: _enabled,
        url: _url.text,
        deviceId: _device.text,
        accessKey: _key.text,
        accessPassword: _password.text,
        token: _enrollment.text,
      );
      if (!mounted) return;
      setState(() {
        _configured |= _enrollment.text.trim().isNotEmpty;
        _key.clear();
        _enrollment.clear();
      });
      widget.onSettingsChanged?.call();
      showClipyMessage(context, context.l10n.settingsSaved);
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _error =
            error is FormatException && error.message == 'relayPasswordRequired'
            ? t(
                '启用中继前请填写访问密码。',
                'Enter the access password before enabling relay.',
              )
            : error is FormatException &&
                  error.message == 'invalidRelayPassword'
            ? t(
                '访问密码须为 8–128 位 ASCII 可见字符，不可包含空格。',
                'Use 8–128 printable ASCII characters without spaces.',
              )
            : error is FormatException && error.message == 'enrollmentRequired'
            ? t(
                '首次配置请先导入本设备接入配置，之后可单独更换公网 Key。',
                'Import device enrollment once; then the Internet Key can be replaced separately.',
              )
            : error is FormatException && error.message == 'invalidRelayURL'
            ? t(
                '中继地址无效：请填写 wss://…/v2/ws 或 wss://…/relay/v1/ws。',
                'Invalid relay URL: use wss://…/v2/ws or wss://…/relay/v1/ws.',
              )
            : error is FormatException && error.message == 'invalidDevice'
            ? t(
                '设备 ID 格式无效（仅允许字母、数字、-、_，1–80 位）。',
                'Invalid device ID (1–80 alphanumeric, - or _ characters).',
              )
            : error is FormatException && error.message == 'deviceMismatch'
            ? t(
                '设备 ID 与接入配置 JSON 中的 device 不一致。',
                'Device ID does not match the device field in enrollment JSON.',
              )
            : error is FormatException && error.message == 'publicKeyMismatch'
            ? t(
                '接入配置 JSON 的公钥与私钥不匹配（导入完整配置需含成对 secret_key 与 public_key）。',
                'Enrollment JSON public/secret keypair mismatch.',
              )
            : error is FormatException &&
                  error.message == 'invalidConfiguration'
            ? t(
                '接入配置 JSON 缺少有效字段（需含 app="clipy"、group、device、token≥32位、trusted_peers）。',
                'Enrollment JSON is missing required valid fields.',
              )
            : t(
                '保存失败，请检查设备 ID、WSS 地址、Key 和接入配置是否匹配。',
                'Could not save. Check the device ID, WSS URL, key and enrollment configuration.',
              ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _copyEnrollment() async {
    try {
      final device = _device.text.trim();
      if (!RelayConfiguration.validDevice(device)) {
        throw const FormatException('invalidDevice');
      }
      final info = await ClipyRelayIdentity.publicInfo(device);
      await Clipboard.setData(ClipboardData(text: info));
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(t('本机公钥登记信息', 'Device enrollment information')),
          content: SelectableText(info),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(t('关闭', 'Close')),
            ),
          ],
        ),
      );
    } catch (_) {
      if (mounted) {
        showClipyMessage(
          context,
          t('请先填写有效的设备 ID。', 'Enter a valid device ID first.'),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => ClipySection(
    title: t('中继设置', 'Relay settings'),
    subtitle: t(
      '设备 ID 和公网 Key 分开保存；局域网无需配置中继。',
      'Keep device ID and Internet Key separate. LAN needs no relay setup.',
    ),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.showGroupManagement) ...[
            SegmentedButton<bool>(
              segments: [
                ButtonSegment(
                  value: true,
                  label: Text(t('公网设备组', 'Relay device group')),
                ),
                ButtonSegment(
                  value: false,
                  label: Text(t('中继连接', 'Relay connection')),
                ),
              ],
              selected: {_groupTab},
              onSelectionChanged: _loaded && !_saving
                  ? (value) => setState(() => _groupTab = value.first)
                  : null,
            ),
            const SizedBox(height: 12),
            if (_groupTab)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.devices),
                title: Text(t('公网设备组', 'Relay device group')),
                subtitle: Text(
                  t('查看设备、添加设备或扫码加入', 'View devices, invite or scan to join'),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  await Navigator.of(context).push(
                    Platform.isIOS
                        ? CupertinoPageRoute<void>(
                            builder: (_) => const RelayGroupPage(),
                          )
                        : MaterialPageRoute<void>(
                            builder: (_) => const RelayGroupPage(),
                          ),
                  );
                  if (mounted) {
                    await _load();
                    widget.onSettingsChanged?.call();
                  }
                },
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(
                    const ClipboardData(
                      text: 'https://github.com/JunWeiUp/common-relay',
                    ),
                  );
                  if (!context.mounted) return;
                  showClipyMessage(
                    context,
                    t('中继公开项目链接已复制', 'Relay project link copied'),
                  );
                },
                icon: const Icon(Icons.copy_rounded, size: 16),
                label: Text(
                  t(
                    '复制中继公开项目链接（含部署文档）',
                    'Copy relay project link (with deployment docs)',
                  ),
                ),
              ),
            ),
          ],
          if (!_groupTab) ...[
            // Connection form: endpoint, credentials and enrollment.
            if (widget.showGroupManagement) const SizedBox.shrink(),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(t('启用公网中继', 'Enable Internet relay')),
              value: _enabled,
              onChanged: !_loaded || _saving
                  ? null
                  : (value) => setState(() => _enabled = value),
            ),
            TextField(
              key: const PageStorageKey('relay-url'),
              controller: _url,
              onChanged: (value) {
                // Only clear password when switching to a different server origin;
                // changing path (/relay/v1/ws -> /v2/ws) on the same host preserves it.
                final nextOrigin = _originOf(value);
                if (nextOrigin != _lastOrigin) {
                  _lastOrigin = nextOrigin;
                  setState(() {
                    _password.clear();
                    _showPassword = false;
                  });
                }
              },
              enabled: _loaded && !_saving,
              autocorrect: false,
              textDirection: TextDirection.ltr,
              maxLines: null,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.next,
              inputFormatters: [
                FilteringTextInputFormatter.singleLineFormatter,
              ],
              decoration: InputDecoration(labelText: t('中继地址', 'Relay URL')),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const PageStorageKey('relay-access-password'),
              controller: _password,
              enabled: _loaded && !_saving,
              obscureText: !_showPassword,
              autocorrect: false,
              enableSuggestions: false,
              textDirection: TextDirection.ltr,
              decoration: InputDecoration(
                labelText: t('访问密码', 'Access password'),
                helperMaxLines: 8,
                helperText: t(
                  '仅保存在本机安全存储，不包含在邀请中。8–128 位可见 ASCII 字符，不含空格；关闭中继后可留空清除。启用前须填写；修改地址后请重新填写。',
                  'Stored securely on this device, never in invitations. 8–128 printable ASCII characters, no spaces. Clear while relay is disabled. Required before enabling; re-enter after changing URL.',
                ),
                suffixIcon: IconButton(
                  tooltip: _showPassword
                      ? t('隐藏密码', 'Hide password')
                      : t('显示密码', 'Show password'),
                  onPressed: _loaded && !_saving
                      ? () => setState(() => _showPassword = !_showPassword)
                      : null,
                  icon: Icon(
                    _showPassword ? Icons.visibility_off : Icons.visibility,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const PageStorageKey('relay-device-id'),
              controller: _device,
              enabled: _loaded && !_saving,
              autocorrect: false,
              enableSuggestions: false,
              maxLength: 80,
              maxLines: null,
              keyboardType: TextInputType.text,
              textInputAction: TextInputAction.next,
              textDirection: TextDirection.ltr,
              style: Theme.of(context).textTheme.bodyMedium,
              inputFormatters: [
                FilteringTextInputFormatter.singleLineFormatter,
              ],
              decoration: InputDecoration(
                labelText: t('设备 ID', 'Device ID'),
                counterText: '',
                helperMaxLines: 6,
                helperText: t(
                  '填写服务端登记的 ID；更换 Key 时无需修改。',
                  'Use the registered ID. Keep it when replacing the key.',
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const PageStorageKey('relay-access-key'),
              controller: _key,
              enabled: _loaded && !_saving,
              obscureText: !_showKey,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: t('公网 Key', 'Internet Key'),
                helperMaxLines: 6,
                helperText: _configured
                    ? t(
                        '已保存，留空保持不变；点右侧眼睛可载入并修改',
                        'Saved; leave blank to keep or tap eye to edit',
                      )
                    : null,
                suffixIcon: IconButton(
                  tooltip: _showKey
                      ? t('隐藏 Key', 'Hide key')
                      : t('显示并编辑 Key', 'Show and edit key'),
                  onPressed: _loaded && !_saving ? _toggleShowKey : null,
                  icon: Icon(
                    _showKey ? Icons.visibility_off : Icons.visibility,
                  ),
                ),
              ),
            ),
            // ExpansionTile stores a bool in PageStorage. Each field needs a
            // distinct key so its internal scroll offset cannot read that bool
            // (or the Devices list offset) when the section is expanded.
            ExpansionTile(
              key: const PageStorageKey('relay-enrollment-section'),
              shape: const Border(),
              collapsedShape: const Border(),
              childrenPadding: const EdgeInsets.only(top: 4, bottom: 12),
              tilePadding: EdgeInsets.zero,
              title: Text(t('首次接入 / 更新信任配置', 'Enrollment / trusted peers')),
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    TextButton.icon(
                      onPressed: _loaded && !_saving ? _copyEnrollment : null,
                      icon: const Icon(Icons.key),
                      label: Text(
                        t('复制本机公钥登记信息', 'Copy device enrollment info'),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _loaded && !_saving
                          ? _loadCurrentEnrollment
                          : null,
                      icon: const Icon(Icons.edit_note),
                      label: Text(t('载入当前配置', 'Load current')),
                    ),
                    TextButton.icon(
                      onPressed: _loaded && !_saving ? _pasteEnrollment : null,
                      icon: const Icon(Icons.content_paste),
                      label: Text(t('粘贴', 'Paste')),
                    ),
                  ],
                ),
                TextField(
                  key: const PageStorageKey('relay-enrollment-input'),
                  controller: _enrollment,
                  enabled: _loaded && !_saving,
                  obscureText: !_showEnrollmentText,
                  maxLines: _showEnrollmentText ? 4 : 1,
                  minLines: 1,
                  onChanged: _syncDeviceFromEnrollment,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: t('本设备接入配置 JSON', 'Device enrollment JSON'),
                    helperMaxLines: 6,
                    helperText: t(
                      '支持随时载入修改或粘贴新配置；粘贴含 device 的 JSON 会自动同步上方设备 ID。',
                      'Load to edit anytime or paste new JSON; Device ID syncs automatically.',
                    ),
                    suffixIcon: IconButton(
                      tooltip: _showEnrollmentText
                          ? t('隐藏配置', 'Hide JSON')
                          : t('显示配置', 'Show JSON'),
                      onPressed: _loaded && !_saving
                          ? () => setState(
                              () => _showEnrollmentText = !_showEnrollmentText,
                            )
                          : null,
                      icon: Icon(
                        _showEnrollmentText
                            ? Icons.visibility_off
                            : Icons.visibility,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _loaded && !_saving ? _save : null,
              child: Text(
                t(
                  _saving ? '正在保存…' : '保存中继设置',
                  _saving ? 'Saving…' : 'Save relay settings',
                ),
              ),
            ),
          ],
        ],
      ),
    ),
  );
}
