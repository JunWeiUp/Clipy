import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'database/clipboard_repository.dart';
import 'log_manager.dart';
import 'models.dart';
import 'sync_manager.dart';

class ClipboardManager with WidgetsBindingObserver, ChangeNotifier {
  static final ClipboardManager instance = ClipboardManager._();
  ClipboardManager._();

  static const _clipboardChannel = MethodChannel(
    'com.clipyclone.clipy_android/clipboard',
  );

  String? _lastText;

  /// Recent remote-origin hashes used as a second loopback guard (the first
  /// line is `_lastText == text`). Kept as a bounded, time-windowed set so
  /// concurrent remote pushes and restart windows are both covered.
  /// Keep aligned with the macOS side's recentRemoteHashes.
  final List<_RemoteHashEntry> _recentRemoteHashes = [];
  static const int _recentRemoteHashMax = 20;
  static const Duration _recentRemoteHashTtl = Duration(seconds: 60);

  /// Bundle ids / package names excluded from history and sync. Defaults match
  /// the macOS side (password managers / keychain) so behavior is symmetric.
  /// Keep aligned with PreferencesManager.defaultExcludedApps on macOS.
  static const List<String> _defaultExcludedApps = [
    // macOS password managers / keychain
    'com.agilebits.onepassword7',
    'com.apple.keychainaccess',
    // Android password managers (best-effort package ids)
    'com.android.onepassword',
    'com.agilebits.onepassword',
    'com.onepassword.android',
  ];

  int _historyLimit = 1000;
  List<String> _excludedApps = [];
  Timer? _pollTimer;
  bool _monitoring = false;
  bool _inBackground = false;
  bool _lifecycleObserverRegistered = false;

  int get historyLimit => _historyLimit;
  List<String> get excludedApps => List.unmodifiable(_excludedApps);

  Future<List<HistoryEntry>> fetchPage({
    required int offset,
    required int limit,
  }) {
    return ClipboardRepository.instance.fetchPage(offset: offset, limit: limit);
  }

  Future<int> count() => ClipboardRepository.instance.count();

  Future<void> reloadPreferences() async {
    await _loadPreferences();
  }

  Future<void> init() async {
    appLog('Initializing ClipboardManager...');
    await _loadPreferences();

    if (Platform.isAndroid) {
      _clipboardChannel.setMethodCallHandler(_handleClipboardMethodCall);
      if (!_lifecycleObserverRegistered) {
        WidgetsBinding.instance.addObserver(this);
        _lifecycleObserverRegistered = true;
      }
      await startMonitoring();
    } else {
      _startPolling(const Duration(seconds: 1));
    }
  }

  Future<dynamic> _handleClipboardMethodCall(MethodCall call) async {
    if (call.method == 'onClipboardChanged') {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      final text = args['text'] as String?;
      final isBaseline = args['isBaseline'] as bool? ?? false;
      // Real source package from the native side (Android). Falls back to a
      // generic platform label so excludedApps still has something to compare.
      final sourcePackage = args['sourcePackage'] as String?;
      final sourceApp = (sourcePackage != null && sourcePackage.isNotEmpty)
          ? sourcePackage
          : (Platform.isIOS ? 'iOS' : 'Android');
      if (text != null && text.isNotEmpty) {
        await _processClipboardText(
          text,
          recordHistory: !isBaseline && _lastText != null,
          sourceApp: sourceApp,
        );
      }
    }
    return null;
  }

  Future<void> startMonitoring() async {
    if (!Platform.isAndroid || _monitoring) return;
    _monitoring = true;
    try {
      await _clipboardChannel.invokeMethod('startMonitoring');
    } catch (e) {
      appLog(
        'ClipboardManager: failed to start native monitoring: $e',
        level: 'warning',
      );
    }
    _updateBackgroundPoll();
  }

  Future<void> stopMonitoring() async {
    if (!Platform.isAndroid || !_monitoring) return;
    _monitoring = false;
    _stopPolling();
    try {
      await _clipboardChannel.invokeMethod('stopMonitoring');
    } catch (e) {
      appLog(
        'ClipboardManager: failed to stop native monitoring: $e',
        level: 'warning',
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _inBackground =
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.inactive;

    if (state == AppLifecycleState.detached) {
      unawaited(stopMonitoring());
      return;
    }

    if (state == AppLifecycleState.resumed) {
      _stopPolling();
      if (Platform.isAndroid && !_monitoring) {
        unawaited(startMonitoring());
      }
      // Catch up on anything copied while we were backgrounded. Android 10+
      // blocks background clipboard reads, so this resume poll is the
      // reliable path (per sync power plan v2 — no background polling).
      unawaited(_pollClipboardOnce());
    }

    _updateBackgroundPoll();
  }

  void _updateBackgroundPoll() {
    // Foreground-only (per sync power plan v2): the native
    // OnPrimaryClipChangedListener is the primary capture path while visible.
    // Background polling is removed — Android 10+ blocks background clipboard
    // reads, so the 5min wake was pure battery cost with no real benefit.
    if (!Platform.isAndroid) return;
    if (_inBackground) {
      _stopPolling();
    }
  }

  void _startPolling(Duration interval) {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      interval,
      (_) => unawaited(_pollClipboardOnce()),
    );
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<void> _pollClipboardOnce() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      await _processClipboardText(
        data.text!,
        recordHistory: _lastText != null,
        sourceApp: Platform.isMacOS
            ? 'macOS'
            : (Platform.isIOS ? 'iOS' : 'Android'),
      );
    }
  }

  Future<void> _processClipboardText(
    String text, {
    required bool recordHistory,
    String? sourceApp,
  }) async {
    if (text == _lastText) return;
    if (recordHistory) {
      final item = HistoryItem(type: 'text', value: text);
      final entry = HistoryEntry(
        item: item,
        date: DateTime.now(),
        sourceApp: sourceApp,
        contentHash: _contentHashForItem(item),
      );
      await _addToHistory(entry);
    }
    _lastText = text;
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    _historyLimit = prefs.getInt('historyLimit') ?? 1000;
    _excludedApps =
        prefs.getStringList('excludedApps') ?? List.from(_defaultExcludedApps);
  }

  /// Records a remote-origin hash so the next local copy of the same content is
  /// recognized as a loopback and not re-broadcast.
  void _rememberRemoteHash(String hash) {
    _recentRemoteHashes.add(_RemoteHashEntry(hash: hash, at: DateTime.now()));
    _pruneRemoteHashes();
  }

  bool _wasRecentlyRemote(String hash) {
    _pruneRemoteHashes();
    return _recentRemoteHashes.any((e) => e.hash == hash);
  }

  void _pruneRemoteHashes() {
    final cutoff = DateTime.now().subtract(_recentRemoteHashTtl);
    _recentRemoteHashes.removeWhere((e) => e.at.isBefore(cutoff));
    while (_recentRemoteHashes.length > _recentRemoteHashMax) {
      _recentRemoteHashes.removeAt(0);
    }
  }

  Future<void> _addToHistory(
    HistoryEntry entry, {
    bool broadcast = true,
  }) async {
    if (entry.sourceApp != null && _excludedApps.contains(entry.sourceApp)) {
      return;
    }

    final normalizedEntry = entry.contentHash != null
        ? entry
        : HistoryEntry(
            item: entry.item,
            date: entry.date,
            sourceApp: entry.sourceApp,
            contentHash: _contentHashForItem(entry.item),
          );

    // Loopback guard: skip broadcast if this exact content just arrived from a
    // remote peer (single-field `_lastText` check above is the first line).
    final isLoopback =
        normalizedEntry.contentHash != null &&
        _wasRecentlyRemote(normalizedEntry.contentHash!);

    if (broadcast && !isLoopback) {
      if (normalizedEntry.item.type == 'text') {
        // Primary LAN clipboard sync — always text/plain.
        unawaited(
          SyncManager.instance.broadcastSync(
            normalizedEntry.item.value as String,
            normalizedEntry.contentHash!,
          ),
        );
      }
    }

    await ClipboardRepository.instance.insert(normalizedEntry);
    await ClipboardRepository.instance.trimToLimit(_historyLimit);
    onHistoryChanged?.call();
    notifyListeners();
  }

  void copyToClipboard(HistoryItem item) {
    if (item.type == 'text') {
      Clipboard.setData(ClipboardData(text: item.value as String));
      _lastText = item.value as String;
    }
  }

  /// SharedPreferences key read by Kotlin FGS when there is no Activity —
  /// MethodChannel replies often never arrive until the UI attaches.
  static const _headlessClipboardKey = 'clipy.headlessClipboard';

  /// Returns true when history row is durable. Clipboard is best-effort and
  /// must NEVER block the ACK path after force-kill (headless engine).
  Future<bool> handleRemoteSync(String text, String hash) async {
    if (text.isEmpty) return false;
    final effectiveHash = hash.isNotEmpty
        ? hash
        : (_contentHashForItem(HistoryItem(type: 'text', value: text)) ??
              text.hashCode.toString());

    try {
      final latest = await ClipboardRepository.instance.latestEntry();
      if (latest != null && latest.contentHash == effectiveHash) {
        _rememberRemoteHash(effectiveHash);
        _lastText = text;
        // Same as current top of history — do not re-set system clipboard.
        appLog(
          'handleRemoteSync: already latest hash=${effectiveHash.substring(0, effectiveHash.length.clamp(0, 8))} (skip clipboard)',
        );
        return true;
      }

      _rememberRemoteHash(effectiveHash);
      _lastText = text;

      final item = HistoryItem(type: 'text', value: text);
      final entry = HistoryEntry(
        item: item,
        date: DateTime.now(),
        sourceApp: 'Remote Sync',
        contentHash: effectiveHash,
      );

      await _addToHistory(entry, broadcast: false);
      // Queue + non-blocking write so ACK is not stuck until UI opens.
      unawaited(_writeSystemClipboard(text));
      appLog(
        'handleRemoteSync: stored hash=${effectiveHash.substring(0, effectiveHash.length.clamp(0, 8))}',
      );
      return true;
    } catch (e) {
      appLog('handleRemoteSync failed: $e', level: 'error');
      return false;
    }
  }

  /// Fast path: MethodChannel (may hang headless). Fallback: prefs for FGS drain.
  ///
  /// The prefs fallback is size-gated: SharedPreferences is kept fully in
  /// memory on BOTH sides (Kotlin's map + the Dart plugin cache), so a huge
  /// clip would be pinned 2-3x until the next FGS drain. Large texts skip the
  /// fallback — they stay in history, just without a headless clipboard write.
  static const _headlessClipboardPrefsMaxChars = 64 * 1024;

  Future<void> _writeSystemClipboard(String text) async {
    if (text.length <= _headlessClipboardPrefsMaxChars) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_headlessClipboardKey, text);
      } catch (e) {
        appLog('headless clipboard prefs write failed: $e', level: 'warning');
      }
    }

    try {
      final native = await _clipboardChannel
          .invokeMethod<bool>('setText', {'text': text})
          .timeout(const Duration(milliseconds: 400), onTimeout: () => false);
      if (native == true) {
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.remove(_headlessClipboardKey);
        } catch (_) {}
        return;
      }
    } catch (e) {
      appLog('native setText failed/timeout: $e', level: 'warning');
    }
    try {
      await Clipboard.setData(
        ClipboardData(text: text),
      ).timeout(const Duration(milliseconds: 400));
    } catch (e) {
      appLog('Flutter Clipboard.setData failed/timeout: $e', level: 'warning');
    }
  }

  /// Batch catch-up path: ingest multiple remote history frames in one DB
  /// transaction with a single notifyListeners, instead of N. Used when a peer
  /// answers our `history.fetch` (or flushes a large pending backlog on
  /// reconnect) — without this each frame triggers insert + notifyListeners,
  /// and the list clears+rebuilds on every notify (a visible refresh storm).
  ///
  /// Dedup: drops any frame whose hash already exists in the DB, so a replay
  /// is idempotent. System clipboard is written only when at least one **new**
  /// hash was inserted (newest among new items); all-known replay leaves the
  /// clipboard untouched. Skip broadcast (these came *from* a peer).
  Future<void> handleRemoteSyncBatch(
    List<({String text, String hash})> items,
  ) async {
    if (items.isEmpty) return;
    // Normalize empty hashes the same way as handleRemoteSync.
    final normalized = <({String text, String hash})>[];
    for (final item in items) {
      if (item.text.isEmpty) continue;
      final effectiveHash = item.hash.isNotEmpty
          ? item.hash
          : (_contentHashForItem(HistoryItem(type: 'text', value: item.text)) ??
                item.text.hashCode.toString());
      normalized.add((text: item.text, hash: effectiveHash));
    }
    if (normalized.isEmpty) return;

    // Pre-filter against existing hashes to avoid a pointless transaction.
    // insertBatch itself also uses INSERT OR IGNORE as a second line of defense
    // (in case two batches race or a hash slips through normalization), and it
    // does NOT bump created_at on existing rows — so a fetch replay is truly
    // idempotent: existing entries keep their position and the UI never rebuilds.
    final existingHashes = await ClipboardRepository.instance.existingHashes(
      normalized.map((e) => e.hash).toList(),
    );
    final toInsert = <HistoryEntry>[];
    for (final item in normalized) {
      if (existingHashes.contains(item.hash)) continue;
      _rememberRemoteHash(item.hash);
      toInsert.add(
        HistoryEntry(
          item: HistoryItem(type: 'text', value: item.text),
          date: DateTime.now(),
          sourceApp: 'Remote Sync',
          contentHash: item.hash,
        ),
      );
    }
    if (toInsert.isEmpty) {
      appLog(
        'handleRemoteSyncBatch: ${normalized.length} received, 0 new — skip clipboard',
      );
      return;
    }
    final inserted = await ClipboardRepository.instance.insertBatch(toInsert);
    appLog(
      'handleRemoteSyncBatch: ${normalized.length} received, ${toInsert.length} new (post-dedup), $inserted inserted',
    );
    if (inserted == 0) return; // all were IGNORE'd (race / normalization drift)
    await ClipboardRepository.instance.trimToLimit(_historyLimit);
    // Mac pushes oldest-first; last new item is the newest among inserts.
    final newestText = toInsert.last.item.value as String;
    _lastText = newestText;
    unawaited(_writeSystemClipboard(newestText));
    onHistoryChanged?.call();
    notifyListeners();
  }

  Future<void> clearHistory() async {
    await ClipboardRepository.instance.clearAll();
    onHistoryChanged?.call();
    notifyListeners();
  }

  Future<void> updateHistoryLimit(int limit) async {
    _historyLimit = limit;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('historyLimit', limit);
    await ClipboardRepository.instance.trimToLimit(_historyLimit);
    onHistoryChanged?.call();
    notifyListeners();
  }

  Future<void> updateExcludedApps(List<String> apps) async {
    _excludedApps = apps;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('excludedApps', apps);
  }

  void Function()? onHistoryChanged;

  String? _contentHashForItem(HistoryItem item) {
    switch (item.type) {
      case 'text':
        final text = (item.value as String).trim();
        final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
        final bytes = utf8.encode(normalized);
        return sha256.convert(bytes).toString();
      default:
        final bytes = utf8.encode(jsonEncode(item.toJson()));
        return sha256.convert(bytes).toString();
    }
  }
}

class _RemoteHashEntry {
  final String hash;
  final DateTime at;
  const _RemoteHashEntry({required this.hash, required this.at});
}
