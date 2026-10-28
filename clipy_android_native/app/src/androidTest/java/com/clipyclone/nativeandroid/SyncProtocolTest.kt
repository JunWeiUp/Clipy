package com.clipyclone.nativeandroid

import android.util.Base64
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.clipyclone.nativeandroid.sync.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayInputStream
import java.io.EOFException
import java.io.FilterInputStream
import java.nio.ByteBuffer

@RunWith(AndroidJUnit4::class)
class SyncProtocolTest {
    @Test fun usesTheExistingDartAndSwiftCipherVector() {
        val crypto = SyncCrypto()
        assertEquals("30f891b68d235b41eb215ffe624c29d3782f27efc26c8f00e80e10ef9daa8304",
            crypto.key().joinToString("") { "%02x".format(it.toInt() and 255) })
        val vector = "AAECAwQFBgcICQoLhdUwCui4zMJDC8GLd3CsDGCvgcc2/Zua+hgmwEW4aNreepO2aYY99Q=="
        assertEquals("default transport 世界", crypto.decryptText(vector))
        assertEquals(vector, crypto.seal("default transport 世界".toByteArray(Charsets.UTF_8), ByteArray(12) { it.toByte() }))
    }
    @Test fun binaryChunksAndTamperDetection() {
        val crypto = SyncCrypto()
        val plain = ByteBuffer.allocate(70004).putInt(42).put(ByteArray(70000) { (it and 255).toByte() }).array()
        val sealed = crypto.encryptBytes(plain)
        assertArrayEquals(plain, crypto.decryptBytes(sealed))
        val modified = Base64.decode(sealed, Base64.NO_WRAP).also { it[it.lastIndex] = (it.last().toInt() xor 255).toByte() }
        assertNull(crypto.decryptBytes(Base64.encodeToString(modified, Base64.NO_WRAP)))
        assertNull(crypto.decryptText("bad"))
        assertNull(crypto.decryptText(Base64.encodeToString(ByteArray(28), Base64.NO_WRAP)))
        val first = Base64.decode(crypto.encryptText("same"), 0).take(12)
        val second = Base64.decode(crypto.encryptText("same"), 0).take(12)
        assertNotEquals(first, second)
    }
    @Test fun readsFragmentedAndCoalescedFramesWithoutLosingBytes() {
        val one = SyncEnvelope(SyncType.HELLO, "fixture", name = "设备", port = 5566, sessionPolicy = SESSION_POLICY)
        val two = SyncEnvelope(SyncType.HISTORY_DIRECT, "fixture", hash = "hash", payload = "ciphertext")
        val bytes = SyncProtocol.encode(one) + SyncProtocol.encode(two)
        val fragmented = object : FilterInputStream(ByteArrayInputStream(bytes)) {
            override fun read(b: ByteArray, off: Int, len: Int): Int = super.read(b, off, minOf(1, len))
        }
        assertEquals(one, SyncProtocol.decode(SyncProtocol.readBody(fragmented)!!))
        assertEquals(two, SyncProtocol.decode(SyncProtocol.readBody(fragmented)!!))
        assertNull(SyncProtocol.readBody(fragmented))
    }
    @Test fun rejectsBadLengthsTruncationAndInvalidTypes() {
        for (size in listOf(0, -1, MAX_FRAME_BYTES + 1)) {
            try { SyncProtocol.readBody(ByteArrayInputStream(ByteBuffer.allocate(4).putInt(size).array())); fail("Accepted length $size") }
            catch (_: IllegalArgumentException) { }
        }
        try { SyncProtocol.readBody(ByteArrayInputStream(byteArrayOf(0, 0))); fail("Accepted truncated header") } catch (_: EOFException) { }
        assertNull(SyncProtocol.decode("{\"v\":\"3\"}".toByteArray()))
        assertNull(SyncProtocol.decode(byteArrayOf(0xff.toByte())))
        assertNull(SyncProtocol.decode("{} trailing".toByteArray()))
        val unknown = SyncProtocol.decode("{\"v\":3,\"type\":\"future.extension\",\"peerId\":\"x\",\"extra\":true}".toByteArray())
        assertEquals("future.extension", unknown?.type)
    }
    @Test fun duplicatePolicyMatchesCurrentProtocol() {
        assertFalse(SyncProtocol.shouldReplace(SESSION_POLICY, "a", "b", false, true))
        assertTrue(SyncProtocol.shouldReplace(SESSION_POLICY, "a", "b", true, false))
        assertTrue(SyncProtocol.shouldReplace(SESSION_POLICY, "b", "a", false, true))
        assertFalse(SyncProtocol.shouldReplace(SESSION_POLICY, "b", "a", true, false))
        // The current macOS v3 does not advertise this optional capability.
        assertTrue(SyncProtocol.shouldReplace(null, "a", "b", false, true))
    }
}
