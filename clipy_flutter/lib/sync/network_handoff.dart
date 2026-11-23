/// Relay re-announces peers after every refresh, so peer-available probes are
/// throttled; otherwise probe → refreshPeers → peer.up re-arms every few seconds.
const relayPeerProbeCooldown = Duration(seconds: 30);

/// LAN answers within 3s; relay tunnels (mobile data, remote relay, backlog
/// flush) need a longer window before a silent session is retired.
const lanProbeDelay = Duration(seconds: 3);
const relayProbeDelay = Duration(seconds: 8);

Duration networkProbeDelay({required bool hasRelaySession}) =>
    hasRelaySession ? relayProbeDelay : lanProbeDelay;

bool shouldStartRelayPeerProbe(DateTime? lastProbe, DateTime now) =>
    lastProbe == null || now.difference(lastProbe) >= relayPeerProbeCooldown;

/// A probe may expire only the same connection, and only when it produced
/// neither a pong nor any inbound bytes (a busy flush can queue the pong).
bool shouldExpireNetworkProbe({
  required Object capturedConnection,
  required Object? currentConnection,
  required DateTime previousPong,
  required DateTime currentPong,
  required DateTime previousInbound,
  required DateTime currentInbound,
}) =>
    identical(capturedConnection, currentConnection) &&
    !currentPong.isAfter(previousPong) &&
    !currentInbound.isAfter(previousInbound);
