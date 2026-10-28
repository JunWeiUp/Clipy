package com.clipyclone.nativeandroid.sync

import org.json.JSONObject
import org.json.JSONTokener
import java.io.DataInputStream
import java.io.EOFException
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.UUID

const val SYNC_VERSION = 3
const val MAX_FRAME_BYTES = 2 * 1024 * 1024
const val MAX_HANDSHAKE_BYTES = 64 * 1024
const val SESSION_POLICY = "peer-id-v1"

object SyncType {
    const val HELLO = "hello"; const val WELCOME = "welcome"
    const val HISTORY = "history"; const val HISTORY_DIRECT = "history.direct"
    const val HISTORY_FETCH = "history.fetch"; const val ACK = "ack"
    const val NOTIF_POST = "notif.post"; const val NOTIF_DISMISS = "notif.dismiss"
    const val NOTIF_CLEAR = "notif.clear"; const val NOTIF_ACK = "notif.ack"; const val NOTIF_CONFIG = "notif.config"
    const val PING = "ping"; const val PONG = "pong"
    const val FILE_META = "file.meta"; const val FILE_CHUNK = "file.chunk"; const val FILE_ACK = "file.ack"
}

data class SyncEnvelope(
    val type: String, val peerId: String, val msgId: String = UUID.randomUUID().toString(),
    val v: Int = SYNC_VERSION, val name: String? = null, val port: Int? = null,
    val ts: Double = System.currentTimeMillis() / 1000.0, val hash: String? = null,
    val payload: String? = null, val sessionPolicy: String? = null,
) {
    fun json(): JSONObject = JSONObject().apply {
        put("v", v); put("type", type); put("msgId", msgId); put("peerId", peerId); put("ts", ts)
        name?.let { put("name", it) }; port?.let { put("port", it) }; hash?.let { put("hash", it) }
        payload?.let { put("payload", it) }; sessionPolicy?.let { put("sessionPolicy", it) }
    }
}

object SyncProtocol {
    fun encode(envelope: SyncEnvelope): ByteArray {
        val body = envelope.json().toString().toByteArray(Charsets.UTF_8)
        require(body.size in 1..MAX_FRAME_BYTES) { "Invalid frame size" }
        return ByteBuffer.allocate(body.size + 4).putInt(body.size).put(body).array()
    }

    fun decode(body: ByteArray): SyncEnvelope? = try {
        require(body.size in 1..MAX_FRAME_BYTES)
        val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(body)).toString()
        val tokener = JSONTokener(text)
        val value = tokener.nextValue() as JSONObject
        require(tokener.nextClean() == '\u0000')
        fun optionalString(key: String): String? = if (!value.has(key) || value.isNull(key)) null else value.get(key) as String
        fun optionalInt(key: String): Int? {
            if (!value.has(key) || value.isNull(key)) return null
            val raw = value.get(key)
            require(raw is Int || raw is Long)
            val long = (raw as Number).toLong()
            require(long in Int.MIN_VALUE..Int.MAX_VALUE)
            return long.toInt()
        }
        val timestamp = if (!value.has("ts") || value.isNull("ts")) 0.0 else (value.get("ts") as Number).toDouble()
        require(timestamp.isFinite())
        SyncEnvelope(type = optionalString("type") ?: "", peerId = optionalString("peerId") ?: "",
            msgId = optionalString("msgId") ?: "", v = optionalInt("v") ?: 0, name = optionalString("name"),
            port = optionalInt("port"), ts = timestamp, hash = optionalString("hash"), payload = optionalString("payload"),
            sessionPolicy = optionalString("sessionPolicy"))
    } catch (_: Exception) { null }

    /** Read exactly one frame; no read-ahead is lost between handshake and session. */
    fun readBody(input: InputStream, maxBytes: Int = MAX_FRAME_BYTES): ByteArray? {
        val first = input.read()
        if (first == -1) return null
        val prefix = ByteArray(4); prefix[0] = first.toByte()
        val data = DataInputStream(input)
        data.readFully(prefix, 1, 3)
        val size = ByteBuffer.wrap(prefix).int
        require(size in 1..maxBytes) { "Invalid frame length" }
        return ByteArray(size).also { data.readFully(it) }
    }

    fun shouldReplace(remotePolicy: String?, localId: String, remoteId: String,
                      existingInbound: Boolean, incomingInbound: Boolean): Boolean {
        if (remotePolicy != SESSION_POLICY) return true
        val preferInbound = localId > remoteId
        return existingInbound != preferInbound || incomingInbound == preferInbound
    }
}
