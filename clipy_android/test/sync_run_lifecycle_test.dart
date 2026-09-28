import 'dart:async';

import 'package:clipy_android/sync/run_lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a late connection cannot join a restarted foreground run', () async {
    final lifecycle = SyncRunLifecycle();
    final connected = Completer<void>();
    final release = Completer<void>();
    var adopted = false;

    final oldRun = lifecycle.begin();
    final pendingConnection = () async {
      connected.complete();
      await release.future;
      if (lifecycle.isCurrent(oldRun)) adopted = true;
    }();

    await connected.future;
    lifecycle.stop();
    expect(lifecycle.isCurrent(oldRun), isFalse);

    final resumedRun = lifecycle.begin();
    release.complete();
    await pendingConnection;

    expect(adopted, isFalse);
    expect(lifecycle.isCurrent(resumedRun), isTrue);
  });
}
