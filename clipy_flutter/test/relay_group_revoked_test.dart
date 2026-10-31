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

class _Headers implements HttpHeaders {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _RejectedResponse extends Stream<List<int>>
    implements HttpClientResponse {
  @override
  int get statusCode => 401;
  @override
  String get reasonPhrase => 'Unauthorized';
  @override
  int get contentLength => 0;
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
  }) => const Stream<List<int>>.empty().listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Request implements HttpClientRequest {
  @override
  HttpHeaders get headers => _Headers();
  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();
  @override
  Future<HttpClientResponse> close() async => _RejectedResponse();
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Client implements HttpClient {
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async => _Request();
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _RejectAccess extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) => _Client();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'revoked group hides stale members and invite; local recovery works offline',
    (tester) async {
      await tester.runAsync(() async {
        await SodiumInit.init();
      });
      SharedPreferences.setMockInitialValues({
        'appLanguage': 'zh',
        'syncRelayDeviceId': 'phone',
        'syncRelayEnabled': true,
      });
      await AppLanguageController.instance.init();
      final identity = jsonEncode({
        'secret_key': '01' * 32,
        'public_key': '02' * 32,
      });
      final state = {
        'version': 1,
        'app': 'clipy',
        'group': 'expired',
        'revision': 1,
        'previous': '',
        'members': [
          {
            'device': 'phone',
            'name': 'Cached phone',
            'manager': true,
            'public_key': '02' * 32,
            'signing_key': '03' * 32,
          },
        ],
        'invitation': '',
        'request_hash': '',
      };
      FlutterSecureStorage.setMockInitialValues({
        'commonRelayIdentity': identity,
        'commonRelayConfig': jsonEncode({
          'url': 'wss://example.invalid/relay/v1/ws',
          'app': 'clipy',
          'group': 'expired',
          'device': 'phone',
          'token': 't' * 32,
          'secret_key': '01' * 32,
          'trusted_peers': <String, String>{},
          'group_entry': {
            'payload': base64Encode(utf8.encode(jsonEncode(state))),
            'signature': '00' * 64,
            'signer': 'phone',
          },
        }),
      });
      final previous = HttpOverrides.current;
      HttpOverrides.global = _RejectAccess();
      addTearDown(() => HttpOverrides.global = previous);
      await tester.pumpWidget(const MaterialApp(home: RelayGroupPage()));
      await tester.pumpAndSettle();
      expect(find.text('设备组不可用'), findsOneWidget);
      expect(find.text('添加设备'), findsNothing);
      expect(find.textContaining('Cached phone'), findsNothing);
      await tester.tap(find.text('返回创建或加入'));
      await tester.pumpAndSettle();
      expect(find.text('清除失效的组配置？'), findsOneWidget);
      await tester.tap(find.text('清除并继续'));
      await tester.pumpAndSettle();
      expect(find.text('创建你的设备组'), findsOneWidget);
      expect(find.text('加入已有组'), findsOneWidget);
      expect(await ClipyRelayIdentity.config(), '');
      expect(jsonEncode(await ClipyRelayIdentity.localIdentity()), identity);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('syncRelayDeviceId'), isNot('phone'));
      expect(prefs.getBool('syncRelayEnabled'), false);
      expect(tester.takeException(), isNull);
    },
  );
}
