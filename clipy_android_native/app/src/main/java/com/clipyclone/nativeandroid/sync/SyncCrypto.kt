package com.clipyclone.nativeandroid.sync

import android.util.Base64
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/** Same payload bytes as Dart encrypt and Swift CryptoKit: nonce12 || ciphertext || tag16. */
class SyncCrypto {
    @Volatile private var keyBytes = MessageDigest.getInstance("SHA-256")
        .digest("ClipySyncSecret2026".toByteArray(Charsets.UTF_8))
    private val random = SecureRandom()
    fun key(): ByteArray = keyBytes.copyOf()
    fun configureKey(hex: String) {
        require(Regex("^[a-f0-9]{64}$").matches(hex))
        keyBytes = ByteArray(32) { hex.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    }
    fun encryptText(text: String): String = encryptBytes(text.toByteArray(Charsets.UTF_8))
    fun encryptBytes(plain: ByteArray): String = seal(plain, ByteArray(12).also(random::nextBytes))
    internal fun seal(plain: ByteArray, nonce: ByteArray): String {
        require(nonce.size == 12)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(keyBytes, "AES"), GCMParameterSpec(128, nonce))
        return Base64.encodeToString(nonce + cipher.doFinal(plain), Base64.NO_WRAP)
    }
    fun decryptBytes(payload: String): ByteArray? = try {
        val combined = Base64.decode(payload, Base64.DEFAULT)
        // Match shipping clients, which reject the empty-plaintext 28-byte form.
        require(combined.size > 28)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(keyBytes, "AES"), GCMParameterSpec(128, combined, 0, 12))
        cipher.doFinal(combined, 12, combined.size - 12)
    } catch (_: Exception) { null }
    fun decryptText(payload: String): String? = try {
        decryptBytes(payload)?.let { Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(it)).toString() }
    } catch (_: Exception) { null }
}
