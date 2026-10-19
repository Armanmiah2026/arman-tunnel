package com.sensei.tunnel

import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream

/**
 * Pure protocol logic behind ProxyEngine: SOCKS5 on the client side (what
 * tun2socks and the E2E probe dial at 127.0.0.1:10808) and either SOCKS5 or
 * HTTP CONNECT on the upstream side (the proxy server the config points at).
 *
 * No Android types live here on purpose — every byte-level rule is pinned by
 * the JVM unit tests in src/test (wire format, auth placement, reply codes)
 * so they run without an emulator.
 */
object ProxyProtocol {

    const val REP_SUCCESS = 0x00
    const val REP_GENERAL_FAILURE = 0x01
    const val REP_NOT_ALLOWED = 0x02
    const val REP_NETWORK_UNREACHABLE = 0x03
    const val REP_HOST_UNREACHABLE = 0x04
    const val REP_CONNECTION_REFUSED = 0x05
    const val REP_TTL_EXPIRED = 0x06
    const val REP_COMMAND_NOT_SUPPORTED = 0x07
    const val REP_ADDRESS_TYPE_NOT_SUPPORTED = 0x08

    const val CMD_CONNECT = 0x01

    private const val MAX_RESPONSE_HEADER_BYTES = 8192

    class ProtocolException(message: String) : IOException(message)

    // ---------------------------------------------------------------- reads

    /** Reads exactly [buf.size] bytes; throws EOFException when the peer hangs up. */
    fun readFully(input: InputStream, buf: ByteArray) {
        var off = 0
        while (off < buf.size) {
            val n = input.read(buf, off, buf.size - off)
            if (n < 0) throw EOFException("stream closed after $off/${buf.size} bytes")
            off += n
        }
    }

    private fun readByte(input: InputStream): Int {
        val b = input.read()
        if (b < 0) throw EOFException("stream closed")
        return b
    }

    // -------------------------------------------------- client-facing SOCKS5

    /** Client greeting: VER=5, NMETHODS, METHODS[]. */
    fun readGreeting(input: InputStream) {
        val ver = readByte(input)
        if (ver != 0x05) throw ProtocolException("greeting version $ver, expected 5")
        val n = readByte(input)
        if (n < 1) throw ProtocolException("client offered no auth methods")
        readFully(input, ByteArray(n))
    }

    /** We always answer with "no auth required" — tun2socks speaks it. */
    fun methodSelectNoAuth(): ByteArray = byteArrayOf(0x05, 0x00)

    data class SocksRequest(val cmd: Int, val host: String, val port: Int, val raw: ByteArray)

    /**
     * Full SOCKS5 request: VER CMD RSV ATYP DST.ADDR DST.PORT. The exact
     * wire bytes are kept in [SocksRequest.raw] so they can be forwarded to
     * an upstream SOCKS5 server untouched (IPv6 included).
     */
    fun readRequest(input: InputStream): SocksRequest {
        val ver = readByte(input)
        if (ver != 0x05) throw ProtocolException("request version $ver, expected 5")
        val cmd = readByte(input)
        val rsv = readByte(input)
        if (rsv != 0x00) throw ProtocolException("reserved byte $rsv, expected 0")
        val atyp = readByte(input)
        val addr: ByteArray
        val host: String
        // The domain's length prefix is PART of the wire form — raw must be
        // byte-for-byte what arrived or an upstream SOCKS5 server chokes on it.
        val lenPrefix: ByteArray
        when (atyp) {
            0x01 -> {
                addr = ByteArray(4)
                readFully(input, addr)
                host = addr.joinToString(".") { (it.toInt() and 0xFF).toString() }
                lenPrefix = ByteArray(0)
            }
            0x03 -> {
                val len = readByte(input)
                if (len < 1) throw ProtocolException("empty domain in request")
                addr = ByteArray(len)
                readFully(input, addr)
                host = String(addr, Charsets.UTF_8)
                lenPrefix = byteArrayOf(len.toByte())
            }
            0x04 -> {
                addr = ByteArray(16)
                readFully(input, addr)
                host = formatIpv6(addr)
                lenPrefix = ByteArray(0)
            }
            else -> throw ProtocolException("address type $atyp not supported")
        }
        val port = (readByte(input) shl 8) or readByte(input)
        val raw = byteArrayOf(ver.toByte(), cmd.toByte(), 0x00, atyp.toByte()) +
            lenPrefix +
            addr +
            byteArrayOf((port shr 8).toByte(), (port and 0xFF).toByte())
        return SocksRequest(cmd, host, port, raw)
    }

    private fun formatIpv6(addr: ByteArray): String =
        (0 until 8).joinToString(":") { i ->
            (((addr[i * 2].toInt() and 0xFF) shl 8) or (addr[i * 2 + 1].toInt() and 0xFF)).toString(16)
        }

    /**
     * SOCKS5 reply for the CLIENT. BND.ADDR/PORT are zeroes — allowed by
     * RFC 1928 for CONNECT and ignored by tun2socks and Java's SOCKS client.
     */
    fun reply(rep: Int): ByteArray =
        byteArrayOf(0x05, rep.toByte(), 0x00, 0x01, 0, 0, 0, 0, 0, 0)

    // ------------------------------------------------------- upstream SOCKS5

    /** Method negotiation with the upstream proxy (+ RFC1929 user/pass when creds exist). */
    fun negotiateUpstreamSocks(upIn: InputStream, upOut: OutputStream, user: String, pass: String) {
        val greeting = if (user.isNotEmpty()) {
            byteArrayOf(0x05, 0x02, 0x00, 0x02)
        } else {
            byteArrayOf(0x05, 0x01, 0x00)
        }
        upOut.write(greeting)
        upOut.flush()
        val ver = readByte(upIn)
        if (ver != 0x05) throw ProtocolException("upstream greeting version $ver, expected 5")
        when (readByte(upIn)) {
            0x00 -> return
            0x02 -> {
                if (user.isEmpty()) {
                    throw ProtocolException("upstream demands user/pass auth but no credentials are set")
                }
                val u = user.toByteArray(Charsets.UTF_8)
                val p = pass.toByteArray(Charsets.UTF_8)
                if (u.size > 255 || p.size > 255) throw ProtocolException("credentials too long for SOCKS auth")
                upOut.write(byteArrayOf(0x01, u.size.toByte()) + u + byteArrayOf(p.size.toByte()) + p)
                upOut.flush()
                if (readByte(upIn) != 0x01) throw ProtocolException("bad auth sub-negotiation version")
                if (readByte(upIn) != 0x00) throw ProtocolException("upstream rejected the credentials")
            }
            0xFF -> throw ProtocolException("upstream accepts none of the auth methods we offer")
            else -> throw ProtocolException("upstream chose an auth method we did not offer")
        }
    }

    /** Reads the upstream's reply, consuming BND.ADDR/PORT; returns its REP code. */
    fun readUpstreamReply(upIn: InputStream): Int {
        val ver = readByte(upIn)
        if (ver != 0x05) throw ProtocolException("upstream reply version $ver, expected 5")
        val rep = readByte(upIn)
        readByte(upIn) // RSV
        when (readByte(upIn)) { // BND.ADDR — consume whatever form it takes
            0x01 -> readFully(upIn, ByteArray(4))
            0x03 -> {
                val len = readByte(upIn)
                readFully(upIn, ByteArray(len))
            }
            0x04 -> readFully(upIn, ByteArray(16))
            else -> throw ProtocolException("upstream reply address type unsupported")
        }
        readFully(upIn, ByteArray(2)) // BND.PORT
        return rep
    }

    // ----------------------------------------------------- upstream HTTP CONNECT

    /**
     * CONNECT request for an upstream HTTP proxy. Proxy-Authorization is a
     * regular header INSIDE the block (the old engine appended it after the
     * terminating blank line, where proxies ignore it).
     */
    fun buildConnect(host: String, port: Int, user: String, pass: String): ByteArray {
        val sb = StringBuilder()
        sb.append("CONNECT ").append(host).append(':').append(port).append(" HTTP/1.1\r\n")
        sb.append("Host: ").append(host).append(':').append(port).append("\r\n")
        if (user.isNotEmpty()) {
            sb.append("Proxy-Authorization: Basic ").append(base64Encode("$user:$pass")).append("\r\n")
        }
        sb.append("Proxy-Connection: Keep-Alive\r\n\r\n")
        return sb.toString().toByteArray(Charsets.ISO_8859_1)
    }

    /** Reads the CONNECT status line + headers; returns the HTTP status code. */
    fun readConnectResponse(upIn: InputStream): Int {
        val buf = StringBuilder()
        while (buf.length < MAX_RESPONSE_HEADER_BYTES) {
            val b = upIn.read()
            if (b < 0) throw EOFException("upstream closed during CONNECT response")
            buf.append(b.toChar())
            val n = buf.length
            if (n >= 4 &&
                buf[n - 4] == '\r' && buf[n - 3] == '\n' &&
                buf[n - 2] == '\r' && buf[n - 1] == '\n'
            ) {
                val firstLine = buf.substring(0, buf.indexOf("\r\n"))
                val parts = firstLine.split(" ")
                if (parts.size < 2 || !parts[0].startsWith("HTTP/")) {
                    throw ProtocolException("bad CONNECT status line: $firstLine")
                }
                return parts[1].toIntOrNull()
                    ?: throw ProtocolException("bad CONNECT status code: $firstLine")
            }
        }
        throw ProtocolException("CONNECT response headers exceeded $MAX_RESPONSE_HEADER_BYTES bytes")
    }

    /** HTTP → SOCKS reply mapping: 2xx opens, 403 is a ruleset denial, the rest is general failure. */
    fun httpCodeToRep(code: Int): Int = when {
        code in 200..299 -> REP_SUCCESS
        code == 403 -> REP_NOT_ALLOWED
        else -> REP_GENERAL_FAILURE
    }

    // ---------------------------------------------------------------- base64

    private const val B64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

    /**
     * Standard base64 without line wraps. java.util.Base64 needs API 26 but
     * minSdk is 24 — and the JVM tests assert the exact output anyway.
     */
    fun base64Encode(text: String): String = base64Encode(text.toByteArray(Charsets.UTF_8))

    fun base64Encode(data: ByteArray): String {
        val sb = StringBuilder((data.size + 2) / 3 * 4)
        var i = 0
        while (i + 2 < data.size) {
            val n = ((data[i].toInt() and 0xFF) shl 16) or
                ((data[i + 1].toInt() and 0xFF) shl 8) or
                (data[i + 2].toInt() and 0xFF)
            sb.append(B64_ALPHABET[(n shr 18) and 63])
            sb.append(B64_ALPHABET[(n shr 12) and 63])
            sb.append(B64_ALPHABET[(n shr 6) and 63])
            sb.append(B64_ALPHABET[n and 63])
            i += 3
        }
        when (data.size - i) {
            1 -> {
                val n = (data[i].toInt() and 0xFF) shl 16
                sb.append(B64_ALPHABET[(n shr 18) and 63])
                sb.append(B64_ALPHABET[(n shr 12) and 63])
                sb.append("==")
            }
            2 -> {
                val n = ((data[i].toInt() and 0xFF) shl 16) or ((data[i + 1].toInt() and 0xFF) shl 8)
                sb.append(B64_ALPHABET[(n shr 18) and 63])
                sb.append(B64_ALPHABET[(n shr 12) and 63])
                sb.append(B64_ALPHABET[(n shr 6) and 63])
                sb.append('=')
            }
        }
        return sb.toString()
    }
}
