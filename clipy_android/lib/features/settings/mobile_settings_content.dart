import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../app_localizations.dart';
import '../../ui/app_components.dart';
import '../../ui/app_theme.dart';
import '../devices/devices_page.dart';

class MobileSettingsContent extends StatefulWidget {
  final VoidCallback onOpenLogs;
  final VoidCallback onOpenReceivedFiles;
  const MobileSettingsContent({
    super.key,
    required this.onOpenLogs,
    required this.onOpenReceivedFiles,
  });
  @override
  State<MobileSettingsContent> createState() => _MobileSettingsContentState();
}

class _MobileSettingsContentState extends State<MobileSettingsContent>
    with WidgetsBindingObserver {
  static const _widgetChannel = MethodChannel(
    'com.clipyclone.clipy_android/widget',
  );
  bool _timerWidgetPinned = false;
  bool _pinning = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshPinned();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshPinned();
  }

  Future<void> _refreshPinned() async {
    try {
      final pinned =
          await _widgetChannel.invokeMethod<bool>('isTimerWidgetPinned') ??
          false;
      if (mounted) setState(() => _timerWidgetPinned = pinned);
    } catch (_) {
      /* Not every platform supports launcher widgets. */
    }
  }

  Future<void> _pin() async {
    if (_pinning) return;
    setState(() => _pinning = true);
    try {
      final ok =
          await _widgetChannel.invokeMethod<bool>('requestPinTimerWidget') ??
          false;
      if (!mounted) return;
      showClipyMessage(
        context,
        ok
            ? context.l10n.timerWidgetPinRequested
            : context.l10n.timerWidgetPinFailed,
      );
      if (ok) {
        await Future<void>.delayed(const Duration(seconds: 3));
        if (mounted) await _refreshPinned();
      }
    } catch (_) {
      if (mounted) showClipyMessage(context, context.l10n.timerWidgetPinFailed);
    } finally {
      if (mounted) setState(() => _pinning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ClipySection(
            title: l10n.personalize,
            child: Column(
              children: [
                ListTile(
                  leading: const ClipyIcon(Icons.palette_outlined),
                  title: Text(l10n.appearance),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: SegmentedButton<ThemeMode>(
                      showSelectedIcon: false,
                      segments: [
                        ButtonSegment(
                          value: ThemeMode.system,
                          label: Text(l10n.systemTheme),
                        ),
                        ButtonSegment(
                          value: ThemeMode.light,
                          label: Text(l10n.lightTheme),
                        ),
                        ButtonSegment(
                          value: ThemeMode.dark,
                          label: Text(l10n.darkTheme),
                        ),
                      ],
                      selected: {AppAppearance.instance.mode},
                      onSelectionChanged: (value) async {
                        await AppAppearance.instance.setMode(value.first);
                        if (mounted) setState(() {});
                      },
                    ),
                  ),
                ),
                const Divider(indent: 20, endIndent: 20),
                ListTile(
                  leading: const ClipyIcon(Icons.language_rounded),
                  title: Text(l10n.languageLabel),
                  trailing: DropdownButtonHideUnderline(
                    child: DropdownButton<AppLanguage>(
                      value: AppLanguageController.instance.language,
                      onChanged: (language) async {
                        if (language == null) return;
                        await AppLanguageController.instance.setLanguage(
                          language,
                        );
                        if (mounted) setState(() {});
                      },
                      items: AppLanguage.values
                          .map(
                            (language) => DropdownMenuItem(
                              value: language,
                              child: Text(language.displayName),
                            ),
                          )
                          .toList(),
                    ),
                  ),
                ),
              ],
            ),
          ),
          ClipySection(
            title: l10n.homeWidgetSection,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const ClipyIcon(Icons.timer_outlined),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          l10n.timerWidgetTitle,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    l10n.timerWidgetDesc,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 18),
                  FilledButton.tonalIcon(
                    onPressed: _timerWidgetPinned || _pinning ? null : _pin,
                    icon: Icon(
                      _timerWidgetPinned
                          ? Icons.check_circle_outline
                          : Icons.add_rounded,
                    ),
                    label: Text(
                      _timerWidgetPinned
                          ? l10n.timerWidgetAdded
                          : l10n.addToHomeScreen,
                    ),
                  ),
                ],
              ),
            ),
          ),
          ClipySection(
            title: l10n.toolsAndSupport,
            child: Column(
              children: [
                ListTile(
                  leading: const ClipyIcon(Icons.tune_rounded),
                  title: Text(l10n.connectionSettings),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => showModalBottomSheet<bool>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => const ConnectionEditor(),
                  ),
                ),
                const Divider(indent: 76, endIndent: 20),
                ListTile(
                  leading: const ClipyIcon(Icons.folder_open_rounded),
                  title: Text(l10n.receivedFiles),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: widget.onOpenReceivedFiles,
                ),
                const Divider(indent: 76, endIndent: 20),
                ListTile(
                  leading: const ClipyIcon(Icons.article_outlined),
                  title: Text(l10n.viewLogs),
                  subtitle: Text(l10n.appRuntimeLogs),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: widget.onOpenLogs,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              children: [
                Text('Clipy', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 6),
                Text(
                  l10n.aboutClipy,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
