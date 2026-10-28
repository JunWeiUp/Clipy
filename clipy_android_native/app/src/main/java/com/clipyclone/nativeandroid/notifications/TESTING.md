# Native notification and sharing verification

These fixtures run only on an isolated preview emulator. They must not be used
against the shipping package or a device with configured outbound sharing.
The app ID stays `com.clipyclone.clipy_android.nativepreview` during migration.

## Ordinary regressions

- `NativeNotificationTest`: WeChat archive/replacement/deduplication, durable ACK,
  no ACK on storage failure, pending-before-send and ACK state.
- `NativeNotificationContentTest`: InboxStyle latest line, API24–29 MessagingStyle
  Bundles and public API30+ decoder, BIG_TEXT/TEXT fallback.
- `NativeSharingTest`: text/size limits, private URI rejection, file-count cap,
  byte-exact content streams, URI deduplication, cleanup/cancellation, and retry
  only failed items for the same peer.

The test APK's `ShareFixtureProvider` is a pure-Java, exported test-only provider.
It exposes only fixed synthetic data and a UUID-tagged synthetic notification;
it does not accept arbitrary filesystem paths or notification contents.

## Real system listener path

Grant notification-listener access only to the preview's existing component:
`com.clipyclone.clipy_android.nativepreview/com.clipyclone.clipy_android.ClipyNotificationListenerService`.
Use the system Notification access UI on API26 (its notification shell command
has no `allow_listener` implementation). Preserve other enabled listeners.
On API33+, grant `POST_NOTIFICATIONS` to the test APK as well.

Run `NativeNotificationSystemTest`'s two ordinary methods. They back up/restore
notification preferences, select only the test package, and cancel/delete only
the UUID fixture. One checks actual NLS → SQLite plus system removal without an
Activity. The other additionally sends over a loopback v3 session and confirms
both pending queues are cleared by `notif.ack`; it requires initially-disabled
LAN, no sharing targets, and empty send queues to prevent external delivery.

`am instrument` recreates the target process. The ordinary methods intentionally
use the production `setEnabled(true)` path after setting the test-only filters;
that path requests soft rebinding when instrumentation terminated the old NLS.
This is not proof of restoring an already-enabled collector on cold start.

## Separate cold-start proof

Run the following sequence after the listener permission is granted, always run
restore in a `finally`-equivalent path. No whole XML rewrite or `force-stop` is
needed. The driver snapshots only three notification keys in its private backup,
and the cold test verifies a different process ID from the preparation process.

```sh
adb -s "$ANDROID_SERIAL" shell am instrument -w -e notificationColdStartDriver prepare -e class 'com.clipyclone.nativeandroid.NativeNotificationColdDriverTest#prepare' com.clipyclone.clipy_android.nativepreview.test/androidx.test.runner.AndroidJUnitRunner
adb -s "$ANDROID_SERIAL" shell am instrument -w -e notificationColdStartFixture true -e class 'com.clipyclone.nativeandroid.NativeNotificationSystemTest#coldStartRecoversAnAlreadyEnabledListenerWithoutAnActivityOrEnableCall' com.clipyclone.clipy_android.nativepreview.test/androidx.test.runner.AndroidJUnitRunner
adb -s "$ANDROID_SERIAL" shell am instrument -w -e notificationColdStartDriver restore -e class 'com.clipyclone.nativeandroid.NativeNotificationColdDriverTest#restore' com.clipyclone.clipy_android.nativepreview.test/androidx.test.runner.AndroidJUnitRunner
```

The cold test calls only Application's normal `initialize()` API. It never opens
an Activity, toggles collection on, or forces a component reconnect. The driver
and cold test are explicitly opt-in and skipped by the ordinary suite; record
their separate results instead of counting skipped cases as verification.
Non-sensitive stage logs use `ClipyNlsFixture` (no notification content).

### Listener recovery deadline

Only the listener reconnection wait allows 20 seconds. Android 8.0 `PackageManagerService` batches component changes made with `DONT_KILL_APP` using `BROADCAST_DELAY = 10 * 1000`; the native recovery attempts soft rebind for two seconds before toggling the component. API 26 fixture logs show service creation 10.06–10.11 seconds after that toggle. A 10-second total test deadline incorrectly kills the instrumentation process before the framework completes recovery. Posting/persistence and wire delivery retain their 10-second deadlines, and ACK/removal retain five seconds.

Source: [AOSP android-8.0.0_r1 PackageManagerService.java](https://android.googlesource.com/platform/frameworks/base/+/android-8.0.0_r1/services/core/java/com/android/server/pm/PackageManagerService.java), `BROADCAST_DELAY` and `setEnabledSetting` → `SEND_PENDING_BROADCAST`. Local phase evidence: `/tmp/clipy-nls-phases-5582.txt`.
