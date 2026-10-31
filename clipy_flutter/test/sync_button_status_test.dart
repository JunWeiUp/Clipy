import 'package:flutter_test/flutter_test.dart';
import 'package:clipy_flutter/app_localizations.dart';
import 'package:clipy_flutter/features/devices/devices_page.dart';
import 'package:clipy_flutter/sync/relay_client.dart';

void main() {
  final strings = AppStrings(AppLanguage.zh);
  String label({
    bool enabled = true,
    bool server = true,
    bool lan = false,
    bool relay = false,
    bool scanning = false,
    bool busy = false,
    RelayConnectionState state = RelayConnectionState.disabled,
  }) => syncButtonLabel(
    strings,
    enabled: enabled,
    serverRunning: server,
    lan: lan,
    relay: relay,
    relayState: state,
    scanning: scanning,
    busy: busy,
  );
  test('listening and relay presence do not imply a connected peer', () {
    expect(label(), strings.syncWaiting);
    expect(label(scanning: true), strings.syncSearching);
    expect(label(state: RelayConnectionState.ready), strings.syncRelayReady);
    expect(
      label(state: RelayConnectionState.connecting),
      strings.syncRelayConnecting,
    );
    expect(
      label(state: RelayConnectionState.retrying),
      strings.syncRelayRetrying,
    );
    expect(label(server: false), strings.diagServerNotBound);
  });
  test('live transports take priority over relay control retries', () {
    expect(
      label(lan: true, state: RelayConnectionState.retrying),
      strings.syncLanConnected,
    );
    expect(label(relay: true), strings.syncRelayConnected);
    expect(label(lan: true, relay: true), strings.syncMixedConnected);
    expect(label(enabled: false, lan: true), strings.syncStart);
    expect(label(busy: true), strings.syncStarting);
    expect(label(busy: true, enabled: false), strings.syncStopping);
  });
}
