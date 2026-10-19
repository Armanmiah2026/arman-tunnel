package com.sensei.tunnel

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException

/**
 * Wire-level tests for the local SOCKS5 → upstream proxy relay.
 *
 * These pin exactly what the old engine got wrong: the SOCKS reply must be
 * built for the CLIENT, Proxy-Authorization must sit INSIDE the CONNECT
 * header block, and upstream user/pass auth must be negotiated for real.
 */
class ProxyProtocolTest {

    /** bytes() rejects literals > 0x7F — this takes unsigned bytes. */
    private fun bytes(vararg v: Int) = ByteArray(v.size) { i -> v[i].toByte() }

    private fun input(vararg bytes: Int) =
        ByteArrayInputStream(bytes.map { it.toByte() }.toByteArray())

    private fun inputOf(s: String) = ByteArrayInputStream(s.toByteArray(Charsets.ISO_8859_1))

    private fun ascii(b: ByteArray) = String(b, Charsets.ISO_8859_1)

    // ------------------------------------------------------------ client side

    @Test
    fun greetingAcceptsSocks5() {
        ProxyProtocol.readGreeting(input(0x05, 0x02, 0x00, 0x02)) // no throw
    }

    @Test
    fun greetingRejectsOtherVersions() {
        try {
            ProxyProtocol.readGreeting(input(0x04, 0x01, 0x00)) // SOCKS4 client
            fail("expected ProtocolException for version 4")
        } catch (_: ProxyProtocol.ProtocolException) {
        }
    }

    @Test
    fun greetingHitsEofOnBindProbe() {
        // The service's local-bind probe connects and hangs up at once —
        // that must arrive as EOF (engine drops it quietly), not a crash.
        try {
            ProxyProtocol.readGreeting(ByteArrayInputStream(ByteArray(0)))
            fail("expected EOFException")
        } catch (_: EOFException) {
        }
    }

    @Test
    fun methodSelectRepliesNoAuth() {
        assertArrayEquals(bytes(0x05, 0x00), ProxyProtocol.methodSelectNoAuth())
    }

    @Test
    fun requestDomainParsedAndRawForwardable() {
        // VER CMD RSV ATYP=domain(len 11) "example.com" PORT 443
        val raw = bytes(
            0x05, 0x01, 0x00, 0x03, 0x0B,
        ) + "example.com".toByteArray() + bytes(0x01, 0xBB)
        val req = ProxyProtocol.readRequest(ByteArrayInputStream(raw))
        assertEquals(ProxyProtocol.CMD_CONNECT, req.cmd)
        assertEquals("example.com", req.host)
        assertEquals(443, req.port)
        // The EXACT bytes go to an upstream SOCKS5 server untouched.
        assertArrayEquals(raw, req.raw)
    }

    @Test
    fun requestIpv4Parsed() {
        val raw = bytes(0x05, 0x01, 0x00, 0x01, 10, 0, 0, 1, 0x1F, 0x90) // 10.0.0.1:8080
        val req = ProxyProtocol.readRequest(ByteArrayInputStream(raw))
        assertEquals("10.0.0.1", req.host)
        assertEquals(8080, req.port)
        assertArrayEquals(raw, req.raw)
    }

    @Test
    fun requestIpv6Parsed() {
        // ::1 port 443
        val raw = bytes(0x05, 0x01, 0x00, 0x04) +
            ByteArray(15) + bytes(0x01) + bytes(0x01, 0xBB)
        val req = ProxyProtocol.readRequest(ByteArrayInputStream(raw))
        assertEquals("0:0:0:0:0:0:0:1", req.host)
        assertEquals(443, req.port)
        assertArrayEquals(raw, req.raw)
    }

    @Test
    fun requestUnknownAddressTypeRejected() {
        try {
            ProxyProtocol.readRequest(input(0x05, 0x01, 0x00, 0x7F))
            fail("expected ProtocolException for unknown ATYP")
        } catch (_: ProxyProtocol.ProtocolException) {
        }
    }

    @Test
    fun replyIsBuiltForTheClient() {
        // THE old bug: this reply went to the UPSTREAM. RFC 1928 layout:
        // VER REP RSV ATYP BND.ADDR BND.PORT — 10 bytes, all client-facing.
        val rep = ProxyProtocol.reply(ProxyProtocol.REP_SUCCESS)
        assertEquals(10, rep.size)
        assertArrayEquals(
            bytes(0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0),
            rep,
        )
        val refused = ProxyProtocol.reply(ProxyProtocol.REP_CONNECTION_REFUSED)
        assertEquals(0x05, refused[1].toInt())
    }

    // --------------------------------------------------------- upstream SOCKS5

    @Test
    fun upstreamNoAuthNegotiation() {
        val captured = ByteArrayOutputStream()
        // upstream answers: chosen method 0 (no auth)
        val reply = input(0x05, 0x00)
        ProxyProtocol.negotiateUpstreamSocks(reply, captured, "", "")
        assertArrayEquals(bytes(0x05, 0x01, 0x00), captured.toByteArray())
    }

    @Test
    fun upstreamUserPassNegotiationPerRfc1929() {
        val captured = ByteArrayOutputStream()
        // upstream picks METHOD 2 (username/password)…
        val reply = input(0x05, 0x02, 0x01, 0x00)
        ProxyProtocol.negotiateUpstreamSocks(reply, captured, "arman", "secret")
        val out = captured.toByteArray()
        // …first the greeting offers BOTH no-auth and user/pass…
        assertArrayEquals(bytes(0x05, 0x02, 0x00, 0x02), out.copyOf(4))
        // …then the RFC1929 sub-negotiation: VER=1 ULEN user PLEN pass.
        val rest = out.copyOfRange(4, out.size)
        val expected = bytes(0x01, 0x05) + "arman".toByteArray() +
            bytes(0x06) + "secret".toByteArray()
        assertArrayEquals(expected, rest)
    }

    @Test
    fun upstreamRejectingCredentialsFails() {
        val captured = ByteArrayOutputStream()
        val reply = input(0x05, 0x02, 0x01, 0x01) // auth status != 0
        try {
            ProxyProtocol.negotiateUpstreamSocks(reply, captured, "arman", "wrong")
            fail("expected ProtocolException on rejected credentials")
        } catch (_: ProxyProtocol.ProtocolException) {
        }
    }

    @Test
    fun upstreamOfferingNoMethodWeCanUseFails() {
        val captured = ByteArrayOutputStream()
        val reply = input(0x05, 0xFF)
        try {
            ProxyProtocol.negotiateUpstreamSocks(reply, captured, "", "")
            fail("expected ProtocolException on method 0xFF")
        } catch (_: ProxyProtocol.ProtocolException) {
        }
    }

    @Test
    fun upstreamReplySuccessConsumedFully() {
        val rep = ProxyProtocol.readUpstreamReply(
            input(0x05, 0x00, 0x00, 0x01, 198, 51, 100, 1, 0x01, 0xBB),
        )
        assertEquals(ProxyProtocol.REP_SUCCESS, rep)
    }

    @Test
    fun upstreamReplyDomainBndConsumedFully() {
        // REP=5 (connection refused), BND = domain "foo" port 80 — the parser
        // must consume every form or the following relay reads garbage.
        val bytes = bytes(0x05, 0x05, 0x00, 0x03, 0x03) +
            "foo".toByteArray() + bytes(0x00, 0x50, 0x99) // trailing byte = junk
        val stream = ByteArrayInputStream(bytes)
        assertEquals(0x05, ProxyProtocol.readUpstreamReply(stream))
        assertEquals(0x99, stream.read()) // exactly the junk left
    }

    @Test
    fun upstreamReplyIpv6BndConsumedFully() {
        val bytes = bytes(0x05, 0x00, 0x00, 0x04) + ByteArray(16) +
            bytes(0x00, 0x50, 0x77)
        val stream = ByteArrayInputStream(bytes)
        assertEquals(0x00, ProxyProtocol.readUpstreamReply(stream))
        assertEquals(0x77, stream.read())
    }

    @Test
    fun upstreamReplyBadVersionFails() {
        try {
            ProxyProtocol.readUpstreamReply(input(0x04, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0))
            fail("expected ProtocolException on version 4 reply")
        } catch (_: ProxyProtocol.ProtocolException) {
        }
    }

    // ---------------------------------------------------- upstream HTTP CONNECT

    @Test
    fun connectRequestPutsAuthInsideHeaders() {
        val text = ascii(ProxyProtocol.buildConnect("a.example", 443, "arman", "secret"))
        assertTrue(text.startsWith("CONNECT a.example:443 HTTP/1.1\r\n"))
        assertTrue(text.contains("Host: a.example:443\r\n"))
        assertTrue(text.endsWith("\r\n\r\n"))
        val auth = text.indexOf("Proxy-Authorization: Basic YXJtYW46c2VjcmV0")
        assertTrue("auth header missing", auth > 0)
        // THE old bug appended auth AFTER the terminating blank line.
        assertTrue(
            "auth must sit before the final blank line",
            auth < text.lastIndexOf("\r\n\r\n"),
        )
    }

    @Test
    fun connectRequestWithoutCredsOmitsAuth() {
        val text = ascii(ProxyProtocol.buildConnect("a.example", 80, "", ""))
        assertTrue(!text.contains("Proxy-Authorization"))
        assertTrue(text.endsWith("\r\n\r\n"))
    }

    @Test
    fun connectResponseParsesStatus() {
        assertEquals(200, ProxyProtocol.readConnectResponse(inputOf("HTTP/1.1 200 Connection established\r\nVia: 1.1 proxy\r\n\r\n")))
        assertEquals(407, ProxyProtocol.readConnectResponse(inputOf("HTTP/1.0 407 Auth required\r\n\r\n")))
    }

    @Test
    fun connectResponseGarbageRejected() {
        try {
            ProxyProtocol.readConnectResponse(inputOf("NOT-HTTP\r\n\r\n"))
            fail("expected ProtocolException on non-HTTP status line")
        } catch (_: ProxyProtocol.ProtocolException) {
        }
    }

    @Test
    fun connectResponseEofIsEof() {
        try {
            ProxyProtocol.readConnectResponse(inputOf("HTTP/1.1 200"))
            fail("expected EOFException on truncated response")
        } catch (_: EOFException) {
        }
    }

    @Test
    fun httpCodesMapToSocksWithHonesty() {
        assertEquals(ProxyProtocol.REP_SUCCESS, ProxyProtocol.httpCodeToRep(200))
        assertEquals(ProxyProtocol.REP_SUCCESS, ProxyProtocol.httpCodeToRep(204))
        assertEquals(ProxyProtocol.REP_NOT_ALLOWED, ProxyProtocol.httpCodeToRep(403))
        assertEquals(ProxyProtocol.REP_GENERAL_FAILURE, ProxyProtocol.httpCodeToRep(407))
        assertEquals(ProxyProtocol.REP_GENERAL_FAILURE, ProxyProtocol.httpCodeToRep(502))
        assertEquals(ProxyProtocol.REP_GENERAL_FAILURE, ProxyProtocol.httpCodeToRep(404))
    }

    // ---------------------------------------------------------------- base64

    @Test
    fun base64MatchesRfcVectors() {
        assertEquals("", ProxyProtocol.base64Encode(""))
        assertEquals("Zg==", ProxyProtocol.base64Encode("f"))
        assertEquals("Zm8=", ProxyProtocol.base64Encode("fo"))
        assertEquals("Zm9v", ProxyProtocol.base64Encode("foo"))
        assertEquals("dXNlcjpwYXNz", ProxyProtocol.base64Encode("user:pass"))
    }
}
