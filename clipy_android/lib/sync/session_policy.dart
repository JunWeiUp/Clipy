const syncSessionPolicy = 'peer-id-v1';

/// Both ends must retain the same physical socket after simultaneous discovery.
/// A sole connection is always accepted; this policy applies only to duplicates.
bool shouldReplaceSyncSession({
  String? remotePolicy,
  required String localId,
  required String remoteId,
  required bool existingInbound,
  required bool incomingInbound,
}) {
  // Old clients unconditionally replace duplicates. Do not apply a competing
  // selection rule unless the peer explicitly advertises the same policy.
  if (remotePolicy != syncSessionPolicy) return true;
  final preferInbound = localId.compareTo(remoteId) > 0;
  return existingInbound != preferInbound || incomingInbound == preferInbound;
}
