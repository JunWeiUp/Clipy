package com.clipyclone.nativeandroid.relay

import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import android.util.Base64
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.clipyclone.nativeandroid.relay.securestorage.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.security.KeyStore
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class RelaySecureStorageTest {
    /** Same implementation and formats; isolate both preference files and RSA alias from app credentials. */
    private class IsolatedContext(base: Context) : ContextWrapper(base) {
        private val suffix = UUID.randomUUID().toString().take(8)
        val prefix = "secure-fixture-$suffix-"
        val names = mutableSetOf<String>()
        override fun getApplicationContext(): Context = this
        override fun getPackageName(): String = "io.clipy.fixture.$suffix"
        override fun getSharedPreferences(name: String, mode: Int): SharedPreferences {
            names += prefix + name
            return super.getSharedPreferences(prefix + name, mode)
        }
        fun snapshot(): Map<String, Map<String, *>> = names.associateWith {
            baseContext.getSharedPreferences(it, Context.MODE_PRIVATE).all.toMap()
        }
        fun cleanup() {
            names.forEach { baseContext.deleteSharedPreferences(it) }
            KeyStore.getInstance("AndroidKeyStore").apply {
                load(null)
                deleteEntry(packageName + ".FlutterSecureStoragePluginKey")
                deleteEntry(packageName + ".FlutterSecureStoragePluginKeyOAEP")
            }
        }
    }
    private suspend fun ready(store: NativeSecureStorageAdapter) {
        val result = CompletableDeferred<Unit>()
        store.initializeNative(object : SecurePreferencesCallback<Void> {
            override fun onSuccess(value: Void?) { result.complete(Unit) }
            override fun onError(error: Exception) { result.completeExceptionally(error) }
        })
        withTimeout(10000) { result.await() }
    }
    /** Reproduces Flutter 10.0.0 AndroidOptions.toMap(), not native defaults. */
    private class ShippingStorage(context: Context) : FlutterSecureStorage(context) {
        fun initializeShipping(callback: SecurePreferencesCallback<Void>) {
            initialize(FlutterSecureStorageConfig(hashMapOf<String, Any>(
                "keyCipherAlgorithm" to "RSA_ECB_OAEPwithSHA_256andMGF1Padding",
                "storageCipherAlgorithm" to "AES_GCM_NoPadding",
                "encryptedSharedPreferences" to "false",
                "resetOnError" to "true",
                "migrateOnAlgorithmChange" to "true",
                "enforceBiometrics" to "false"
            )), callback)
        }
    }
    @Test fun readsShippingOaepIdentityWithoutChangingCiphertextAlgorithmsOrKeys() = runBlocking {
        val context = IsolatedContext(InstrumentationRegistry.getInstrumentation().targetContext)
        try {
            val shipping = ShippingStorage(context)
            val initialized = CompletableDeferred<Unit>()
            shipping.initializeShipping(object : SecurePreferencesCallback<Void> {
                override fun onSuccess(value: Void?) { initialized.complete(Unit) }
                override fun onError(error: Exception) { initialized.completeExceptionally(error) }
            })
            withTimeout(10000) { initialized.await() }
            val secret = "02".repeat(32)
            val public = com.clipyclone.nativeandroid.relay.sdk.Crypto("clipy", "", "", secret, emptyMap()).publicKey()
            val identity = org.json.JSONObject().put("secret_key", secret).put("public_key", public).toString()
            val prefKey = shipping.addPrefixToKey("commonRelayIdentity")
            shipping.write(prefKey, identity)
            val prefs = context.getSharedPreferences("FlutterSecureStorage", Context.MODE_PRIVATE)
            val encryptedIdentity = prefs.getString(prefKey, null)
            val algorithms = context.getSharedPreferences("FlutterSecureStorageConfiguration", Context.MODE_PRIVATE)
            assertEquals("RSA_ECB_OAEPwithSHA_256andMGF1Padding", algorithms.getString("FlutterSecureSAlgorithmKey", null))
            assertEquals("AES_GCM_NoPadding", algorithms.getString("FlutterSecureSAlgorithmStorage", null))
            val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            val alias = context.packageName + ".FlutterSecureStoragePluginKeyOAEP"
            assertTrue(keyStore.containsAlias(alias))
            val certificate = keyStore.getCertificate(alias).encoded
            val before = context.snapshot()

            val native = NativeSecureStorageAdapter(context); ready(native)
            assertEquals(identity, native.get("commonRelayIdentity"))
            // Exercise the actual native identity reader as well as raw storage.
            assertEquals(public, RelaySecureStore(context).identity().getString("public_key"))
            assertEquals(encryptedIdentity, prefs.getString(prefKey, null))
            assertEquals(before, context.snapshot())
            assertArrayEquals(certificate, keyStore.getCertificate(alias).encoded)
            assertFalse(keyStore.containsAlias(context.packageName + ".FlutterSecureStoragePluginKey"))
        } finally { context.cleanup() }
    }

    @Test fun nativeWrapperPreservesCiphertextAndRefusesDestructiveReset() = runBlocking {
        val context = IsolatedContext(InstrumentationRegistry.getInstrumentation().targetContext)
        try {
            val first = NativeSecureStorageAdapter(context); ready(first)
            first.put("fixture", "fixture credential")
            val prefs = context.getSharedPreferences("FlutterSecureStorage", Context.MODE_PRIVATE)
            val key = first.addPrefixToKey("fixture")
            val raw = prefs.getString(key, null)!!
            assertNotEquals("fixture credential", raw)
            val second = NativeSecureStorageAdapter(context); ready(second)
            assertEquals("fixture credential", second.get("fixture"))
            val bytes = Base64.decode(raw, Base64.DEFAULT)
            bytes[bytes.lastIndex] = (bytes.last().toInt() xor 255).toByte()
            val corrupt = Base64.encodeToString(bytes, Base64.DEFAULT)
            prefs.edit().putString(key, corrupt).commit()
            assertThrows(Exception::class.java) { second.get("fixture") }
            assertEquals(corrupt, prefs.getString(key, null))
            prefs.edit().putString(key, raw).commit()
            assertEquals("fixture credential", second.get("fixture"))
        } finally { context.cleanup() }
    }
    @Test fun restoresExistingEnrollmentIdentityAndNeverReplacesMalformedSavedIdentity() = runBlocking {
        val context = IsolatedContext(InstrumentationRegistry.getInstrumentation().targetContext)
        try {
            val store = RelaySecureStore(context)
            val secret = "01".repeat(32)
            val public = com.clipyclone.nativeandroid.relay.sdk.Crypto("clipy", "", "", secret, emptyMap()).publicKey()
            val raw = org.json.JSONObject().put("secret_key", secret).put("public_key", public).put("device", "fixture").toString()
            store.write("commonRelayConfig", raw)
            val identity = store.identity()
            assertEquals(public, identity.getString("public_key"))
            assertEquals(secret, identity.getString("secret_key"))
            assertEquals(raw, store.read("commonRelayConfig"))
            store.write("commonRelayIdentity", "not valid json")
            try { store.identity(); fail("Malformed saved identity must fail, not regenerate") } catch (_: org.json.JSONException) { }
            assertEquals("not valid json", store.read("commonRelayIdentity"))
        } finally { context.cleanup() }
    }

}
