import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_localizations.dart';
import '../../database/pending_sync_repository.dart';
import '../../sync/diagnostics.dart';
import '../../sync_manager.dart';
import '../../ui/app_components.dart';

/// Per-device sync health (state, pending queue, last ACK, last error).
/// Mirrors the macOS settings section; data lives in memory only.
class SyncDiagnosticsPage extends StatefulWidget {
  const SyncDiagnosticsPage({super.key});

  @override
  State<SyncDiagnosticsPage> createState() => _SyncDiagnosticsPageState();
}

class _DiagnosticsRow {
  _DiagnosticsRow({
    required this.record,
    required this.name,
    required this.online,
    required this.authorized,
    required this.pending,
  });
  final SyncPeerDiagnostics record;
  final String name;
  final bool online;
  final bool authorized;
  final int pending;
}

class _SyncDiagnosticsPageState extends State<SyncDiagnosticsPage> {
  List<_DiagnosticsRow> _rows = const [];
  Timer? _timer;

  SyncDiagnostics get _diagnostics => SyncManager.instance.diagnostics;

  @override
  void initState() {
    super.initState();
    _diagnostics.addListener(_reload);
    // Pending counts and relative times change without a notification.
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _reload());
    _reload();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _diagnostics.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final manager = SyncManager.instance;
    final pending = await PendingSyncRepository.instance.pendingCounts();
    if (!mounted) return;
    final records = Map.of(_diagnostics.records);
    final online = manager.connectedPeerIds;
    final authorized = manager.authorizedPeerIds.toSet();
    for (final id in {...online, ...pending.keys, ...authorized}) {
      records.putIfAbsent(id, () => SyncPeerDiagnostics(id));
    }
    final rows =
        [
          for (final r in records.values)
            _DiagnosticsRow(
              record: r,
              name: r.name ?? manager.resolvedPeerLabel(r.peerId),
              online: online.contains(r.peerId),
              authorized: authorized.contains(r.peerId),
              pending: pending[r.peerId] ?? 0,
            ),
        ]..sort((a, b) {
          if (a.online != b.online) return a.online ? -1 : 1;
          return a.name.toLowerCase().compareTo(b.name.toLowerCase());
        });
    setState(() => _rows = rows);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.syncDiagnosticsTitle),
        actions: [
          IconButton(
            tooltip: l10n.syncDiagnosticsReset,
            icon: const Icon(Icons.delete_sweep_rounded),
            onPressed: _diagnostics.reset,
          ),
        ],
      ),
      body: _rows.isEmpty
          ? ClipyEmptyState(
              icon: Icons.monitor_heart_outlined,
              title: l10n.syncDiagnosticsEmpty,
              message: l10n.syncDiagnosticsHint,
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                  child: Text(
                    l10n.syncDiagnosticsHint,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                for (final row in _rows) _DiagnosticsCard(row: row),
              ],
            ),
    );
  }
}

class _DiagnosticsCard extends StatelessWidget {
  const _DiagnosticsCard({required this.row});
  final _DiagnosticsRow row;

  String _time(AppStrings l10n, DateTime? t) {
    if (t == null) return '—';
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 60) return l10n.syncDiagnosticsSecondsAgo(d.inSeconds);
    if (d.inMinutes < 60) return l10n.syncDiagnosticsMinutesAgo(d.inMinutes);
    if (d.inHours < 24) return l10n.syncDiagnosticsHoursAgo(d.inHours);
    return '${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final r = row.record;
    final shortId = r.peerId.substring(0, r.peerId.length.clamp(0, 8));
    final details = <String>[
      if (r.host != null) r.host!,
      shortId,
      if (row.online)
        '${l10n.syncDiagnosticsSessionUp} ${_time(l10n, r.sessionUpAt)}'
      else if (r.sessionDownAt != null)
        '${l10n.syncDiagnosticsSessionDown} ${_time(l10n, r.sessionDownAt)}',
      '${l10n.syncDiagnosticsLastSent} ${_time(l10n, r.lastSentAt)}',
      '${l10n.syncDiagnosticsLastAck} ${_time(l10n, r.lastAckAt)}',
      '${l10n.syncDiagnosticsLastReceived} ${_time(l10n, r.lastReceivedAt)}',
    ];
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 10,
                  color: row.online ? Colors.green : colors.outline,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    row.name,
                    style: text.titleSmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  row.online
                      ? l10n.syncDiagnosticsOnline
                      : l10n.syncDiagnosticsOffline,
                  style: text.bodySmall,
                ),
                if (!row.authorized) ...[
                  const SizedBox(width: 8),
                  Text(
                    l10n.syncDiagnosticsNotAuthorized,
                    style: text.bodySmall,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 6),
            Text(
              l10n.syncDiagnosticsPending(row.pending),
              style: text.bodySmall?.copyWith(
                color: row.pending > 0 ? Colors.orange : null,
                fontWeight: row.pending > 0 ? FontWeight.w600 : null,
              ),
            ),
            const SizedBox(height: 4),
            SelectableText(details.join(' · '), style: text.bodySmall),
            if (r.lastError != null) ...[
              const SizedBox(height: 4),
              SelectableText(
                '${l10n.syncDiagnosticsLastError}: ${r.lastError} · ${_time(l10n, r.lastErrorAt)}',
                style: text.bodySmall?.copyWith(color: colors.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
