package com.snapdark.tunnel

import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * Minimal local HTTP proxy that forwards every request through a SOCKS server.
 *
 * SSH-family tunnels only expose a SOCKS listener (127.0.0.1:10808) — unlike
 * xray there is no HTTP inbound, so the app's own HTTP stack (which cannot
 * speak SOCKS) had no way to route through the tunnel and leaked out the
 * physical interface (real IP / location shown while connected). This bridge
 * listens on the same port xray's HTTP inbound uses (10809) and forwards
 * everything over SOCKS, so app-internal requests ride the tunnel on every
 * protocol: xray (native HTTP inbound) / SSH+DNSTT (this bridge) / OpenVPN
 * (process bound to the VPN network instead).
 *
 * Supports CONNECT (HTTPS — what Dart's HttpClient uses via findProxy) and
 * absolute-form plain-HTTP requests.
 */
class HttpSocksBridge(
    private val bindHost: String,
    private val listenPort: Int,
    private val socksHost: String,
    private val socksPort: Int,
) {
    private var server: ServerSocket? = null
    private var acceptThread: Thread? = null
    private val pool: ExecutorService = Executors.newFixedThreadPool(16) { r ->
        Thread(r, "snapdark-http-bridge").apply { isDaemon = true }
    }

    /** In-flight socket pairs. Reads block and ignore interrupts, so
     *  shutdownNow() alone left them parked until the SOCKS side EOF'd;
     *  stop() closes them explicitly now. A cached (unbounded) pool also let
     *  a chatty app leak one thread per stalled CONNECT. */
    private val liveSockets = java.util.concurrent.CopyOnWriteArraySet<Socket>()

    fun start() {
        val ss = ServerSocket()
        ss.reuseAddress = true
        ss.bind(InetSocketAddress(bindHost, listenPort), 64)
        server = ss
        acceptThread = Thread({
            while (!ss.isClosed) {
                val client = try {
                    ss.accept()
                } catch (e: Exception) {
                    if (ss.isClosed) break
                    // ECONNABORTED/EMFILE during an interface flap must not
                    // kill the bridge: the app's own HTTP would silently stop
                    // riding the tunnel and leak the real IP again.
                    android.util.Log.w("HttpSocksBridge", "accept retry: ${e.message}")
                    try { Thread.sleep(250) } catch (_: InterruptedException) { break }
                    continue
                }
                pool.execute { handle(client) }
            }
        }, "snapdark-http-bridge-accept").apply {
            isDaemon = true
            start()
        }
    }

    fun stop() {
        try { server?.close() } catch (_: Exception) {}
        server = null
        for (sk in liveSockets) {
            try { sk.close() } catch (_: Exception) {}
        }
        liveSockets.clear()
        try { pool.shutdownNow() } catch (_: Exception) {}
    }

    /** Request head plus any body bytes that arrived in the same read. */
    private class Parsed(val head: String, val rest: ByteArray)

    private fun handle(client: Socket) {
        try {
            client.tcpNoDelay = true
            client.soTimeout = 30_000
            val input = client.getInputStream()
            val parsed = readHead(input)
            if (parsed == null) {
                try { client.close() } catch (_: Exception) {}
                return
            }
            val lines = parsed.head.split("\r\n")
            val requestLine = lines.firstOrNull()
            if (requestLine == null) {
                try { client.close() } catch (_: Exception) {}
                return
            }
            val parts = requestLine.split(" ")
            if (parts.size < 3) {
                respond(client, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
                return
            }
            val method = parts[0].uppercase()

            if (method == "CONNECT") {
                val (host, port) = splitHostPort(parts[1], 443)
                client.soTimeout = 0
                val upstream = try {
                    dial(host, port).also { liveSockets.add(it); liveSockets.add(client) }
                } catch (e: Exception) {
                    respond(client, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
                    return
                }
                val up = upstream
                up.soTimeout = 0
                client.getOutputStream().apply {
                    write("HTTP/1.1 200 Connection Established\r\n\r\n".toByteArray())
                    flush()
                }
                // Bytes the client pipelined after its CONNECT header (early
                // TLS ClientHello, pipelining stacks) belong to the UPSTREAM.
                // The old code wrote them back to the client — the tunnel
                // client received its own bytes and the server never saw the
                // handshake, hanging until both sides timed out.
                if (parsed.rest.isNotEmpty()) {
                    up.getOutputStream().apply { write(parsed.rest); flush() }
                }
                pump(client, up)
            } else {
                // Absolute-form: "GET http://host[:port]/path HTTP/1.1".
                val url = parts[1]
                if (!url.startsWith("http://")) {
                    respond(client, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
                    return
                }
                val rest = url.substring("http://".length)
                val slash = rest.indexOf('/')
                val authority = if (slash >= 0) rest.substring(0, slash) else rest
                val path = if (slash >= 0) rest.substring(slash) else "/"
                val (host, port) = splitHostPort(authority, 80)
                val upstream = try {
                    dial(host, port).also { liveSockets.add(it); liveSockets.add(client) }
                } catch (e: Exception) {
                    respond(client, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
                    return
                }
                client.soTimeout = 0
                // Rewrite the request line to origin-form, keep every other
                // header as sent, and make sure a Host header exists.
                val out = upstream.getOutputStream()
                val sb = StringBuilder("$method $path ${parts[2]}\r\n")
                var hasHost = false
                for (i in 1 until lines.size) {
                    val l = lines[i]
                    if (l.isEmpty()) break
                    if (l.startsWith("Host:", ignoreCase = true)) hasHost = true
                    sb.append(l).append("\r\n")
                }
                if (!hasHost) sb.append("Host: ").append(authority).append("\r\n")
                sb.append("\r\n")
                out.write(sb.toString().toByteArray(Charsets.UTF_8))
                if (parsed.rest.isNotEmpty()) out.write(parsed.rest)
                out.flush()
                pump(client, upstream)
            }
        } catch (_: Exception) {
            // Any throw after dial() used to leak the upstream socket (only
            // the client was closed) — a forwarded SOCKS channel burned per
            // aborted request.
            try { client.close() } catch (_: Exception) {}
        } finally {
            liveSockets.remove(client)
        }
    }

    /** `host:port` / `[ipv6]:port` / bare host (defaultPort). The old
     *  `trim('[' ,']')` + lastIndexOf(':') combo parsed `[::1]:8443` into the
     *  host `::1]:8443` and port 443, and a bare `2001:db8::1` into host
     *  `2001:db8:` port 1 — literal addresses that can never resolve. */
    private fun splitHostPort(target: String, defaultPort: Int): Pair<String, Int> {
        val t = target.trim()
        if (t.startsWith("[")) {
            val close = t.indexOf(']')
            if (close > 0) {
                val h = t.substring(1, close)
                val after = t.substring(close + 1)
                val p = if (after.startsWith(":")) after.substring(1).toIntOrNull() else null
                return h to (p ?: defaultPort)
            }
        }
        val colon = t.lastIndexOf(':')
        if (colon > 0 && !t.substring(0, colon).contains(':')) {
            val p = t.substring(colon + 1).toIntOrNull()
            if (p != null) return t.substring(0, colon) to p
        }
        return t to defaultPort
    }

    /** Dial through the SOCKS server. The hostname is resolved on the CLIENT
     *  preferring IPv4 (matching DarkTunnel): the SSH exit then connects over
     *  IPv4 and the public-IP check reports an IPv4 address — sending the bare
     *  hostname instead let the server's resolver pick AAAA and the exit went
     *  v6. IPv6-only hostnames fall back to the unresolved name (resolved at
     *  the proxy). */
    private fun dial(host: String, port: Int): Socket {
        val s = Socket(Proxy(Proxy.Type.SOCKS, InetSocketAddress(socksHost, socksPort)))
        s.tcpNoDelay = true
        s.connect(resolvePreferV4(host, port), 12_000)
        return s
    }

    private fun resolvePreferV4(host: String, port: Int): InetSocketAddress {
        if (host.isEmpty()) return InetSocketAddress.createUnresolved(host, port)
        return try {
            val v4 = java.net.InetAddress.getAllByName(host)
                .firstOrNull { it is java.net.Inet4Address }
            if (v4 != null) InetSocketAddress(v4, port)
            else InetSocketAddress.createUnresolved(host, port)
        } catch (_: Exception) {
            InetSocketAddress.createUnresolved(host, port)
        }
    }

    private fun readHead(input: InputStream): Parsed? {
        val buf = ByteArray(8192)
        val out = ByteArrayOutputStream()
        while (out.size() < 64 * 1024) {
            val n = input.read(buf)
            if (n < 0) return null
            out.write(buf, 0, n)
            val bytes = out.toByteArray()
            val s = String(bytes, Charsets.ISO_8859_1)
            val idx = s.indexOf("\r\n\r\n")
            if (idx >= 0) {
                return Parsed(s.substring(0, idx), bytes.copyOfRange(idx + 4, bytes.size))
            }
        }
        return null
    }

    private fun respond(client: Socket, raw: String) {
        try {
            client.getOutputStream().apply { write(raw.toByteArray()); flush() }
        } catch (_: Exception) {}
        try { client.close() } catch (_: Exception) {}
    }

    /** Byte pipe in both directions until either side closes. */
    private fun pump(a: Socket, b: Socket) {
        liveSockets.add(a); liveSockets.add(b)
        val t = Thread({
            copy(a.getInputStream(), b.getOutputStream())
            closeBoth(a, b)
        }, "snapdark-bridge-pump")
        t.isDaemon = true
        t.start()
        copy(b.getInputStream(), a.getOutputStream())
        closeBoth(a, b)
    }

    private fun copy(input: InputStream, output: OutputStream) {
        try {
            val buf = ByteArray(16 * 1024)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                output.write(buf, 0, n)
                output.flush()
            }
        } catch (_: Exception) {}
    }

    private fun closeBoth(a: Socket, b: Socket) {
        try { a.close() } catch (_: Exception) {}
        try { b.close() } catch (_: Exception) {}
    }
}
