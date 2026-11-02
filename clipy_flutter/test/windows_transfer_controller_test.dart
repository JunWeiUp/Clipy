import 'dart:async';
import 'package:clipy_flutter/features/devices/windows_transfer_controller.dart';
import 'package:clipy_flutter/sync/file_send_cancellation.dart';
import 'package:clipy_flutter/sync_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'cancel interrupts an ACK wait without touching another token',
    () async {
      final first = FileSendCancellation();
      final other = FileSendCancellation();
      final pending = first.wait(Completer<bool>().future);
      final assertion = expectLater(pending, throwsA(isA<FileSendCancelled>()));
      first.cancel();
      first.cancel();
      await assertion;
      expect(await other.wait(Future.value(true)), isTrue);
    },
  );

  test(
    'progress is associated by id and peer; failed bytes do not become 100%',
    () async {
      final progress = StreamController<FileProgress>(sync: true);
      final sends = <String, Completer<bool>>{};
      final cancelled = <String>[];
      final controller = WindowsTransferController(
        progress: progress.stream,
        send: (file, peer, id) {
          sends[id] = Completer<bool>();
          return sends[id]!.future;
        },
        cancel: cancelled.add,
      );
      addTearDown(() {
        controller.dispose();
        progress.close();
      });
      final sendingA = controller.sendPath('/tmp/same-name.bin', 'peer-a');
      final rowA = controller.rows.single;
      final sendingB = controller.sendPath('/tmp/same-name.bin', 'peer-b');
      final rowB = controller.rows.first;
      progress.add(
        FileProgress(
          fileId: rowA.id,
          peerId: 'peer-a',
          fileName: rowA.name,
          progress: .25,
          receivedBytes: 25,
          totalBytes: 100,
          isOutgoing: true,
        ),
      );
      expect(rowA.bytes, 25);
      expect(rowB.bytes, 0);
      progress.add(
        FileProgress(
          fileId: rowA.id,
          peerId: 'peer-a',
          fileName: rowA.name,
          progress: 1,
          receivedBytes: 100,
          totalBytes: 100,
          isOutgoing: true,
          isFailed: true,
        ),
      );
      expect(rowA.bytes, 25);
      expect(rowA.status, WindowsTransferStatus.failed);
      controller.cancel(rowB);
      expect(cancelled, [rowB.id]);
      expect(rowB.status, WindowsTransferStatus.cancelled);
      sends[rowA.id]!.complete(false);
      sends[rowB.id]!.complete(false);
      await Future.wait([sendingA, sendingB]);
      final retry = controller.retry(rowA);
      final retryRow = controller.rows.first;
      expect(retryRow.peerId, 'peer-a');
      expect(retryRow.id, isNot(rowA.id));
      sends[retryRow.id]!.complete(true);
      await retry;
      expect(retryRow.status, WindowsTransferStatus.completed);
      expect(controller.rows.where((r) => r.peerId == 'peer-b').length, 1);
    },
  );

  test(
    'same peer cannot overlap a send or retry while cancellation is draining',
    () async {
      final pending = Completer<bool>();
      var calls = 0;
      final controller = WindowsTransferController(
        progress: const Stream.empty(),
        send: (_, _, _) {
          calls++;
          return pending.future;
        },
        cancel: (_) {},
      );
      addTearDown(controller.dispose);
      final first = controller.sendPath('/tmp/first', 'peer');
      final row = controller.rows.single;
      expect(controller.canSendTo('peer'), isFalse);
      expect(controller.canSendTo('other'), isTrue);
      await controller.sendPath('/tmp/second', 'peer');
      controller.cancel(row);
      await controller.retry(row);
      expect(calls, 1);
      pending.complete(false);
      await first;
      expect(controller.canSendTo('peer'), isTrue);
    },
  );

  test('journal remains bounded and completed files cannot retry', () async {
    final controller = WindowsTransferController(
      progress: const Stream.empty(),
      send: (_, _, _) async => true,
      cancel: (_) {},
    );
    addTearDown(controller.dispose);
    for (var i = 0; i < 110; i++) {
      await controller.sendPath('/tmp/file-$i', 'peer');
    }
    expect(controller.rows.length, 100);
    final first = controller.rows.first.id;
    await controller.retry(controller.rows.first);
    expect(controller.rows.first.id, first);
  });
}
