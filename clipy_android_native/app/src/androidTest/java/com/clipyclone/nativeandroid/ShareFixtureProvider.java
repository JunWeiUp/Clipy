package com.clipyclone.nativeandroid;

import android.Manifest;
import android.content.pm.PackageManager;
import android.content.ContentProvider;
import android.content.Intent;
import android.content.ClipData;
import java.util.ArrayList;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.os.Build;
import android.os.Bundle;
import android.content.ContentValues;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;

/** Test-APK-only provider. Pure Java keeps its independent process free of target-app dependencies. */
public final class ShareFixtureProvider extends ContentProvider {
    public static final String AUTHORITY = "com.clipyclone.clipy_android.nativepreview.test.share-fixture";
    public static byte[] bytes(String key) {
        if ("one".equals(key)) return "shared content 世界".getBytes(StandardCharsets.UTF_8);
        if ("two".equals(key)) { byte[] data = new byte[65 * 1024 + 9]; for (int i = 0; i < data.length; i++) data[i] = (byte)(i % 251); return data; }
        return "synthetic fixture".getBytes(StandardCharsets.UTF_8);
    }
    @Override public boolean onCreate() { return true; }
    @Override public String getType(Uri uri) { return "application/octet-stream"; }
    @Override public Cursor query(Uri uri, String[] projection, String selection, String[] selectionArgs, String sortOrder) {
        String key = uri.getLastPathSegment();
        String name = "name".equals(key) ? "../unsafe/name.txt" : key + ".bin";
        String[] columns = projection != null ? projection : new String[]{OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE};
        Object[] values = new Object[columns.length];
        for (int i = 0; i < columns.length; i++) {
            if (OpenableColumns.DISPLAY_NAME.equals(columns[i])) values[i] = name;
            else if (OpenableColumns.SIZE.equals(columns[i])) values[i] = bytes(key).length;
        }
        MatrixCursor cursor = new MatrixCursor(columns); cursor.addRow(values); return cursor;
    }
    @Override public ParcelFileDescriptor openFile(Uri uri, String mode) throws java.io.FileNotFoundException {
        String key = uri.getLastPathSegment();
        if (!"r".equals(mode)) throw new java.io.FileNotFoundException("read-only fixture");
        try {
            if ("blocked".equals(key)) {
                ParcelFileDescriptor[] pipe = ParcelFileDescriptor.createPipe();
                Thread writer = new Thread(() -> {
                    try (ParcelFileDescriptor.AutoCloseOutputStream output = new ParcelFileDescriptor.AutoCloseOutputStream(pipe[1])) {
                        Thread.sleep(1500); output.write(bytes(key));
                    } catch (Exception ignored) { }
                }); writer.setDaemon(true); writer.start(); return pipe[0];
            }
            if (!"one".equals(key) && !"two".equals(key) && !"name".equals(key)) throw new java.io.FileNotFoundException("unknown fixture");
            File file = new File(getContext().getCacheDir(), "share-provider-" + key + ".bin");
            try (FileOutputStream output = new FileOutputStream(file)) { output.write(bytes(key)); }
            return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY);
        } catch (IOException error) { throw new java.io.FileNotFoundException(error.getMessage()); }
    }
    @Override public Bundle call(String method, String argument, Bundle extras) {
        if ("launchTextShare".equals(method) || "launchMultipleShare".equals(method)) {
            if (!"nativepreview".equals(argument) && !"reference".equals(argument))
                throw new IllegalArgumentException("Only isolated parity packages are allowed");
            String target = "com.clipyclone.clipy_android." + argument;
            Intent intent = new Intent("launchTextShare".equals(method) ? Intent.ACTION_SEND : Intent.ACTION_SEND_MULTIPLE)
                .setClassName(target, "com.clipyclone.clipy_android.MainActivity")
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_GRANT_READ_URI_PERMISSION);
            if ("launchTextShare".equals(method)) {
                intent.setType("text/plain").putExtra(Intent.EXTRA_TEXT, "Synthetic shared text parity");
            } else {
                ArrayList<Uri> files = new ArrayList<>();
                files.add(Uri.parse("content://" + AUTHORITY + "/one"));
                files.add(Uri.parse("content://" + AUTHORITY + "/two"));
                intent.setType("application/octet-stream").putParcelableArrayListExtra(Intent.EXTRA_STREAM, files);
                ClipData clip = ClipData.newRawUri("Synthetic parity files", files.get(0));
                clip.addItem(new ClipData.Item(files.get(1))); intent.setClipData(clip);
            }
            getContext().startActivity(intent);
            Bundle result = new Bundle(); result.putString("target", target); return result;
        }
        if (!"postNotification".equals(method) && !"cancelNotification".equals(method)) throw new IllegalArgumentException("fixture method");
        if (argument == null || !argument.matches("[0-9a-fA-F-]{36}")) throw new IllegalArgumentException("fixture token");
        NotificationManager manager = getContext().getSystemService(NotificationManager.class);
        String tag = "clipy-native-fixture-" + argument;
        if ("cancelNotification".equals(method)) manager.cancel(tag, 7109);
        else {
            if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(new NotificationChannel("clipy_test_nls", "Native NLS fixture", NotificationManager.IMPORTANCE_LOW));
            Notification.Builder builder = Build.VERSION.SDK_INT >= 26 ? new Notification.Builder(getContext(), "clipy_test_nls") : new Notification.Builder(getContext());
            builder.setSmallIcon(android.R.drawable.ic_dialog_info).setContentTitle("Native NLS fixture")
                .setSubText("Fixture subtitle").setContentText("2 messages")
                .setStyle(new Notification.InboxStyle().addLine("Older fixture " + argument).addLine("Newest fixture " + argument))
                .setAutoCancel(false);
            if (Build.VERSION.SDK_INT >= 33 && getContext().checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
                throw new SecurityException("Grant test APK POST_NOTIFICATIONS before the NLS fixture");
            manager.notify(tag, 7109, builder.build());
        }
        Bundle result = new Bundle(); result.putString("packageName", getContext().getPackageName()); return result;
    }
    @Override public Uri insert(Uri uri, ContentValues values) { throw new UnsupportedOperationException(); }
    @Override public int delete(Uri uri, String selection, String[] args) { return 0; }
    @Override public int update(Uri uri, ContentValues values, String selection, String[] args) { return 0; }
}
