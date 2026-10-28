# Signed upgrade inspection

This optional Android 11+ instrumentation APK inspects the installed production
app using its original signing identity. It has no launcher and does not replace
the application, seed data, change preferences, migrate schemas or export Android
Keystore keys. The main native application still supports Android 7+.

Build with the existing release signing configuration:

```sh
./clipy_android_native/gradlew -p clipy_android_native :upgradeProbe:assembleRelease
adb -s "$ANDROID_SERIAL" install -r clipy_android_native/upgradeProbe/build/outputs/apk/release/upgradeProbe-release.apk
adb -s "$ANDROID_SERIAL" shell am instrument -w -e mode backup com.clipyclone.clipy_android.upgradeprobe/com.clipyclone.upgradeprobe.UpgradeProbe
```

Use `mode inspect` after upgrade. Success is reported as `result=complete` and a
checkpoint directory. A consistent `VACUUM INTO` snapshot includes committed
SQLite WAL rows. Other persistent private files are copied without altering the
originals. The JSON manifest contains file hashes, logical history-table hashes,
per-preference hashes, UID, granted permissions, notification access, power/alarm
access, widget count, and Keystore alias/public-certificate hashes. It does not
print stored values or credentials to instrumentation output.

Checkpoints are staged in app-private external cache, excluded from Auto Backup.
The archive contains private application data. Pull the checkpoint into private
local storage, verify its ZIP integrity and SHA-256, then remove only that exact
checkpoint directory from the device. Keep the backup for upgrade recovery.
Remove the inspection APK when validation finishes. A backup is not proven until
the reported success, copied archive and manifest have all been checked.

Instrumentation restarts the target process without opening an Activity. Schedule
it while the application is idle. It does not freeze other devices' incoming
sync, so new records received between snapshots must be distinguished from data
loss. Android Keystore keys remain on the device; a ZIP is not a portable export
of those hardware-backed keys.
