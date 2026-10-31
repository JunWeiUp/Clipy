import 'dart:async';

import 'package:clipy_flutter/sync/crypto.dart';
import 'package:clipy_flutter/sync/text_delivery_receipts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'socket write without a receiver ACK is not success (unpaired keys)',
    () async {
      final sender = SyncCrypto()..configureKey('01' * 32);
      final receiver = SyncCrypto()..configureKey('02' * 32);
      final receipts = TextDeliveryReceipts(
        timeout: const Duration(milliseconds: 20),
      );
      var wrote = false;
      final result = receipts.send(
        peerId: 'mi10',
        hash: 'hash',
        dispatch: () async {
          wrote = true;
          final plaintext = receiver.decryptText(
            sender.encryptText('fixture')!,
          );
          if (plaintext != null) {
            receipts.acknowledge(peerId: 'mi10', hash: 'hash');
          }
        },
      );
      expect(await result, isFalse);
      expect(wrote, isTrue);
    },
  );

  test('requires both the target peer and content hash', () async {
    final receipts = TextDeliveryReceipts();
    var completed = false;
    final result = receipts.send(
      peerId: 'mi10',
      hash: 'hash',
      dispatch: () async {},
    );
    unawaited(result.then((_) => completed = true));
    receipts.acknowledge(peerId: 'other', hash: 'hash');
    receipts.acknowledge(peerId: 'mi10', hash: 'other');
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    receipts.acknowledge(peerId: 'mi10', hash: 'hash');
    expect(await result, isTrue);
  });

  test('accepts a fast ACK during dispatch', () async {
    final receipts = TextDeliveryReceipts();
    expect(
      await receipts.send(
        peerId: 'mi10',
        hash: 'hash',
        dispatch: () async {
          receipts.acknowledge(peerId: 'mi10', hash: 'hash');
        },
      ),
      isTrue,
    );
  });

  test('concurrent identical sends share one write and receipt', () async {
    final receipts = TextDeliveryReceipts();
    var sends = 0;
    Future<void> dispatch() async {
      sends++;
    }

    final first = receipts.send(
      peerId: 'mi10',
      hash: 'hash',
      dispatch: dispatch,
    );
    final second = receipts.send(
      peerId: 'mi10',
      hash: 'hash',
      dispatch: dispatch,
    );
    expect(sends, 1);
    receipts.acknowledge(peerId: 'mi10', hash: 'hash');
    expect(await Future.wait([first, second]), [true, true]);
  });

  test(
    'stop cancels waits and late dispatch errors do not affect a new send',
    () async {
      final receipts = TextDeliveryReceipts();
      final oldDispatch = Completer<void>();
      final old = receipts.send(
        peerId: 'mi10',
        hash: 'hash',
        dispatch: () => oldDispatch.future,
      );
      receipts.cancelAll();
      expect(await old, isFalse);
      final next = receipts.send(
        peerId: 'mi10',
        hash: 'hash',
        dispatch: () async {},
      );
      oldDispatch.completeError(StateError('old connection failed'));
      await Future<void>.delayed(Duration.zero);
      receipts.acknowledge(peerId: 'mi10', hash: 'hash');
      expect(await next, isTrue);
    },
  );

  test('dispatch failure releases the wait immediately', () async {
    final receipts = TextDeliveryReceipts();
    expect(
      await receipts.send(
        peerId: 'mi10',
        hash: 'hash',
        dispatch: () async {
          throw StateError('storage unavailable');
        },
      ),
      isFalse,
    );
    receipts.cancelAll();
  });

  test('bounds outstanding sends and releases capacity on stop', () async {
    final receipts = TextDeliveryReceipts();
    final waits = [
      for (var i = 0; i < 32; i++)
        receipts.send(peerId: 'mi10', hash: '$i', dispatch: () async {}),
    ];
    var dispatched = false;
    expect(
      await receipts.send(
        peerId: 'mi10',
        hash: 'overflow',
        dispatch: () async {
          dispatched = true;
        },
      ),
      isFalse,
    );
    expect(dispatched, isFalse);
    receipts.cancelAll();
    expect(await Future.wait(waits), everyElement(isFalse));
    final next = receipts.send(
      peerId: 'mi10',
      hash: 'new',
      dispatch: () async {},
    );
    receipts.acknowledge(peerId: 'mi10', hash: 'new');
    expect(await next, isTrue);
  });
}
