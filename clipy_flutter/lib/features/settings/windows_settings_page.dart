import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_localizations.dart';
import '../../clipboard_manager.dart';
import '../../ui/app_components.dart';
import '../../ui/app_theme.dart';
import '../devices/devices_page.dart';
import 'windows_hotkey_settings.dart';
import 'windows_behavior_settings.dart';

/// Settings backed by the existing Windows preferences and platform channels.
class WindowsSettingsPage extends StatefulWidget {
  const WindowsSettingsPage({
    super.key,
    this.onBack,
    required this.onOpenLogs,
    required this.onOpenReceivedFiles,
  });
  final VoidCallback? onBack;
  final VoidCallback onOpenLogs;
  final VoidCallback onOpenReceivedFiles;

  @override
  State<WindowsSettingsPage> createState() => _WindowsSettingsPageState();
}

class _WindowsSettingsPageState extends State<WindowsSettingsPage> {
  late final _excluded = TextEditingController(
    text: ClipboardManager.instance.excludedApps.join('\n'),
  );
  late final Future<String> _version = _readVersion();
  int _section = 2;

  Future<String> _readVersion() async {
    try {
      final info = await const MethodChannel(
        'com.clipyclone.clipy_android/storage',
      ).invokeMapMethod<String, String>('getAppVersion');
      final version = info?['version']?.trim() ?? '';
      final build = info?['build']?.trim() ?? '';
      if (version.isEmpty) return '—';
      return build.isEmpty ? 'v$version' : 'v$version ($build)';
    } catch (_) {
      return '—';
    }
  }

  @override
  void dispose() {
    _excluded.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final categories = [l10n.personalize, l10n.history, context.l10n.general];
    final icons = [
      Icons.palette_outlined,
      Icons.history,
      Icons.settings_outlined,
    ];
    final colors = Theme.of(context).colorScheme;
    Widget settingCard({required Widget child}) =>
        Card(margin: const EdgeInsets.only(bottom: 4), child: child);
    Widget contents() => ListView(
      padding: const EdgeInsets.fromLTRB(36, 28, 36, 28),
      children: [
        Text(
          '${l10n.settings}  ›  ${categories[_section]}',
          style: Theme.of(context).textTheme.headlineLarge,
        ),
        const SizedBox(height: 14),
        if (_section == 0) ...[
          settingCard(
            child: ListTile(
              leading: const Icon(Icons.palette_outlined),
              title: Text(l10n.appearance),
              trailing: DropdownButton<ThemeMode>(
                value: AppAppearance.instance.mode,
                onChanged: (mode) async {
                  if (mode == null) return;
                  await AppAppearance.instance.setMode(mode);
                  if (mounted) setState(() {});
                },
                items: [
                  DropdownMenuItem(
                    value: ThemeMode.system,
                    child: Text(l10n.systemTheme),
                  ),
                  DropdownMenuItem(
                    value: ThemeMode.light,
                    child: Text(l10n.lightTheme),
                  ),
                  DropdownMenuItem(
                    value: ThemeMode.dark,
                    child: Text(l10n.darkTheme),
                  ),
                ],
              ),
            ),
          ),
          settingCard(
            child: ListTile(
              leading: const Icon(Icons.language),
              title: Text(l10n.languageLabel),
              trailing: DropdownButton<AppLanguage>(
                value: AppLanguageController.instance.language,
                onChanged: (language) async {
                  if (language == null) return;
                  await AppLanguageController.instance.setLanguage(language);
                  if (mounted) setState(() {});
                },
                items: [
                  for (final language in AppLanguage.values)
                    DropdownMenuItem(
                      value: language,
                      child: Text(language.displayName),
                    ),
                ],
              ),
            ),
          ),
        ],
        if (_section == 1) ...[
          settingCard(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l10n.windowsExcludedApps,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _excluded,
                    minLines: 3,
                    maxLines: 6,
                    decoration: InputDecoration(
                      labelText: l10n.windowsExcludedApps,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton(
                      onPressed: () async {
                        final names = _excluded.text
                            .split('\n')
                            .map((name) => name.trim())
                            .where((name) => name.isNotEmpty)
                            .toSet()
                            .toList();
                        try {
                          await ClipboardManager.instance.updateExcludedApps(
                            names,
                          );
                          if (context.mounted) {
                            showClipyMessage(context, l10n.settingsSaved);
                          }
                        } catch (_) {
                          if (context.mounted) {
                            showClipyMessage(context, l10n.operationFailed);
                          }
                        }
                      },
                      child: Text(l10n.saveExcludedApps),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        if (_section == 2) ...[
          const WindowsBehaviorSettings(),
          const SizedBox(height: 16),
          Text(
            l10n.windowsShortcuts,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          const WindowsHotkeySettings(),
          const SizedBox(height: 16),
          settingCard(
            child: ListTile(
              leading: const Icon(Icons.tune),
              title: Text(l10n.connectionSettings),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showModalBottomSheet<bool>(
                context: context,
                isScrollControlled: true,
                builder: (_) => const ConnectionEditor(),
              ),
            ),
          ),
          settingCard(
            child: ListTile(
              leading: const Icon(Icons.folder_open),
              title: Text(l10n.receivedFiles),
              trailing: const Icon(Icons.chevron_right),
              onTap: widget.onOpenReceivedFiles,
            ),
          ),
          settingCard(
            child: ListTile(
              leading: const Icon(Icons.article_outlined),
              title: Text(l10n.viewLogs),
              subtitle: Text(l10n.appRuntimeLogs),
              trailing: const Icon(Icons.chevron_right),
              onTap: widget.onOpenLogs,
            ),
          ),
          const SizedBox(height: 18),
          Text('Clipy', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(l10n.aboutClipy, style: Theme.of(context).textTheme.bodySmall),
          FutureBuilder<String>(
            future: _version,
            builder: (context, snapshot) => Text(
              '${l10n.appVersionLabel} ${snapshot.data ?? '—'}',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
        ],
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 620) {
          return Column(
            children: [
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var i = 0; i < categories.length; i++)
                      TextButton(
                        onPressed: () => setState(() => _section = i),
                        child: Text(categories[i]),
                      ),
                  ],
                ),
              ),
              Expanded(child: contents()),
            ],
          );
        }
        return Row(
          children: [
            SizedBox(
              width: 260,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(12, 0, 8, 20),
                children: [
                  if (widget.onBack != null)
                    ListTile(
                      leading: const Icon(Icons.arrow_back, size: 18),
                      title: Text(l10n.history),
                      onTap: widget.onBack,
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 20, 12, 24),
                    child: Row(
                      children: [
                        Image.asset(
                          'assets/branding/clipy-logo.png',
                          width: 44,
                          height: 44,
                        ),
                        const SizedBox(width: 12),
                        const Text('Clipy'),
                      ],
                    ),
                  ),
                  for (final i in [2, 0, 1])
                    ListTile(
                      dense: true,
                      selected: i == _section,
                      selectedTileColor: colors.onSurface.withValues(
                        alpha: .06,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                      leading: Icon(icons[i], size: 18),
                      title: Text(categories[i]),
                      onTap: () => setState(() => _section = i),
                    ),
                ],
              ),
            ),
            VerticalDivider(width: 1, color: colors.outlineVariant),
            Expanded(child: contents()),
          ],
        );
      },
    );
  }
}
