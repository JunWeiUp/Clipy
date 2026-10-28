package com.clipyclone.nativeandroid.relay

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.clipyclone.nativeandroid.relay.sdk.Crypto
import com.clipyclone.nativeandroid.relay.sdk.InvitationLinks
import com.clipyclone.nativeandroid.relay.sdk.RelayGroups
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith

/** Cross-language fixtures produced by the upstream Python SDK, not native self-roundtrips. */
@RunWith(AndroidJUnit4::class)
class RelaySdkVectorsTest {
    private fun fixture(name: String): JSONObject = InstrumentationRegistry.getInstrumentation().context.assets
        .open("relay/$name").bufferedReader().use { JSONObject(it.readText()) }
    @Test fun decryptsPythonBoxAndSecretStreamVectors() {
        val v = fixture("crypto-vectors.json")
        val bob = Crypto("example", "test", "bob", v.getString("bob_secret"), mapOf("alice" to v.getString("alice_public")))
        assertEquals(v.getString("bob_public"), bob.publicKey())
        val id = v.getString("id")
        assertEquals("aGVsbG8=", bob.open("alice", "message", id, v.getString("message")).getString("data"))
        assertThrows(Exception::class.java) { bob.open("alice", "message", "wrong", v.getString("message")) }
        assertEquals(v.getLong("offline_expires"), bob.open("alice", "message", id, v.getString("offline_message")).getLong("expires"))
        Crypto.SecretStream(v.getJSONObject("stream_descriptor")).use { stream ->
            val aad = bob.aad("alice", "bob", "stream", id, 0)
            assertEquals(v.getString("stream_aad"), String(aad, Charsets.UTF_8))
            assertArrayEquals("hello".toByteArray(), stream.pull(Crypto.unhex(v.getString("stream_ciphertext")), aad))
            assertTrue(stream.finished)
            assertThrows(Exception::class.java) { stream.pull(Crypto.unhex(v.getString("stream_ciphertext")), aad) }
        }
    }
    @Test fun verifiesSignedMembershipDelegationsAndRejectsAmbiguousPayloads() {
        val v = fixture("group-vectors.json")
        val groups = RelayGroups(v.getJSONObject("config"), false)
        val managerKey = v.getJSONObject("manager").getString("signing_key")
        assertEquals(managerKey, groups.member("Mac").getString("signing_key"))
        val initial = v.getJSONObject("initial"); val approved = v.getJSONObject("approved")
        RelayGroups.verify(v.getJSONObject("self_service"), managerKey)
        RelayGroups.verify(initial, managerKey)
        groups.advance(initial, approved); groups.advance(approved, v.getJSONObject("removed"))
        groups.advance(approved, v.getJSONObject("renamed"))
        groups.advance(approved, v.getJSONObject("left")); groups.advance(approved, v.getJSONObject("disbanded"))
        for (name in listOf("unauthorized_rename", "unauthorized_disband")) assertThrows(Exception::class.java) { groups.advance(approved, v.getJSONObject(name)) }
        assertThrows(Exception::class.java) { groups.advance(initial, v.getJSONObject("removed")) }
        val automatic = v.getJSONObject("auto_admission")
        groups.advance(initial, automatic.getJSONObject("approved"))
        val invalidAutomatic = automatic.getJSONArray("invalid")
        repeat(invalidAutomatic.length()) { index -> assertThrows(Exception::class.java) { groups.advance(initial, invalidAutomatic.getJSONObject(index).getJSONObject("entry")) } }
        val strict = v.getJSONObject("strict_payload")
        val valid = strict.getJSONArray("valid")
        repeat(valid.length()) { groups.advance(approved, valid.getJSONObject(it).getJSONObject("entry")) }
        for (set in listOf("invalid", "invalid_auto")) {
            val cases = strict.getJSONArray(set)
            repeat(cases.length()) { index -> assertThrows(cases.getJSONObject(index).getString("case"), Exception::class.java) { groups.advance(if (set == "invalid") approved else initial, cases.getJSONObject(index).getJSONObject("entry")) } }
        }
    }
    @Test fun opensCrossLanguageInvitationLinksAndRejectsTampering() {
        val v = fixture("invitation-link-vectors.json")
        val key = Crypto.unhex(v.getString("key"))
        val invitation = InvitationLinks.open(v.getString("packet"), key)
        assertEquals(v.getJSONObject("invitation").getString("id"), invitation.getString("id"))
        assertEquals(v.getString("read_token"), InvitationLinks.readToken(key))
        assertEquals(v.getString("link"), InvitationLinks.make(invitation, key))
        assertEquals(invitation.getString("url"), InvitationLinks.parse(v.getString("link"), false).url)
        assertThrows(Exception::class.java) { InvitationLinks.open(v.getString("packet"), ByteArray(32)) }
        assertThrows(Exception::class.java) { InvitationLinks.parse(v.getString("link") + "=", false) }
        assertThrows(Exception::class.java) { InvitationLinks.parse(v.getString("link").replace("relay.example.com", "user@relay.example.com"), false) }
    }
    @Test fun rejectsImplicitConfigurationAndKeepsLanIdentitySeparate() {
        assertFalse(RelayConfiguration.validUrl("ws://example.com/relay/v1/ws"))
        assertFalse(RelayConfiguration.validUrl("wss://example.com/relay/v1/ws?token=bad"))
        assertFalse(RelayConfiguration.validDevice("bad/device"))
        assertThrows(IllegalArgumentException::class.java) { RelayConfiguration.update("", "device", "a".repeat(32), "") }
        val id = "00000000-0000-0000-0000-000000000001"
        assertEquals(id, RelayConfiguration.lanPeer("custom-device", JSONObject().put("peerId", id)))
        assertNull(RelayConfiguration.lanPeer("custom-device", null))
    }
}
