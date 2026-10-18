/// A probe may expire only the same connection, and only without a new pong.
bool shouldExpireNetworkProbe({
  required Object capturedConnection,
  required Object? currentConnection,
  required DateTime previousPong,
  required DateTime currentPong,
}) =>
    identical(capturedConnection, currentConnection) &&
    !currentPong.isAfter(previousPong);
