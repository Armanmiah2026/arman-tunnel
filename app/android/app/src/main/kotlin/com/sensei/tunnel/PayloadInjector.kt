package com.sensei.tunnel

import android.os.Build
import android.util.Log
import java.io.BufferedInputStream
import java.io.FileDescriptor
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.io.PushbackInputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.Collections
import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.ThreadFactory
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import javax.net.ssl.SNIHostName
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLParameters
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager
import java.security.SecureRandom

/**
 * Local TCP relay that performs injector-style HTTP "payload" injection in front
 * of the tunnel connection (SSH, OpenVPN or V2Ray/xray).
 *
 * Flow per accepted connection (the client connects to 127.0.0.1:[localPort]):
 *   1. open a socket to the upstream (a bug-host proxy, or the real server directly)
 *   2. optionally wrap it in TLS with a spoofed SNI (the `*_SNI` modes)
 *   3. write the rendered payload, if there is one
 *   4. consume whatever the upstream replies before the real protocol starts,
 *      as described by [prelude]
 *   5. pipe bytes bidirectionally between the client and upstream
 *
 * The tunnel engine then speaks its own protocol over the clean stream as if
 * 127.0.0.1 were the real server.
 *
 * A blank [payloadTemplate] means "inject nothing": the `*_SNI` modes then act as
 * a plain TLS wrapper (stunnel-style port-443 SSH / OpenVPN over TLS), which is a
 * real configuration that must not have a synthetic `CONNECT` bolted onto it. The
 * default `CONNECT` request is only supplied for the PROXY modes, where an HTTP
 * proxy genuinely requires one.
 */
class PayloadInjector(
    private val mode: Mode,
    private val targetHost: String,
    private val targetPort: Int,
    private val proxyHost: String,
    private val proxyPort: Int,
    private val sni: String,
    payloadTemplate: String,
    private val payloadEnhanced: Boolean = false,
    private val prelude: Prelude = Prelude.SSH_BANNER,

    /**
     * The downstream client speaks WebSocket (xray ws transport) and the
     * injected payload may be ANY content type — the v2rayinject.py server
     * consumes it for routing and performs the real backend handshake itself.
     * In that flow xray's own handshake must never reach the wire: this relay
     * terminates the handshake locally (answers xray's `GET … Upgrade:
     * websocket` with a computed `101`) and then shuttles frames. Payloads that
     * open with an `HTTP/` status line use the two-phase dance instead.
     */
    private val terminateWs: Boolean = false,
    private val tcpKeepaliveIdleSec: Int = 30,

    /**
     * How the LOCAL client talks to this relay.
     *
     * [Frontend.RAW] — the client dials 127.0.0.1:port and immediately speaks
     * its own protocol (SSH, xray). The target is fixed at construction.
     *
     * [Frontend.HTTP_CONNECT] — the relay behaves like an HTTP proxy: the client
     * sends `CONNECT host:port HTTP/1.1` first, and the relay answers
     * `HTTP/1.0 200 Connection Established` once the upstream is ready. This is
     * what OpenVPN3 does when the profile carries `http-proxy 127.0.0.1 <port>`,
     * and it is the only way to front OpenVPN without rewriting `remote` (which
     * breaks multi-remote profiles and hides the real host from the payload).
     */
    private val frontend: Frontend = Frontend.RAW,

    /**
     * Force an outer TLS wrap with the spoofed SNI even in DIRECT_SNI mode
     * (the SNI-fronted OpenVPN shape: outer TLS → raw inner OpenVPN bytes,
     * stunnel-style). Without this, DIRECT_SNI relays cleartext and only
     * rewrites a raw ClientHello in flight — which can never fire for OpenVPN,
     * because ovpn3 frames its TLS inside its own control packets. A blank
     * payload stays blank: the front pipes whatever follows the handshake
     * straight to the backend (OpenVPN Lite's CONNECT dance is local to it).
     */
    private val wrapOuterTls: Boolean = false,

    /**
     * Hook to call [android.net.VpnService.protect] on every upstream socket.
     *
     * Mandatory whenever the tunnel engine builds its OWN TUN interface
     * (OpenVPN3 does): the relay's socket to the real server must stay OUTSIDE
     * that TUN, otherwise the bytes that are supposed to establish the tunnel
     * are routed into the not-yet-established tunnel and the dial deadlocks.
     * Relying on `addDisallowedApplication(self)` alone is not enough — it is
     * best-effort and OEM-dependent.
     */
    private val socketProtector: ((Socket) -> Boolean)? = null,
) {
    enum class Mode { DIRECT, DIRECT_SNI, PROXY, PROXY_SNI }

    enum class Frontend { RAW, HTTP_CONNECT }

    /**
     * What the upstream is expected to emit between the injected payload and the
     * start of the real tunnel protocol.
     *
     * Only SSH has a greeting the relay can synchronise on. OpenVPN and xray
     * speak first, so for them the relay must stop after the HTTP response
     * headers (if any) instead of waiting for a banner that never arrives.
     */
    enum class Prelude { SSH_BANNER, HTTP_HEADERS }

    companion object {
        private const val TAG = "PayloadInjector"

        /**
         * Upper bound on prelude bytes. Kept below the per-connection pushback
         * buffer so `unread()` can never overflow.
         */
        private const val PRELUDE_MAX_BYTES = 16384
        private const val PUSHBACK_BUFFER_BYTES = 32768
        private const val PRELUDE_READ_TIMEOUT_MS = 10000

        /**
         * How much of the upstream's pre-protocol reply to put in the log. The
         * log view renders HTML, so a panel's coloured response is readable
         * there — but a full page would drown the rest of the log.
         */
        private const val PRELUDE_LOG_MAX_CHARS = 2000

        /** How long the very first connection waits to see whether the upstream replies. */
        private const val REPLY_SNIFF_TIMEOUT_MS = 1500

        /**
         * How long to wait for the handshake-accept response in the fake-response
         * dance. Legit servers answer within an RTT of receiving the handshake;
         * a variant that never sends it must not stall the session for long.
         */
        private const val HANDSHAKE_ACCEPT_TIMEOUT_MS = 3000

        private const val SPLIT_DELAY_MS = 10L
        private const val LONG_SPLIT_DELAY_MS = 150L

        private val NEXT_CONN_ID = AtomicInteger(1)

        /** Segment separators produced by the `[split]` / `[delay_split]` tokens. */
        private const val SPLIT_MARK = "\u0000\u0001SPLIT\u0001\u0000"
        private const val DELAY_SPLIT_MARK = "\u0000\u0001DELAYSPLIT\u0001\u0000"

        private val UNKNOWN_TOKEN = Regex("\\[[^\\[\\]\\r\\n]{1,64}\\]", RegexOption.IGNORE_CASE)

        /**
         * `[rotate=URL]` — bug-host rotation: fetch the host list from [URL]
         * and substitute a different entry per connection. The list is cached
         * per process (a reconnect must not re-download); failures degrade to
         * an empty substitution rather than leaking the token.
         */
        private val ROTATE_TOKEN = Regex("\\[rotate=([^\\[\\]]+)]", RegexOption.IGNORE_CASE)
        private val rotateCache = java.util.concurrent.ConcurrentHashMap<String, List<String>>()

        /** spec → epoch ms of the last failed remote fetch (60 s cooldown). */
        private val rotateFailAt = java.util.concurrent.ConcurrentHashMap<String, Long>()
        private const val ROTATE_FAIL_COOLDOWN_MS = 60_000L

        /**
         * `[cr*N]` / `[lf*N]` / `[crlf*N]` / `[lfcr*N]` — line-repeat tokens
         * from injector share formats. Used to pad requests with batches of
         * line breaks without typing them out.
         */
        private val REPEAT_TOKEN =
            Regex("\\[(cr|lf|crlf|lfcr)\\*(\\d{1,3})]", RegexOption.IGNORE_CASE)

        /**
         * Injector share formats store CRLFs as literal `\r\n` escape text
         * inside the payload; their engines convert them to real CRLF on the
         * wire. Payloads pasted from other apps keep that form, so expand the
         * escapes before token rendering — otherwise the upstream receives one
         * giant line and multi-request response counting sees a single line.
         */
        private val ESCAPED_CRLF = Regex("\\\\r\\\\n")
        private val ESCAPED_LF = Regex("\\\\n")
        private val ESCAPED_CR = Regex("\\\\r")

        private val HTTP_METHODS = listOf(
            "CONNECT ", "GET ", "POST ", "PUT ", "HEAD ",
            "OPTIONS ", "PATCH ", "DELETE ", "TRACE ", "PURGE ",
        )


        fun modeFrom(name: String?): Mode = when (name?.lowercase()) {
            "directsni", "direct_sni" -> Mode.DIRECT_SNI
            "proxy" -> Mode.PROXY
            "proxysni", "proxy_sni" -> Mode.PROXY_SNI
            else -> Mode.DIRECT
        }
    }

    private val running = AtomicBoolean(false)
    private var serverSocket: ServerSocket? = null
    private var acceptThread: Thread? = null

    /** Live sockets, so [stop] can actually tear the relay down. */
    private val liveSockets: MutableSet<Socket> =
        Collections.synchronizedSet(mutableSetOf<Socket>())

    private val workers = Executors.newCachedThreadPool(object : ThreadFactory {
        private val n = AtomicInteger(1)
        override fun newThread(r: Runnable): Thread =
            Thread(r, "injector-${n.getAndIncrement()}").apply { isDaemon = true }
    })

    /**
     * The host whose name DPI should see (`[host]` placeholder / TLS SNI). An
     * explicit SNI / bug host wins in every mode — in plain PROXY mode it is the
     * only way to express a bug-host `Host:` header.
     */
    private val frontHost: String = if (sni.isNotBlank()) sni else targetHost

    private val usesProxy: Boolean get() = mode == Mode.PROXY || mode == Mode.PROXY_SNI
    // The SNI modes wrap the upstream in TLS: PROXY_SNI to the bug proxy,
    // DIRECT_SNI stunnel-style with the spoofed SNI (SSH "SSL(TCP)" configs and
    // BD panels whose WSS opener must ride inside the TLS — in cleartext the
    // ISP's transparent HTTP filter 302s it to filter.ncnd.robi.com.bd), and
    // wrapOuterTls when the caller forces it (SNI-fronted OpenVPN). Plain
    // DIRECT_SNI + HTTP_CONNECT without wrapOuterTls keeps the in-flight
    // ClientHello rewrite instead (never fires for OpenVPN; SSH is RAW).
    private val wrapsTls: Boolean get() =
        mode == Mode.DIRECT_SNI || mode == Mode.PROXY_SNI || wrapOuterTls

    /** Kept so the HTTP_CONNECT frontend can re-render `[raw]` per connection. */
    private val payloadTemplateRaw: String = payloadTemplate

    /** Round-robin cursor for `[rotate=URL]` bug-host rotation. Declared
     * before the payload metrics: the constructor-time render resolves
     * `[rotate=...]` tokens and touches these fields. */
    private val rotateCounter = AtomicInteger(0)
    private val repeatCounter = AtomicInteger(0)

    // (There used to be a `lastRotateHost` field here — shared instance state
    // that concurrent connections raced on, leaking one connection's rotated
    // bug host into another's [host] token. The render now threads the
    // resolved host through locally instead.)

    /** Payload split into segments at the `[split]` / `[delay_split]` boundaries. */
    private val payloadSegments: List<Segment> = buildSegments(payloadTemplate)

    /**
     * Number of HTTP request lines the payload carries — the front answers one
     * response per request before the tunnel's own bytes can ride the
     * connection. Multi-request payloads (CF warm-up + cache PURGE + the real
     * websocket upgrade) earn three responses, classic CONNECT payloads one.
     */
    private val payloadRequestCount: Int = payloadSegments  // construction-time hint; per-connection count wins
        .asSequence()
        .map { it.bytes.toString(Charsets.US_ASCII) }
        .flatMap { it.lineSequence() }
        .map { it.trimStart() }
        .count { line ->
            // "[method]" renders to "CONNECT …" in place, so a template line
            // led by the token is a request line too.
            line.startsWith("[method]", ignoreCase = true) ||
                HTTP_METHODS.any { line.startsWith(it, ignoreCase = true) }
        }

    /** True when [renderPayload] injected the auto WSS-upgrade opener. */
    private val usingSynthesizedWss: Boolean =
        frontend == Frontend.RAW && payloadTemplate.isBlank() && !usesProxy &&
            mode == Mode.DIRECT_SNI &&
            sni.isNotBlank() && !sni.equals(targetHost, ignoreCase = true)
    private val payloadLength: Int = payloadSegments.sumOf { it.bytes.size }
    private val payloadHead: String = payloadSegments.firstOrNull()?.bytes
        ?.toString(Charsets.US_ASCII)?.trimStart()?.uppercase().orEmpty()

    /** Payload opens with a request method (`GET /x HTTP/1.1`, `CONNECT …`). */
    private val payloadIsHttpRequest: Boolean =
        HTTP_METHODS.any { payloadHead.startsWith(it) }

    /**
     * Payload opens with a status line (`HTTP/1.1 200 OK`) — a fake-response
     * opener for `v2rayinject.py`-style servers: the server replies 101 at once,
     * then treats the client's NEXT header block (the tunnel's real handshake)
     * as the routable request and answers it with a second 101.
     */
    private val payloadIsHttpResponse: Boolean = payloadHead.startsWith("HTTP/")

    /**
     * Whether the upstream answers the payload with an HTTP response. Sniffed once
     * on the first connection and reused: probing per connection cost a fixed
     * stall on every dial, which is fatal for the xray path.
     */
    private val httpReplyExpected = AtomicReference<Boolean?>(null)

    private class Segment(val bytes: ByteArray, val delayAfterMs: Long)

    /**
     * Start listening; returns the local port the client should connect to.
     * Pass [fixedPort] > 0 to bind a specific port (used by the V2Ray path where
     * the xray config must reference the port up front); 0 picks an ephemeral one.
     */
    fun start(fixedPort: Int = 0): Int {
        val ss = ServerSocket()
        ss.reuseAddress = true
        ss.bind(InetSocketAddress("127.0.0.1", fixedPort))
        serverSocket = ss
        running.set(true)
        acceptThread = Thread { acceptLoop(ss) }.apply { isDaemon = true; start() }
        Log.i(
            TAG,
            "Injector listening on 127.0.0.1:${ss.localPort} mode=$mode front=$frontHost " +
                "payload=${payloadLength}B segments=${payloadSegments.size} tls=$wrapsTls",
        )
        return ss.localPort
    }

    fun stop() {
        running.set(false)
        try { serverSocket?.close() } catch (_: Exception) {}
        serverSocket = null
        // Close in-flight connections so their copy loops unblock instead of
        // lingering until the next read returns.
        val snapshot = synchronized(liveSockets) { liveSockets.toList() }
        snapshot.forEach { closeQuietly(it) }
        liveSockets.clear()
        workers.shutdownNow()
    }

    private fun acceptLoop(ss: ServerSocket) {
        while (running.get()) {
            val client = try {
                ss.accept()
            } catch (e: Exception) {
                if (!running.get() || ss.isClosed) break  // real shutdown
                // Transient accept failures are NORMAL on Android: ECONNABORTED
                // fires while a network interface flaps (wifi↔cell handover,
                // VPN reconfig) and EMFILE under fd pressure. The old code
                // broke out of the loop for them — the bound socket stayed,
                // `running` stayed true and every later dial completed at TCP
                // level but was never serviced: a zombie relay until the app
                // process was killed.
                Log.w(TAG, "accept failed (retrying): ${e.javaClass.simpleName}: ${e.message}")
                try {
                    Thread.sleep(250)
                } catch (_: InterruptedException) {
                    break
                }
                continue
            }
            try {
                workers.execute { handle(client) }
            } catch (_: Exception) {
                closeQuietly(client) // pool shut down mid-accept
            }
        }
    }

    private fun handle(client: Socket) {
        val connId = NEXT_CONN_ID.getAndIncrement()
        var upstream: Socket? = null
        track(client)
        try {
            client.tcpNoDelay = true
            // Client side needs pushback: the CONNECT frontend and the WS
            // terminator both read ahead here, and any bytes past what they
            // consumed must still flow to the relay.
            val clientInput = PushbackInputStream(
                BufferedInputStream(client.getInputStream(), 16384),
                PUSHBACK_BUFFER_BYTES,
            )

            // HTTP_CONNECT frontend: read and swallow the client's
            // `CONNECT host:port` request block before touching the upstream.
            // OpenVPN3's `http-proxy 127.0.0.1 <port>` speaks this.
            var connectRequestLine: String? = null
            if (frontend == Frontend.HTTP_CONNECT) {
                connectRequestLine = readConnectRequest(clientInput, connId)
                    ?: run {
                        closeQuietly(client)
                        return
                    }
            }

            var host = if (usesProxy) proxyHost else targetHost
            var port = if (usesProxy) proxyPort else targetPort
            // HTTP_CONNECT routing: an OpenVPN profile with multiple `remote`
            // lines fails over by sending CONNECT for the NEXT host — dialing
            // the construction-time targetHost regardless (the old behaviour)
            // sent failover attempts to the dead primary and broke ovpn3's
            // cert-name verification. Proxy modes keep dialing the bug host by
            // design (the payload carries the real target).
            if (frontend == Frontend.HTTP_CONNECT && !usesProxy) {
                parseConnectTarget(connectRequestLine)?.let { (h, p) ->
                    if (h.isNotBlank() && p > 0 && (h != host || p != port)) {
                        SenseiTunnelVpnService.emitLog(
                            "Injector[$connId]: dialing the client's CONNECT target $h:$p (was $host:$port)"
                        )
                        host = h
                        port = p
                    }
                }
            }
            if (host.isBlank() || port <= 0) {
                throw IOException("injector upstream not configured (host=$host port=$port)")
            }
            SenseiTunnelVpnService.emitLog(
                "Injector[$connId]: connect mode=$mode frontend=$frontend " +
                    "target=$targetHost:$targetPort upstream=$host:$port payload=${payloadLength}B"
            )
            // Dial the upstream with ONE retry on a fresh protected socket.
            // The first dial right after a session teardown can black-hole
            // (the SYN dies while the old network is still settling — the
            // symptom was "kexTimeout (12000 ms) expired" followed by an
            // instant success on the very next attempt). 5s + 6s keeps the
            // whole budget inside trilead's 12s banner/kex timeout.
            var protectedEarly = false
            var plain = Socket()
            var dialed = false
            var lastDialError: Exception? = null
            val dialTimeouts = intArrayOf(5000, 6000)
            for (attempt in dialTimeouts.indices) {
                val sock = Socket()
                var early = false
                try {
                    // Protect BEFORE connect: once the engine's own TUN is up, an
                    // unprotected socket's SYN goes into the tunnel it is trying
                    // to build, and the dial deadlocks. VpnService.protect() needs
                    // a real file descriptor, which a fresh unconnected Socket
                    // does not have — bind to an ephemeral local port first to
                    // materialize one.
                    if (socketProtector != null) {
                        try {
                            sock.bind(InetSocketAddress(0))
                            early = protectSocket(sock, connId, fatal = false)
                        } catch (e: Exception) {
                            Log.w(TAG, "pre-connect bind/protect: ${e.message}")
                        }
                    }
                    sock.connect(InetSocketAddress(host, port), dialTimeouts[attempt])
                    plain = sock
                    protectedEarly = early
                    dialed = true
                    if (attempt > 0) {
                        SenseiTunnelVpnService.emitLog(
                            "Injector[$connId]: upstream connected on attempt ${attempt + 1}"
                        )
                    }
                    break
                } catch (e: Exception) {
                    closeQuietly(sock)
                    lastDialError = e
                    SenseiTunnelVpnService.emitLog(
                        "Injector[$connId]: upstream dial $host:$port failed " +
                            "(${e.javaClass.simpleName}: ${e.message})" +
                            if (attempt == 0) " — retrying once" else ""
                    )
                }
            }
            if (!dialed) {
                throw lastDialError ?: IOException("upstream dial failed: $host:$port")
            }
            track(plain)
            upstream = plain
            plain.tcpNoDelay = true
            // Keep the upstream leg alive at the TCP layer. Without this an
            // OpenVPN session is completely silent after CONNECTED and any
            // ~7s idle timeout on the server/front-end drops it mid-session
            // (NETWORK_EOF_ERROR). The SSLSocket below shares this fd, so
            // setting it once on `plain` covers the outer TLS too.
            if (tcpKeepaliveIdleSec > 0) setShortTcpKeepalive(plain, tcpKeepaliveIdleSec)
            // Fall back to protecting the connected socket: still keeps the
            // session's payload out of the tunnel even if the early attempt
            // could not run.
            if (!protectedEarly) protectSocket(plain, connId)
            SenseiTunnelVpnService.emitLog("Injector[$connId]: upstream TCP connected")

            // PROXY_SNI (TLS to the bug proxy) or wrapOuterTls (SNI-fronted
            // OpenVPN front): wrap in TLS; the spoofed hostname rides in the
            // TLS handshake SNI.
            val us = wrapTlsIfNeeded(plain, host, port, connId)
            if (us !== plain) {
                // The SSLSocket owns `plain` and closes it; tracking both would
                // leak the plain reference for the relay's lifetime.
                liveSockets.remove(plain)
                track(us)
                upstream = us
            }

            val up = us.getOutputStream()
            val pushbackInput = PushbackInputStream(
                BufferedInputStream(us.getInputStream(), 16384),
                PUSHBACK_BUFFER_BYTES,
            )

            val sentRequests = writePayload(up, connId, connectRequestLine)
            val payloadSent = sentRequests > 0
            // The front answers exactly the requests that went on the wire.
            val expectResponses = if (payloadSent) sentRequests else payloadRequestCount

            // Injected-WS tunnel (TDZ Payload Proxy style): the server consumes
            // the payload block for routing, answers ONE fabricated 101, then
            // pipes everything else raw into the backend. So: swallow that
            // single 101, forward the tunnel's real handshake untouched, and
            // tolerate a SECOND 101 coming back from a real websocket backend.
            // Works for every payload content type — the server never inspects it.
            val injectedWs = terminateWs && payloadSent && prelude == Prelude.HTTP_HEADERS

            // Does the upstream answer with an HTTP response we must swallow?
            // Proxy modes always do. Otherwise sniff once, on the first
            // connection only, and cache the verdict for the relay's lifetime.
            var consumeHttp = usesProxy || injectedWs
            if (!consumeHttp && payloadSent && payloadIsHttpRequest) {
                consumeHttp = sniffHttpReply(us, pushbackInput, connId)
            }

            // Forwarding starts immediately for most modes. For DIRECT_SNI with a
            // spoofed SNI we must first read + rewrite the client's TLS
            // ClientHello (after the 200, see below), so defer the client->up
            // pump until that rewrite is done. Never in [wrapOuterTls] mode:
            // there the outer TLS already carries the SNI and the client speaks
            // OpenVPN (never a raw ClientHello).
            val sniRewrite = mode == Mode.DIRECT_SNI && !wrapOuterTls && sni.isNotBlank() &&
                frontend == Frontend.HTTP_CONNECT
            var t1: Future<*>? = if (!sniRewrite) {
                workers.submit(Runnable {
                    copy(clientInput, up, client, us, "client->upstream", connId)
                })
            } else null

            var failed = false
            when {
                injectedWs -> if (consumeHttpHeaders(pushbackInput, us, connId, expect101 = true) == null) failed = true
                payloadSent || consumeHttp -> {
                    val ready = when (prelude) {
                        Prelude.SSH_BANNER -> consumePreludeUntilSsh(pushbackInput, us, connId)
                        Prelude.HTTP_HEADERS ->
                            if (consumeHttp) consumePayloadResponses(pushbackInput, us, connId, expectResponses) else true
                    }
                    if (!ready) failed = true
                }
            }

            if (failed) {
                t1?.cancel(true)
                // Tell the local client the proxy leg failed instead of dropping
                // the socket silently — OpenVPN3 then logs a real proxy error.
                if (frontend == Frontend.HTTP_CONNECT) {
                    writeConnectStatus(client, "502 Bad Gateway")
                }
                closeQuietly(client)
                closeQuietly(us)
                return
            }

            // A real websocket backend behind the inject server answers the
            // forwarded handshake with its own 101 — swallow it too. Raw-protocol
            // backends send nothing here; after a short wait the plain relay
            // takes over with whatever bytes arrived.
            if (injectedWs && !awaitHandshakeAccept(pushbackInput, us, connId)) {
                t1?.cancel(true)
                if (frontend == Frontend.HTTP_CONNECT) {
                    writeConnectStatus(client, "502 Bad Gateway")
                }
                closeQuietly(client)
                closeQuietly(us)
                return
            }

            // Upstream is clean now, so the local client may start: answer its
            // CONNECT with a 200 exactly once, after the payload dance.
            if (frontend == Frontend.HTTP_CONNECT) {
                writeConnectStatus(client, "200 Connection Established")
                SenseiTunnelVpnService.emitLog(
                    "Injector[$connId]: answered client CONNECT with 200"
                )
            }

            // DIRECT_SNI + spoofed SNI: rewrite the client's TLS ClientHello SNI
            // in flight. The client (OpenVPN3) now starts its handshake; we read
            // the first TLS record (the ClientHello), swap the server_name for
            // the spoofed host, forward the patched record, then let the relay
            // pump the rest. No outer TLS wrap — the server still presents its
            // real certificate, which OpenVPN3 verifies against the profile's
            // <ca>; only the on-wire SNI is spoofed (DPI bypass). If the
            // ClientHello can't be parsed we fall back to a transparent relay.
            if (sniRewrite) {
                try {
                    val first = readTlsRecord(clientInput)
                    val out = if (first != null) rewriteSni(first, sni) else null
                    when {
                        out != null -> {
                            up.write(out)
                            up.flush()
                            SenseiTunnelVpnService.emitLog(
                                "Injector[$connId]: SNI rewritten to $sni " +
                                    "(${first!!.size}B -> ${out.size}B)"
                            )
                        }
                        first != null -> {
                            up.write(first)
                            up.flush()
                            SenseiTunnelVpnService.emitLog(
                                "Injector[$connId]: SNI rewrite skipped (unparsable ClientHello); relayed ${first.size}B raw"
                            )
                        }
                        else -> SenseiTunnelVpnService.emitLog(
                            "Injector[$connId]: SNI rewrite skipped (no ClientHello); relaying raw"
                        )
                    }
                } catch (e: Exception) {
                    SenseiTunnelVpnService.emitLog(
                        "Injector[$connId]: SNI rewrite failed: ${e.message}; relaying raw"
                    )
                }
                t1 = workers.submit(Runnable {
                    copy(clientInput, up, client, us, "client->upstream", connId)
                })
            }

            copy(pushbackInput, client.getOutputStream(), client, us, "upstream->client", connId)
        } catch (e: Exception) {
            val msg = "Injector[$connId]: relay error ${e.javaClass.simpleName}: ${e.message}"
            Log.w(TAG, msg)
            SenseiTunnelVpnService.emitLog(msg)
            if (frontend == Frontend.HTTP_CONNECT) {
                try { writeConnectStatus(client, "502 Bad Gateway") } catch (_: Exception) {}
            }
            closeQuietly(client)
            closeQuietly(upstream)
        }
    }

    /**
     * Keep the relay's upstream socket out of the tunnel the engine is building.
     * Returns whether the protect actually succeeded.
     */
    private fun protectSocket(socket: Socket, connId: Int, fatal: Boolean = true): Boolean {
        val protector = socketProtector ?: return true
        val ok = try {
            protector(socket)
        } catch (e: Exception) {
            Log.w(TAG, "protect failed: ${e.message}")
            false
        }
        if (!ok && fatal) {
            SenseiTunnelVpnService.emitLog(
                "Injector[$connId]: VpnService.protect() refused the upstream socket — " +
                    "traffic may loop into the tunnel"
            )
        }
        return ok
    }

    /**
     * Read the local client's `CONNECT host:port HTTP/1.1` request plus its
     * header block. Returns the request line (so `[netData]`/`[raw]` payload
     * tokens can reproduce it verbatim — the standard injector share
     * behavior), or null if
     * the client sent something this frontend cannot serve.
     */
    private fun readConnectRequest(input: PushbackInputStream, connId: Int): String? {
        val bytes = ArrayList<Byte>(512)
        val one = ByteArray(1)
        var prev1 = 0.toChar()
        var prev2 = 0.toChar()
        var prev3 = 0.toChar()
        while (bytes.size < PRELUDE_MAX_BYTES) {
            val n = try {
                input.read(one)
            } catch (e: Exception) {
                SenseiTunnelVpnService.emitLog(
                    "Injector[$connId]: client CONNECT read failed: ${e.javaClass.simpleName}"
                )
                return null
            }
            if (n <= 0) {
                SenseiTunnelVpnService.emitLog(
                    "Injector[$connId]: client closed before sending CONNECT (${bytes.size}B)"
                )
                return null
            }
            bytes.add(one[0])
            val c = one[0].toInt().toChar()
            val crlfCrlf = prev3 == '\r' && prev2 == '\n' && prev1 == '\r' && c == '\n'
            val lfLf = prev1 == '\n' && c == '\n'
            if (crlfCrlf || lfLf) break
            prev3 = prev2; prev2 = prev1; prev1 = c
        }
        val head = bytes.toByteArray().toString(Charsets.ISO_8859_1)
        val requestLine = head.lineSequence().firstOrNull()?.trim().orEmpty()
        if (!requestLine.uppercase().startsWith("CONNECT ")) {
            SenseiTunnelVpnService.emitLog(
                "Injector[$connId]: expected CONNECT from local client, got: " +
                    requestLine.take(80)
            )
            return null
        }
        SenseiTunnelVpnService.emitLog("Injector[$connId]: client CONNECT: $requestLine")
        return requestLine
    }

    /** Pull `host:port` out of a `CONNECT host:port HTTP/1.1` request line.
     *  Bracketed IPv6 (`[::1]:1194`) is handled; a bare host means default 443. */
    private fun parseConnectTarget(requestLine: String?): Pair<String, Int>? {
        val parts = requestLine?.trim()?.split(Regex("\\s+")) ?: return null
        if (parts.size < 2 || !parts[0].equals("CONNECT", ignoreCase = true)) return null
        val target = parts[1]
        return try {
            if (target.startsWith("[")) {
                val close = target.indexOf(']')
                if (close <= 0) return null
                val h = target.substring(1, close)
                val p = if (close + 1 < target.length && target[close + 1] == ':') {
                    target.substring(close + 2).toIntOrNull() ?: 443
                } else 443
                h to p
            } else {
                val colon = target.lastIndexOf(':')
                if (colon > 0 && !target.substring(0, colon).contains(':')) {
                    target.substring(0, colon) to (target.substring(colon + 1).toIntOrNull() ?: 443)
                } else {
                    target to 443
                }
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun writeConnectStatus(client: Socket, status: String) {
        val out = client.getOutputStream()
        out.write("HTTP/1.0 $status\r\n\r\n".toByteArray(Charsets.US_ASCII))
        out.flush()
    }

    /**
     * Write the payload segments, honouring `[split]` boundaries and enhanced mode.
     *
     * [connectRequestLine] is the request line the local client actually sent
     * (HTTP_CONNECT frontend only). When present, `[raw]`/`[netData]`-style
     * tokens are re-rendered against it, so the bytes on the wire carry the real
     * `CONNECT host:port HTTP/1.1` the engine asked for instead of a synthesized
     * one — that is what injector apps do, and some panels match on
     * it exactly.
     */
    /** Returns the number of HTTP request lines ACTUALLY written (0 = nothing
     *  sent). Not the construction-time count: `[random]`/`[repeat]` re-render
     *  per connection, and a variant with a different request count made the
     *  caller consume too few (front's extra responses pumped into the engine's
     *  handshake) or too many (stalls + bogus 502s) responses. */
    private fun writePayload(
        up: OutputStream,
        connId: Int,
        connectRequestLine: String? = null,
    ): Int {
        // Re-render per connection: `[raw]`/`[netData]` need the client's
        // request line, and `[rotate=...]` must advance per connection (the
        // construction-time render only fixes the initial segment metrics).
        val segments = buildSegments(payloadTemplateRaw, connectRequestLine)
        if (segments.isEmpty()) {
            SenseiTunnelVpnService.emitLog("Injector[$connId]: no payload (pass-through)")
            return 0
        }
        val requestCount = segments.countRequestLines()
        val totalBytes = segments.sumOf { it.bytes.size }
        for ((index, seg) in segments.withIndex()) {
            val bytes = seg.bytes
            val isLast = index == segments.lastIndex
            if (payloadEnhanced && bytes.size > 4) {
                // "Enhanced": split each segment across two TCP writes to defeat
                // simple inline-string DPI matching.
                val cut = bytes.size / 2
                up.write(bytes, 0, cut); up.flush()
                sleepQuietly(SPLIT_DELAY_MS)
                up.write(bytes, cut, bytes.size - cut); up.flush()
            } else {
                up.write(bytes); up.flush()
            }
            if (!isLast || seg.delayAfterMs > 0) sleepQuietly(seg.delayAfterMs)
        }
        SenseiTunnelVpnService.emitLog(
            "Injector[$connId]: payload sent ${totalBytes}B in ${segments.size} segment(s), " +
                "$requestCount request line(s) enhanced=$payloadEnhanced" +
                (if (usingSynthesizedWss) " (auto WSS upgrade)" else "")
        )
        return requestCount
    }

    /** Count request lines in rendered payload bytes (see writePayload). */
    private fun List<Segment>.countRequestLines(): Int = asSequence()
        .map { it.bytes.toString(Charsets.US_ASCII) }
        .flatMap { it.lineSequence() }
        .map { it.trimStart() }
        .count { line ->
            line.startsWith("[method]", ignoreCase = true) ||
                HTTP_METHODS.any { line.startsWith(it, ignoreCase = true) }
        }

    /**
     * Peek at the first bytes to see whether the upstream replied with an HTTP
     * response. Runs at most once per relay; every later connection reuses the
     * answer, so no connection after the first pays a stall.
     */
    private fun sniffHttpReply(sock: Socket, input: PushbackInputStream, connId: Int): Boolean {
        httpReplyExpected.get()?.let { return it }
        val prevTimeout = sock.soTimeout
        var verdict = false
        try {
            sock.soTimeout = REPLY_SNIFF_TIMEOUT_MS
            val buf = ByteArray(5)
            val n = input.read(buf)
            if (n > 0) {
                input.unread(buf, 0, n)
                verdict = String(buf, 0, n, Charsets.US_ASCII).startsWith("HTTP/", ignoreCase = true)
            }
        } catch (_: Exception) {
            // No early reply: the upstream speaks second.
        } finally {
            try { sock.soTimeout = prevTimeout } catch (_: Exception) {}
        }
        httpReplyExpected.compareAndSet(null, verdict)
        val cached = httpReplyExpected.get() ?: verdict
        SenseiTunnelVpnService.emitLog("Injector[$connId]: upstream httpReply=$cached (sniffed once)")
        return cached
    }

    /**
     * Wrap the upstream socket in TLS for the SNI modes so the tunnel rides
     * inside an encrypted stream (port-443 SSH / stunnel).
     *
     * A handshake failure is fatal on purpose: silently continuing in cleartext
     * used to leak the payload — and the credentials behind it — to the network
     * the user is trying to hide from.
     */
    // ---- TLS ClientHello SNI rewriting (DIRECT_SNI, no outer TLS) ----

    private fun u16(b: ByteArray, off: Int): Int =
        ((b[off].toInt() and 0xFF) shl 8) or (b[off + 1].toInt() and 0xFF)

    private fun u24(b: ByteArray, off: Int): Int =
        ((b[off].toInt() and 0xFF) shl 16) or
            ((b[off + 1].toInt() and 0xFF) shl 8) or
            (b[off + 2].toInt() and 0xFF)

    private fun putU16(out: ByteArray, off: Int, v: Int) {
        out[off] = (v shr 8).toByte()
        out[off + 1] = (v and 0xFF).toByte()
    }

    private fun putU24(out: ByteArray, off: Int, v: Int) {
        out[off] = (v shr 16).toByte()
        out[off + 1] = (v shr 8).toByte()
        out[off + 2] = (v and 0xFF).toByte()
    }

    /**
     * Read exactly one full TLS record from [input]. Returns the full record
     * bytes (header + body) or null on EOF / if the first byte isn't a
     * handshake record (in which case the header bytes are pushed back so the
     * caller can relay transparently).
     */
    private fun readTlsRecord(input: PushbackInputStream): ByteArray? {
        val header = ByteArray(5)
        var off = 0
        while (off < 5) {
            val n = input.read(header, off, 5 - off)
            if (n < 0) return null
            off += n
        }
        if (header[0] != 0x16.toByte()) {
            input.unread(header, 0, off)
            return null
        }
        val len = u16(header, 3)
        if (len <= 0 || len > 1 shl 16) return null
        val body = ByteArray(len)
        off = 0
        while (off < len) {
            val n = input.read(body, off, len - off)
            if (n < 0) return null
            off += n
        }
        val out = ByteArray(5 + len)
        System.arraycopy(header, 0, out, 0, 5)
        System.arraycopy(body, 0, out, 5, len)
        return out
    }

    /**
     * Parse a TLS ClientHello record and rewrite its SNI server_name to
     * [newSni], rebuilding all the length fields. Returns the patched record,
     * or null if it isn't a parsable ClientHello. If no SNI extension is
     * present one is added (OpenVPN3 omits SNI for IP literals), so the spoofed
     * host still appears on the wire.
     */
    private fun rewriteSni(record: ByteArray, newSni: String): ByteArray? {
        try {
            if (record.size < 5 || record[0] != 0x16.toByte()) return null
            val recLen = u16(record, 3)
            if (5 + recLen > record.size) return null
            val hsOff = 5
            if (record[hsOff] != 0x01.toByte()) return null // not ClientHello
            val hsLen = u24(record, hsOff + 1)
            val bodyOff = hsOff + 4
            val bodyEnd = bodyOff + hsLen
            if (bodyEnd > record.size) return null
            val body = record.copyOfRange(bodyOff, bodyEnd)

            var p = 0
            p += 2 // client_version
            if (p >= body.size) return null
            val sidLen = body[p].toInt() and 0xFF
            p += 1 + sidLen
            if (p + 2 > body.size) return null
            val csLen = u16(body, p)
            p += 2 + csLen
            if (p >= body.size) return null
            val compLen = body[p].toInt() and 0xFF
            p += 1 + compLen
            if (p + 2 > body.size) return null
            val extTotal = u16(body, p)
            val extStart = p
            val extEnd = p + 2 + extTotal
            if (extEnd > body.size) return null

            val newSniBytes = newSni.toByteArray(Charsets.US_ASCII)
            val newExts = ArrayList<Pair<Int, ByteArray>>()
            var q = extStart + 2
            var found = false
            while (q < extEnd) {
                if (q + 4 > extEnd) return null
                val extType = u16(body, q)
                val extLen = u16(body, q + 2)
                if (q + 4 + extLen > extEnd) return null
                val extData = body.copyOfRange(q + 4, q + 4 + extLen)
                if (extType == 0x0000) {
                    val entry = ByteArray(3 + newSniBytes.size)
                    entry[0] = 0; entry[1] = 0 // host_name
                    putU16(entry, 2, newSniBytes.size)
                    System.arraycopy(newSniBytes, 0, entry, 3, newSniBytes.size)
                    val newList = ByteArray(2 + entry.size)
                    putU16(newList, 0, entry.size)
                    System.arraycopy(entry, 0, newList, 2, entry.size)
                    val newExtData = ByteArray(2 + newList.size)
                    putU16(newExtData, 0, newList.size)
                    System.arraycopy(newList, 0, newExtData, 2, newList.size)
                    newExts.add(0x0000 to newExtData)
                    found = true
                } else {
                    newExts.add(extType to extData)
                }
                q += 4 + extLen
            }
            if (!found) {
                val entry = ByteArray(3 + newSniBytes.size)
                entry[0] = 0; entry[1] = 0
                putU16(entry, 2, newSniBytes.size)
                System.arraycopy(newSniBytes, 0, entry, 3, newSniBytes.size)
                val newList = ByteArray(2 + entry.size)
                putU16(newList, 0, entry.size)
                System.arraycopy(entry, 0, newList, 2, entry.size)
                val newExtData = ByteArray(2 + newList.size)
                putU16(newExtData, 0, newList.size)
                System.arraycopy(newList, 0, newExtData, 2, newList.size)
                newExts.add(0x0000 to newExtData)
            }

            var extsSize = 0
            for ((_, d) in newExts) extsSize += 4 + d.size
            val newBody = ByteArray(extStart + 2 + extsSize)
            System.arraycopy(body, 0, newBody, 0, extStart)
            putU16(newBody, extStart, extsSize)
            var w = extStart + 2
            for ((type, d) in newExts) {
                putU16(newBody, w, type)
                putU16(newBody, w + 2, d.size)
                System.arraycopy(d, 0, newBody, w + 4, d.size)
                w += 4 + d.size
            }

            val newRecord = ByteArray(9 + newBody.size)
            System.arraycopy(record, 0, newRecord, 0, 5)
            newRecord[5] = 0x01.toByte() // ClientHello
            putU24(newRecord, 6, newBody.size) // handshake length
            System.arraycopy(newBody, 0, newRecord, 9, newBody.size)
            putU16(newRecord, 3, 4 + newBody.size) // record length
            return newRecord
        } catch (e: Exception) {
            Log.w(TAG, "rewriteSni failed: ${e.message}")
            return null
        }
    }

    private fun wrapTlsIfNeeded(socket: Socket, host: String, port: Int, connId: Int): Socket {
        if (!wrapsTls) return socket
        val sniHost = sni.ifBlank { targetHost }
        // When the SNI is a spoofed/bug host (sni != the real upstream host), the
        // outer TLS is only a DPI-bypass transport: the server cert will not match
        // the SNI hostname. The inner tunnel protocol (OpenVPN remote-cert-tls,
        // SSH host key, etc.) does its own verification, so the outer handshake
        // must not abort on a hostname mismatch — otherwise every directSni config
        // dies at the outer TLS with a cert error before the engine ever starts.
        // wrapOuterTls (SNI-fronted OpenVPN) is ALWAYS trust-all: the front
        // presents its own cert regardless of the spoofed SNI, exactly like
        // OpenVPN Lite's SStream (it logs the peer CN and moves on).
        val trustAll = wrapOuterTls ||
            (sni.isNotBlank() && !sni.equals(targetHost, ignoreCase = true))
        try {
            val sslFactory = if (trustAll) {
                val trustAllManager = object : X509TrustManager {
                    override fun checkClientTrusted(chain: Array<out java.security.cert.X509Certificate>?, authType: String?) {}
                    override fun checkServerTrusted(chain: Array<out java.security.cert.X509Certificate>?, authType: String?) {}
                    override fun getAcceptedIssuers(): Array<java.security.cert.X509Certificate>? = null
                }
                val ctx = SSLContext.getInstance("TLS")
                ctx.init(null, arrayOf<TrustManager>(trustAllManager), SecureRandom())
                ctx.socketFactory
            } else {
                SSLSocketFactory.getDefault() as SSLSocketFactory
            }
            val ssl = sslFactory.createSocket(socket, host, port, true) as SSLSocket

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                val params = ssl.sslParameters ?: SSLParameters()
                try {
                    params.serverNames = listOf(SNIHostName(sniHost))
                } catch (_: IllegalArgumentException) {
                    Log.d(TAG, "SNI skipped (IP address or invalid): $sniHost")
                }
                ssl.sslParameters = params
            }

            ssl.startHandshake()
            SenseiTunnelVpnService.emitLog("Injector[$connId]: TLS established to $host:$port sni=$sniHost${if (trustAll) " (trust-all: spoofed SNI)" else ""}")
            return ssl
        } catch (e: Exception) {
            val msg = "Injector[$connId]: TLS handshake to $host:$port failed " +
                "(${e.javaClass.simpleName}: ${e.message}) — refusing to fall back to cleartext"
            Log.w(TAG, msg)
            SenseiTunnelVpnService.emitLog(msg)
            closeQuietly(socket)
            throw IOException(msg, e)
        }
    }

    /**
     * Discard every byte before the real SSH identification line.
     *
     * WebSocket/proxy injectors can return `HTTP/1.1 101` plus custom text before
     * the actual SSH stream. None of that can be handed to Trilead; KEX must start
     * only after a complete RFC-style SSH banner line is available.
     */
    private fun consumePreludeUntilSsh(input: PushbackInputStream, sock: Socket, connId: Int): Boolean {
        val bytes = ArrayList<Byte>(8192)
        try {
            val prevTimeout = sock.soTimeout
            sock.soTimeout = PRELUDE_READ_TIMEOUT_MS
            try {
                val one = ByteArray(1)
                var matched = 0
                var httpHeadersSeen = false
                while (bytes.size < PRELUDE_MAX_BYTES) {
                    val n = input.read(one)
                    if (n <= 0) return logNoSshPrelude(connId, bytes, "eof")
                    bytes.add(one[0])

                    val sshAt = findSshBannerStart(bytes)
                    if (sshAt >= 0) {
                        val keep = bytes.subList(sshAt, bytes.size).toByteArray()
                        input.unread(keep)
                        val discarded = bytes.subList(0, sshAt)
                        val banner = readLinePreview(bytes, sshAt)
                        SenseiTunnelVpnService.emitLog(
                            "Injector[$connId]: discarded prelude ${discarded.size}B; SSH starts: $banner"
                        )
                        if (discarded.isNotEmpty()) {
                            emitPrelude(connId, discarded.toByteArray())
                        }
                        return true
                    }

                    val c = one[0].toInt().toChar()
                    matched = when {
                        (matched == 0 || matched == 2) && c == '\r' -> matched + 1
                        (matched == 1 || matched == 3) && c == '\n' -> matched + 1
                        else -> 0
                    }
                    if (!httpHeadersSeen && matched == 4) {
                        httpHeadersSeen = true
                        SenseiTunnelVpnService.emitLog(
                            "Injector[$connId]: HTTP/WS headers ended after ${bytes.size}B; waiting for real SSH banner"
                        )
                    }
                }
                return logNoSshPrelude(connId, bytes, "limit ${PRELUDE_MAX_BYTES}B")
            } finally {
                try { sock.soTimeout = prevTimeout } catch (_: Exception) {}
            }
        } catch (e: Exception) {
            return logNoSshPrelude(connId, bytes, "${e.javaClass.simpleName}: ${e.message}")
        }
    }

    /**
     * Discard one HTTP response (status line + headers) up to and including the
     * terminating blank line, leaving the socket at the first byte of the real
     * tunnel stream. Used by protocols that speak first and therefore have no
     * greeting to synchronise on.
     *
     * With [expect101] the response must be a WebSocket upgrade (`101`);
     * anything else is a refusal from the server/backend and fails the relay.
     */
    /**
     * Swallow one HTTP response (up to the header end). Returns the status
     * line, or null on EOF / timeout / oversize — and on a non-101 when
     * [expect101] is set (the injected-WS dance).
     */
    private fun consumeHttpHeaders(
        input: PushbackInputStream,
        sock: Socket,
        connId: Int,
        expect101: Boolean = false,
    ): String? {
        val bytes = ArrayList<Byte>(4096)
        val prevTimeout = sock.soTimeout
        sock.soTimeout = PRELUDE_READ_TIMEOUT_MS
        try {
            val one = ByteArray(1)
            // CRLFCRLF, or LFLF on bare-LF servers. Tracked as a small state
            // machine over the last bytes seen rather than a counter, so a stray
            // "\n\r\n" cannot terminate the headers one byte early.
            var prev1 = 0.toChar()
            var prev2 = 0.toChar()
            var prev3 = 0.toChar()
            while (bytes.size < PRELUDE_MAX_BYTES) {
                val n = input.read(one)
                if (n <= 0) {
                    SenseiTunnelVpnService.emitLog(
                        "Injector[$connId]: upstream closed during HTTP response after ${bytes.size}B"
                    )
                    return null
                }
                bytes.add(one[0])
                val c = one[0].toInt().toChar()
                val crlfCrlf = prev3 == '\r' && prev2 == '\n' && prev1 == '\r' && c == '\n'
                val lfLf = prev1 == '\n' && c == '\n'
                if (crlfCrlf || lfLf) {
                    val status = bytes.toByteArray().toString(Charsets.US_ASCII)
                        .lineSequence().firstOrNull()?.trim().orEmpty()
                    if (expect101 && !status.contains("101")) {
                        SenseiTunnelVpnService.emitLog(
                            "Injector[$connId]: upstream refused the upgrade: $status"
                        )
                        emitPrelude(connId, bytes.toByteArray())
                        return null
                    }
                    SenseiTunnelVpnService.emitLog(
                        "Injector[$connId]: consumed HTTP response ${bytes.size}B; status: $status"
                    )
                    return status
                }
                prev3 = prev2; prev2 = prev1; prev1 = c
            }
            SenseiTunnelVpnService.emitLog(
                "Injector[$connId]: HTTP response exceeded ${PRELUDE_MAX_BYTES}B without header end"
            )
            return null
        } catch (e: Exception) {
            SenseiTunnelVpnService.emitLog(
                "Injector[$connId]: HTTP response read failed after ${bytes.size}B ${e.javaClass.simpleName}: ${e.message}"
            )
            return null
        } finally {
            try { sock.soTimeout = prevTimeout } catch (_: Exception) {}
        }
    }

    /**
     * Consume every HTTP response the payload's requests earn — a multi-request
     * payload (CF warm-up + cache PURGE + the real websocket upgrade) makes the
     * front answer once per request before the tunnel's own bytes flow.
     * Intermediate 4xx are noise (CloudFront's WAF 403s UA-less warm-up
     * requests and the PURGE — verified on the wire); only the LAST response
     * decides: a 4xx/5xx there means no tunnel opened, so the caller refuses
     * the client (HTTP CONNECT → 502) instead of the old behaviour of answering
     * 200 and relaying the error page straight into the engine's handshake.
     */
    private fun consumePayloadResponses(
        input: PushbackInputStream,
        sock: Socket,
        connId: Int,
        requestCount: Int,
    ): Boolean {
        val count = requestCount.coerceAtLeast(1)
        var last: String? = null
        for (i in 1..count) {
            last = consumeHttpHeaders(input, sock, connId) ?: return false
        }
        val code = last.orEmpty().split(" ").getOrNull(1)?.toIntOrNull() ?: 0
        if (code in 400..599) {
            SenseiTunnelVpnService.emitLog(
                "Injector[$connId]: backend refused the tunnel handshake after $count response(s): $last"
            )
            return false
        }
        return true
    }

    /**
     * Second phase of the fake-response dance: the client's real handshake has
     * been forwarded upstream, so wait for the `HTTP/1.1 101` that answers it
     * and swallow it — the tunnel engine downstream expects exactly one response
     * (this one), not two.
     *
     * A non-101 means the backend refused; both directions are torn down. No
     * response within [HANDSHAKE_ACCEPT_TIMEOUT_MS] is tolerated for server
     * variants that only send the first 101: whatever arrived stays buffered and
     * the plain relay takes over.
     */
    private fun awaitHandshakeAccept(input: PushbackInputStream, sock: Socket, connId: Int): Boolean {
        val bytes = ArrayList<Byte>(512)
        val prevTimeout = try { sock.soTimeout } catch (_: Exception) { 0 }
        try {
            sock.soTimeout = HANDSHAKE_ACCEPT_TIMEOUT_MS
            val one = ByteArray(1)
            val end = "\r\n\r\n"
            var matched = 0
            while (bytes.size < PRELUDE_MAX_BYTES) {
                val n = input.read(one)
                if (n <= 0) {
                    input.unread(bytes.toByteArray())
                    SenseiTunnelVpnService.emitLog(
                        "Injector[$connId]: upstream closed before handshake accept (${bytes.size}B)"
                    )
                    return false
                }
                bytes.add(one[0])
                val c = one[0].toInt().toChar()
                matched = if (matched < end.length && c == end[matched]) matched + 1 else
                    if (c == end[0]) 1 else 0
                if (matched == end.length) break
            }

            val head = bytes.toByteArray().toString(Charsets.US_ASCII)
            val status = head.lineSequence().firstOrNull()?.trim().orEmpty()
            if (!status.startsWith("HTTP/", ignoreCase = true)) {
                // Not a response at all — protocol data from a variant that
                // skips the second 101. Hand it through untouched.
                input.unread(bytes.toByteArray())
                return true
            }
            SenseiTunnelVpnService.emitLog("Injector[$connId]: handshake accept: $status")
            if (!status.contains("101")) {
                SenseiTunnelVpnService.emitLog(
                    "Injector[$connId]: backend refused the tunnel handshake — check path/protocol"
                )
                return false
            }
            // Push the accepted 101 back so the relay loop forwards it to the
            // local client (xray for RAW frontend, ovpn2 for HTTP_CONNECT).
            // Without this, xray never receives the 101 that completes its WS
            // upgrade and closes (client->upstream EOF after 199B).
            input.unread(bytes.toByteArray())
            return true
        } catch (e: Exception) {
            // Timeout or transient error: fall back to plain relay with whatever
            // we already read pushed back.
            try { input.unread(bytes.toByteArray()) } catch (_: Exception) {}
            SenseiTunnelVpnService.emitLog(
                "Injector[$connId]: no handshake accept (${e.javaClass.simpleName}); relaying raw"
            )
            return true
        } finally {
            try { sock.soTimeout = prevTimeout } catch (_: Exception) {}
        }
    }

    private fun logNoSshPrelude(connId: Int, bytes: List<Byte>, reason: String): Boolean {
        SenseiTunnelVpnService.emitLog(
            "Injector[$connId]: no complete SSH banner after discarding ${bytes.size}B ($reason)"
        )
        if (bytes.isNotEmpty()) emitPrelude(connId, bytes.toByteArray())
        return false
    }

    /**
     * Emit what the upstream sent before the tunnel protocol started.
     *
     * Kept as separate lines with their CRLFs turned into newlines rather than
     * squashed onto one line: these blobs are the server's own HTTP response —
     * often with a coloured HTML body — and the log view renders markup, so
     * flattening it destroyed the only place the user can see what a bug host
     * or panel actually replied.
     */
    private fun emitPrelude(connId: Int, raw: ByteArray) {
        val text = raw.toString(Charsets.ISO_8859_1)
            .replace("\r\n", "\n")
            .replace('\r', '\n')
            .trim()
        if (text.isEmpty()) return
        val clipped = if (text.length > PRELUDE_LOG_MAX_CHARS) {
            text.take(PRELUDE_LOG_MAX_CHARS) + "… (${text.length}B total)"
        } else {
            text
        }
        SenseiTunnelVpnService.emitLog("Injector[$connId]: upstream replied:\n$clipped")
    }

    private fun readLinePreview(bytes: List<Byte>, start: Int): String {
        val end = bytes.indexOfFirstFrom(start) { it.toInt().toChar() == '\n' }
            .let { if (it >= 0) it else bytes.size }
        return bytes.subList(start, end).toByteArray().toString(Charsets.US_ASCII)
            .replace("\r", "")
            .take(120)
    }

    private inline fun List<Byte>.indexOfFirstFrom(start: Int, predicate: (Byte) -> Boolean): Int {
        for (i in start until size) {
            if (predicate(this[i])) return i
        }
        return -1
    }

    /** Accept only complete SSH identification lines, not `SSH-` text inside HTTP 101 bodies. */
    private fun findSshBannerStart(bytes: List<Byte>): Int {
        if (bytes.size < 8) return -1
        val max = bytes.size - 8
        for (i in 0..max) {
            val lineStart = i == 0 || bytes[i - 1].toInt().toChar() == '\n'
            if (!lineStart) continue

            val isSsh20 = bytes.matchAscii(i, "SSH-2.0-")
            val isSsh199 = bytes.size - i >= 9 && bytes.matchAscii(i, "SSH-1.99-")
            if (!isSsh20 && !isSsh199) continue

            val lineEnd = bytes.indexOfFirstFrom(i) { it.toInt().toChar() == '\n' }
            if (lineEnd < 0) continue
            if (isValidSshBannerLine(bytes, i, lineEnd)) return i
        }
        return -1
    }

    private fun isValidSshBannerLine(bytes: List<Byte>, start: Int, end: Int): Boolean {
        val cleanEnd = if (end > start && bytes[end - 1].toInt().toChar() == '\r') end - 1 else end
        if (cleanEnd - start !in 8..255) return false

        val softwareStart = when {
            bytes.matchAscii(start, "SSH-2.0-") -> start + 8
            bytes.matchAscii(start, "SSH-1.99-") -> start + 9
            else -> return false
        }
        if (softwareStart > cleanEnd) return false

        for (i in softwareStart until cleanEnd) {
            val c = bytes[i].toInt() and 0xff
            if (c !in 32..126) return false
        }
        return true
    }

    private fun List<Byte>.matchAscii(start: Int, text: String): Boolean {
        if (size - start < text.length) return false
        for (offset in text.indices) {
            if (this[start + offset].toInt().toChar() != text[offset]) return false
        }
        return true
    }

    private fun copy(input: InputStream, output: OutputStream, a: Socket, b: Socket, label: String, connId: Int) {
        val buf = ByteArray(16384)
        var total = 0L
        try {
            while (running.get()) {
                // `PushbackInputStream.read(b, off, len)` copies the pushed-back
                // bytes and then BLOCKS on the socket for the remainder of `len`.
                // The prelude consumer pushes the SSH banner back here, so a
                // server that sends only the banner and waits would stall
                // forever. Cap the request at what is already buffered so the
                // pushed-back bytes are delivered immediately.
                val ready = try { input.available() } catch (_: Exception) { 0 }
                val want = if (ready in 1 until buf.size) ready else buf.size
                val n = input.read(buf, 0, want)
                if (n < 0) {
                    SenseiTunnelVpnService.emitLog("Injector[$connId]: $label EOF after ${total}B")
                    break
                }
                total += n
                if (total == n.toLong()) {
                    SenseiTunnelVpnService.emitLog("Injector[$connId]: $label first ${n}B")
                }
                output.write(buf, 0, n)
                output.flush()
            }
        } catch (e: Exception) {
            SenseiTunnelVpnService.emitLog("Injector[$connId]: $label error after ${total}B ${e.javaClass.simpleName}: ${e.message}")
        } finally {
            closeQuietly(a); closeQuietly(b)
        }
    }

    private fun track(socket: Socket) {
        liveSockets.add(socket)
        if (!running.get()) closeQuietly(socket)
    }

    private fun closeQuietly(socket: Socket?) {
        if (socket == null) return
        liveSockets.remove(socket)
        try { socket.close() } catch (_: Exception) {}
    }

    private fun sleepQuietly(ms: Long) {
        if (ms <= 0) return
        try { Thread.sleep(ms) } catch (_: InterruptedException) {}
    }

    // ---------------------------------------------------------------- payload

    /**
     * Render the payload template and split it at the `[split]` / `[delay_split]`
     * boundaries. Returns an empty list when nothing should be injected.
     *
     * [clientRequestLine] (HTTP_CONNECT frontend) replaces the synthesized
     * `CONNECT` used by the `[raw]`/`[netData]` family with the request line the
     * local engine actually sent.
     */
    private fun buildSegments(template: String, clientRequestLine: String? = null): List<Segment> {
        val rendered = renderPayload(template, clientRequestLine)
        if (rendered.isEmpty()) return emptyList()

        val segments = mutableListOf<Segment>()
        var rest = rendered
        while (true) {
            val split = rest.indexOf(SPLIT_MARK)
            val delaySplit = rest.indexOf(DELAY_SPLIT_MARK)
            val at = when {
                split < 0 -> delaySplit
                delaySplit < 0 -> split
                else -> minOf(split, delaySplit)
            }
            if (at < 0) break
            val isDelay = at == delaySplit && (split < 0 || delaySplit <= split)
            val mark = if (isDelay) DELAY_SPLIT_MARK else SPLIT_MARK
            val head = rest.substring(0, at)
            if (head.isNotEmpty()) {
                segments.add(
                    Segment(
                        head.toByteArray(Charsets.ISO_8859_1),
                        if (isDelay) LONG_SPLIT_DELAY_MS else SPLIT_DELAY_MS,
                    )
                )
            }
            rest = rest.substring(at + mark.length)
        }
        if (rest.isNotEmpty()) segments.add(Segment(rest.toByteArray(Charsets.ISO_8859_1), 0))
        return segments
    }

    /**
     * Render the injector-style payload template.
     *
     * Supported (the shared injector-app token table and the common
     * community extensions):
     *  - `[method]` → CONNECT
     *  - `[host]` / `[bug]` / `[bug_host]` → front (SNI/bug) host
     *  - `[cf]` → the server being tunneled to — for CloudFront-style configs
     *    the distribution domain the edge IP must see in `Host:`
     *    (dropped tokens used to leave an empty Host → CF 400)
     *  - `[host_port]` → front host:port · `[real_host_port]` → real target
     *  - `[port]`, `[ip]`, `[ip_port]`, `[protocol]`, `[ua]`, `[user-agent]`
     *  - `[ssh]` / `[ssh_host]` / `[ssh_port]`,
     *    `[proxy]` / `[proxy_host]` / `[proxy_port]` → injector proxy
     *  - `[rotate=URL]` → one host per connection from the bug-host list at URL
     *  - `[cr*N]` `[lf*N]` `[crlf*N]` `[lfcr*N]` → N repeated line breaks
     *  - literal `\r\n` / `\n` / `\r` escapes → real CRLF / LF / CR (HTTP
     *    Custom share format stores CRLFs escaped this way)
     *  - `[netData]` / `[raw]` / `[real_raw]` / `[net_data]` → `CONNECT …` line
     *  - `[realData]` / `[real_data]` → `CONNECT …` line + blank line
     *  - `[auth]` → empty (no proxy auth)
     *  - `[split]` `[instant_split]` `[delay_split]` `[delay]` `[split_delay]`
     *    → TCP segment boundaries (immediate / delayed).
     *  - `[random]` / `[repeat]` → payload-variant selector (random pick /
     *    per-connection cycle), `[rlb]` → real target host, from the
     *    injector-share format used by other apps.
     *
     * Unrecognised `[token]`s are dropped rather than transmitted literally —
     * leaving them in corrupts the request line and is worse than omitting them.
     */
    /** Standard websocket-upgrade opener; Host baked as the real target host. */
    private fun defaultWssUpgrade(): String =
        "GET / HTTP/1.1[crlf]Host: $targetHost[crlf]Upgrade: websocket" +
            "[crlf]Connection: Upgrade[crlf][crlf]"

    /**
     * If [spec] is non-blank, return the bug host this connection should use
     * (round-robin, cached per spec). `[rotate=a;b;c]` is an inline host list
     * (the injector-share format used by other apps); anything starting with
     * `http://`/`https://` is fetched as a remote list. Null when the list is
     * empty or unreachable — the token is then dropped like any unknown.
     */
    private fun hostForRotate(spec: String): String? {
        if (spec.isEmpty()) return null
        val remote = spec.startsWith("http://", true) || spec.startsWith("https://", true)
        // A failed fetch must NOT be cached forever: the old code stored the
        // empty list, so one DNS blip during the first dial disabled bug-host
        // rotation for the entire process lifetime. Cache only successes;
        // failures get a 60 s cooldown so a dead URL is not hammered.
        val cached = rotateCache[spec]
        val hosts = cached ?: run {
            val failedAt = rotateFailAt[spec] ?: 0L
            if (remote && System.currentTimeMillis() - failedAt < ROTATE_FAIL_COOLDOWN_MS) {
                return null
            }
            val list = if (remote) fetchRotateList(spec)
            else spec.split(';').map { it.trim() }.filter { it.isNotEmpty() }
            if (list.isEmpty()) {
                if (remote) rotateFailAt[spec] = System.currentTimeMillis()
                return null
            }
            rotateFailAt.remove(spec)
            rotateCache[spec] = list
            list
        }
        if (hosts.isEmpty()) {
            SenseiTunnelVpnService.emitLog("Injector: rotate list empty/unreachable: $spec")
            return null
        }
        val host = hosts[rotateCounter.getAndIncrement().mod(hosts.size)]
        // Returned to the caller — the render threads it locally (no shared field).
        SenseiTunnelVpnService.emitLog("Injector: rotate[${spec.take(40)}] -> $host (${hosts.size} hosts)")
        return host
    }

    /** Download a `[rotate=...]` bug-host list. Never throws; empty on failure. */
    private fun fetchRotateList(url: String): List<String> = try {
        val conn = java.net.URL(url).openConnection() as java.net.HttpURLConnection
        conn.connectTimeout = 5000
        conn.readTimeout = 5000
        conn.instanceFollowRedirects = true
        conn.setRequestProperty("User-Agent", USER_AGENT)
        val body = try {
            val stream = if (conn.responseCode in 200..299) conn.inputStream else conn.errorStream
            stream?.bufferedReader(Charsets.UTF_8)?.use { r ->
                val sb = StringBuilder()
                val buf = CharArray(4096)
                while (sb.length < 65536) {
                    val n = r.read(buf)
                    if (n < 0) break
                    sb.append(buf, 0, n)
                }
                sb.toString()
            }.orEmpty()
        } finally {
            conn.disconnect()
        }
        body.split(Regex("[\\r\\n,;\\s]+"))
            .map { it.trim() }
            .filter { it.isNotEmpty() && !it.startsWith("#") }
            .distinct()
            .also { SenseiTunnelVpnService.emitLog("Injector: rotate list $url -> ${it.size} host(s)") }
    } catch (e: Exception) {
        Log.w(TAG, "rotate list fetch failed: ${e.message}")
        SenseiTunnelVpnService.emitLog("Injector: rotate list fetch failed: ${e.message}")
        emptyList()
    }


    private fun renderPayload(template: String, clientRequestLine: String? = null): String {
        // A blank template means "inject nothing" EXCEPT:
        //  * proxy modes need their default CONNECT, and
        //  * the RAW frontend (engine bytes go straight onto the socket) with
        //    DIRECT_SNI and a FAKE SNI (bug host ≠ target) on today's BD-style
        //    panels hits an HTTP mux that silently swallows raw SSH — the
        //    classic SSL-WS entry is a websocket upgrade (verified against
        //    haproxy `acl_path_regex → ws backend`). Synthesize the standard
        //    WSS opener so SSH-over-TLS works without the user typing one.
        //
        // The HTTP_CONNECT frontend (OpenVPN via `http-proxy`) is deliberately
        // excluded from the WSS synth: the relay is a proxy and the blank-payload
        // SNI modes are a pure TLS wrap (stunnel). Synthesizing a `GET /` there
        // made multiplexed panels route the connection to their websocket
        // backend, so the OpenVPN handshake that followed never reached the
        // OpenVPN backend. Same for [wrapOuterTls] (SNI-fronted OpenVPN): the
        // front pipes raw OpenVPN bytes to the backend right after the outer
        // handshake — OpenVPN Lite's `TO PROXY: CONNECT` exchange is ovpn3
        // talking to its LOCAL back server, never on the wire (verified: a
        // synthesized CONNECT inside the outer TLS made the front close the
        // connection instantly with 0 bytes relayed).
        var tpl = when {
            template.isNotBlank() -> template
            usesProxy -> DEFAULT_PAYLOAD
            frontend == Frontend.RAW && mode == Mode.DIRECT_SNI &&
                sni.isNotBlank() &&
                !sni.equals(targetHost, ignoreCase = true) -> defaultWssUpgrade()
            else -> return ""
        }

        // Share formats store CRLFs as literal `\r\n` escape text; expand
        // first so the escape bytes can never swallow a token boundary.
        tpl = tpl
            .replace(ESCAPED_CRLF, "\r\n")
            .replace(ESCAPED_LF, "\n")
            .replace(ESCAPED_CR, "\r")

        // `[random]` — pick one payload variant at random (injector-share
        // format); `[repeat]` — cycle variants one connection at a time.
        if (tpl.contains("[random]", ignoreCase = true)) {
            tpl = tpl.split("[random]", ignoreCase = true).random()
        }
        if (tpl.contains("[repeat]", ignoreCase = true)) {
            val parts = tpl.split("[repeat]", ignoreCase = true)
            tpl = parts[repeatCounter.getAndIncrement().mod(parts.size)]
        }

        // `[rotate=URL]`: pick one host per connection from the remote
        // bug-host list (cached per URL). When rotating, `[host]`/`[bug]`
        // render the rotated entry — that is the host DPI should see.
        val rotating = ROTATE_TOKEN.containsMatchIn(tpl)
        var resolvedRotate: String? = null
        tpl = ROTATE_TOKEN.replace(tpl) { m ->
            hostForRotate(m.groupValues[1].trim()).also { resolvedRotate = it }.orEmpty()
        }

        // `[raw]`/`[netData]` mean "the request line the client sent". With the
        // HTTP_CONNECT frontend that is a real value; otherwise synthesize it.
        // While rotating, `[host]`-family tokens take the rotated bug host —
        // from THIS render's resolution, never shared state.
        val hostToken = if (rotating) (resolvedRotate ?: frontHost) else frontHost
        val rawConnect = clientRequestLine ?: "CONNECT $targetHost:$targetPort HTTP/1.1"
        var out = tpl
            .replace("[method]", "CONNECT", ignoreCase = true)
            .replace("[real_host_port]", "$targetHost:$targetPort", ignoreCase = true)
            .replace("[host_port]", "$hostToken:$targetPort", ignoreCase = true)
            .replace("[ssh_host]", targetHost, ignoreCase = true)
            .replace("[ssh_port]", targetPort.toString(), ignoreCase = true)
            .replace("[ssh]", "$targetHost:$targetPort", ignoreCase = true)
            .replace("[rlb]", targetHost, ignoreCase = true)
            .replace("[cf]", targetHost, ignoreCase = true)
            .replace("[bug_host]", hostToken, ignoreCase = true)
            .replace("[bug]", hostToken, ignoreCase = true)
            .replace("[host]", hostToken, ignoreCase = true)
            .replace("[ip]", targetHost, ignoreCase = true)
            .replace("[ip_port]", "$targetHost:$targetPort", ignoreCase = true)
            .replace("[port]", targetPort.toString(), ignoreCase = true)
            .replace("[protocol]", "HTTP/1.1", ignoreCase = true)
            .replace("[ua]", USER_AGENT, ignoreCase = true)
            .replace("[user-agent]", USER_AGENT, ignoreCase = true)
            .replace("[app]", "SenseiTunnel", ignoreCase = true)
            .replace("[real_raw]", rawConnect, ignoreCase = true)
            .replace("[net_data]", rawConnect, ignoreCase = true)
            .replace("[netdata]", rawConnect, ignoreCase = true)
            .replace("[raw]", rawConnect, ignoreCase = true)
            .replace("[realdata]", "$rawConnect\r\n\r\n", ignoreCase = true)
            .replace("[real_data]", "$rawConnect\r\n\r\n", ignoreCase = true)
            .replace("[auth]", "", ignoreCase = true)
            .replace("[proxy_host]", proxyHost, ignoreCase = true)
            .replace("[proxy_port]", if (proxyPort > 0) proxyPort.toString() else "", ignoreCase = true)
            .replace("[instant_split]", SPLIT_MARK, ignoreCase = true)
            .replace("[split_instant]", SPLIT_MARK, ignoreCase = true)
            .replace("[delay_split]", DELAY_SPLIT_MARK, ignoreCase = true)
            .replace("[split_delay]", DELAY_SPLIT_MARK, ignoreCase = true)
            .replace("[delay]", DELAY_SPLIT_MARK, ignoreCase = true)
            .replace("[split]", SPLIT_MARK, ignoreCase = true)
            .replace("[lfcr]", "\n\r", ignoreCase = true)
            .replace("[crlf]", "\r\n", ignoreCase = true)
            .replace("[cr]", "\r", ignoreCase = true)
            .replace("[lf]", "\n", ignoreCase = true)

        // `[cr*N]`-family: line-repeat tokens (one replacement pass, so a
        // repeated count can't recurse into itself).
        out = REPEAT_TOKEN.replace(out) { m ->
            val unit = when (m.groupValues[1].lowercase()) {
                "cr" -> "\r"
                "lf" -> "\n"
                "crlf" -> "\r\n"
                else -> "\n\r"
            }
            unit.repeat(m.groupValues[2].toInt().coerceIn(1, 64))
        }

        if (proxyHost.isNotBlank() && proxyPort > 0) {
            out = out.replace("[proxy]", "$proxyHost:$proxyPort", ignoreCase = true)
        }

        // Strip blank lines before a fake-response opener: servers scan for the
        // first `\r\n\r\n` to find the header block, so leading `[crlf]`s (a
        // common share habit) would make them see an EMPTY first header and take
        // the wrong code path.
        val stripped = out.trimStart(' ', '\r', '\n')
        if (stripped.length < out.length && stripped.startsWith("HTTP/", ignoreCase = true)) {
            out = stripped
        }

        // Drop leftovers, but never touch the split sentinels.
        val leftovers = UNKNOWN_TOKEN.findAll(out).map { it.value }.distinct().toList()
        if (leftovers.isNotEmpty()) {
            out = UNKNOWN_TOKEN.replace(out, "")
            Log.w(TAG, "Dropped unsupported payload tokens: ${leftovers.joinToString(",")}")
            SenseiTunnelVpnService.emitLog(
                "Injector: dropped unsupported payload token(s) ${leftovers.joinToString(", ")}"
            )
        }

        return normalizePayload(out)
    }

    /**
     * Give header-only payloads a valid request line, so a proxy has something
     * it can actually parse.
     *
     * Response-style openers (`HTTP/1.1 200 OK…`) are passed through untouched:
     * they are intentional fake-response openers for v2rayinject.py-style
     * servers and must not be rewritten into requests.
     */
    private fun normalizePayload(payload: String): String {
        if (payload.isEmpty()) return ""

        val lineEnd = payload.indexOf('\n').let { if (it >= 0) it else payload.length }
        val firstLineRaw = payload.substring(0, lineEnd)
        // A split sentinel inside the request line means the user deliberately
        // fragmented it; leave such payloads exactly as authored.
        if (firstLineRaw.contains(SPLIT_MARK) || firstLineRaw.contains(DELAY_SPLIT_MARK)) return payload

        val firstLine = firstLineRaw.trimEnd('\r').trim()
        if (firstLine.isEmpty()) return payload

        val upper = firstLine.uppercase()
        if (upper.startsWith("HTTP/")) return payload

        if (HTTP_METHODS.any { upper.startsWith(it) }) return payload

        val headerOnly = firstLine.contains(':') && !firstLine.contains("HTTP/")
        if (headerOnly) {
            return "CONNECT $frontHost:$targetPort HTTP/1.1\r\n$payload"
        }

        return payload
    }

    /**
     * Enable TCP keepalive on the relay's upstream socket and shrink the idle
     * window so an idle tunnel (OpenVPN after CONNECTED, etc.) is not dropped by
     * a server/front-end ~7s timeout. The public [Socket.keepAlive] flag alone
     * uses Android's ~2h idle default — useless here — so tune TCP_KEEPIDLE/
     * TCP_KEEPINTVL/TCP_KEEPCNT via libcore's setsockopt when available.
     * Purely best-effort: any failure falls back to plain keepalive and logs.
     */
    private fun setShortTcpKeepalive(socket: Socket, idleSec: Int = 5) {
        try {
            socket.keepAlive = true
            val fdMethod = try {
                Socket::class.java.getDeclaredMethod("getFileDescriptor")
            } catch (_: NoSuchMethodException) {
                Socket::class.java.getMethod("getFileDescriptor")
            }
            fdMethod.isAccessible = true
            val fd = fdMethod.invoke(socket) as? FileDescriptor ?: return
            val os = Class.forName("libcore.io.Os")
            val setsockoptInt = os.getMethod(
                "setsockoptInt",
                FileDescriptor::class.java,
                Int::class.javaPrimitiveType,
                Int::class.javaPrimitiveType,
                Int::class.javaPrimitiveType,
            )
            val osConstants = Class.forName("libcore.io.OsConstants")
            val solTcp = osConstants.getField("SOL_TCP").getInt(null)
            val keepIdle = osConstants.getField("TCP_KEEPIDLE").getInt(null)
            val keepIntvl = osConstants.getField("TCP_KEEPINTVL").getInt(null)
            val keepCnt = osConstants.getField("TCP_KEEPCNT").getInt(null)
            setsockoptInt.invoke(null, fd, solTcp, keepIdle, idleSec)
            setsockoptInt.invoke(null, fd, solTcp, keepIntvl, 3)
            setsockoptInt.invoke(null, fd, solTcp, keepCnt, 3)
        } catch (e: Throwable) {
            Log.d(TAG, "keepalive tuning skipped: ${e.message}")
        }
    }
}

private const val USER_AGENT =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"

private const val DEFAULT_PAYLOAD =
    "[method] [host_port] [protocol][crlf]Host: [host][crlf]Connection: Keep-Alive[crlf][crlf]"
