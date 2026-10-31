import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipy_flutter/sync/screen_control_state.dart';

void main() {
  const state = MacScreenState(
    configured: true,
    locked: true,
    helper: true,
    challenge: 'nonce',
  );
  test('only phone platforms expose Mac screen control', () {
    expect(macScreenControlSupportedOn('android'), isTrue);
    expect(macScreenControlSupportedOn('ios'), isTrue);
    for (final os in ['windows', 'macos', 'linux']) {
      expect(macScreenControlSupportedOn(os), isFalse);
    }
  });

  test('connected mode sends direct commands without credentials', () {
    final command = jsonDecode(macScreenCommand(state, 'unlock')!) as Map;
    expect(command, {'action': 'unlock', 'challenge': 'nonce'});
    expect(macScreenCommand(state, 'other'), null);
    expect(
      macScreenCommand(
        const MacScreenState(
          configured: false,
          locked: false,
          helper: true,
          challenge: 'n',
        ),
        'lock',
      ),
      null,
    );
  });
  test('old Mac mode is detected; unknown state is not unlocked', () {
    final old = MacScreenState.parse(
      '{"configured":true,"locked":null,"helper":false,"challenge":"n"}',
    )!;
    expect(old.directControl, false);
    expect(old.locked, null);
    expect(macScreenCommand(old, 'unlock'), null);
    expect(
      MacScreenState.parse(
        '{"controlMode":"connected-v1","configured":true,"locked":false,"helper":true,"challenge":"n"}',
      )!.directControl,
      true,
    );
    expect(
      MacScreenState.parse(
        '{"configured":true,"locked":"false","helper":true,"challenge":"n"}',
      ),
      null,
    );
    expect(MacScreenState.parse('[]'), null);
    expect(MacScreenState.parse('x' * 2049), null);
  });
  test('results must match the command challenge and have known status', () {
    expect(
      parseMacScreenResult('{"status":"ok","challenge":"nonce"}', 'nonce'),
      'ok',
    );
    expect(
      parseMacScreenResult('{"status":"ok","challenge":"old"}', 'nonce'),
      null,
    );
    expect(
      parseMacScreenResult(
        '{"status":"invented","challenge":"nonce"}',
        'nonce',
      ),
      null,
    );
    expect(parseMacScreenResult('bad', 'nonce'), null);
    for (final status in [
      'busy',
      'cooldown',
      'notConfigured',
      'sessionUnavailable',
    ]) {
      expect(
        parseMacScreenResult(
          jsonEncode({'status': status, 'challenge': 'nonce'}),
          'nonce',
        ),
        status,
      );
    }
  });
}
