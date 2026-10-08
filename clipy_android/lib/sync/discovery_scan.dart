/// Ephemeral scan state. A completed probe is not necessarily a found device.
class DiscoveryProgress {
  final bool running;
  final int completed;
  final int total;
  const DiscoveryProgress({
    this.running = false,
    this.completed = 0,
    this.total = 0,
  });
  double? get fraction => total == 0 ? null : completed / total;
}

/// Fixed-size worker pool: progress follows finished probes, never scheduled IPs.
/// Cancellation stops scheduling and suppresses late progress from old runs.
Future<void> runDiscoveryScan(
  List<String> hosts, {
  required int concurrency,
  required bool Function() isCurrent,
  required Future<void> Function(String) probe,
  required void Function(int completed, int total) onProgress,
}) async {
  if (concurrency < 1) throw ArgumentError.value(concurrency, 'concurrency');
  if (!isCurrent()) return;
  var next = 0;
  var completed = 0;
  onProgress(0, hosts.length);
  Future<void> worker() async {
    while (isCurrent() && next < hosts.length) {
      await probe(hosts[next++]);
      if (!isCurrent()) return;
      onProgress(++completed, hosts.length);
    }
  }

  await Future.wait(
    List.generate(
      hosts.length < concurrency ? hosts.length : concurrency,
      (_) => worker(),
    ),
  );
}
