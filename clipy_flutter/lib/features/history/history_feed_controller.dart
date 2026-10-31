import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import '../../models.dart';

typedef HistoryPageLoader =
    Future<List<HistoryEntry>> Function({
      required int offset,
      required int limit,
      required String query,
      required String filter,
    });

/// Serializes pagination and refresh. A refresh during a query is replayed,
/// and results belonging to an older search can never replace the current one.
class HistoryFeedController extends ChangeNotifier {
  HistoryFeedController(this.loader, {this.pageSize = 50});
  final HistoryPageLoader loader;
  final int pageSize;
  List<HistoryEntry> entries = [];
  String query = '';
  String filter = 'all';
  bool loading = false;
  bool hasMore = true;
  bool failed = false;
  bool _disposed = false;
  bool _resetPending = false;
  int _revision = 0;
  Future<void>? _running;

  Future<void> search(String text, String type) {
    query = text.trim();
    filter = type;
    // Old matches must not be presented under the new filter.
    entries = [];
    return refresh();
  }

  Future<void> refresh() {
    _revision++;
    _resetPending = true;
    return _start();
  }

  Future<void> loadMore() {
    if (!hasMore || loading || _disposed) return _running ?? Future.value();
    return _start();
  }

  Future<void> _start() {
    if (_disposed) return Future.value();
    if (_running != null) return _running!;
    final completion = Completer<void>();
    _running = completion.future;
    loading = true;
    failed = false;
    notifyListeners();
    unawaited(_drain(completion));
    return completion.future;
  }

  Future<void> _drain(Completer<void> completion) async {
    do {
      final reset = _resetPending;
      _resetPending = false;
      final revision = _revision;
      final limit = reset ? math.max(pageSize, entries.length) : pageSize;
      try {
        final page = await loader(
          offset: reset ? 0 : entries.length,
          limit: limit,
          query: query,
          filter: filter,
        );
        if (!_disposed && revision == _revision) {
          entries = reset ? page : [...entries, ...page];
          hasMore = page.length == limit;
          failed = false;
        }
      } catch (_) {
        if (!_disposed && revision == _revision) failed = true;
      }
    } while (!_disposed && _resetPending);
    loading = false;
    _running = null;
    if (!_disposed) notifyListeners();
    completion.complete();
  }

  @override
  void dispose() {
    _disposed = true;
    _revision++;
    super.dispose();
  }
}
