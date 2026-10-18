package com.sensei.tunnel

import android.util.Log
import java.io.DataInputStream
import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.net.Socket
import java.net.SocketException
import java.util.concurrent.Executors
import java.util.concurrent.ThreadFactory
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/**
 * Local UDP DNS gateway that answers queries over TCP through a SOCKS5 proxy.
 *
 * SSH dynamic port forwarding (`-D`) only implements the SOCKS `CONNECT` command —
 * there is no `UDP ASSOCIATE`, so nothing UDP can traverse an SSH tunnel. Plain
 * UDP DNS therefore dies in SSH mode and every lookup fails even though the
 * tunnel itself is healthy.
 *
 * tun2socks can redirect port-53 traffic to a gateway address (`--dnsgw`). This
 * class is that gateway: it takes the UDP query, re-frames it as RFC 1035
 * DNS-over-TCP (2-byte length prefix), sends it through the SOCKS proxy to the
 * upstream resolver, and returns the answer as UDP.
 *
 * Non-DNS UDP (QUIC, etc.) still cannot cross an SSH tunnel; clients fall back to
 * TCP, which is the expected behaviour for SSH tunnels.
 */
class DnsUdpToTcpGateway(
    private val listenPort: Int,
    private val socksHost: String,
    private val socksPort: Int,
    private val upstreamDns: List<String>,
) {
    companion object {
        private const val TAG = "DnsGateway"
        private const val MAX_UDP_DNS = 1500
        private const val CONNECT_TIMEOUT_MS = 4000
        private const val QUERY_TIMEOUT_MS = 6000
        private const val RESOLVER_COOLDOWN_MS = 30_000L
        private val NEXT_ID = AtomicInteger(1)
    }

    private val running = AtomicBoolean(false)
    private var socket: DatagramSocket? = null
    private var thread: Thread? = null
    // Bounded pool: a cached pool let every retransmit of every stuck query
    // spawn a fresh thread + SOCKS dial — with a black-holed upstream the
    // resolver (bionic retries after ~2 s) piled threads up without limit.
    // CallerRunsPolicy just slows the receive loop when saturated.
    private val workers = java.util.concurrent.ThreadPoolExecutor(
        2, 8, 30L, java.util.concurrent.TimeUnit.SECONDS,
        java.util.concurrent.LinkedBlockingQueue(64),
        object : ThreadFactory {
            private val n = AtomicInteger(1)
            override fun newThread(r: Runnable): Thread =
                Thread(r, "dnsgw-${n.getAndIncrement()}").apply { isDaemon = true }
        },
        java.util.concurrent.ThreadPoolExecutor.CallerRunsPolicy(),
    )

    /** Port actually bound (differs from [listenPort] when it walked past an
     *  address already in use — a reconnect racing the previous session's
     *  gateway teardown used to abort the whole connect with EADDRINUSE). */
    var actualPort: Int = listenPort
        private set

    /** Bind the UDP listener. Returns the port actually bound. Walks a few
     *  neighbouring ports before falling back to an ephemeral one. */
    fun start(): Int {
        var ds: DatagramSocket? = null
        var bound = listenPort
        // Quick rebinds after a fast disconnect/reconnect can hit the old
        // socket's lingering state; walk up rather than failing the connect.
        for (candidate in listenPort..listenPort + 16) {
            try {
                ds = DatagramSocket(InetSocketAddress("127.0.0.1", candidate))
                bound = candidate
                break
            } catch (e: SocketException) {
                if (candidate == listenPort + 16) {
                    ds = DatagramSocket(InetSocketAddress("127.0.0.1", 0))
                    bound = ds.localPort
                    break
                }
            }
        }
        actualPort = bound
        socket = ds
        running.set(true)
        thread = Thread { loop(ds!!) }.apply { isDaemon = true; start() }
        Log.i(TAG, "DNS gateway on 127.0.0.1:$bound via socks $socksHost:$socksPort -> $upstreamDns")
        return bound
    }

    fun stop() {
        running.set(false)
        try { socket?.close() } catch (_: Exception) {}
        socket = null
        workers.shutdownNow()
    }

    private fun loop(ds: DatagramSocket) {
        val buf = ByteArray(MAX_UDP_DNS)
        while (running.get()) {
            val packet = DatagramPacket(buf, buf.size)
            try {
                ds.receive(packet)
            } catch (e: SocketException) {
                if (running.get()) Log.w(TAG, "receive failed: ${e.message}")
                break
            } catch (e: Exception) {
                if (running.get()) Log.w(TAG, "receive error: ${e.message}")
                continue
            }
            val query = packet.data.copyOfRange(packet.offset, packet.offset + packet.length)
            val from = packet.socketAddress
            try {
                workers.execute { resolve(ds, query, from) }
            } catch (_: Exception) {
                // Only a shutdown may reject now; a full queue runs inline.
                if (!running.get()) break
            }
        }
    }

    /** Spec → epoch ms until which it is skipped (a dead resolver used to be
     *  retried — with full timeouts — on EVERY query, stalling all lookups for
     *  8–16 s while the healthy secondary waited its turn). */
    private val resolverCooldown = java.util.concurrent.ConcurrentHashMap<String, Long>()

    private fun resolve(ds: DatagramSocket, query: ByteArray, from: java.net.SocketAddress) {
        val id = NEXT_ID.getAndIncrement()
        val now = System.currentTimeMillis()
        for (server in upstreamDns) {
            val (host, port) = splitHostPort(server)
            if (host.isBlank()) continue
            if ((resolverCooldown[server] ?: 0L) > now) continue
            try {
                val answer = queryOverSocks(host, port, query)
                resolverCooldown.remove(server)
                ds.send(DatagramPacket(answer, answer.size, from))
                return
            } catch (e: Exception) {
                resolverCooldown[server] = now + RESOLVER_COOLDOWN_MS
                Log.d(TAG, "dns[$id] via $host:$port failed (cooling ${RESOLVER_COOLDOWN_MS / 1000}s): ${e.javaClass.simpleName}: ${e.message}")
            }
        }
        Log.w(TAG, "dns[$id] no upstream answered; dropping query")
    }

    /** Split a DNS server spec into host + port. Handles `1.1.1.1`,
     *  `1.1.1.1:53`, `[fd00::c]:53` and BARE IPv6 (`2001:4860:4860::8888`).
     *  The old `substringBeforeLast(':')` turned every IPv6 address into
     *  garbage (host `2001:4860:4860:`, port `8888`) which was then sent to
     *  the SOCKS proxy as a *domain* — silently unresolvable forever. */
    private fun splitHostPort(server: String): Pair<String, Int> {
        val t = server.trim()
        if (t.startsWith("[")) {
            val close = t.indexOf(']')
            if (close > 0) {
                val h = t.substring(1, close)
                val after = t.substring(close + 1)
                val p = if (after.startsWith(":")) after.substring(1).toIntOrNull() else null
                return h to (p ?: 53)
            }
        }
        val colon = t.lastIndexOf(':')
        if (colon > 0 && !t.substring(0, colon).contains(':')) {
            val p = t.substring(colon + 1).toIntOrNull()
            if (p != null) return t.substring(0, colon) to p
        }
        return t to 53
    }

    /** One DNS-over-TCP exchange through the SOCKS5 proxy. */
    private fun queryOverSocks(dnsHost: String, dnsPort: Int, query: ByteArray): ByteArray {
        Socket().use { sock ->
            sock.tcpNoDelay = true
            sock.connect(InetSocketAddress(socksHost, socksPort), CONNECT_TIMEOUT_MS)
            sock.soTimeout = QUERY_TIMEOUT_MS
            val out = sock.getOutputStream()
            val input = DataInputStream(sock.getInputStream())

            // SOCKS5 greeting: one method, "no authentication".
            out.write(byteArrayOf(0x05, 0x01, 0x00)); out.flush()
            val greeting = ByteArray(2)
            input.readFully(greeting)
            if (greeting[0] != 0x05.toByte() || greeting[1] != 0x00.toByte()) {
                throw IOException("socks greeting rejected (${greeting[0]},${greeting[1]})")
            }

            // CONNECT to the resolver. Send a literal IPv4 when we have one so the
            // proxy never has to resolve a name (it could not, at this point).
            val request = ArrayList<Byte>(32)
            request.add(0x05); request.add(0x01); request.add(0x00)
            val literal = parseIpv4(dnsHost)
            if (literal != null) {
                request.add(0x01)
                literal.forEach { request.add(it) }
            } else {
                val nameBytes = dnsHost.toByteArray(Charsets.US_ASCII)
                if (nameBytes.size > 255) throw IOException("resolver name too long")
                request.add(0x03)
                request.add(nameBytes.size.toByte())
                nameBytes.forEach { request.add(it) }
            }
            request.add(((dnsPort shr 8) and 0xff).toByte())
            request.add((dnsPort and 0xff).toByte())
            out.write(request.toByteArray()); out.flush()

            // Reply: VER REP RSV ATYP BND.ADDR BND.PORT
            val head = ByteArray(4)
            input.readFully(head)
            if (head[1] != 0x00.toByte()) throw IOException("socks connect failed rep=${head[1]}")
            when (head[3].toInt() and 0xff) {
                0x01 -> input.skipBytes(4)
                0x03 -> input.skipBytes((input.readByte().toInt() and 0xff))
                0x04 -> input.skipBytes(16)
                else -> throw IOException("socks reply atyp=${head[3]}")
            }
            input.skipBytes(2) // bound port

            // DNS over TCP: 2-byte big-endian length prefix in both directions.
            out.write(byteArrayOf(((query.size shr 8) and 0xff).toByte(), (query.size and 0xff).toByte()))
            out.write(query)
            out.flush()

            val lenBuf = ByteArray(2)
            input.readFully(lenBuf)
            val len = ((lenBuf[0].toInt() and 0xff) shl 8) or (lenBuf[1].toInt() and 0xff)
            if (len <= 0 || len > 65535) throw IOException("bad dns tcp length $len")
            val answer = ByteArray(len)
            input.readFully(answer)
            return answer
        }
    }

    private fun parseIpv4(host: String): ByteArray? {
        val parts = host.split('.')
        if (parts.size != 4) return null
        val out = ByteArray(4)
        for (i in 0..3) {
            val n = parts[i].toIntOrNull() ?: return null
            if (n < 0 || n > 255) return null
            out[i] = n.toByte()
        }
        return out
    }
}
