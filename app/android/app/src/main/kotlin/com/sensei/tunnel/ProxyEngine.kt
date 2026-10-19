package com.sensei.tunnel

import android.net.VpnService
import android.util.Log
import java.io.EOFException
import java.io.InputStream
import java.io.OutputStream
import java.net.ConnectException
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.Collections
import java.util.concurrent.ConcurrentHashMap

/**
 * Local SOCKS5 server that tun2socks (and the E2E probe) use as the outbound
 * for proxy-family configs (protocol socks / http_proxy):
 *
 *   tun2socks ──SOCKS5──▶ [this 127.0.0.1:10808] ──SOCKS5 / HTTP CONNECT──▶ configured proxy ──▶ internet
 *
 * The SERVICE owns the TUN and runs tun2socks; this engine never touches the
 * TUN (the old build established a second one nobody read). Every upstream
 * socket is [VpnService.protect]ed before dialing so the tunnel never sees
 * its own traffic. Handshake replies go to the CLIENT; the upstream side
 * speaks the mode's protocol (SOCKS5 with optional RFC1929 user/pass, or
 * HTTP CONNECT with Proxy-Authorization inside the header block).
 *
 * Listener is loopback-only and is closed by [stop] together with every
 * in-flight socket, so a reconnect cannot hit "port in use".
 */
class ProxyEngine(
    private val vpnService: VpnService,
    private val mode: String,
    private val host: String,
    private val port: Int,
    private val user: String,
    private val pass: String,
    private val onExit: (String?) -> Unit,
) {
    private var serverSocket: ServerSocket? = null

    @Volatile
    private var running = false

    private val openSockets: MutableSet<Socket> =
        Collections.newSetFromMap(ConcurrentHashMap())

    fun start(): Boolean {
        return try {
            val ss = ServerSocket()
            ss.reuseAddress = true
            ss.bind(InetSocketAddress("127.0.0.1", LISTEN_PORT), 64)
            serverSocket = ss
            running = true
            Thread({ acceptLoop() }, "proxy-accept").apply {
                isDaemon = true
            }.start()
            Log.i(
                TAG,
                "local SOCKS5 on 127.0.0.1:$LISTEN_PORT → $mode upstream $host:$port " +
                    "(auth=${user.isNotEmpty()})",
            )
            true
        } catch (e: Exception) {
            onExit(e.message)
            false
        }
    }

    private fun acceptLoop() {
        while (running) {
            try {
                val client = serverSocket?.accept() ?: break
                openSockets.add(client)
                Thread({ handleClient(client) }, "proxy-client").apply {
                    isDaemon = true
                }.start()
            } catch (e: Exception) {
                if (running) onExit(e.message)
                break
            }
        }
    }

    private fun handleClient(client: Socket) {
        var upstream: Socket? = null
        try {
            client.soTimeout = HANDSHAKE_TIMEOUT_MS
            val input = client.getInputStream()
            val output = client.getOutputStream()

            // 1) SOCKS5 greeting. The service's bind probe connects and hangs
            //    up immediately — that lands here as EOF: drop it quietly and
            //    never dial the upstream for a non-conversation.
            try {
                ProxyProtocol.readGreeting(input)
            } catch (_: EOFException) {
                return
            } catch (e: ProxyProtocol.ProtocolException) {
                Log.w(TAG, "bad client greeting: ${e.message}")
                return
            }
            output.write(ProxyProtocol.methodSelectNoAuth())
            output.flush()

            // 2) SOCKS5 request → where the client wants to go.
            val req = try {
                ProxyProtocol.readRequest(input)
            } catch (_: EOFException) {
                return
            } catch (e: ProxyProtocol.ProtocolException) {
                try {
                    output.write(ProxyProtocol.reply(ProxyProtocol.REP_ADDRESS_TYPE_NOT_SUPPORTED))
                    output.flush()
                } catch (_: Exception) {
                }
                Log.w(TAG, "bad client request: ${e.message}")
                return
            }

            if (req.cmd != ProxyProtocol.CMD_CONNECT) {
                output.write(ProxyProtocol.reply(ProxyProtocol.REP_COMMAND_NOT_SUPPORTED))
                output.flush()
                return
            }

            // 3) Dial the configured proxy OUTSIDE the tunnel, then 4) run the
            //    upstream handshake. Any failure maps to a SOCKS reply code
            //    for the client — a dead server must look like a refused
            //    connection, never like a silent hang or a fake success.
            val rep = try {
                val up = Socket()
                if (!vpnService.protect(up)) {
                    up.close()
                    ProxyProtocol.REP_GENERAL_FAILURE
                } else {
                    openSockets.add(up)
                    upstream = up
                    up.connect(InetSocketAddress(host, port), UPSTREAM_CONNECT_TIMEOUT_MS)
                    if (mode == "socks") {
                        ProxyProtocol.negotiateUpstreamSocks(
                            up.getInputStream(), up.getOutputStream(), user, pass,
                        )
                        up.getOutputStream().write(req.raw)
                        up.getOutputStream().flush()
                        ProxyProtocol.readUpstreamReply(up.getInputStream())
                    } else {
                        up.getOutputStream().write(
                            ProxyProtocol.buildConnect(req.host, req.port, user, pass),
                        )
                        up.getOutputStream().flush()
                        ProxyProtocol.httpCodeToRep(
                            ProxyProtocol.readConnectResponse(up.getInputStream()),
                        )
                    }
                }
            } catch (e: ConnectException) {
                Log.w(TAG, "upstream $host:$port refused: ${e.message}")
                ProxyProtocol.REP_CONNECTION_REFUSED
            } catch (e: SocketTimeoutException) {
                Log.w(TAG, "upstream $host:$port timed out")
                ProxyProtocol.REP_HOST_UNREACHABLE
            } catch (e: ProxyProtocol.ProtocolException) {
                Log.w(TAG, "upstream protocol error: ${e.message}")
                ProxyProtocol.REP_GENERAL_FAILURE
            } catch (e: Exception) {
                Log.w(TAG, "upstream failed: ${e.message}")
                ProxyProtocol.REP_GENERAL_FAILURE
            }

            // 5) THE reply goes to the CLIENT (the old build wrote a stray
            //    0x05 byte into the upstream stream and never answered).
            output.write(ProxyProtocol.reply(rep))
            output.flush()
            if (rep != ProxyProtocol.REP_SUCCESS) return

            // 6) Full-duplex relay until either side closes.
            client.soTimeout = 0
            upstream?.soTimeout = 0
            val up = upstream ?: return
            relay(client, up)
        } catch (e: Exception) {
            // Client vanished mid-handshake (cancel, probe, app pause).
            if (running) Log.d(TAG, "client dropped: ${e.message}")
        } finally {
            closeQuietly(client)
            closeQuietly(upstream)
            openSockets.remove(client)
            upstream?.let { openSockets.remove(it) }
        }
    }

    private fun relay(a: Socket, b: Socket) {
        val t1 = Thread({ copyStream(a.getInputStream(), b.getOutputStream()) }, "proxy-r1")
            .apply { isDaemon = true }
        val t2 = Thread({ copyStream(b.getInputStream(), a.getOutputStream()) }, "proxy-r2")
            .apply { isDaemon = true }
        t1.start()
        t2.start()
        t1.join()
        // One direction ended means the flow is over: closing the pair unblocks
        // the sibling thread's read instead of leaving it parked forever.
        closeQuietly(a)
        closeQuietly(b)
        t2.join(RELAY_JOIN_TIMEOUT_MS)
    }

    private fun copyStream(input: InputStream, output: OutputStream) {
        try {
            val buf = ByteArray(16 * 1024)
            while (true) {
                val n = input.read(buf)
                if (n == -1) break
                output.write(buf, 0, n)
                output.flush()
            }
        } catch (_: Exception) {
        }
    }

    private fun closeQuietly(sock: Socket?) {
        try {
            sock?.close()
        } catch (_: Exception) {
        }
    }

    fun stop() {
        running = false
        try {
            serverSocket?.close()
        } catch (_: Exception) {
        }
        serverSocket = null
        // Snapshot first: the set is concurrent, but iteration + removal from
        // the accept/client threads racing close() must not surprise either side.
        for (s in openSockets.toList()) closeQuietly(s)
        openSockets.clear()
    }

    companion object {
        private const val TAG = "ProxyEngine"
        const val LISTEN_PORT = 10808
        private const val HANDSHAKE_TIMEOUT_MS = 8_000
        private const val UPSTREAM_CONNECT_TIMEOUT_MS = 10_000
        private const val RELAY_JOIN_TIMEOUT_MS = 1_000L
    }
}
