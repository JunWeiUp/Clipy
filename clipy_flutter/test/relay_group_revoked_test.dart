import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:clipy_flutter/app_localizations.dart';
import 'package:clipy_flutter/features/devices/relay_group_page.dart';
import 'package:clipy_flutter/sync/relay_identity.dart';
import 'package:clipy_flutter/sync/relay_client.dart';
import 'package:common_relay/common_relay.dart' as cr;
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sodium/sodium.dart';

final _sentHeaders = <String, Object>{};

class _Headers implements HttpHeaders {
  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) =>
      set(name, value);
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _sentHeaders[name.toLowerCase()] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _Socket implements Socket {
  @override
  void destroy() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _RejectedResponse extends Stream<List<int>>
    implements HttpClientResponse {
  @override
  int get statusCode => 401;
  @override
  Future<Socket> detachSocket() async => _Socket();
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
  test(
    'WS handshake sends scoped credential and retry reads replacement without losing identity',
    () async {
      final sodium = await SodiumInit.init();
      final pair = sodium.crypto.box.keyPair();
      final identity = {
        'app': 'clipy',
        'group': 'fixture',
        'device': 'phone',
        'token': 't' * 32,
        'secret_key': cr.hex(pair.secretKey.extractBytes()),
        'public_key': cr.hex(pair.publicKey),
        'trusted_peers': <String, String>{},
      };
      pair.secretKey.dispose();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final url = 'ws://127.0.0.1:${server.port}/relay/v1/ws';
      final requests = <Map<String, String>>[];
      final subscription = server.listen((request) async {
        requests.add({
          'access': request.headers.value('Relay-Access') ?? '',
          'authorization': request.headers.value('Authorization') ?? '',
        });
        request.response.statusCode = 401;
        await request.response.close();
      });
      FlutterSecureStorage.setMockInitialValues({});
      await ClipyRelayIdentity.saveAccessPassword(url, 'fixture-access-123');
      final directory = await Directory.systemTemp.createTemp(
        'clipy-relay-test-',
      );
      var rejected = Completer<void>();
      final client = SyncRelayClient(
        url: url,
        token: jsonEncode(identity),
        id: 'local',
        name: 'Fixture',
        port: 5566,
        addresses: [],
        hasSession: (_) => false,
        tryLan: (_, _, _) async {},
        onSocket: (_, socket) => socket.destroy(),
        journal: cr.RelayJournal(directory),
        allowLocalTest: true,
        onStateChanged: (state) {
          if (state == RelayConnectionState.accessDenied &&
              !rejected.isCompleted) {
            rejected.complete();
          }
        },
      );
      try {
        _sentHeaders.clear();
        client.start();
        await rejected.future.timeout(const Duration(seconds: 5));
        expect(requests.last['access'], 'fixture-access-123');
        expect(requests.last['authorization'], 'Bearer ${identity['token']}');
        rejected = Completer<void>();
        await ClipyRelayIdentity.saveAccessPassword(url, 'replacement-fixture');
        client.networkChanged();
        await rejected.future.timeout(const Duration(seconds: 5));
        expect(requests.last['access'], 'replacement-fixture');
        expect(client.token, jsonEncode(identity));
      } finally {
        client.stop();
        await subscription.cancel();
        await server.close(force: true);
        await directory.delete(recursive: true);
      }
    },
  );
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
      await ClipyRelayIdentity.saveAccessPassword(
        'wss://example.invalid/relay/v1/ws',
        'fixture-access-123',
      );
      final before = await ClipyRelayIdentity.config();
      _sentHeaders.clear();
      final previous = HttpOverrides.current;
      HttpOverrides.global = _RejectAccess();
      addTearDown(() => HttpOverrides.global = previous);
      await tester.pumpWidget(const MaterialApp(home: RelayGroupPage()));
      await tester.pumpAndSettle();
      expect(find.text('设备组不可用'), findsOneWidget);
      expect(find.text('修改访问密码'), findsOneWidget);
      expect(find.text('重试验证'), findsOneWidget);
      expect(find.textContaining('访问密码或设备身份不可用'), findsOneWidget);
      expect(_sentHeaders['relay-access'], 'fixture-access-123');
      expect(await ClipyRelayIdentity.config(), before);
      expect(
        (await SharedPreferences.getInstance()).getString('syncRelayDeviceId'),
        'phone',
      );
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
