import 'package:flutter_test/flutter_test.dart';
import 'package:clipy_android/sync/file_receive_flow_control.dart';

void main() {
  test(
    'a large burst never queues more than two native decrypt operations',
    () {
      var remaining = 1024;
      var queued = 0;
      var written = 0;
      var pauses = 0;
      var resumes = 0;
      late FileReceiveFlowControl flow;
      void drain() {
        while (remaining > 0 && !flow.isAtCapacity) {
          remaining--;
          queued++;
          flow.enqueue();
          expect(queued, lessThanOrEqualTo(2));
        }
      }

      flow = FileReceiveFlowControl(
        pause: () => pauses++,
        resume: () => resumes++,
        drain: drain,
      );
      drain();
      expect(flow.isPaused, isTrue);
      while (queued > 0) {
        queued--;
        written++;
        flow.complete();
      }
      expect(written, 1024);
      expect(remaining, 0);
      expect(pauses, 1);
      expect(resumes, 1);
      expect(flow.isPaused, isFalse);
    },
  );

  test(
    'late decrypt completions cannot resume a replaced or closed socket',
    () {
      var calls = 0;
      final flow = FileReceiveFlowControl(
        pause: () => calls++,
        drain: () => calls++,
        resume: () => calls++,
      );
      flow.enqueue();
      flow.enqueue();
      expect(calls, 1);
      flow.close();
      flow.complete();
      flow.complete();
      flow.enqueue();
      expect(calls, 1);
    },
  );
}
