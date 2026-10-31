import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:clipy_flutter/app_localizations.dart';
import 'package:clipy_flutter/features/devices/relay_group_page.dart';
import 'package:clipy_flutter/sync/relay_identity.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sodium/sodium.dart';
import 'package:common_relay/common_relay.dart' as cr;
import 'package:clipy_flutter/sync/relay_groups.dart';

class _Headers implements HttpHeaders {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(Map<String, dynamic> value)
    : bytes = utf8.encode(jsonEncode(value));
  final List<int> bytes;
  @override
  int get statusCode => 200;
  @override
  String get reasonPhrase => 'OK';
  @override
  int get contentLength => bytes.length;
  @override
  bool get isRedirect => false;
  @override
  bool get persistentConnection => false;
  @override
  List<RedirectInfo> get redirects => [];
  @override
  HttpHeaders get headers => _Headers();
  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(bytes).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Request implements HttpClientRequest {
  _Request(this.value);
  final Map<String, dynamic> value;
  @override
  HttpHeaders get headers => _Headers();
  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();
  @override
  Future<HttpClientResponse> close() async => _Response(value);
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Client implements HttpClient {
  _Client(this.reply);
  final Map<String, dynamic> Function(Uri) reply;
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _Request(reply(url));
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _MockNetwork extends HttpOverrides {
  _MockNetwork(this.reply);
  final Map<String, dynamic> Function(Uri) reply;
  @override
  HttpClient createHttpClient(SecurityContext? context) => _Client(reply);
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 15; i++) {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final applicant in [true, false]) {
    testWidgets(
      applicant
          ? 'approval automatically activates applicant; pauses and disposes cleanly'
          : 'inviter automatically sees a signed join request',
      (tester) async {
        late Sodium sodium;
        await tester.runAsync(() async {
          sodium = await SodiumInit.init();
        });
        SharedPreferences.setMockInitialValues({
          'appLanguage': 'zh',
          'syncRelayDeviceId': applicant ? 'phone' : 'mac',
        });
        await AppLanguageController.instance.init();
        FlutterSecureStorage.setMockInitialValues({});
        final base = {
          'url': 'wss://example.invalid/relay/v1/ws',
          'app': 'clipy',
          'group': 'test-group',
          'trusted_peers': <String, String>{},
        };
        final manager = cr.RelayGroups(sodium, {
          ...base,
          'device': 'mac',
          'token': 'm' * 32,
          'secret_key': '01' * 32,
        });
        final phone = cr.RelayGroups(sodium, {
          ...base,
          'device': 'phone',
          'token': 'p' * 32,
          'secret_key': '02' * 32,
        });
        final member = manager.member('Test Mac')..['manager'] = true;
        final invitation = <String, dynamic>{
          ...base,
          'version': 1,
          'id': 'test-invitation',
          'secret': 's' * 32,
          'expires': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 600,
          'manager': member,
        };
        final request = phone.sign({
          'version': 1,
          'app': 'clipy',
          'group': 'test-group',
          'invitation': invitation['id'],
          'member': phone.member('Test phone'),
          'token_hash': cr.RelayGroups.digest(utf8.encode('p' * 32)),
        });
        final root = manager.sign({
          'version': 1,
          'app': 'clipy',
          'group': 'test-group',
          'revision': 1,
          'previous': '',
          'members': [member],
          'invitation': '',
          'request_hash': '',
        });
        final approved = manager.sign({
          ...cr.RelayGroups.unpack(root),
          'revision': 2,
          'previous': cr.RelayGroups.digest(cr.RelayGroups.payload(root)),
          'members': [member, phone.member('Test phone')],
          'invitation': invitation['id'],
          'request_hash': cr.RelayGroups.digest(
            cr.RelayGroups.payload(request),
          ),
        });
        FlutterSecureStorage.setMockInitialValues({
          'commonRelayIdentity': jsonEncode({
            'secret_key': applicant ? '02' * 32 : '01' * 32,
            'public_key': (applicant ? phone : manager).member(
              'local',
            )['public_key'],
          }),
        });
        if (applicant) {
          phone.config['pending_join'] = {
            'invitation': invitation,
            'request': request,
          };
          await ClipyRelayGroups.savePending(phone);
        } else {
          manager.accept(root);
          await ClipyRelayGroups.persist(manager);
          // Start without an invitation to exercise the default mode control.
        }
        var ready = false, polls = 0;
        final previous = HttpOverrides.current;
        HttpOverrides.global = _MockNetwork((uri) {
          if (uri.path.endsWith('/group')) {
            return {
              'entries': [],
              'revision': applicant ? 2 : 1,
              'online': <String>[],
            };
          }
          polls++;
          return applicant
              ? (ready ? {'entry': approved} : {})
              : (ready ? {'request': request} : {});
        });
        addTearDown(() => HttpOverrides.global = previous);
        await tester.pumpWidget(const MaterialApp(home: RelayGroupPage()));
        await settle(tester);
        if (!applicant) {
          final control = find.byType(SwitchListTile);
          await tester.scrollUntilVisible(
            control,
            300,
            scrollable: find.byType(Scrollable).first,
          );
          expect(tester.widget<SwitchListTile>(control).value, true);
          await tester.tap(control);
          await tester.pumpAndSettle();
          expect(tester.widget<SwitchListTile>(control).value, false);
          await tester.pumpWidget(const SizedBox.shrink());
          await ClipyRelayIdentity.saveGroupInvitation(jsonEncode(invitation));
          await tester.pumpWidget(const MaterialApp(home: RelayGroupPage()));
          await settle(tester);
        }
        expect(find.text('完成加入'), findsNothing);
        expect(find.text('查看加入申请'), findsNothing);
        await tester.pump(const Duration(seconds: 2));
        await settle(tester);
        expect(polls, 1);
        if (applicant) {
          for (final state in [
            AppLifecycleState.inactive,
            AppLifecycleState.hidden,
            AppLifecycleState.paused,
          ]) {
            tester.binding.handleAppLifecycleStateChanged(state);
          }
          await tester.pump(const Duration(seconds: 5));
          expect(polls, 1);
          for (final state in [
            AppLifecycleState.hidden,
            AppLifecycleState.inactive,
            AppLifecycleState.resumed,
          ]) {
            tester.binding.handleAppLifecycleStateChanged(state);
          }
        }
        ready = true;
        await tester.pump(const Duration(seconds: 2));
        await settle(tester);
        if (applicant) {
          expect(await ClipyRelayGroups.pending(), isNull);
          expect(
            jsonDecode(await ClipyRelayIdentity.config())['group_entry'],
            approved,
          );
          expect(find.text('等待批准'), findsNothing);
          final prefs = await SharedPreferences.getInstance();
          expect(prefs.getBool('syncRelayEnabled'), true);
        } else {
          await tester.scrollUntilVisible(
            find.textContaining('Test phone').first,
            400,
            scrollable: find.byType(Scrollable).first,
          );
          expect(find.textContaining('Test phone'), findsWidgets);
          expect(find.textContaining('批准加入'), findsWidgets);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        final before = polls;
        await tester.pump(const Duration(seconds: 10));
        expect(polls, before);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
