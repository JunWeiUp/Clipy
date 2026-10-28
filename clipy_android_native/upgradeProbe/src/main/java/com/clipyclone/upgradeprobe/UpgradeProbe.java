package com.clipyclone.upgradeprobe;

import android.app.Activity;
import android.app.Instrumentation;
import android.appwidget.AppWidgetManager;
import android.content.ComponentName;
import android.content.Context;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.os.Bundle;
import android.provider.Settings;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.DigestOutputStream;
import java.security.MessageDigest;
import java.security.KeyStore;
import java.util.*;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

/** Same-signature, explicitly invoked backup/inspection of the existing sandbox.
 * No launcher, network code, preference writes, schema migration or key export.
 * The archive contains private data and must be pulled into private local storage.
 */
public final class UpgradeProbe extends Instrumentation {
    private Bundle arguments;
    private final byte[] buffer = new byte[64 * 1024];
    private static final String TARGET = "com.clipyclone.clipy_android";
    @Override public void onCreate(Bundle args) { super.onCreate(args); arguments = args; start(); }
    @Override public void onStart() {
        Bundle result = new Bundle();
        File temporary = null;
        try {
            Context context = getTargetContext();
            if (!TARGET.equals(context.getPackageName())) throw new SecurityException("Unexpected inspection target");
            String mode = arguments.getString("mode", "inspect");
            if (!mode.equals("inspect") && !mode.equals("backup")) throw new IllegalArgumentException("Unknown mode");
            // Cache staging is excluded from Android Auto Backup. The verified
            // checkpoint is copied to private host storage and then removed.
            File external = context.getExternalCacheDir();
            if (external == null) throw new IOException("External app-private storage unavailable");
            File destination = new File(external, "native-upgrade-checkpoint-" + UUID.randomUUID());
            if (!destination.mkdirs()) throw new IOException("Cannot create checkpoint directory");
            temporary = new File(context.getCacheDir(), "upgrade-probe-" + UUID.randomUUID());
            if (!temporary.mkdirs()) throw new IOException("Cannot create snapshot workspace");
            File dataRoot = context.getDataDir();
            JSONObject manifest = new JSONObject();
            JSONObject files = new JSONObject();
            JSONObject preferences = new JSONObject();
            JSONObject tables = new JSONObject();
            manifest.put("format", 1).put("mode", mode).put("files", files)
                .put("preferences", preferences).put("historyTables", tables);
            PackageInfo info = context.getPackageManager().getPackageInfo(TARGET, PackageManager.GET_PERMISSIONS);
            manifest.put("package", TARGET).put("versionName", info.versionName)
                .put("versionCode", info.versionCode).put("uid", info.applicationInfo.uid);
            manifest.put("backupEligible", (info.applicationInfo.flags & android.content.pm.ApplicationInfo.FLAG_ALLOW_BACKUP) != 0);
            manifest.put("batteryOptimizationsIgnored", context.getSystemService(android.os.PowerManager.class)
                .isIgnoringBatteryOptimizations(TARGET));
            if (android.os.Build.VERSION.SDK_INT >= 31) manifest.put("exactAlarmsAllowed",
                context.getSystemService(android.app.AlarmManager.class).canScheduleExactAlarms());
            JSONArray permissions = new JSONArray();
            if (info.requestedPermissions != null) for (int i = 0; i < info.requestedPermissions.length; i++) {
                if ((info.requestedPermissionsFlags[i] & PackageInfo.REQUESTED_PERMISSION_GRANTED) != 0)
                    permissions.put(info.requestedPermissions[i]);
            }
            manifest.put("grantedPermissions", permissions);
            String listeners = Settings.Secure.getString(context.getContentResolver(), "enabled_notification_listeners");
            manifest.put("notificationAccess", listeners != null && Arrays.stream(listeners.split(":"))
                .anyMatch(s -> s.equals(TARGET + "/" + TARGET + ".ClipyNotificationListenerService")
                    || s.equals(TARGET + "/.ClipyNotificationListenerService")));
            manifest.put("widgetCount", AppWidgetManager.getInstance(context).getAppWidgetIds(
                new ComponentName(TARGET, TARGET + ".TimerWidgetProvider")).length);
            KeyStore keys = KeyStore.getInstance("AndroidKeyStore"); keys.load(null);
            List<String> aliases = Collections.list(keys.aliases()); Collections.sort(aliases);
            JSONArray keyAliases = new JSONArray();
            JSONObject certificates = new JSONObject();
            for (String alias : aliases) {
                String aliasHash = hex(MessageDigest.getInstance("SHA-256").digest(alias.getBytes(StandardCharsets.UTF_8)));
                keyAliases.put(aliasHash);
                java.security.cert.Certificate certificate = keys.getCertificate(alias);
                certificates.put(aliasHash, certificate == null ? JSONObject.NULL
                    : hex(MessageDigest.getInstance("SHA-256").digest(certificate.getEncoded())));
            }
            manifest.put("keystoreAliasHashes", keyAliases);
            manifest.put("keystoreCertificateHashes", certificates);
            File archive = new File(destination, "data.zip");
            try (ZipOutputStream zip = mode.equals("backup") ? new ZipOutputStream(new FileOutputStream(archive)) : null) {
                for (String name : new String[]{"files", "shared_prefs", "no_backup", "app_flutter", "databases"}) {
                    visit(context, dataRoot, new File(dataRoot, name), temporary, zip, files, preferences, tables, 0);
                }
            }
            if (mode.equals("backup")) manifest.put("archiveSha256", hash(archive));
            File manifestFile = new File(destination, "manifest.json");
            try (FileOutputStream out = new FileOutputStream(manifestFile)) {
                out.write(manifest.toString(2).getBytes(StandardCharsets.UTF_8)); out.getFD().sync();
            }
            result.putString("checkpoint", destination.getAbsolutePath());
            result.putString("result", "complete");
            removeTemporary(temporary); temporary = null;
            finish(Activity.RESULT_OK, result);
        } catch (Throwable error) {
            // Never print database values, preference contents or credentials.
            result.putString("result", "failed");
            result.putString("errorType", error.getClass().getSimpleName());
            finish(Activity.RESULT_CANCELED, result);
        } finally { if (temporary != null) removeTemporary(temporary); }
    }

    private void visit(Context context, File root, File file, File temporary, ZipOutputStream zip,
                       JSONObject files, JSONObject preferences, JSONObject tables, int depth) throws Exception {
        if (!file.exists()) return;
        if (depth > 32 || !file.getCanonicalPath().startsWith(root.getCanonicalPath() + File.separator))
            throw new IOException("Unsafe checkpoint path");
        if (file.isDirectory()) {
            File[] children = file.listFiles();
            if (children == null) throw new IOException("Unreadable checkpoint directory");
            Arrays.sort(children, Comparator.comparing(File::getName));
            for (File child : children) visit(context, root, child, temporary, zip, files, preferences, tables, depth + 1);
            return;
        }
        String relative = root.toURI().relativize(file.toURI()).getPath();
        // Journals belong to the consistent SQLite snapshot, never copy a live WAL.
        if ((file.getName().endsWith("-wal") || file.getName().endsWith("-shm") || file.getName().endsWith("-journal"))
                && isDatabase(new File(file.getPath().replaceFirst("-(wal|shm|journal)$", "")))) return;
        File source = file;
        if (isDatabase(file)) {
            source = new File(temporary, UUID.randomUUID() + ".db");
            try (SQLiteDatabase db = SQLiteDatabase.openDatabase(file.getPath(), null, SQLiteDatabase.OPEN_READONLY,
                    database -> { throw new android.database.sqlite.SQLiteDatabaseCorruptException("Original database preserved"); })) {
                // VACUUM INTO takes a consistent SQLite snapshot, including committed WAL rows.
                db.execSQL("VACUUM INTO ?", new Object[]{source.getAbsolutePath()});
            }
            if (relative.equals("files/clipy.db")) inspectTables(source, tables);
        }
        files.put(relative, new JSONObject().put("size", source.length()).put("sha256", hash(source)));
        if (relative.startsWith("shared_prefs/") && relative.endsWith(".xml")) {
            String name = file.getName().substring(0, file.getName().length() - 4);
            JSONObject values = new JSONObject();
            for (Map.Entry<String, ?> entry : context.getSharedPreferences(name, Context.MODE_PRIVATE).getAll().entrySet()) {
                Object value = entry.getValue();
                String canonical;
                if (value instanceof Set) {
                    List<String> list = new ArrayList<>();
                    for (Object item : (Set<?>) value) list.add(String.valueOf(item));
                    Collections.sort(list); canonical = "set:" + new JSONArray(list);
                } else canonical = value.getClass().getName() + ":" + value;
                values.put(entry.getKey(), hex(MessageDigest.getInstance("SHA-256").digest(canonical.getBytes(StandardCharsets.UTF_8))));
            }
            preferences.put(relative, values);
        }
        if (zip != null) {
            zip.putNextEntry(new ZipEntry(relative));
            try (InputStream in = new FileInputStream(source)) { int count; while ((count = in.read(buffer)) != -1) zip.write(buffer, 0, count); }
            zip.closeEntry();
        }
        if (!source.equals(file) && !source.delete()) throw new IOException("Cannot clean snapshot workspace");
    }
    private void inspectTables(File snapshot, JSONObject tables) throws Exception {
        try (SQLiteDatabase db = SQLiteDatabase.openDatabase(snapshot.getPath(), null, SQLiteDatabase.OPEN_READONLY)) {
            for (String table : new String[]{"clipboard_history", "notifications", "file_transfers"}) {
                MessageDigest digest = MessageDigest.getInstance("SHA-256"); long rows = 0;
                MessageDigest rowDigest = MessageDigest.getInstance("SHA-256");
                JSONArray rowHashes = new JSONArray();
                try (Cursor cursor = db.rawQuery("SELECT * FROM " + table + " ORDER BY rowid", null);
                     DataOutputStream stream = new DataOutputStream(new DigestOutputStream(new OutputStream() {
                         @Override public void write(int value) { rowDigest.update((byte) value); }
                         @Override public void write(byte[] value, int offset, int length) { rowDigest.update(value, offset, length); }
                     }, digest))) {
                    while (cursor.moveToNext()) {
                        rowDigest.reset();
                        rows++; stream.writeInt(cursor.getColumnCount());
                        for (int i = 0; i < cursor.getColumnCount(); i++) {
                            int type = cursor.getType(i); stream.writeInt(type);
                            if (type == Cursor.FIELD_TYPE_NULL) continue;
                            byte[] value = type == Cursor.FIELD_TYPE_BLOB ? cursor.getBlob(i) : cursor.getString(i).getBytes(StandardCharsets.UTF_8);
                            stream.writeInt(value.length); stream.write(value);
                        }
                        rowHashes.put(hex(rowDigest.digest()));
                    }
                }
                tables.put(table, new JSONObject().put("rows", rows).put("sha256", hex(digest.digest())).put("rowHashes", rowHashes));
            }
            JSONObject receivedFiles = new JSONObject();
            try (Cursor cursor = db.rawQuery("SELECT file_path FROM file_transfers", null)) {
                while (cursor.moveToNext()) {
                    String path = cursor.getString(0);
                    if (path == null) continue;
                    File file = new File(path);
                    JSONObject state = new JSONObject().put("exists", file.isFile());
                    if (file.isFile()) state.put("size", file.length()).put("sha256", hash(file));
                    receivedFiles.put(hex(MessageDigest.getInstance("SHA-256").digest(path.getBytes(StandardCharsets.UTF_8))), state);
                }
            }
            tables.getJSONObject("file_transfers").put("referencedFiles", receivedFiles);
        }
    }
    private boolean isDatabase(File file) throws IOException {
        if (!file.isFile() || file.length() < 16) return false;
        byte[] header = new byte[16];
        try (InputStream in = new FileInputStream(file)) {
            return in.read(header) == 16 && Arrays.equals(header, "SQLite format 3\u0000".getBytes(StandardCharsets.US_ASCII));
        }
    }
    private String hash(File file) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        try (InputStream in = new FileInputStream(file)) { int count; while ((count = in.read(buffer)) != -1) digest.update(buffer, 0, count); }
        return hex(digest.digest());
    }
    private static String hex(byte[] bytes) {
        StringBuilder result = new StringBuilder();
        for (byte value : bytes) result.append(String.format(Locale.ROOT, "%02x", value & 255));
        return result.toString();
    }
    private static void removeTemporary(File file) {
        if (file.isDirectory()) { File[] children = file.listFiles(); if (children != null) for (File child : children) removeTemporary(child); }
        file.delete();
    }
}
