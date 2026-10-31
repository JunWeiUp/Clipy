import 'package:clipy_flutter/features/settings/windows_hotkeys.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('restores saved keys and keeps the old binding on conflict', () async {
    SharedPreferences.setMockInitialValues({
      'windows.hotkey.history': '2:72',
      'windows.hotkey.screenshot': '6:83',
    });
    final state = <String, Object?>{
      'historyModifiers': 6,
      'historyKey': 86,
      'history': true,
      'screenshotModifiers': 6,
      'screenshotKey': 65,
      'screenshot': true,
    };
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(WindowsHotkeys.channel, (call) async {
          calls.add(call.method);
          if (call.method == 'getHotkeys') {
            return Map<String, Object?>.of(state);
          }
          if (call.method == 'restoreHotkeys') {
            state.addAll(Map<String, Object?>.from(call.arguments as Map));
            return null;
          }
          if (call.method == 'setHotkey') {
            final args = Map<String, Object?>.from(call.arguments as Map);
            if (args['key'] == 88) return false;
            state['${args['kind']}Modifiers'] = args['modifiers'];
            state['${args['kind']}Key'] = args['key'];
            return true;
          }
          throw MissingPluginException();
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(WindowsHotkeys.channel, null),
    );

    await WindowsHotkeys.initialize();
    expect(calls, contains('restoreHotkeys'));
    expect(state['historyKey'], 72);
    expect(await WindowsHotkeys.save('history', 2, 88), isFalse);
    expect(state['historyKey'], 72);
    expect(
      (await SharedPreferences.getInstance()).getString(
        'windows.hotkey.history',
      ),
      '2:72',
    );
    expect(await WindowsHotkeys.save('history', 2, 74), isTrue);
    expect(state['historyKey'], 74);
    expect(
      (await SharedPreferences.getInstance()).getString(
        'windows.hotkey.history',
      ),
      '2:74',
    );
  });
}
