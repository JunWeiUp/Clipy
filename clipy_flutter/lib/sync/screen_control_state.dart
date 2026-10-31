import 'dart:convert';
import 'dart:io' show Platform;

/// Mac lock/unlock is a phone-only control (Android/iOS). Desktop clients
/// neither query Mac screen state nor show the controls.
bool macScreenControlSupportedOn(String operatingSystem) =>
    operatingSystem == 'android' || operatingSystem == 'ios';

final bool macScreenControlSupported = macScreenControlSupportedOn(
  Platform.operatingSystem,
);

class MacScreenState {
  final bool directControl;
  final bool configured;
  final bool? locked;
  final bool helper;
  final String challenge;
  const MacScreenState({
    this.directControl = true,
    required this.configured,
    required this.locked,
    required this.helper,
    required this.challenge,
  });
  static MacScreenState? parse(String text) {
    if (text.length > 2048) return null;
    try {
      final value = jsonDecode(text);
      if (value is! Map ||
          value['configured'] is! bool ||
          (value['locked'] != null && value['locked'] is! bool) ||
          value['helper'] is! bool ||
          value['challenge'] is! String ||
          (value['challenge'] as String).length > 64) {
        return null;
      }
      return MacScreenState(
        directControl: value['controlMode'] == 'connected-v1',
        configured: value['configured'],
        locked: value['locked'],
        helper: value['helper'],
        challenge: value['challenge'],
      );
    } catch (_) {
      return null;
    }
  }
}

/// The Mac-local configuration opts in every connected peer. No manual key.
String? macScreenCommand(MacScreenState state, String action) {
  if (!state.directControl ||
      !state.configured ||
      state.locked == null ||
      !['lock', 'unlock'].contains(action) ||
      state.challenge.isEmpty) {
    return null;
  }
  return jsonEncode({'action': action, 'challenge': state.challenge});
}

String? parseMacScreenResult(String text, String challenge) {
  if (text.length > 2048) return null;
  try {
    final value = jsonDecode(text);
    if (value is! Map ||
        value['challenge'] != challenge ||
        value['status'] is! String ||
        !{
          'ok',
          'unavailable',
          'helperMissing',
          'permissionOrHelper',
          'accessibilityRequired',
          'secureFieldUnavailable',
          'secureFieldWriteFailed',
          'secureConfirmFailed',
          'credentialInvalid',
          'credentialUnavailable',
          'busy',
          'notConfigured',
          'sessionUnavailable',
          'cooldown',
          'cancelled',
          'notConfirmed',
          'invalidAction',
        }.contains(value['status'])) {
      return null;
    }
    return value['status'] as String;
  } catch (_) {
    return null;
  }
}
