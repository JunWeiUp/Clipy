import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:clipy_android/utils/async_refresh_controller.dart';

void main() {
  test('coalesces bursts and only publishes the latest load', () async {
    final controller = AsyncRefreshController();
    final gate = Completer<void>();
    var calls = 0;
    final published = <int>[];
    Future<void> load(bool Function() isCurrent) async {
      final call = ++calls;
      if (call == 1) await gate.future;
      if (isCurrent()) published.add(call);
    }

    final first = controller.refresh(load);
    for (var i = 0; i < 100; i++) {
      unawaited(controller.refresh(load));
    }
    expect(calls, 1);
    gate.complete();
    await first;
    expect(calls, 2);
    expect(published, [2]);
    controller.dispose();
  });

  test('dispose invalidates an outstanding load and prevents reruns', () async {
    final controller = AsyncRefreshController();
    final gate = Completer<void>();
    var published = false;
    final pending = controller.refresh((isCurrent) async {
      await gate.future;
      published = isCurrent();
    });
    controller.dispose();
    gate.complete();
    await pending;
    await controller.refresh((_) async => fail('load after dispose'));
    expect(published, false);
  });

  test('a failed load does not wedge future refreshes', () async {
    final controller = AsyncRefreshController();
    await expectLater(
      controller.refresh((_) async => throw StateError('test')),
      throwsStateError,
    );
    var loaded = false;
    await controller.refresh((_) async => loaded = true);
    expect(loaded, true);
    controller.dispose();
  });
}
