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
  const RelaySettings({super.key, this.onSettingsChanged});
  final VoidCallback? onSettingsChanged;
  @override
  State<RelaySettings> createState() => _RelaySettingsState();
}

class _RelaySettingsState extends State<RelaySettings> {
  final _url = TextEditingController();
  final _device = TextEditingController();
  final _key = TextEditingController();
  final _enrollment = TextEditingController();
  bool _enabled = false, _loaded = false, _saving = false, _configured = false;
  String? _error;
  bool get zh => AppLanguageController.instance.language == AppLanguage.zh;
  String t(String cn, String en) => zh ? cn : en;

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
      if (!mounted) return;
      setState(() {
        _enabled = prefs.getBool('syncRelayEnabled') ?? false;
        _url.text =
            prefs.getString('syncRelayURL') ?? 'wss://eglish.top/relay/v1/ws';
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
      await SyncManager.instance.updateRelaySettings(
        enabled: _enabled,
        url: _url.text,
        deviceId: _device.text,
        accessKey: _key.text,
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
            error is FormatException && error.message == 'enrollmentRequired'
            ? t(
                '首次配置请先导入本设备接入配置，之后可单独更换公网 Key。',
                'Import device enrollment once; then the Internet Key can be replaced separately.',
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
    title: t('公网中继', 'Internet relay'),
    subtitle: t(
      '设备 ID 和公网 Key 分开保存；局域网无需配置中继。',
      'Keep device ID and Internet Key separate. LAN needs no relay setup.',
    ),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.devices),
            title: Text(t('管理公网设备组', 'Manage relay device group')),
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
            enabled: _loaded && !_saving,
            autocorrect: false,
            textDirection: TextDirection.ltr,
            maxLines: null,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.next,
            inputFormatters: [FilteringTextInputFormatter.singleLineFormatter],
            decoration: InputDecoration(labelText: t('中继地址', 'Relay URL')),
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
            inputFormatters: [FilteringTextInputFormatter.singleLineFormatter],
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
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: t('公网 Key', 'Internet Key'),
              helperMaxLines: 6,
              helperText: _configured
                  ? t('已保存，留空保持不变', 'Saved; leave blank to keep')
                  : null,
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
              TextButton.icon(
                onPressed: _loaded && !_saving ? _copyEnrollment : null,
                icon: const Icon(Icons.key),
                label: Text(t('复制本机公钥登记信息', 'Copy device enrollment info')),
              ),
              TextField(
                key: const PageStorageKey('relay-enrollment-input'),
                controller: _enrollment,
                enabled: _loaded && !_saving,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: t('本设备接入配置 JSON', 'Device enrollment JSON'),
                  helperMaxLines: 6,
                  helperText: t(
                    '首次接入时导入；仅换 Key 无需重复填写。',
                    'Import once. Not needed when only replacing the key.',
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
      ),
    ),
  );
}
