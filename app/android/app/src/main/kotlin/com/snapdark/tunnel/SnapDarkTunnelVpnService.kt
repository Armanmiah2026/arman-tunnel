package com.snapdark.tunnel

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.net.VpnService
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.util.Log
import io.flutter.plugin.common.EventChannel
import com.trilead.ssh2.Connection
import com.trilead.ssh2.ConnectionMonitor
import com.trilead.ssh2.DynamicPortForwarder
import com.trilead.ssh2.HTTPProxyData
import java.io.File
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Proxy
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean

class SnapDarkTunnelVpnService : VpnService() {

    companion object {
        const val ACTION_START = "com.snapdark.tunnel.START"
        const val ACTION_STOP = "com.snapdark.tunnel.STOP"
        const val ACTION_RECONNECT = "com.snapdark.tunnel.RECONNECT"
        const val NOTIFICATION_CHANNEL_ID = "snapdark_tunnel_vpn"
        const val NOTIFICATION_ID = 1
        private const val MAX_RECONNECT_ATTEMPTS = 6
        private const val TAG = "SnapDarkTunnelVPN"

        var isRunning = false
            private set
        var lastDelay = -1L
            private set
        var lastError = ""
            private set
        /** True when the active tunnel is OpenVPN (no SOCKS proxy for ping). */
        var isOpenvpnMode = false
            private set
        /** Protocol name of the live tunnel ("" when idle) — vless/vmess/
         *  trojan/shadowsocks/ssh/sshDnstt/openvpn. Dart uses it to decide
         *  how the app's own HTTP traffic must be routed (local proxy vs
         *  bound-to-VPN direct). */
        var activeMode = ""
            private set
        var stateEventSink: EventChannel.EventSink? = null
        var statsEventSink: EventChannel.EventSink? = null

        /** Connected-at epoch ms of the LIVE service session (0 = not
         *  connected). Dart reads this on app re-entry so the home timer
         *  resumes from the real start instead of resetting to zero after
         *  the app was swiped from recents while the VPN kept running. */
        /** The live service instance (null when no tunnel exists). Lets the
         *  activity poke the watchdog on resume. */
        @JvmStatic
        fun instance(): SnapDarkTunnelVpnService? = instanceRef?.get()

        @JvmStatic
        fun connectedAt(): Long {
            val inst = instanceRef?.get()
            return inst?.connectedAtTimestamp ?: 0L
        }

        private var instanceRef: java.lang.ref.WeakReference<SnapDarkTunnelVpnService>? = null

        /** Session info for Dart: real elapsed seconds + server name. */
        @JvmStatic
        fun sessionInfo(): Map<String, Any> {
            val inst = instanceRef?.get()
            val at = inst?.connectedAtTimestamp ?: 0L
            return mapOf(
                "connectedAt" to at,
                "elapsedSec" to (if (at > 0) (System.currentTimeMillis() - at) / 1000 else 0L),
                "serverName" to (inst?.serverName ?: ""),
                "mode" to (inst?.mode ?: ""),
                "running" to isRunning,
            )
        }

        /**
         * Endpoint redaction for the in-app log: the config bundle is
         * encrypted precisely so the backend host/port never travels in the
         * clear — the log channel must not leak it. Matches IPv4[:port] and
         * domain[:port]; loopback stays readable (local proxy ports are not
         * secret and are useful while debugging).
         */
        private val endpointRe = Regex(
            """(?<![\w.-])((?:\d{1,3}\.){3}\d{1,3}|(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,})(:\d{2,5})?\b"""
        )

        fun redact(msg: String): String = endpointRe.replace(msg) { m ->
            val host = m.groupValues[1]
            if (host.equals("127.0.0.1", true) || host.equals("localhost", true)) m.value
            else "***"
        }

        private fun releaseLogAllowed(msg: String): Boolean {
            if (BuildConfig.DEBUG) return true
            val m = msg.lowercase()
            return m.contains("locked") ||
                m.contains("admin") ||
                m.contains("server") ||
                m.contains("tweak") ||
                m.contains("auth failed") ||
                m.contains("authentication failed") ||
                m.contains("failed") ||
                m.contains("error") ||
                m.contains("connected") ||
                m.contains("disconnected") ||
                m.contains("reconnect")
        }

        fun emitLog(msg: String) {
            if (!releaseLogAllowed(msg)) return
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                // Same guard emitState/emitStats have: after the activity (and
                // with it the EventChannel sink) is gone, sink?.success throws,
                // and an unguarded throw on the MAIN LOOPER kills the process —
                // taking the running tunnel with it.
                try {
                    stateEventSink?.success("log:" + redact(msg))
                } catch (e: Exception) {
                    Log.e(TAG, "Failed to emit log", e)
                }
            }
        }

        /**
         * Fresh one-shot latency probe. When the tunnel is up the request goes
         * through the local SOCKS (127.0.0.1:10808) so it measures the real
         * round-trip via the remote server; hostname resolution happens at the
         * proxy (remote DNS). Falls back to a direct TCP connect otherwise.
         * Returns -1 on timeout/failure.
         */
    /** Serial executor for latency probes — socket work never touches the UI thread. */
    val pingExecutor: java.util.concurrent.Executor =
        java.util.concurrent.Executors.newSingleThreadExecutor { r ->
            Thread(r, "snapdark-ping").apply { isDaemon = true }
        }

    /** Pool for the per-card latency sweep. [pingExecutor] is single-threaded,
     * which is right for one probe but would serialise a whole server list
     * (each connect can burn its full 3.5 s timeout), so the sweep gets its
     * own bounded pool. */
    // 16 threads: a full feed can be 60+ servers, and pingHosts bounds the whole
    // batch at 6s — with only 8 threads the tail of the list could not even
    // finish its connect attempt in that window and came back as a false
    // "no reply".
    val pingPoolExecutor: java.util.concurrent.ExecutorService =
        java.util.concurrent.Executors.newFixedThreadPool(16) { r ->
            Thread(r, "snapdark-ping-pool").apply { isDaemon = true }
        }

    /**
     * Probes many [host, port] targets at once and returns the elapsed ms per
     * target in the SAME order (-1 = unreachable/timeout).
     *
     * [throughVpn] routes each probe through the running tunnel (SOCKS on
     * 10808, or the VPN-bound process socket for OpenVPN) so a card badge
     * measures the latency the user actually gets through the server; with no
     * session up the probes fall back to a direct connect automatically.
     */
    fun pingHosts(targets: List<Pair<String, Int>>, throughVpn: Boolean = false): IntArray {
        if (targets.isEmpty()) return IntArray(0)
        val out = IntArray(targets.size) { -1 }
        val pool = pingPoolExecutor
        val latch = java.util.concurrent.CountDownLatch(targets.size)
        targets.forEachIndexed { i, (host, port) ->
            pool.execute {
                try {
                    out[i] = pingHost(host, port, throughVpn)
                } catch (_: Throwable) {
                    out[i] = -1
                } finally {
                    latch.countDown()
                }
            }
        }
        // Bounded so a hung DNS/socket can never wedge the caller forever;
        // whatever has not answered yet stays -1.
        try {
            latch.await(6, java.util.concurrent.TimeUnit.SECONDS)
        } catch (_: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        return out
    }

        /**
         * The live VPN network (cached on the service instance), or null with
         * no session. Probes pass this to `socketFactory` / `getAllByName` to
         * ride the tunnel EXPLICITLY — the app process itself is never bound
         * to it anymore, so the app's own traffic (config feed, worker calls,
         * update checks) stays on the user's physical network.
         */
        fun vpnNetworkRef(): Network? {
            val svc = instanceRef?.get() ?: return null
            val cm = svc.getSystemService(android.content.Context.CONNECTIVITY_SERVICE)
                as? ConnectivityManager ?: return null
            val cached = svc.boundVpnNetwork
            if (cached != null && cm.getNetworkCapabilities(cached) != null) return cached
            val fresh = cm.allNetworks.firstOrNull { n ->
                cm.getNetworkCapabilities(n)?.hasTransport(
                    android.net.NetworkCapabilities.TRANSPORT_VPN
                ) == true
            }
            svc.boundVpnNetwork = fresh
            return fresh
        }

        /** Resolve [host] on [net] (tunnel DNS); null on refusal/failure. */
        private fun resolveOn(net: Network, host: String): InetAddress? = try {
            if (host.matches(Regex("\\d{1,3}(\\.\\d{1,3}){3}"))) {
                InetAddress.getByName(host)
            } else {
                net.getAllByName(host).firstOrNull()
            }
        } catch (_: Exception) {
            null
        }

        fun pingHost(host: String, port: Int, throughVpn: Boolean): Int {
            var sock: Socket? = null
            return try {
                val start = System.currentTimeMillis()
                // OpenVPN has no SOCKS proxy: the probe dials through the VPN
                // network's socket factory EXPLICITLY (the process is not bound
                // to the tunnel — the app keeps its own network). SSH / V2Ray
                // expose the SOCKS proxy on 10808 instead. When no session is
                // up — or the OEM refuses the owner-UID factory socket (EPERM)
                // — fall back to a direct connect so cards still show a real
                // number instead of a blank badge.
                val vnet = if (throughVpn && isRunning && isOpenvpnMode) vpnNetworkRef() else null
                sock = if (vnet != null) {
                    try { vnet.socketFactory.createSocket() } catch (_: Exception) { Socket() }
                } else if (throughVpn && isRunning) {
                    Socket(Proxy(Proxy.Type.SOCKS, InetSocketAddress("127.0.0.1", 10808)))
                } else {
                    Socket()
                }
                sock.soTimeout = 4000
                val target = if (vnet != null) {
                    resolveOn(vnet, host)?.let { InetSocketAddress(it, port) }
                        ?: InetSocketAddress(host, port)
                } else if (throughVpn && isRunning) {
                    InetSocketAddress.createUnresolved(host, port)
                } else {
                    InetSocketAddress(host, port)
                }
                sock.connect(target, 3500)
                sock.close()
                (System.currentTimeMillis() - start).toInt().coerceAtLeast(1)
            } catch (e: Exception) {
                -1
            } finally {
                try { sock?.close() } catch (_: Exception) {}
            }
        }

        /**
         * HTTP-level probe: connect, send a real `GET`/`HEAD` and wait for the
         * status line.
         *
         * A bare TCP connect only proves a socket opened — a captive portal, a
         * half-dead proxy or a server that accepts and never answers all look
         * "fast". Measuring to the response status line measures what the user
         * actually experiences, and the status is worth surfacing.
         *
         * Returns `ms` (>0, or -1), `status` (e.g. "204 No Content", empty when
         * the request failed) and `server` when the response advertises one.
         */
        fun httpPing(
            urlOrHost: String,
            port: Int,
            throughVpn: Boolean,
            useHttps: Boolean,
        ): Map<String, Any> {
            // Accept "example.com", "example.com/path", "http(s)://host[:port]/path".
            var scheme = if (useHttps) "https" else "http"
            var rest = urlOrHost.trim()
            Regex("^(https?)://", RegexOption.IGNORE_CASE).find(rest)?.let { m ->
                scheme = m.groupValues[1].lowercase()
                rest = rest.substring(m.value.length)
            }
            val slash = rest.indexOf('/')
            var authority = if (slash >= 0) rest.substring(0, slash) else rest
            val path = if (slash >= 0) rest.substring(slash) else "/"
            var targetPort = port
            // Do not mistake an IPv6 literal's colons for a port separator.
            if (!authority.startsWith("[")) {
                val colon = authority.lastIndexOf(':')
                if (colon > 0) {
                    authority.substring(colon + 1).toIntOrNull()?.let {
                        targetPort = it
                        authority = authority.substring(0, colon)
                    }
                }
            }
            if (targetPort <= 0) targetPort = if (scheme == "https") 443 else 80
            val host = authority.removeSurrounding("[", "]")

            var sock: Socket? = null
            val start = System.currentTimeMillis()
            return try {
                // OpenVPN: dial the VPN network explicitly through its socket
                // factory (the process is NOT bound to the tunnel). SSH/V2Ray:
                // the SOCKS proxy on 10808. If the OEM refuses the factory
                // socket, fall back to a direct dial — a real physical-network
                // number beats "Ping failed" on every card.
                val vnet = if (throughVpn && isRunning && isOpenvpnMode) {
                    vpnNetworkRef()
                } else null
                var plain = if (throughVpn && isRunning && !isOpenvpnMode) {
                    Socket(Proxy(Proxy.Type.SOCKS, InetSocketAddress("127.0.0.1", 10808)))
                } else if (vnet != null) {
                    try { vnet.socketFactory.createSocket() } catch (_: Exception) { Socket() }
                } else {
                    Socket()
                }
                val viaVpnFactory = vnet != null
                plain.soTimeout = 5000
                val target = if (throughVpn && isRunning && !isOpenvpnMode) {
                    // Resolve at the proxy so DNS also goes through the tunnel.
                    InetSocketAddress.createUnresolved(host, targetPort)
                } else if (vnet != null) {
                    resolveOn(vnet, host)?.let { InetSocketAddress(it, targetPort) }
                        ?: InetSocketAddress(host, targetPort)
                } else {
                    InetSocketAddress(host, targetPort)
                }
                // Some OEMs throw the EPERM on CONNECT, not createSocket
                // ("Binding socket to network N failed: EPERM"). One honest
                // retry on the physical network — a real ping number beats
                // a blank badge (matches the documented fallback contract).
                try {
                    plain.connect(target, 4000)
                } catch (e: java.io.IOException) {
                    if (!viaVpnFactory) throw e
                    plain = Socket()
                    plain.soTimeout = 5000
                    plain.connect(target, 4000)
                }
                sock = plain
                plain.tcpNoDelay = true

                val io: Socket = if (scheme == "https") {
                    val ssl = (javax.net.ssl.SSLSocketFactory.getDefault()
                        as javax.net.ssl.SSLSocketFactory)
                        .createSocket(plain, host, targetPort, true)
                        as javax.net.ssl.SSLSocket
                    ssl.soTimeout = 5000
                    ssl.startHandshake()
                    sock = ssl
                    ssl
                } else {
                    plain
                }

                val req = "HEAD $path HTTP/1.1\r\n" +
                    "Host: $host\r\n" +
                    "User-Agent: SnapDarkTunnel/ping\r\n" +
                    "Accept: */*\r\n" +
                    "Connection: close\r\n\r\n"
                io.getOutputStream().apply {
                    write(req.toByteArray(Charsets.US_ASCII))
                    flush()
                }

                val reader = io.getInputStream().bufferedReader(Charsets.ISO_8859_1)
                val statusLine = reader.readLine().orEmpty()
                val ms = (System.currentTimeMillis() - start).toInt().coerceAtLeast(1)

                var server = ""
                // Read a bounded number of headers looking for Server:.
                var seen = 0
                while (seen < 30) {
                    val line = reader.readLine() ?: break
                    if (line.isEmpty()) break
                    if (line.startsWith("Server:", ignoreCase = true)) {
                        server = line.substringAfter(':').trim()
                    }
                    seen++
                }

                // "HTTP/1.1 204 No Content" → "204 No Content"
                val status = statusLine
                    .substringAfter(' ', statusLine)
                    .trim()
                    .takeIf { statusLine.startsWith("HTTP/", ignoreCase = true) }
                    .orEmpty()

                mapOf(
                    "ms" to if (status.isEmpty()) -1 else ms,
                    "status" to status,
                    "server" to server,
                    "target" to "$scheme://$host:$targetPort$path",
                )
            } catch (e: Exception) {
                mapOf(
                    "ms" to -1,
                    "status" to "",
                    "server" to "",
                    "target" to "$scheme://$host:$targetPort$path",
                    "error" to "${e.javaClass.simpleName}: ${e.message ?: ""}",
                )
            } finally {
                try { sock?.close() } catch (_: Exception) {}
            }
        }
    }

    private var vpnInterface: ParcelFileDescriptor? = null
    private var xrayProcess: Process? = null
    private var hysteriaProcess: Process? = null
    private var tun2socksProcess: Process? = null
    private val running = AtomicBoolean(false)
    private var config = ""
    private var serverName = ""
    private var isSsh = false
    private var sshUser = ""
    private var sshPass = ""
    private var sshProxyHost = ""
    private var sshProxyPort = 0
    private var serverAddress = ""
    private var serverPort = 443
    private var serverSni = ""
    private var injectModeName = "none"
    private var payloadTemplate = ""
    private var payloadInjector: PayloadInjector? = null
    private var mtu = 1500
    private var dnsServers: List<String> = listOf("8.8.8.8", "8.8.4.4", "1.1.1.1")
    private val dnsPrimary: String get() = dnsServers.firstOrNull() ?: "8.8.8.8"
    private val dnsSecondary: String get() =
        dnsServers.getOrNull(1) ?: (dnsServers.firstOrNull() ?: "8.8.8.8")
    private var bypassLan = true
    private var useWakeLock = false
    private var autoReconnect = false
    private var keepAliveMode = 1
    private var killSwitch = false
    private var hotspotShare = true
    @Volatile private var boundVpnNetwork: Network? = null
    private var splitMode = "off"
    private var splitApps: List<String> = emptyList()
    private var lastDownSpeed = 0L
    private var lastUpSpeed = 0L
    private var connectedAtTimestamp = 0L

    /**
     * When a redelivered ACTION_START continues a killed-process session,
     * the original session start to restore once the tunnel is up. 0 = none.
     */
    private var restoreSessionStartAt = 0L

    /**
     * Service-side session memory, separate from any Flutter storage: the
     * session start survives a process kill (START_REDELIVER_INTENT restart)
     * and is cleared only by an explicit stop, so the home timer keeps
     * counting the SAME session after "kill from recents → reopen".
     */
    private val sessionPrefs by lazy {
        getSharedPreferences("snapdark_session", MODE_PRIVATE)
    }

    private fun persistSessionStart(at: Long) {
        sessionPrefs.edit().putLong("connectedAt", at).apply()
    }

    private fun clearPersistedSession() {
        sessionPrefs.edit().remove("connectedAt").apply()
        restoreSessionStartAt = 0L
    }
    private val notificationHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private val notificationTicker = object : Runnable {
        override fun run() {
            if (connectedAtTimestamp > 0) {
                updateNotification(true)
                notificationHandler.postDelayed(this, 1000)
            }
        }
    }
    private var wakeLock: android.os.PowerManager.WakeLock? = null
    private var wifiLock: android.net.wifi.WifiManager.WifiLock? = null
    private var lastStartIntent: Intent? = null

    /**
     * Consecutive auto-reconnect tries since the last real "connected" state.
     * Exponential backoff (2.5s → 60s, max 6) instead of the old single 2.5s
     * retry — a carrier hiccup or a server that needs a second to release the
     * old session usually heals within the first 3 tries; past that the tunnel
     * is genuinely down and we stop hammering it.
     */
    @Volatile private var reconnectAttempts = 0
    private var mode = ""
    private var isOpenvpn = false
    private var isWireguard = false
    private var isProxy = false
    private var isPsiphon = false
    private var isHysteria = false
    private var wireguardConfig = ""
    private var proxyMode = ""
    private var psiphonRegion = ""
    private var ovpnConfig = ""
    /**
     * Which OpenVPN engine to drive. Default is **2.x** ([OpenVpn2Engine], an
     * exec'd libovpnexec.so on the management interface); `true` selects the
     * openvpn3 ClientAPI ([OpenVpnEngine]) as a fallback. See startOpenVpn for
     * why ovpn2 is the default.
     */
    private var ovpnUseOvpn3 = false
    private var dnsttServer = ""
    private var dnsttKey = ""
    private var dnsttResolver = ""
    private var dnsttProcess: Process? = null
    private var dnsttActive = false
    private val dnsttLocalPort = 7301
    private var payloadEnhanced = false
    private var sshCompression = false
    private var v2rayInject = false
    private val injectLocalPort = 8089
    /**
     * UDP DNS gateway for SSH mode. SSH dynamic forwarding is TCP-only, so port-53
     * UDP has to be re-framed as DNS-over-TCP through the SOCKS proxy.
     */
    private var dnsGateway: DnsUdpToTcpGateway? = null
    private val dnsGatewayPort = 7353
    /** Port the gateway ACTUALLY bound (walks up when 7353 is taken mid-reconnect). */
    private var dnsGatewayActualPort = dnsGatewayPort
    private var dnsGatewayActive = false
    /** Set by the trilead connection monitor when the SSH session drops. */
    private val sshDied = AtomicBoolean(false)
    private var openVpnEngine: OpenVpnEngine? = null
    private var openVpn2Engine: OpenVpn2Engine? = null
    private val xrayOutput = StringBuilder()
    private var sshConnection: Connection? = null
    private var sshForwarder: DynamicPortForwarder? = null
    private var sshHttpBridge: HttpSocksBridge? = null
    /** Local SOCKS5 → upstream-proxy relay for socks/http_proxy configs. */
    private var proxyEngine: ProxyEngine? = null

    // Native binary paths
    private lateinit var xrayBin: File
    private lateinit var hysteriaBin: File
    private lateinit var tun2socksBin: File
    private lateinit var filesDir: File
    private lateinit var configDir: File

    // Stats tracking
    private var lastUpload = 0L
    private var lastDownload = 0L
    private var statsThread: Thread? = null

    /** Set by the screen-on / app-resume receivers: the next watchdog tick
     *  probes immediately instead of waiting out the 20 s cadence. This is the
     *  "phone slept, NAT dropped the flow, I'm back — fix it NOW" path. */
    @Volatile private var livenessUrgent = false

    /** Engine byte total at the previous watchdog pass (openvpn3 has no byte
     *  counters — the ovpn2 engine's numbers are the only proof of life when
     *  the process could not be bound to the VPN network). */
    private var lastEngineBytes = 0L

    /** Dedicated thread for the auto-reconnect backoff sleeps. The old code
     *  slept on statsThread — which cleanup() interrupts (self!), so every
     *  backoff collapsed to 0 ms and all six attempts fired instantly. */
    /**
     * Bumped whenever a scheduled reconnect must die (user Stop, newer attempt,
     * ACTION_START). The backoff thread polls it instead of holding a
     * cancellable Future.
     */
    @Volatile private var reconnectGen = 0
    private var reconnectThread: Thread? = null

    private val reconnectHandler = Handler(Looper.getMainLooper())
    private var reconnectPending: Runnable? = null

    private var livenessReceiver: BroadcastReceiver? = null

    override fun onCreate() {
        super.onCreate()
        instanceRef = java.lang.ref.WeakReference(this)
        filesDir = applicationContext.filesDir
        configDir = File(filesDir, "xray")
        configDir.mkdirs()

        val nativeLibDir = File(applicationInfo.nativeLibraryDir)
        xrayBin = File(nativeLibDir, "libxray.so")
        hysteriaBin = File(nativeLibDir, "libhysteria.so")
        tun2socksBin = File(nativeLibDir, "libtun2socks.so")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                // System-redelivered restart after the process was killed
                // (swipe from recents / OEM kill): the UI is NOT alive. The
                // persisted session start keeps the HOME TIMER continuous —
                // a redelivered reconnect is the SAME user session, not a
                // new one. A user-initiated connect (UI alive) starts fresh.
                if (!MainActivity.uiAlive) {
                    val kept = sessionPrefs.getLong("connectedAt", 0L)
                    if (kept > 0) {
                        restoreSessionStartAt = kept
                        Log.i(TAG, "Redelivered restart: continuing session started at $kept")
                    }
                }

                // A second START while a session is live used to overwrite the
                // ~30 shared fields (isOpenvpnMode, lastStartIntent, server
                // name…) and only THEN be dropped by startVpn()'s running
                // guard — the old tunnel kept running under the new server's
                // identity: wrong ping path (probe bypassed the SOCKS), wrong
                // notification, and the next auto-reconnect dialed a server the
                // user never picked. Same target → ignore the duplicate;
                // different target → it IS a switch: stop first, then adopt.
                val incoming = StartTarget(
                    address = intent.getStringExtra("address") ?: "",
                    port = intent.getIntExtra("port", 443),
                    mode = intent.getStringExtra("mode") ?: "",
                )
                if (running.get()) {
                    if (incoming == currentTarget) {
                        Log.i(TAG, "START for the live target — already running, ignored")
                        return START_REDELIVER_INTENT
                    }
                    Log.i(TAG, "Server switched while live — tearing the old session down first")
                    stopVpn()
                }
                currentTarget = incoming

                config = intent.getStringExtra("config") ?: ""
                serverName = intent.getStringExtra("serverName") ?: ""
                isSsh = intent.getBooleanExtra("isSsh", false)
                sshUser = intent.getStringExtra("sshUser") ?: ""
                sshPass = intent.getStringExtra("sshPass") ?: ""
                sshProxyHost = intent.getStringExtra("injectHost") ?: ""
                sshProxyPort = intent.getStringExtra("injectPort")?.toIntOrNull() ?: 0
                serverAddress = intent.getStringExtra("address") ?: ""
                serverPort = intent.getIntExtra("port", 443)
                serverSni = intent.getStringExtra("sni") ?: ""
                injectModeName = intent.getStringExtra("injectMode") ?: "none"
                payloadTemplate = intent.getStringExtra("payload") ?: ""
                mtu = intent.getIntExtra("mtu", 1500)
// Prefer the ordered list; fall back to the two legacy extras so an older
            // Dart build talking to this engine still gets a working DNS.
            val dnsExtra = intent.getStringArrayListExtra("dnsServers")
            dnsServers = (dnsExtra?.mapNotNull { it?.trim() }?.filter { it.isNotEmpty() })
                ?.takeIf { it.isNotEmpty() }
                ?: listOfNotNull(
                    intent.getStringExtra("dnsPrimary")?.takeIf { it.isNotBlank() },
                    intent.getStringExtra("dnsSecondary")?.takeIf { it.isNotBlank() },
                ).ifEmpty { listOf("8.8.8.8", "8.8.4.4", "1.1.1.1") }
                bypassLan = intent.getBooleanExtra("bypassLan", true)
                useWakeLock = intent.getBooleanExtra("wakeLock", false)
                autoReconnect = intent.getBooleanExtra("autoReconnect", false)
                keepAliveMode = intent.getIntExtra("keepAliveMode", 1).coerceIn(0, 2)
                killSwitch = intent.getBooleanExtra("killSwitch", false)
                hotspotShare = intent.getBooleanExtra("hotspotShare", true)
                splitMode = intent.getStringExtra("splitMode") ?: "off"
                splitApps = intent.getStringArrayListExtra("splitApps")?.toList() ?: emptyList()
                lastStartIntent = Intent(intent)
                mode = intent.getStringExtra("mode") ?: ""
                isOpenvpn = intent.getBooleanExtra("isOpenvpn", false)
                isOpenvpnMode = isOpenvpn
                isWireguard = intent.getBooleanExtra("isWireguard", false)
                isProxy = intent.getBooleanExtra("isProxy", false)
                isPsiphon = intent.getBooleanExtra("isPsiphon", false)
                isHysteria = intent.getBooleanExtra("isHysteria", false)
                wireguardConfig = intent.getStringExtra("wireguardConfig") ?: ""
                proxyMode = intent.getStringExtra("proxyMode") ?: ""
                psiphonRegion = intent.getStringExtra("psiphonRegion") ?: ""
                Companion.activeMode = mode
                ovpnConfig = intent.getStringExtra("ovpnConfig") ?: ""
                ovpnUseOvpn3 = intent.getBooleanExtra("ovpnUseOvpn3", false)
                dnsttServer = intent.getStringExtra("dnsttServer") ?: ""
                dnsttKey = intent.getStringExtra("dnsttKey") ?: ""
                dnsttResolver = intent.getStringExtra("dnsttResolver") ?: ""
                payloadEnhanced = intent.getBooleanExtra("payloadEnhanced", false)
                sshCompression = intent.getBooleanExtra("sshCompression", false)
                v2rayInject = intent.getBooleanExtra("v2rayInject", false)

                // Start foreground immediately to avoid crash on Android 12+
                showNotification()

                Thread { startVpn() }.start()
            }
            ACTION_STOP -> {
                stopVpn()
            }
            ACTION_RECONNECT -> {
                val saved = lastStartIntent
                if (saved != null) {
                    stopVpn()
                    // The 300 ms restart MUST be cancelable: a Stop landing in
                    // that window used to be resurrected by the pending
                    // callback (stopVpn never touched the handler).
                    val r = Runnable {
                        reconnectPending = null
                        saved.action = ACTION_START
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(saved)
                        } else {
                            @Suppress("DEPRECATION")
                            startService(saved)
                        }
                    }
                    reconnectPending = r
                    reconnectHandler.postDelayed(r, 300)
                } else {
                    stopVpn()
                }
            }
        }
        return START_REDELIVER_INTENT
    }

    private fun cancelPendingReconnect() {
        reconnectPending?.let { reconnectHandler.removeCallbacks(it) }
        reconnectPending = null
    }

    /** Called by MainActivity.onResume and the screen-on receiver: force the
     *  watchdog to re-probe on its next ~1 s tick instead of on the 20 s
     *  cadence — "I just unlocked the phone, find out NOW if it still works". */
    fun forceLivenessCheck() {
        if (running.get()) livenessUrgent = true
    }

    private fun registerLivenessReceiver() {
        if (livenessReceiver != null) return
        val r = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                when (intent?.action) {
                    Intent.ACTION_SCREEN_ON,
                    android.os.PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED ->
                        livenessUrgent = true
                }
            }
        }
        val filter = IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_ON)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                addAction(android.os.PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
            }
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(r, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                registerReceiver(r, filter)
            }
            livenessReceiver = r
        } catch (e: Exception) {
            Log.w(TAG, "liveness receiver failed: ${e.message}")
        }
    }

    private fun unregisterLivenessReceiver() {
        try { livenessReceiver?.let { unregisterReceiver(it) } } catch (_: Exception) {}
        livenessReceiver = null
    }

    /** Identity of the running session — used to recognise a duplicate
     *  ACTION_START (system redelivery, double tap) from a real server switch. */
    private data class StartTarget(val address: String, val port: Int, val mode: String)

    @Volatile private var currentTarget = StartTarget("", 0, "")

    private fun startVpn() {
        if (running.getAndSet(true)) {
            Log.w(TAG, "VPN already running")
            return
        }

        // Hard gate: a re-signed / tampered clone must never start. The
        // expected hash lives in libsnapdarkcrypto.so (compile-time define);
        // integrityOk() returns true when it is blank (local debug builds).
        if (!AppSecurity.integrityOk(this)) {
            lastError = "integrity-failed"
            running.set(false)
            Companion.isRunning = false
            Companion.isOpenvpnMode = false
            Companion.activeMode = ""
            emitState("error:$lastError")
            emitLog("Integrity check FAILED — this build is not signed with the official certificate.")
            return
        }

        // Physical-internet gate: devices with "connected, no internet" (SIM
        // data finished, captive portal, dead Wi-Fi) used to fire the whole
        // engine stack at the SHARED FREE relay anyway — 25 s of doomed
        // handshakes, then the auto-reconnect storm. Every user doing this
        // loaded the free servers with traffic they could never serve. Fail
        // fast instead: the app's own sockets are never tunnel-bound anymore,
        // so this probe rides exactly the network the dial would use. The UI
        // must not sit "idle" through the probe window (≤6 s on unvalidated
        // networks) — say connecting first, correct or abort after.
        emitState("connecting")
        if (!physicalInternetOk()) {
            lastError = "no-internet"
            running.set(false)
            Companion.isRunning = false
            Companion.isOpenvpnMode = false
            Companion.activeMode = ""
            emitState("error:$lastError")
            emitLog("No working internet on this device — server was NOT dialed.")
            return
        }

        Companion.isRunning = true
        lastError = ""
        emitState("connecting")

        // A native abort inside libovpncli (SIGSEGV/SIGABRT from a JNI director
        // callback) kills the process with no Java exception and no logcat access
        // on an unrooted device. The phase marker survives that: it is written to
        // disk as we advance and deleted on a clean finish, so the NEXT start can
        // report exactly where the previous session vanished.
        reportPreviousCrash()
        markPhase("start")

        try {
            verifyNativeBinaries()
            copyXrayAssets()
            writeXrayConfig()

            acquireWakeLock()
            registerLivenessReceiver()

            // 3. Create VPN interface. Physical-network check FIRST — after
            // establish() the system's active network IS our own TUN, so the
            // old post-establish wait could never report "no network".
            val builder = Builder()
                .setSession("SnapDark Tunnel")
                .setMtu(mtu)
                .addAddress("26.26.26.1", 30)
                .addRoute("0.0.0.0", 0)
                // Every resolver, in the user's priority order. Android tries them in turn, so
            // one wedged DNS no longer looks like "no internet" (the symptom
            // that started this: YouTube failing to resolve).
            .apply { dnsServers.forEach { dns -> addDnsServer(dns) } }

            // Bypass LAN: exclude private ranges from the tunnel (Android 13+).
            if (bypassLan && Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                try {
                    builder.excludeRoute(android.net.IpPrefix(java.net.InetAddress.getByName("10.0.0.0"), 8))
                    builder.excludeRoute(android.net.IpPrefix(java.net.InetAddress.getByName("172.16.0.0"), 12))
                    builder.excludeRoute(android.net.IpPrefix(java.net.InetAddress.getByName("192.168.0.0"), 16))
                } catch (e: Exception) {
                    Log.w(TAG, "excludeRoute (bypass LAN) failed: ${e.message}")
                }
            }

            // Add IPv6 if supported
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                try {
                    builder.addAddress("fc00::1", 126)
                    builder.addRoute("::", 0)
                } catch (e: Exception) {
                    Log.w(TAG, "IPv6 not supported: ${e.message}")
                }
            }

            applySplitTunnel(builder)

            vpnInterface = builder.establish()
            if (vpnInterface == null) {
                // Permission revoked / config rejected mid-flight — don't spin
                // on a null interface in the probes below.
                throw IOException("VPN interface rejected by the system")
            }
            if (vpnInterface == null) {
                throw IOException("Failed to create VPN interface - permission may be revoked")
            }

            Log.i(TAG, "VPN interface created, fd=${vpnInterface!!.fd}")

            // Soft gate: only block if there is NO network interface at all
            // (airplane mode, SIM out, WiFi off, etc.). We don't require a
            // validated internet path — local / lab / proxy-only setups are
            // legitimate test targets. Give the OS a brief moment to settle.
            if (!waitForAnyNetwork(10_000L)) {
                throw IOException("No network interface (turn on WiFi / mobile data / Ethernet / BT tether)")
            }
            Log.i(TAG, "Network interface up, starting engines")

            showNotification()
            if (isOpenvpn) {
                // OpenVPN drives its own tunnel (no tun2socks).
                markPhase("openvpn")
                startOpenVpn()
            } else if (isWireguard) {
                markPhase("wireguard")
                startWireGuard()
            } else if (isPsiphon) {
                markPhase("psiphon")
                startPsiphon()
            } else if (isHysteria) {
                // Hysteria drives QUIC itself; the local SOCKS5 listener feeds
                // tun2socks exactly like xray's inbound.
                markPhase("hysteria")
                startHysteria()
                startTun2socks()
            } else if (isProxy) {
                markPhase("proxy")
                startProxy()
                // No UDP ASSOCIATE on this listener (same as SSH): the UDP→TCP
                // DNS gateway rides the local SOCKS — start it BEFORE tun2socks
                // so its --dnsgw flag is in the command line.
                startDnsGateway()
                // App-internal HTTP (config refresh, IP check) cannot speak
                // SOCKS — bridge it like the SSH path, or it leaks out the
                // physical interface while connected.
                try {
                    val bridge = HttpSocksBridge("127.0.0.1", 10809, "127.0.0.1", 10808)
                    bridge.start()
                    sshHttpBridge = bridge
                    Log.i(TAG, "HTTP<->SOCKS bridge started on 127.0.0.1:10809 (proxy mode)")
                } catch (e: Exception) {
                    Log.w(TAG, "HTTP bridge failed: ${e.message}")
                    emitLog("HTTP bridge failed: ${e.message} — app self-traffic may bypass the tunnel")
                }
                // The TUN established above was previously READ BY NOTHING:
                // tun2socks must run and point at this engine's local SOCKS5
                // listener (127.0.0.1:10808), exactly like every other
                // local-SOCKS mode (hysteria / ssh / xray).
                startTun2socks()
            } else {
                val wantDnstt = mode.lowercase().contains("dnstt") || (isSsh && dnsttServer.isNotBlank())
                if (isSsh) {
                    if (wantDnstt) startDnstt()
                    startSshSocks()
                } else {
                    // V2Ray-with-payload: front the xray outbound with the local
                    // injector (xray dials 127.0.0.1:injectLocalPort → real server).
                    if (v2rayInject) startV2rayInjector()
                    startXray()
                }
                startTun2socks()
            }

            // 6. Measure initial delay
            measureDelayAsync()

            // 8. Start stats monitoring
            startStatsMonitor()

            // 9. Probe: first verify the local SOCKS / engine socket is ready,
            //    then require a REAL round-trip through the tunnel before we
            //    ever show "connected". A dead server / bad config must land
            //    in the error state, not a fake connected screen.
            emitState("probe:checking")
            if (!runLocalBindProbe()) {
                throw IOException("Tunnel engines started but local SOCKS bind never came up")
            }
            if (!runRealConnectivityProbe()) {
                throw IOException("Tunnel is up but no internet flows through it — server may be down or blocked")
            }

            emitState("connected")
            reconnectAttempts = 0
            connectedAtTimestamp =
                if (restoreSessionStartAt > 0) restoreSessionStartAt
                else System.currentTimeMillis().also { persistSessionStart(it) }
            restoreSessionStartAt = 0L
            notificationHandler.removeCallbacks(notificationTicker)
            notificationHandler.postDelayed(notificationTicker, 1000)
            updateNotification(true)
            noteVpnNetworkHandle()
            clearPhase()
            Log.i(TAG, "VPN connected successfully to $serverName")

        } catch (e: Throwable) {
            Log.e(TAG, "VPN start failed", e)
            // Engine error text (JSch "There was a problem while connecting to
            // host:port", ...) carries the endpoint — redact before it can
            // reach getLastError() and the Dart-side error toast.
            lastError = redact(e.message ?: e.javaClass.simpleName)
            emitState("error:$lastError")
            clearPhase()
            // stopVpn handles cleanup + foreground removal + stopSelf
            stopVpn()
        }
    }

    /** Where the last connect attempt got to; survives a native process abort. */
    private fun phaseFile(): File = File(filesDir, "snapdark_phase.txt")

    private fun markPhase(phase: String) {
        try { phaseFile().writeText("$phase|$serverName|${System.currentTimeMillis()}") } catch (_: Throwable) {}
    }

    private fun clearPhase() {
        try { phaseFile().delete() } catch (_: Throwable) {}
    }

    /**
     * If the previous attempt left a phase marker behind, the process died
     * without unwinding — a native crash. Surface it in the log so the user can
     * report *where* it happened instead of "the app just closed".
     */
    private fun reportPreviousCrash() {
        try {
            val f = phaseFile()
            if (!f.exists()) return
            val parts = f.readText().split("|")
            val phase = parts.getOrNull(0).orEmpty()
            val who = parts.getOrNull(1).orEmpty()
            f.delete()
            if (phase.isNotBlank()) {
                val msg = "Previous session ended abnormally (native crash) at phase '$phase'" +
                    (if (who.isNotBlank()) " on '$who'" else "")
                Log.w(TAG, msg)
                emitLog(msg)
            }
        } catch (_: Throwable) {}
    }

    private fun verifyNativeBinaries() {
        Log.i(TAG, "xray exists: ${xrayBin.exists()}, size: ${xrayBin.length()}")
        Log.i(TAG, "tun2socks exists: ${tun2socksBin.exists()}, size: ${tun2socksBin.length()}")
        if (!xrayBin.exists() || xrayBin.length() == 0L) {
            throw IOException("xray binary missing at ${xrayBin.absolutePath}")
        }
        if (!tun2socksBin.exists() || tun2socksBin.length() == 0L) {
            throw IOException("tun2socks binary missing at ${tun2socksBin.absolutePath}")
        }
    }

    private fun writeXrayConfig() {
        val configFile = File(configDir, "config.json")
        configFile.writeText(config)
        Log.i(TAG, "Xray config written to ${configFile.absolutePath}")
        Log.d(TAG, "Config content: ${config.take(500)}...")
    }

    private fun copyXrayAssets() {
        // geoip/geosite are only needed if the routing config references geoip:/
        // geosite: rules (it currently does not). Copy them if bundled, else skip
        // — keeps the APK ~28MB smaller without breaking xray.
        for (name in listOf("geoip.dat", "geosite.dat")) {
            val target = File(configDir, name)
            if (target.exists() && target.length() > 0) continue
            try {
                assets.open("xray/$name").use { input ->
                    target.outputStream().use { output -> input.copyTo(output) }
                }
            } catch (e: Exception) {
                Log.i(TAG, "geo asset $name not bundled, skipping")
            }
        }
    }

    private fun startWireGuard() {
        val engine = WireGuardEngine(this, wireguardConfig) { err ->
            if (err != null) {
                lastError = "wireguard: $err"
                emitState("error:$lastError")
                handleEngineDeath()
            }
        }
        if (!engine.start()) {
            throw IOException("WireGuard failed to start")
        }
    }

    private fun startPsiphon() {
        val engine = PsiphonEngine(this, psiphonRegion) { err ->
            if (err != null) {
                lastError = "psiphon: $err"
                emitState("error:$lastError")
                handleEngineDeath()
            }
        }
        if (!engine.start()) {
            throw IOException("Psiphon failed to start")
        }
    }

    private fun startProxy() {
        val engine = ProxyEngine(this, proxyMode, serverAddress, serverPort, sshUser, sshPass) { err ->
            if (err != null) {
                lastError = "proxy: $err"
                emitState("error:$lastError")
                handleEngineDeath()
            }
        }
        if (!engine.start()) {
            throw IOException("Proxy failed to start")
        }
        // Keep the reference: stop() must close the 10808 listener on
        // disconnect, or the next session dies with "port in use".
        proxyEngine = engine
    }

    private fun startXray() {
        if (!xrayBin.exists() || xrayBin.length() == 0L) {
            Log.e(TAG, "xray binary not found or empty at ${xrayBin.absolutePath}")
            throw IOException("xray binary not available. Please rebuild the app with native binaries.")
        }

        val configPath = File(configDir, "config.json").absolutePath

        val cmd = arrayOf(
            xrayBin.absolutePath,
            "run",
            "-c", configPath
        )

        Log.i(TAG, "Starting xray: ${cmd.joinToString(" ")}")
        synchronized(xrayOutput) { xrayOutput.clear() }

        val processBuilder = ProcessBuilder(*cmd)
            .redirectErrorStream(true)
            .directory(configDir)

        // Set environment for xray
        val env = processBuilder.environment()
        env["XRAY_LOCATION_ASSET"] = configDir.absolutePath

        xrayProcess = processBuilder.start()

        // Read xray output in a thread
        Thread {
            try {
                val reader = xrayProcess!!.inputStream.bufferedReader()
                var line: String?
                while (reader.readLine().also { line = it } != null) {
                    Log.d(TAG, "xray: $line")
                    synchronized(xrayOutput) {
                        xrayOutput.appendLine(line)
                        if (xrayOutput.length > 4000) {
                            xrayOutput.delete(0, xrayOutput.length - 4000)
                        }
                    }
                }
            } catch (e: Exception) {
                if (running.get()) {
                    Log.e(TAG, "xray output reader error", e)
                }
            }
        }.start()

        // Wait for xray to start
        var waitCount = 0
        while (waitCount < 30) { // 3 seconds max
            Thread.sleep(100)
            waitCount++
            if (!xrayProcess!!.isAlive) {
                val exitCode = xrayProcess!!.exitValue()
                Thread.sleep(100)
                throw IOException("xray failed (exit $exitCode): ${recentXrayOutput()}")
            }
            // Check if SOCKS port is ready
            try {
                val testSocket = Socket()
                testSocket.connect(InetSocketAddress("127.0.0.1", 10808), 100)
                testSocket.close()
                Log.i(TAG, "xray SOCKS5 port is ready")
                break
            } catch (e: Exception) {
                // Port not ready yet, wait more
            }
        }

        if (!xrayProcess!!.isAlive) {
            throw IOException("xray died during startup: ${recentXrayOutput()}")
        }

        Log.i(TAG, "xray started successfully (PID: ${getProcessId(xrayProcess!!)})")
    }

    /**
     * Start the Hysteria 2 client (libhysteria.so) in client mode with the
     * config Dart generated (SOCKS5 listener on 10808 feeds tun2socks, exactly
     * like xray's inbound). The "connected" round-trip probe then validates the
     * QUIC tunnel the same way it does for xray.
     */
    private fun startHysteria() {
        if (!hysteriaBin.exists() || hysteriaBin.length() == 0L) {
            Log.e(TAG, "hysteria binary not found or empty at ${hysteriaBin.absolutePath}")
            throw IOException("hysteria not available. Please rebuild the app with native binaries.")
        }

        val configPath = File(configDir, "hysteria.json")
        // Dart sends the hysteria JSON as the `config` extra when isHysteria
        // (the startVpn branch passes either xray or hysteria config).
        val configStr = config
        if (configStr.isBlank()) {
            throw IOException("hysteria config missing")
        }
        configPath.writeText(configStr)

        val cmd = arrayOf(
            hysteriaBin.absolutePath,
            "client",
            "-c", configPath.absolutePath
        )

        Log.i(TAG, "Starting hysteria: ${cmd.joinToString(" ")}")
        synchronized(xrayOutput) { xrayOutput.clear() }

        val processBuilder = ProcessBuilder(*cmd)
            .redirectErrorStream(true)
            .directory(configDir)
        val env = processBuilder.environment()
        env["HOME"] = configDir.absolutePath
        hysteriaProcess = processBuilder.start()

        Thread {
            try {
                val reader = hysteriaProcess!!.inputStream.bufferedReader()
                var line: String?
                while (reader.readLine().also { line = it } != null) {
                    Log.d(TAG, "hysteria: $line")
                    synchronized(xrayOutput) {
                        xrayOutput.appendLine(line)
                        if (xrayOutput.length > 4000) {
                            xrayOutput.delete(0, xrayOutput.length - 4000)
                        }
                    }
                }
            } catch (e: Exception) {
                if (running.get()) {
                    Log.e(TAG, "hysteria output reader error", e)
                }
            }
        }.start()

        var waitCount = 0
        while (waitCount < 50) { // 5 seconds max (QUIC handshake is slower than xray's)
            Thread.sleep(100)
            waitCount++
            if (!hysteriaProcess!!.isAlive) {
                val exitCode = hysteriaProcess!!.exitValue()
                Thread.sleep(100)
                throw IOException("hysteria failed (exit $exitCode): ${recentXrayOutput()}")
            }
            try {
                val testSocket = Socket()
                testSocket.connect(InetSocketAddress("127.0.0.1", 10808), 100)
                testSocket.close()
                Log.i(TAG, "hysteria SOCKS5 port is ready")
                break
            } catch (e: Exception) {
                // Port not ready yet, wait more
            }
        }

        if (!hysteriaProcess!!.isAlive) {
            throw IOException("hysteria died during startup: ${recentXrayOutput()}")
        }

        Log.i(TAG, "hysteria started successfully (PID: ${getProcessId(hysteriaProcess!!)})")
    }

    /**
     * Start the dnstt/slowDNS client (libh2.so) which tunnels TCP over DNS and
     * exposes a local port that maps to the server's SSH endpoint. SSH then
     * connects to 127.0.0.1:dnsttLocalPort.
     *
     * NOTE: dnstt CLI args vary by build — these are best-effort and may need
     * tuning against the actual libh2 on a device.
     */
    private fun startDnstt() {
        val bin = File(File(applicationInfo.nativeLibraryDir), "libh2.so")
        if (!bin.exists() || bin.length() == 0L) throw IOException("dnstt (libh2) binary missing")
        if (dnsttServer.isBlank()) throw IOException("DNSTT server (nameserver) is required")
        val resolver = dnsttResolver.ifBlank { "$dnsPrimary:53" }
        val cmd = arrayListOf(
            bin.absolutePath,
            "-udp", resolver,
            "-pubkey", dnsttKey,
            dnsttServer,
            "127.0.0.1:$dnsttLocalPort"
        )
        Log.i(TAG, "Starting dnstt: ${cmd.joinToString(" ")}")
        dnsttProcess = ProcessBuilder(cmd).redirectErrorStream(true).directory(filesDir).start()
        Thread {
            try {
                dnsttProcess!!.inputStream.bufferedReader().forEachLine { Log.d(TAG, "dnstt: $it") }
            } catch (_: Exception) {}
        }.start()
        Thread.sleep(1200)
        if (dnsttProcess?.isAlive != true) {
            throw IOException("dnstt failed to start (exit ${try { dnsttProcess?.exitValue() } catch (_: Exception) { "?" }})")
        }
        dnsttActive = true
        Log.i(TAG, "dnstt active on 127.0.0.1:$dnsttLocalPort")
    }

    /**
     * Start OpenVPN via the OpenVPN3 ClientAPI JNI library (libovpncli.so).
     *
     * The profile is optionally fronted by [PayloadInjector] for SNI/payload
     * DPI bypass, then handed to [OpenVpnEngine] which loads libovpncli.so and
     * drives the tunnel through its tun_builder callbacks against this VpnService.
     *
     * If the JNI surface doesn't match the .so on this device
     * (UnsatisfiedLinkError / AbstractMethodError) we tear down cleanly and
     * surface the cause so the user can see it.
     */
    /**
     * Emit the connect-time profile diagnostics: sha256 of the first inline
     * `<ca>` (as DER), its DER size, and the flags that decide how the engine
     * treats the profile. Must never throw — diagnostics only.
     */
    private fun logOvpnProfileDiagnostics(profile: String, remoteHost: String, remotePort: Int) {
        runCatching {
            val caBlock = Regex("(?is)<ca>(.*?)</ca>").find(profile)?.groupValues?.get(1)
            if (caBlock == null) {
                emitLog("OpenVPN profile: NO <ca> block — server cert verification cannot succeed")
            } else {
                val b64 = caBlock
                    .replace(Regex("(?i)-----BEGIN CERTIFICATE-----"), "")
                    .replace(Regex("(?i)-----END CERTIFICATE-----"), "")
                    .replace(Regex("\\s+"), "")
                val der = android.util.Base64.decode(b64, android.util.Base64.DEFAULT)
                val hex = java.security.MessageDigest.getInstance("SHA-256")
                    .digest(der).joinToString("") { "%02x".format(it) }
                emitLog("OpenVPN profile CA sha256=${hex.take(16)}… (${der.size} bytes DER)")
            }
            val hasClientCert = Regex("(?i)<cert\\b").containsMatchIn(profile) ||
                Regex("(?im)^\\s*cert\\s+\\S+").containsMatchIn(profile)
            val hasAuth = Regex("(?im)^\\s*auth-user-pass").containsMatchIn(profile)
            val hasRemoteCertTls = Regex("(?im)^\\s*remote-cert-tls\\b").containsMatchIn(profile)
            emitLog(
                "OpenVPN profile: ${profile.length} chars, remote=$remoteHost:$remotePort, " +
                    "remote-cert-tls=$hasRemoteCertTls, client-cert=$hasClientCert, " +
                    "auth-user-pass=$hasAuth",
            )
        }
    }

    private fun startOpenVpn() {
        val soFile = File(File(applicationInfo.nativeLibraryDir), "libovpncli.so")
        if (!soFile.exists() || soFile.length() == 0L) {
            throw IOException("libovpncli.so missing at ${soFile.absolutePath}")
        }
        if (ovpnConfig.isBlank()) throw IOException("OpenVPN .ovpn config is empty")

        // Parse the first remote host/port from the profile.
        val remoteMatch = Regex("(?im)^\\s*remote\\s+(\\S+)(?:\\s+(\\d+))?(?:\\s+(tcp|udp))?")
            .find(ovpnConfig)
        val remoteHost = remoteMatch?.groupValues?.getOrNull(1)?.takeIf { it.isNotBlank() }
            ?: serverAddress
        val remotePort = remoteMatch?.groupValues?.getOrNull(2)?.toIntOrNull()
            ?: if (serverPort > 0) serverPort else 1194

        var profile = ovpnConfig

        // Fingerprint the <ca> the engine will verify against. The server's
        // certs were re-issued 2026-08-27 (correct digest 98bfe442…); a stale
        // import or an old panel/local entry shows up here immediately instead
        // of burning a 20s cycle on an opaque CERT_VERIFY_FAIL.
        logOvpnProfileDiagnostics(profile, remoteHost, remotePort)

        // OpenVPN-with-payload/SNI: front the OpenVPN TCP stream with the local
        // injector, exposed as an HTTP proxy (`http-proxy 127.0.0.1 <port>`)
        // rather than by rewriting `remote` to 127.0.0.1.
        //
        // Why the proxy form: openvpn3 dials the proxy, sends
        // `CONNECT <real-host>:<port>`, and only starts its own handshake after
        // the 200. That gives the relay the real target per connection (so
        // `[raw]`/`[netData]` payload tokens carry the actual request line), keeps
        // multi-remote profiles intact, and matches how DarkTunnel/HTTP Injector
        // drive OpenVPN. Rewriting `remote` instead made openvpn3 believe the
        // server WAS 127.0.0.1 — `remote-cert`/host checks and any second remote
        // silently broke, and a blank payload sent nothing at all.
        //
        // A profile that already carries its own `http-proxy`/`http-proxy-option`
        // lines is left alone: the user is driving openvpn3's native proxy support
        // deliberately, and stacking ours on top would double-CONNECT.
        // OpenVPN3 (our libovpncli.so) cannot parse `http-proxy-option
        // CUSTOM-HEADER` — those value keys are absent from the binary. But our
        // PayloadInjector performs exactly the same CONNECT-header injection, so
        // translate the profile's http-proxy / CUSTOM-HEADER lines into the
        // injector instead of handing the raw profile to ovpn3 (which would
        // reject it). pointOvpnAtLocalProxy() already strips http-proxy and
        // http-proxy-option lines and appends `http-proxy 127.0.0.1 <port>`, so
        // ovpn3 only ever sees a clean profile aimed at our local relay.
        val customHeaderRe = Regex("(?im)^\\s*http-proxy-option\\s+CUSTOM-HEADER\\s+(.*)\\s*$")
        val ownProxyRe = Regex("(?im)^\\s*http-proxy\\s+(\\S+)\\s+(\\d+)")
        val customHeaders = mutableListOf<String>()
        var ownProxyHost: String? = null
        var ownProxyPort = 0
        for (ln in profile.lineSequence()) {
            customHeaderRe.find(ln)?.let { customHeaders.add(it.groupValues[1].trim()) }
            ownProxyRe.find(ln)?.let { m ->
                ownProxyHost = m.groupValues[1]
                ownProxyPort = m.groupValues[2].toIntOrNull() ?: 0
            }
        }
        val profileHasOwnProxy = ownProxyHost != null
        // Force the injector for CUSTOM-HEADER (ovpn3 can't do it) or when the
        // profile brings its own http-proxy and the user enabled injection.
        val customHeaderInject = customHeaders.isNotEmpty()

        // The injector is a TCP relay: fronting a UDP profile with it forces
        // `proto tcp` against a UDP-only port and the session can never come
        // up. Bypass injection for UDP profiles and dial them directly.
        val profileIsUdp = Regex("(?im)^\\s*proto\\s+udp").containsMatchIn(profile) ||
            Regex("(?im)^\\s*remote\\s+\\S+(?:\\s+\\d+)?\\s+udp").containsMatchIn(profile)

        // OpenVPN3 does its own TLS and CANNOT spoof a custom SNI by itself. The
        // directSni mode replicates OpenVPN Lite's "Direct SSL/TLS" wire shape:
        // outer TLS handshake with the SPOOFED SNI — the front presents its own
        // cert (trust-all on the outer hop; the inner OpenVPN TLS does the real
        // verification) — then RAW OpenVPN bytes piped through. Lite's
        // `TO PROXY: CONNECT …` is ovpn3 talking to its LOCAL back server, never
        // on the wire; sending a CONNECT inside the outer TLS makes the front
        // close instantly. A blank payload therefore stays blank; a user payload
        // is sent as-is right after the handshake. The in-flight ClientHello
        // rewrite is useless for OpenVPN: ovpn3 frames its TLS inside control
        // packets, so a raw ClientHello never appears at byte 0. We also inject
        // for a CUSTOM-HEADER translation, or a real upstream proxy mode aimed
        // at our configured proxy host (not a profile that already carries its
        // own http-proxy — ovpn3 handles that natively).
        val sniMode = injectModeName.equals("directSni", true)
        val realProxyMode = injectModeName.equals("proxy", true) ||
            injectModeName.equals("proxysni", true) || injectModeName.equals("proxySni", true)
        // Plain `direct` mode WITH a payload must still front the OpenVPN TCP
        // stream with the injector: the relay writes the HTTP Upgrade payload
        // to the real server (which replies 101), then OpenVPN handshake flows.
        // Skipping the injector here connected ovpn2 straight to the server with
        // no payload, so it never replied (bytes in=0, no OPENTUN).
        val directPayload = injectModeName.equals("direct", true) &&
            payloadTemplate.isNotBlank() && !profileIsUdp
        val useInject = customHeaderInject || sniMode || directPayload ||
            (realProxyMode && !profileHasOwnProxy && sshProxyHost.isNotBlank() && !profileIsUdp)
        if (profileHasOwnProxy && !customHeaderInject && injectModeName.lowercase() != "none") {
            emitLog("OpenVPN: profile has its own http-proxy line — using ovpn3 native proxy, injector skipped")
        }
        if (profileIsUdp && injectModeName.lowercase() != "none") {
            emitLog("OpenVPN: UDP profile — injector is TCP-only, connecting directly over UDP")
        }
        if (useInject) {
            val inj = if (customHeaderInject) {
                val headerBlock = if (customHeaders.isNotEmpty()) {
                    customHeaders.joinToString("") { arg ->
                        val sp = arg.indexOf(' ')
                        if (sp >= 0) "${arg.substring(0, sp)}: ${arg.substring(sp + 1).trim()}\r\n"
                        else "$arg\r\n"
                    }
                } else ""
                val payloadTpl = if (headerBlock.isNotEmpty()) {
                    "CONNECT [real_host_port] HTTP/1.0\r\n$headerBlock\r\n"
                } else ""
                if (customHeaders.isNotEmpty()) {
                    emitLog("OpenVPN: translated http-proxy-option CUSTOM-HEADER (${customHeaders.size}) into local injector relay")
                }
                Triple(
                    PayloadInjector.Mode.PROXY,
                    payloadTpl,
                    (ownProxyHost ?: sshProxyHost) to (if (ownProxyPort > 0) ownProxyPort else sshProxyPort),
                )
            } else if (sniMode) {
                // directSni = OpenVPN Lite "Direct SSL/TLS": outer TLS wrap with
                // the spoofed SNI; user payload (blank → raw pipe) inside it.
                Triple(
                    PayloadInjector.Mode.DIRECT_SNI,
                    payloadTemplate,
                    remoteHost to remotePort,
                )
            } else {
                Triple(
                    PayloadInjector.modeFrom(injectModeName),
                    payloadTemplate,
                    sshProxyHost to sshProxyPort,
                )
            }
            val injector = PayloadInjector(
                mode = inj.first,
                targetHost = remoteHost,
                targetPort = remotePort,
                proxyHost = inj.third.first,
                proxyPort = inj.third.second,
                sni = serverSni,
                payloadTemplate = inj.second,
                payloadEnhanced = payloadEnhanced,
                prelude = PayloadInjector.Prelude.HTTP_HEADERS,
                frontend = PayloadInjector.Frontend.HTTP_CONNECT,
                tcpKeepaliveIdleSec = tcpKeepAliveIdleSec(),
                // directSni (SSL/TLS): wrap the upstream in outer TLS carrying
                // the spoofed SNI — the SNI-fronted OpenVPN shape. Custom-header
                // translation stays a plain PROXY relay (its http-proxy already
                // is the bug host) and proxySni wraps via PROXY_SNI itself.
                wrapOuterTls = sniMode && !customHeaderInject,                // OpenVPN3 builds its own TUN, so the relay's upstream socket has
                // to be protected or the tunnel's own bytes get routed into it.
                socketProtector = { sock -> protect(sock) },
            )
            val localPort = injector.start()
            payloadInjector = injector
            profile = pointOvpnAtLocalProxy(profile, localPort)
            val upstream = if (customHeaderInject) {
                "${ownProxyHost ?: sshProxyHost}:${if (ownProxyPort > 0) ownProxyPort else sshProxyPort}"
            } else {
                "$remoteHost:$remotePort"
            }
            Log.i(TAG, "OpenVPN via injector proxy 127.0.0.1:$localPort -> $upstream (mode=${inj.first}) sni=$serverSni")
            emitLog("OpenVPN via payload injector (http-proxy 127.0.0.1:$localPort → $upstream)")
        } else {
            emitLog("OpenVPN: connecting directly to $remoteHost:$remotePort (no injector; ovpn3 does its own TLS)")
        }

        // Provide credentials via a creds file referenced by auth-user-pass
        // (portable across OpenVPN builds). Only when the user supplied them.
        if (sshUser.isNotBlank()) {
            val credsFile = File(filesDir, "ovpn_creds.txt")
            credsFile.writeText("$sshUser\n$sshPass\n")
            val authRe = Regex("(?im)^\\s*auth-user-pass.*$")
            profile = if (authRe.containsMatchIn(profile)) {
                profile.replace(authRe, "auth-user-pass ${credsFile.absolutePath}")
            } else {
                profile + "\nauth-user-pass ${credsFile.absolutePath}\n"
            }
        }

        // Tear down the VpnService.Builder interface we created in startVpn();
        // the OpenVpnEngine creates its OWN interface via its TunBuilder. If
        // we keep both, traffic routes nowhere.
        try { vpnInterface?.close() } catch (_: Exception) {}
        vpnInterface = null

        // Drive the engine.
        //
        // OpenVPN **2.x** (libovpnexec.so, management interface) is the default:
        // openvpn3's ClientAPI could not carry data against this server — every
        // compressionMode it offers (no/yes/asym) framed the uplink in a way the
        // server dropped, and it also rejects the legacy directives these
        // profiles use (`cipher none`, `auth none`, `comp-lzo`, CUSTOM-HEADER).
        // ovpn2 is what HTTP Custom / OpenVPN Lite run, and it accepts the
        // profile as written. The openvpn3 engine is kept behind
        // `ovpnUseLegacyEngine` purely as a fallback.
        if (!ovpnUseOvpn3) {
            val engine2 = OpenVpn2Engine(
                vpnService = this,
                profileText = profile,
                sessionName = serverName.ifBlank { "SnapDark OpenVPN" },
                mtu = mtu,
                dnsPrimary = dnsPrimary,
                dnsSecondary = dnsSecondary,
            )
            openVpn2Engine = engine2
            try {
                markPhase("openvpn2:engine")
                emitLog("OpenVPN engine: 2.x (libovpnexec.so, management interface)")
                engine2.start()
                Log.i(TAG, "OpenVPN2 session up")
            } catch (e: Throwable) {
                try { engine2.stop() } catch (_: Exception) {}
                openVpn2Engine = null
                throw IOException(
                    "OpenVPN 2.x engine failed (${e.javaClass.simpleName}: ${e.message})",
                    e,
                )
            }
            return
        }

        val engine = OpenVpnEngine(
            vpnService = this,
            profileText = profile,
            sessionName = serverName.ifBlank { "SnapDark OpenVPN" },
            mtu = mtu,
            dnsPrimary = dnsPrimary,
            dnsSecondary = dnsSecondary,
            keepAlivePingSec = ovpnKeepAlivePingSec(),
        )
        openVpnEngine = engine
        try {
            markPhase("openvpn:engine")
            emitLog("OpenVPN engine: 3.x (libovpncli.so, legacy fallback)")
            engine.start()
            // We no longer adopt the fd into vpnInterface because the OpenVPN
            // C++ library owns the file descriptor and handles closing it.
            Log.i(TAG, "OpenVPN session up via libovpncli.so")
        } catch (e: Throwable) {
            // Clean engine + remove from record so cleanup() doesn't double-stop.
            try { engine.stop() } catch (_: Exception) {}
            openVpnEngine = null
            throw IOException(
                "OpenVPN JNI engine failed (${e.javaClass.simpleName}: ${e.message}). " +
                    "Verify libovpncli.so is the matching build for this JNI surface.",
                e,
            )
        }
    }

    /**
     * Point the profile at the local injector as an HTTP proxy and force
     * `proto tcp` (the relay, and HTTP CONNECT proxying in general, is TCP-only).
     *
     * `remote` lines are left untouched on purpose — openvpn3 needs the real host
     * to build its CONNECT request, verify the certificate name and fail over to
     * a second remote.
     */
    private fun pointOvpnAtLocalProxy(cfg: String, localPort: Int): String {
        val protoRe = Regex("^\\s*proto\\s+(tcp|tcp-client|tcp4|tcp6|udp).*$", RegexOption.IGNORE_CASE)
        val remoteRe = Regex("^(\\s*remote\\s+\\S+(?:\\s+\\d+)?)\\s+(tcp|udp)(\\S*)\\s*$", RegexOption.IGNORE_CASE)
        val proxyRe = Regex("^\\s*http-proxy(-option|-user-pass)?\\s+.*$", RegexOption.IGNORE_CASE)
        var protoDone = false
        val lines = cfg.lines().map { line ->
            when {
                protoRe.matches(line) -> {
                    protoDone = true
                    "proto tcp"
                }
                // `remote host port udp` overrides `proto tcp`; rewrite the
                // per-remote protocol too or openvpn3 still dials UDP.
                remoteRe.matches(line) ->
                    remoteRe.replace(line) { m -> "${m.groupValues[1]} tcp" }
                // Drop any stale proxy directive so ours is the only one.
                proxyRe.matches(line) -> ";$line"
                else -> line
            }
        }.toMutableList()
        if (!protoDone) lines.add("proto tcp")
        lines.add("http-proxy 127.0.0.1 $localPort")
        // No `http-proxy-option` here: this libovpncli.so build carries the
        // `http-proxy-option` keyword but none of its value keys (VERSION/AGENT/
        // CUSTOM_HEADER are absent from the binary's string table), so passing one
        // risks an "unknown option" parse error. The relay supplies the payload
        // anyway, which is what those options would have been used for.
        return lines.joinToString("\n")
    }

    /**
     * Front the xray V2Ray outbound with the local payload injector. xray dials
     * 127.0.0.1:injectLocalPort (set in the generated config); the injector sends
     * the HTTP payload (or proxies via a bug host) then relays to the real
     * server. TLS/SNI stays with xray — the injector does NOT wrap TLS here.
     */
    private fun startV2rayInjector() {
        if (serverAddress.isBlank()) throw IOException("V2Ray inject needs a server address")
        // Force a non-TLS-wrapping mode (DIRECT/PROXY); xray handles TLS itself.
        val mode = if (sshProxyHost.isNotBlank() && sshProxyPort > 0) {
            PayloadInjector.Mode.PROXY
        } else {
            PayloadInjector.Mode.DIRECT
        }
        val injector = PayloadInjector(
            mode = mode,
            targetHost = serverAddress,
            targetPort = serverPort,
            proxyHost = sshProxyHost,
            proxyPort = sshProxyPort,
            // Passing the SNI/bug host lets `[host]` in the payload render to it.
            // Safe here: the injector only wraps TLS in the *_SNI modes, and this
            // path forces DIRECT/PROXY.
            sni = serverSni,
            // A blank payload gets the fake-response opener that
            // `v2rayinject.py`-style servers expect: they answer with a 101,
            // then route the tunnel's real handshake (arriving next) by path.
            payloadTemplate = payloadTemplate.ifBlank { "HTTP/1.1 200 OK\r\n\r\n" },
            payloadEnhanced = payloadEnhanced,
            prelude = PayloadInjector.Prelude.HTTP_HEADERS,
            tcpKeepaliveIdleSec = tcpKeepAliveIdleSec(),
            // Downstream is xray's ws transport: any-type payloads are consumed
            // by v2relay-style servers for routing, so the relay must terminate
            // xray's websocket locally instead of forwarding its handshake.
            terminateWs = true,
            // tun2socks routes everything through the TUN; keep the relay's own
            // upstream socket outside it.
            socketProtector = { sock -> protect(sock) },
        )
        injector.start(injectLocalPort)
        payloadInjector = injector
        Log.i(TAG, "V2Ray injector 127.0.0.1:$injectLocalPort -> $serverAddress:$serverPort mode=$mode enhanced=$payloadEnhanced")
    }

    private fun startSshSocks() {
        if (serverAddress.isBlank() || sshUser.isBlank() || sshPass.isBlank()) {
            throw IOException("SSH host, username, and password are required")
        }

        sshDied.set(false)
        // dnstt and payload injection are alternative ways of reaching the SSH
        // port, but they compose: the injector can front the local dnstt
        // endpoint. Only skip injection when there is genuinely nothing to do.
        val useInject = injectModeName.isNotBlank() &&
            injectModeName.lowercase() !in setOf("none", "dnstt")
        val sshHost = if (dnsttActive) "127.0.0.1" else serverAddress
        val sshPort = if (dnsttActive) dnsttLocalPort else serverPort

        val connection: Connection
        if (useInject) {
            // Route the SSH stream through the local payload injector for DPI bypass.
            val injector = PayloadInjector(
                mode = PayloadInjector.modeFrom(injectModeName),
                targetHost = sshHost,
                targetPort = sshPort,
                proxyHost = sshProxyHost,
                proxyPort = sshProxyPort,
                sni = serverSni,
                payloadTemplate = payloadTemplate,
                payloadEnhanced = payloadEnhanced,
                tcpKeepaliveIdleSec = tcpKeepAliveIdleSec(),
                socketProtector = { sock -> protect(sock) },
            )
            val localPort = injector.start()
            payloadInjector = injector
            connection = Connection("127.0.0.1", localPort)
            connection.setCompression(sshCompression)
            try {
                connection.connect(null, 12000, 12000)
            } catch (e: Throwable) {
                // Walk the whole chain: the interesting failure is usually two or
                // three levels down (a missing cipher class in release builds
                // surfaced only as "Key exchange was not finished").
                val chain = StringBuilder()
                var cause = e.cause
                var depth = 0
                while (cause != null && depth < 6) {
                    chain.append("; cause[").append(depth).append("]=")
                        .append(cause.javaClass.simpleName).append(": ").append(cause.message)
                    cause = cause.cause
                    depth++
                }
                val msg = "SSH connect failed via injector: ${e.javaClass.simpleName}: ${e.message}$chain"
                Log.e(TAG, msg, e)
                emitLog(msg)
                throw e
            }
            Log.i(
                TAG,
                "SSH via payload injector (mode=$injectModeName enhanced=$payloadEnhanced dnstt=$dnsttActive)"
            )
        } else {
            connection = Connection(sshHost, sshPort)
            connection.setCompression(sshCompression)
            if (!dnsttActive && sshProxyHost.isNotBlank() && sshProxyPort > 0) {
                connection.setProxyData(HTTPProxyData(sshProxyHost, sshProxyPort))
            }
            connection.connect(null, 12000, 12000)
            if (dnsttActive) Log.i(TAG, "SSH over DNSTT tunnel")
        }
        if (sshCompression) Log.i(TAG, "SSH compression enabled")

        connection.addConnectionMonitor(object : ConnectionMonitor {
            override fun connectionLost(reason: Throwable?) {
                // Without this the stats watchdog had nothing to check for SSH
                // and a dropped session looked "connected" until a liveness
                // probe happened to fail.
                if (!running.get()) return
                sshDied.set(true)
                val why = reason?.let { "${it.javaClass.simpleName}: ${it.message}" } ?: "unknown"
                Log.w(TAG, "SSH connection lost: $why")
                emitLog("SSH connection lost: $why")
            }
            override fun onReceiveInfo(infoId: Int, infoMsg: String?) {
                if (infoId == ConnectionMonitor.SERVER_BANNER && infoMsg != null) {
                    Log.i(TAG, "SSH MOTD: $infoMsg")
                    emitState("motd:$infoMsg")
                }
            }
            override fun log(level: Int, className: String?, message: String?) {}
        })
        val authed = try {
            connection.authenticateWithPassword(sshUser, sshPass)
        } catch (e: Throwable) {
            val msg = "SSH auth error: ${e.javaClass.simpleName}: ${e.message}"
            Log.e(TAG, msg, e)
            emitLog(msg)
            connection.close()
            throw e
        }
        if (!authed) {
            connection.close()
            emitLog("SSH authentication failed")
            throw IOException("SSH authentication failed")
        }
        // Bind the SOCKS listener. Hotspot share ON binds all interfaces
        // (0.0.0.0) so Wi-Fi clients can reach it; OFF binds loopback so only
        // the app itself (via tun2socks -> 127.0.0.1:10808) can use it.
        // NOTE: an all-interface bind is an unauthenticated proxy reachable by
        // anyone on the same Wi-Fi while connected — intentional for hotspot
        // sharing, but it is the reason to keep the tunnel off untrusted nets.
        val bindHost = if (hotspotShare) "0.0.0.0" else "127.0.0.1"
        sshForwarder = connection.createDynamicPortForwarder(
            InetSocketAddress(bindHost, 10808)
        )
        sshConnection = connection
        Log.i(TAG, "SSH SOCKS started on 127.0.0.1:10808 (inject=$useInject)")

        // The app's own HTTP stack cannot speak SOCKS — give it the same
        // local HTTP port xray exposes (10809) by bridging HTTP <-> SOCKS so
        // app-internal requests (IP/location check, config refresh) ride the
        // SSH tunnel instead of leaking out the physical interface.
        try {
            val bridge = HttpSocksBridge(bindHost, 10809, "127.0.0.1", 10808)
            bridge.start()
            sshHttpBridge = bridge
            Log.i(TAG, "HTTP<->SOCKS bridge started on $bindHost:10809")
        } catch (e: Exception) {
            Log.w(TAG, "HTTP<->SOCKS bridge failed: ${e.message}")
            emitLog("HTTP bridge failed: ${e.message} — app self-traffic may bypass the tunnel")
        }

        startDnsGateway()
    }

    /**
     * SSH mode only: bring up the UDP→TCP DNS gateway that tun2socks redirects
     * port-53 traffic to. Without it every lookup fails, because SSH dynamic
     * forwarding implements SOCKS CONNECT only — there is no UDP ASSOCIATE.
     */
    private fun startDnsGateway() {
        val upstream = listOf(dnsPrimary, dnsSecondary)
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .map { if (it.contains(':')) it else "$it:53" }
            .ifEmpty { listOf("1.1.1.1:53", "8.8.8.8:53") }
        try {
            val gw = DnsUdpToTcpGateway(
                listenPort = dnsGatewayPort,
                socksHost = "127.0.0.1",
                socksPort = 10808,
                upstreamDns = upstream,
            )
            gw.start()
            dnsGateway = gw
            dnsGatewayActive = true
            dnsGatewayActualPort = gw.actualPort
            emitLog("DNS gateway on 127.0.0.1:${gw.actualPort} (DNS-over-TCP via SSH)")
        } catch (e: Exception) {
            dnsGatewayActive = false
            dnsGatewayActualPort = dnsGatewayPort
            Log.w(TAG, "DNS gateway failed to start: ${e.message}")
            emitLog("DNS gateway failed: ${e.message} — name resolution may not work")
        }
    }

    private fun recentXrayOutput(): String {
        return synchronized(xrayOutput) {
            xrayOutput.toString().trim().ifEmpty { "no xray output" }
        }
    }

    private fun startTun2socks() {
        if (!tun2socksBin.exists() || tun2socksBin.length() == 0L) {
            Log.e(TAG, "tun2socks binary not available - VPN will not route traffic")
            throw IOException("tun2socks binary not available. Please rebuild the app with native binaries.")
        }

        val cmd = arrayListOf(
            tun2socksBin.absolutePath,
            "--netif-ipaddr", "26.26.26.2",
            "--netif-netmask", "255.255.255.252",
            "--socks-server-addr", "127.0.0.1:10808",
            "--tunmtu", mtu.toString(),
            "--sock-path", File(filesDir, "sock_path").absolutePath,
            "--enable-udprelay",
            "--loglevel", "notice"
        )

        // SSH mode: SOCKS has no UDP ASSOCIATE, so hand port-53 traffic to the
        // local DNS-over-TCP gateway instead of letting it vanish into udprelay.
        if (dnsGatewayActive) {
            cmd.add("--dnsgw")
            cmd.add("127.0.0.1:$dnsGatewayActualPort")
        }

        Log.i(TAG, "Starting tun2socks: ${cmd.joinToString(" ")}")

        val processBuilder = ProcessBuilder(cmd)
            .redirectErrorStream(true)
            .directory(filesDir)

        tun2socksProcess = processBuilder.start()

        // Read output
        Thread {
            try {
                val reader = tun2socksProcess!!.inputStream.bufferedReader()
                var line: String?
                while (reader.readLine().also { line = it } != null) {
                    Log.d(TAG, "tun2socks: $line")
                }
            } catch (e: Exception) {
                if (running.get()) {
                    Log.e(TAG, "tun2socks output reader error", e)
                }
            }
        }.start()

        sendTunFd()
        Thread.sleep(500)

        if (!tun2socksProcess!!.isAlive) {
            Log.e(TAG, "tun2socks failed to start")
            throw IOException("tun2socks failed to start")
        }

        Log.i(TAG, "tun2socks started successfully")
    }

    private fun sendTunFd() {
        val vpnFileDescriptor = vpnInterface?.fileDescriptor
            ?: throw IOException("VPN file descriptor not available")
        val socketPath = File(filesDir, "sock_path").absolutePath

        Thread {
            var tries = 0
            while (running.get() && tries <= 6) {
                try {
                    Thread.sleep(50L shl tries)
                    LocalSocket().use { localSocket ->
                        localSocket.connect(LocalSocketAddress(socketPath, LocalSocketAddress.Namespace.FILESYSTEM))
                        localSocket.setFileDescriptorsForSend(arrayOf(vpnFileDescriptor))
                        localSocket.outputStream.write(42)
                    }
                    Log.i(TAG, "Sent VPN fd to tun2socks")
                    return@Thread
                } catch (e: Exception) {
                    tries++
                    if (tries > 6) {
                        Log.e(TAG, "Failed to send VPN fd to tun2socks", e)
                    }
                }
            }
        }.start()
    }

    /** Keep this app off the tunnel to prevent routing loops. */
    /**
     * Split tunnel + self-exclusion. Android forbids mixing
     * addAllowedApplication with addDisallowedApplication, so the two modes are
     * handled separately.
     *  - include: ONLY the selected apps are tunneled. Self is left out of the
     *    allow-list, so it bypasses the VPN automatically (no loop).
     *  - exclude/off: everything is tunneled except self and any selected apps.
     *
     * Shared with the OpenVPN 2.x engine, which builds its own interface from
     * the server-pushed config — without this its TUN silently ignored the
     * user's split-tunnel settings.
     */
    fun applySplitTunnel(builder: Builder) {
        val selected = splitApps.filter { it.isNotBlank() && it != packageName }
        if (splitMode == "include" && selected.isNotEmpty()) {
            var added = 0
            for (pkg in selected) {
                try {
                    builder.addAllowedApplication(pkg)
                    added++
                } catch (e: Exception) {
                    Log.w(TAG, "Split include skip $pkg: ${e.message}")
                }
            }
            // If every package failed to resolve, fall back to disallow-self so
            // we don't accidentally tunnel nothing.
            if (added == 0) disallowSelf(builder)
            else emitLog("Split tunnel: only $added app(s) routed")
        } else {
            disallowSelf(builder)
            if (splitMode == "exclude") {
                var excluded = 0
                for (pkg in selected) {
                    try {
                        builder.addDisallowedApplication(pkg)
                        excluded++
                    } catch (e: Exception) {
                        Log.w(TAG, "Split exclude skip $pkg: ${e.message}")
                    }
                }
                if (excluded > 0) emitLog("Split tunnel: $excluded app(s) bypass VPN")
            }
        }
    }

    private fun disallowSelf(builder: Builder) {
        try {
            builder.addDisallowedApplication(packageName)
        } catch (e: Exception) {
            Log.w(TAG, "Failed to disallow self: ${e.message}")
        }
    }

    private fun acquireWakeLock() {
        // Split gates: the Wi-Fi lock used to hide behind the `useWakeLock`
        // early-return, so the "prevents doze-mode throughput collapse"
        // mitigation NEVER ran for a default user (wake lock off). Balanced
        // keep-alive holds the radio; aggressive (or the explicit toggle)
        // additionally holds the CPU — screen-off sessions stop being a
        // NAT-timeout coin flip that leaves "connected but dead".
        if (useWakeLock || keepAliveMode == 2) {
            try {
                val pm = getSystemService(POWER_SERVICE) as android.os.PowerManager
                wakeLock = pm.newWakeLock(
                    android.os.PowerManager.PARTIAL_WAKE_LOCK,
                    "snapdark:tunnel",
                ).apply {
                    setReferenceCounted(false)
                    acquire(10 * 60 * 60 * 1000L) // safety cap 10h
                }
                Log.i(TAG, "WakeLock acquired")
            } catch (e: Exception) {
                Log.w(TAG, "WakeLock failed: ${e.message}")
            }
        }
        if (useWakeLock || keepAliveMode >= 1) {
            try {
                // Keep the Wi-Fi radio at full performance / low latency while
                // the tunnel is up — prevents doze-mode throughput collapse.
                val wm = applicationContext.getSystemService(WIFI_SERVICE) as android.net.wifi.WifiManager
                val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    android.net.wifi.WifiManager.WIFI_MODE_FULL_LOW_LATENCY
                } else {
                    @Suppress("DEPRECATION")
                    android.net.wifi.WifiManager.WIFI_MODE_FULL_HIGH_PERF
                }
                wifiLock = wm.createWifiLock(mode, "snapdark:wifi").apply {
                    setReferenceCounted(false)
                    acquire() // WifiLock has no timed variant; released in cleanup
                }
                Log.i(TAG, "WifiLock acquired (mode=$mode)")
            } catch (e: Exception) {
                Log.w(TAG, "WifiLock failed: ${e.message}")
            }
        }
    }

    private fun releaseWakeLock() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Exception) {}
        wakeLock = null
        try {
            if (wifiLock?.isHeld == true) wifiLock?.release()
        } catch (_: Exception) {}
        wifiLock = null
    }

    private fun sshKeepAliveEveryTicks(): Int = when (keepAliveMode) {
        0 -> 60
        2 -> 15
        else -> 30
    }

    private fun tcpKeepAliveIdleSec(): Int = when (keepAliveMode) {
        0 -> 0
        2 -> 5
        else -> 30
    }

    private fun ovpnKeepAlivePingSec(): Int = when (keepAliveMode) {
        0 -> 0
        2 -> 5
        else -> 30
    }

    /**
     * Measure latency to the endpoint we actually dial. When a bug-host proxy is
     * configured the real server address is usually the blocked one, so probing
     * it directly always failed *and* leaked a connection to the censored host.
     */
    private fun measureDelayAsync() {
        val usesProxy = sshProxyHost.isNotBlank() && sshProxyPort > 0 &&
            injectModeName.lowercase().startsWith("proxy")
        val host = if (usesProxy) sshProxyHost else serverAddress
        val port = if (usesProxy) sshProxyPort else serverPort
        if (host.isBlank() || port <= 0) {
            lastDelay = -1
            return
        }
        Thread {
            try {
                val start = System.currentTimeMillis()
                val socket = Socket()
                socket.connect(InetSocketAddress(host, port), 5000)
                socket.close()
                lastDelay = System.currentTimeMillis() - start
                Log.i(TAG, "Delay to $host:$port = ${lastDelay}ms")
            } catch (e: Exception) {
                lastDelay = -1
                Log.w(TAG, "Delay measurement failed: ${e.message}")
            }
        }.start()
    }

    private fun startStatsMonitor() {
        statsThread = Thread {
            // Baseline captured at monitor start (connect time), so the totals
            // reported to the UI are THIS SESSION's traffic — not the device
            //-wide counters since boot, which made the dashboard show every
            // other app's data.
            var baseRx = android.net.TrafficStats.getTotalRxBytes()
            var baseTx = android.net.TrafficStats.getTotalTxBytes()
            var lastRx = baseRx
            var lastTx = baseTx
            var lastTime = System.currentTimeMillis()
            var tick = 0
            var probeFails = 0
            while (running.get()) {
                try {
                    Thread.sleep(1000)
                    val rx = android.net.TrafficStats.getTotalRxBytes()
                    val tx = android.net.TrafficStats.getTotalTxBytes()
                    val now = System.currentTimeMillis()
                    val dt = (now - lastTime).coerceAtLeast(1)
                    val down = ((rx - lastRx) * 1000 / dt).coerceAtLeast(0)
                    val up = ((tx - lastTx) * 1000 / dt).coerceAtLeast(0)
                    lastRx = rx; lastTx = tx; lastTime = now
                    emitStats(down, up, rx - baseRx, tx - baseTx)
                    if (++tick % 2 == 0) updateNotification(true) // refresh speed every ~2s

                    // SSH-level keepalive: mobile NAT silently drops idle TCP
                    // flows after ~5-10 minutes, which killed the tunnel even
                    // though every process looked alive. An SSH_MSG_IGNORE
                    // every 30s keeps the carrier's NAT entry warm.
                    val sshKeepAliveTicks = sshKeepAliveEveryTicks()
                    if (isSsh && connectedAtTimestamp > 0 && sshKeepAliveTicks > 0 && tick % sshKeepAliveTicks == 0) {
                        try {
                            sshConnection?.sendIgnorePacket()
                        } catch (e: Exception) {
                            Log.w(TAG, "ssh keepalive failed: ${e.message}")
                        }
                    }

                    // ovpn2 reset storm: the front/relay RSTs the ESTABLISHED
                    // tunnel TCP every few seconds and openvpn's internal 4 s
                    // relink loop would spin forever — process alive, watchdog
                    // blind, battery draining, relay hammered. The engine's
                    // breaker hands the session to the supervised reconnect
                    // ladder (backoff + attempt cap + failover) instead.
                    if (isOpenvpn && openVpn2Engine?.resetStorm == true && running.get()) {
                        emitLog("OpenVPN relay keeps dropping the tunnel — supervised reconnect")
                        handleEngineDeath()
                        break
                    }

                    // Watchdog: detect engine death (xray / openvpn engine /
                    // tun2socks / dnstt / ssh). Any dead helper process means the
                    // tunnel is broken even if the main engine still runs.
                    val engineDead = when {
                        isOpenvpn ->
                            (openVpn2Engine != null && !openVpn2Engine!!.isRunning()) ||
                                (openVpnEngine != null && !openVpnEngine!!.isRunning())
                        !isSsh -> (xrayProcess != null && xrayProcess?.isAlive == false) ||
                                  (hysteriaProcess != null && hysteriaProcess?.isAlive == false) ||
                                  tun2socksProcess?.isAlive == false
                        else -> sshDied.get() ||
                                tun2socksProcess?.isAlive == false ||
                                dnsttProcess?.isAlive == false
                    }
                    if (engineDead && running.get()) {
                        Log.w(TAG, "engine process died")
                        handleEngineDeath()
                        break
                    }

                    // Liveness watchdog: an alive engine can still pass zero
                    // traffic (remote dropped / account expired). Re-probe the
                    // tunnel every ~20s; 4 consecutive FULL-SWEEP failures =
                    // dead tunnel. One sweep tries several targets on 80+443,
                    // so a single blocked host/port can no longer execute a
                    // healthy session (the old single-204 probe auto-disconnected
                    // working tunnels on relays that refuse plain 80).
                    // OpenVPN has no SOCKS proxy — probes dial the VPN network's
                    // socket factory explicitly; if the OEM refuses those too,
                    // livenessLooksAlive falls back to engine byte counters.
                    if ((tick % 20 == 0 || livenessUrgent) && running.get()) {
                        livenessUrgent = false
                        val alive = livenessLooksAlive()
                        if (alive) {
                            probeFails = 0
                        } else {
                            probeFails++
                            Log.w(TAG, "liveness probe failed ($probeFails/4)")
                            emitLog("Tunnel liveness check failed ($probeFails/4)")
                            if (probeFails >= 4 && running.get()) {
                                Log.e(TAG, "tunnel dead: 4 consecutive probe sweeps failed")
                                handleEngineDeath()
                                break
                            }
                        }
                    }
                } catch (e: InterruptedException) {
                    break
                } catch (e: Exception) {
                    // keep going
                }
            }
        }
        statsThread?.start()
    }

    private fun handleEngineDeath() {
        when {
             autoReconnect -> {
                 if (reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
                     emitLog("Auto-reconnect gave up after $MAX_RECONNECT_ATTEMPTS attempts")
                     reconnectAttempts = 0
                     if (killSwitch) {
                         emitState("error:tunnel down — kill switch blocking traffic")
                     } else {
                         // Signal Dart to try the next failover candidate
                         emitState("error:reconnect-exhausted")
                         stopVpn()
                     }
                     return
                 }
                reconnectAttempts++
                // 2.5s, 5s, 10s, 20s, 40s, 60s …
                val delayMs = (2500L shl (reconnectAttempts - 1).coerceAtMost(5))
                    .coerceAtMost(60_000L)
                emitState("connecting")
                emitLog("Tunnel dropped — auto-reconnect attempt $reconnectAttempts/$MAX_RECONNECT_ATTEMPTS in ${delayMs / 1000}s")
                // keepTun: with the kill switch armed the interface MUST stay
                // open through the retry window — the old cleanup() closed it,
                // so "kill switch blocking traffic" was a lie and every
                // kill-switch user leaked on the physical network while the app
                // said "connecting".
                // keepSessionStart: a dropped-and-restored tunnel is the SAME
                // user session; wiping the persisted start reset the home timer
                // to 0:00 on every carrier hiccup.
                cleanup(keepTun = killSwitch, keepSessionStart = true)
                running.set(false)
                Companion.isRunning = false
                Companion.isOpenvpnMode = false
                Companion.activeMode = ""
                // The backoff sleep must NOT happen on this thread: this runs
                // on statsThread, and cleanup() just interrupted it — the old
                // code therefore woke Thread.sleep() instantly, the bare
                // catch swallowed the InterruptedException, and all six
                // "backing off" attempts fired back-to-back in ~0 ms.
                val gen = ++reconnectGen
                Thread {
                    var slept = 0L
                    while (slept < delayMs && gen == reconnectGen) {
                        try {
                            Thread.sleep(250)
                        } catch (_: InterruptedException) {
                            break
                        }
                        slept += 250
                    }
                    if (gen != reconnectGen) return@Thread   // stopVpn / newer attempt
                    if (!running.get()) {
                        // Hard no-network: do NOT redial the shared (free) relay
                        // through the whole backoff ladder — the device has no
                        // path to it at all. One clean error, no storm.
                        // (Only the HARD signal here; a flaky probe must never
                        // cancel the reconnect of a session that really lived.)
                        if (!physicalNetworkPresent()) {
                            lastError = "no-internet"
                            emitState("error:no-internet")
                            emitLog("Auto-reconnect cancelled — device has no network.")
                            Handler(Looper.getMainLooper()).post { stopVpn() }
                            return@Thread
                        }
                        lastStartIntent?.let {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(it)
                            } else {
                                @Suppress("DEPRECATION")
                                startService(it)
                            }
                        }
                    }
                }.apply { isDaemon = true; name = "snapdark-reconnect" }.start()
            }
            killSwitch -> {
                // Keep the TUN up so leaking traffic is blocked while down.
                emitState("error:tunnel down — kill switch blocking traffic")
            }
            else -> stopVpn()
        }
    }

    private fun emitStats(down: Long, up: Long, totalDown: Long, totalUp: Long) {
        lastDownSpeed = down
        lastUpSpeed = up
        Handler(Looper.getMainLooper()).post {
            try {
                // Totals must stay Long: Dart ints are 64-bit, and .toInt()
                // here rolled a 2 GiB session over into negative numbers on the
                // dashboard. Speeds (bytes/sec) cannot overflow — totals can.
                statsEventSink?.success(mapOf(
                    "downloadSpeed" to down.toInt(),
                    "uploadSpeed" to up.toInt(),
                    "totalDownload" to totalDown,
                    "totalUpload" to totalUp,
                ))
            } catch (e: Exception) {
                Log.e(TAG, "Failed to emit stats", e)
            }
        }
    }

    private fun stopVpn() {
        Log.i(TAG, "Stopping VPN")
        emitState("disconnecting")

        // An explicit stop wins over ANY scheduled restart: the pending
        // 300 ms reconnect callback dies, and bumping the generation kills a
        // backoff sleep already in flight on the reconnect thread.
        cancelPendingReconnect()
        reconnectGen++

        notificationHandler.removeCallbacks(notificationTicker)
        unregisterLivenessReceiver()
        connectedAtTimestamp = 0
        currentTarget = StartTarget("", 0, "")
        livenessUrgent = false

        running.set(false)
        Companion.isRunning = false
        Companion.isOpenvpnMode = false
        Companion.activeMode = ""

        cleanup()

        // Stop foreground
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()

        emitState("disconnected")
        Log.i(TAG, "VPN stopped")
    }

    private fun cleanup(keepTun: Boolean = false, keepSessionStart: Boolean = false) {
        if (!keepSessionStart) {
            // Explicit stop ends the persisted session — a later connect (user
            // or redelivery) must not inherit this session's start time. An
            // auto-reconnect keeps it so the home timer counts the SAME session.
            clearPersistedSession()
        }
        // Release the app process from the (dying) VPN network first, so the
        // app's own sockets/DNS fall back to the physical network.
        try {
            getSystemService(ConnectivityManager::class.java)
                ?.bindProcessToNetwork(null)
            boundVpnNetwork = null
        } catch (_: Exception) {}

        // Stop tun2socks
        try {
            tun2socksProcess?.destroy()
            tun2socksProcess = null
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping tun2socks", e)
        }

        // Stop xray / SSH / injector / proxy relay
        try {
            sshHttpBridge?.stop()
            sshHttpBridge = null
            proxyEngine?.stop()
            proxyEngine = null
            sshForwarder?.close()
            sshForwarder = null
            sshConnection?.close()
            sshConnection = null
            sshDied.set(false)
            dnsGateway?.stop()
            dnsGateway = null
            dnsGatewayActive = false
            payloadInjector?.stop()
            payloadInjector = null
            dnsttProcess?.destroy()
            dnsttProcess = null
            dnsttActive = false
            // OpenVPN engine stopped via openVpnEngine?.stop() below
            try { openVpn2Engine?.stop() } catch (_: Exception) {}
            openVpn2Engine = null
            try { openVpnEngine?.stop() } catch (_: Exception) {}
            openVpnEngine = null
            xrayProcess?.destroy()
            xrayProcess = null
            hysteriaProcess?.destroy()
            hysteriaProcess = null
        } catch (e: Exception) {
            Log.e(TAG, "Error stopping xray", e)
        }

        // Close VPN interface — kept open while the kill switch is armed during
        // an auto-reconnect window, otherwise every retry leaves the device
        // running raw on the physical network while the UI says "connecting".
        if (keepTun) {
            Log.i(TAG, "Kill switch armed — TUN held open through reconnect")
        } else {
            try {
                vpnInterface?.close()
                vpnInterface = null
            } catch (e: Exception) {
                Log.e(TAG, "Error closing VPN interface", e)
            }
        }

        // Stop stats thread
        statsThread?.interrupt()
        statsThread = null

        releaseWakeLock()
    }

    private fun showNotification() {
        updateNotification(false)
    }

    private fun updateNotification(connected: Boolean) {
        val notificationManager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "SnapDark Tunnel VPN",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "VPN connection status"
                setShowBadge(false)
            }
            notificationManager.createNotificationChannel(channel)
        }

        val intent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // Stop button PendingIntent
        val stopIntent = Intent(this, SnapDarkTunnelVpnService::class.java).apply {
            action = ACTION_STOP
        }
        val stopPending = PendingIntent.getService(
            this, 1, stopIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        // Reconnect button PendingIntent
        val reconnectIntent = Intent(this, SnapDarkTunnelVpnService::class.java).apply {
            action = ACTION_RECONNECT
        }
        val reconnectPending = PendingIntent.getService(
            this, 2, reconnectIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val speed = "↓ ${fmtSpeed(lastDownSpeed)}  ↑ ${fmtSpeed(lastUpSpeed)}"

        // Elapsed time in notification
        val elapsed = if (connectedAtTimestamp > 0) {
            val secs = ((System.currentTimeMillis() - connectedAtTimestamp) / 1000).toInt()
            val h = secs / 3600
            val m = (secs % 3600) / 60
            val s = secs % 60
            if (h > 0) "%d:%02d:%02d".format(h, m, s)
            else "%d:%02d".format(m, s)
        } else ""

        val timerLine = if (connected && elapsed.isNotEmpty()) "⏱ $elapsed  " else ""
        val status = if (connected) "Connected to $serverName" else "Connecting to $serverName"
        val content = if (connected) "$timerLine$speed" else status
        val details = "$status\n${timerLine}$speed"

        val builder = Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle("SnapDark Tunnel")
            .setContentText(content)
            .setStyle(Notification.BigTextStyle().bigText(details))
            .setSmallIcon(R.drawable.ic_notification)
            .setContentIntent(pendingIntent)
            .setOngoing(true)

        if (connected) {
            builder.addAction(
                Notification.Action.Builder(
                    null, "Stop", stopPending
                ).build()
            )
            builder.addAction(
                Notification.Action.Builder(
                    null, "Reconnect", reconnectPending
                ).build()
            )
        }

        // Android 15 (targetSdk 35) migration guidance: pass the FGS type
        // explicitly instead of relying on the manifest-declared one. Below
        // API 34 the typed overload is not available / the bit is unknown.
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(
                NOTIFICATION_ID,
                builder.build(),
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else {
            startForeground(NOTIFICATION_ID, builder.build())
        }
    }

    private fun fmtSpeed(bps: Long): String = when {
        bps < 1024 -> "$bps B/s"
        bps < 1024 * 1024 -> "${"%.1f".format(bps / 1024.0)} KB/s"
        else -> "${"%.1f".format(bps / (1024.0 * 1024))} MB/s"
    }

    private fun emitState(state: String) {
        // Engine error text (JSch etc.) carries the endpoint; errors are shown
        // in the app log, so they pass through the same redaction. MOTDs and
        // ordinary states stay verbatim — they are the server's own words.
        val safe = if (state.startsWith("error:")) {
            "error:" + redact(state.substring("error:".length))
        } else state
        Handler(Looper.getMainLooper()).post {
            try {
                stateEventSink?.success(safe)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to emit state", e)
            }
        }
    }

    private fun categorizeError(msg: String): String {
        val m = msg.lowercase()
        return when {
            m.contains("network") || m.contains("no interface") ||
            m.contains("unreachable") || m.contains("timeout") ||
            m.contains("refused") -> "network"
            m.contains("auth") || m.contains("credential") ||
            m.contains("password") || m.contains("login") -> "auth"
            m.contains("config") || m.contains("parse") ||
            m.contains("invalid") || m.contains("missing") -> "config"
            m.contains("server") || m.contains("host") ||
            m.contains("dns") || m.contains("resolve") -> "server"
            else -> "unknown"
        }
    }

    private fun getProcessId(process: Process): Long {
        return try {
            val field = Process::class.java.getDeclaredField("pid")
            field.isAccessible = true
            field.getLong(process)
        } catch (e: Exception) {
            -1L
        }
    }

    /**
     * Soft wait: pass as soon as the device has ANY active network interface
     * (WiFi / cellular / Ethernet / BT tether). We deliberately do NOT require
     * a validated-internet path — local/lab setups, dummy proxies and offline
     * tests are all legitimate use cases.
     *
     * Returns true if a network was available either immediately or within
     * [timeoutMs]. Emits `waiting:network` while waiting so the UI can show
     * "waiting for connection" instead of stalling silently.
     */
    private fun waitForAnyNetwork(timeoutMs: Long): Boolean {
        val cm = getSystemService(ConnectivityManager::class.java) ?: return true
        if (hasAnyNetwork(cm)) return true

        val ready = java.util.concurrent.atomic.AtomicBoolean(false)
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) { ready.set(true) }
            override fun onCapabilitiesChanged(
                network: Network, caps: NetworkCapabilities
            ) { /* don't require VALIDATED */ }
            override fun onLost(network: Network) { /* keep waiting */ }
        }
        val req = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        try {
            cm.registerNetworkCallback(req, cb)
        } catch (e: Exception) {
            Log.w(TAG, "registerNetworkCallback failed: ${e.message}")
            return hasAnyNetwork(cm)
        }
        emitState("waiting:network")

        val deadline = System.currentTimeMillis() + timeoutMs
        while (running.get() && !ready.get() && System.currentTimeMillis() < deadline) {
            try { Thread.sleep(200) } catch (_: InterruptedException) { break }
            if (hasAnyNetwork(cm)) { ready.set(true); break }
        }
        try { cm.unregisterNetworkCallback(cb) } catch (_: Exception) {}
        return ready.get()
    }

    /** True if a PHYSICAL network is up. Must exclude TRANSPORT_VPN: our own
     *  TUN carries NET_CAPABILITY_INTERNET and would satisfy the check even in
     *  airplane mode, making the whole gate a no-op. */
    private fun hasAnyNetwork(cm: ConnectivityManager): Boolean {
        val candidates = cm.activeNetwork?.let { listOf(it) } ?: cm.allNetworks.toList()
        return candidates.any { n ->
            val caps = cm.getNetworkCapabilities(n) ?: return@any false
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        }
    }

    /** True while whichever OpenVPN engine is active is still alive. */
    private fun ovpnEngineRunning(): Boolean =
        openVpn2Engine?.isRunning() == true || openVpnEngine?.isRunning() == true

    /** True once the active OpenVPN engine reported its tunnel up. */
    private fun ovpnTunnelConnected(): Boolean =
        openVpn2Engine?.isTunnelConnected() == true || openVpnEngine?.isTunnelConnected() == true

    /**
     * Soft probe: verify the engine came up and the local SOCKS port is
     * accepting connections. We don't attempt any external request — local /
     * lab / proxy-only setups are legitimate test targets and the user wants
     * the tunnel marked active as soon as the engine is up.
     */
    private fun runLocalBindProbe(): Boolean {
        val deadline = System.currentTimeMillis() + 8_000L
        if (isOpenvpn) {
            while (System.currentTimeMillis() < deadline) {
                if (ovpnEngineRunning()) {
                    Log.i(TAG, "OpenVPN probe OK (engine alive)")
                    return true
                }
                try { Thread.sleep(200) } catch (_: Exception) { break }
            }
            return false
        }
        while (System.currentTimeMillis() < deadline) {
            val ok = try {
                val sock = Socket()
                sock.connect(InetSocketAddress("127.0.0.1", 10808), 600)
                sock.close()
                true
            } catch (_: Exception) { false }
            if (ok) {
                Log.i(TAG, "Local SOCKS bind OK on 127.0.0.1:10808")
                return true
            }
            try { Thread.sleep(200) } catch (_: Exception) { return false }
        }
        return false
    }

    /**
     * Real end-to-end probe: fetch a generate_204 URL THROUGH the tunnel and
     * require an actual HTTP response. For xray/SSH paths the request goes via
     * the local SOCKS (127.0.0.1:10808) so it exercises the full chain
     * (tun2socks → engine → remote server → internet). For OpenVPN we rely on
     * the engine's CONNECTED event — the app's own sockets bypass its own TUN,
     * so a direct request from this process can't prove tunnel health.
     */
    private fun runRealConnectivityProbe(): Boolean {
        probeFailureLogged = false
        if (isOpenvpn) {
            val deadline = System.currentTimeMillis() + 30_000L
            var loggedWait = false
            while (System.currentTimeMillis() < deadline) {
                if (ovpnTunnelConnected()) {
                    Log.i(TAG, "OpenVPN CONNECTED event received")
                    break
                }
                if (!ovpnEngineRunning()) {
                    Log.w(TAG, "OpenVPN engine died during probe")
                    return false
                }
                if (!loggedWait && System.currentTimeMillis() > deadline - 15_000L) {
                    loggedWait = true
                    emitLog("Waiting for OpenVPN handshake…")
                }
                try { Thread.sleep(300) } catch (_: Exception) { break }
            }
            if (!ovpnTunnelConnected()) {
                Log.w(TAG, "OpenVPN never reached CONNECTED within probe window")
                return false
            }
            // CONNECTED only proves the control channel. Now prove the DATA
            // channel actually carries traffic. The probes below dial through
            // the VPN network's socket factory explicitly, so no process bind
            // is needed (and none is wanted — the app keeps its own network).
            noteVpnNetworkHandle()
            val targets = listOf(
                Triple("connectivitycheck.gstatic.com", "/generate_204", 80),
                Triple("www.google.com", "/generate_204", 80),
                Triple("cp.cloudflare.com", "/generate_204", 80),
                Triple("1.1.1.1", "/cdn-cgi/trace", 80),
                Triple("8.8.8.8", "/generate_204", 80),
                Triple("www.cloudflare.com", "/", 443),
                Triple("1.1.1.1", "/cdn-cgi/trace", 443),
            )
            val pDeadline = System.currentTimeMillis() + 20_000L
            val engineStartIn = ovpnBytesIn()
            var attempt = 0
            while (System.currentTimeMillis() < pDeadline) {
                attempt++
                // Socket probes bound to the VPN network EPERM on several OEMs
                // (the app UID is disallowed from its own VPN) — try them only
                // briefly, then let the engine's byte counters prove the data
                // channel (they cannot lie).
                if (attempt <= 2) {
                    for ((host, path, port) in targets) {
                        if (probeHttpThroughVpnNetwork(host, path, port)) {
                            Log.i(TAG, "OpenVPN data-channel probe OK via $host:$port (attempt $attempt)")
                            emitLog("Connectivity verified through tunnel ($host)")
                            return true
                        }
                    }
                }
                // Data-channel proof without HTTP: if openvpn's own byte counter
                // shows real downlink traffic accumulating, the tunnel carries
                // data even when port-80/DNS probes are blocked by the ISP.
                val engIn = ovpnBytesIn()
                if (engIn >= 0 && engineStartIn >= 0 && engIn - engineStartIn > 5_000L) {
                    emitLog("Connectivity verified through tunnel (bytes flowing: +${engIn - engineStartIn} B down)")
                    return true
                }
                if (attempt % 3 == 0) emitLog("Probing OpenVPN data channel… attempt $attempt")
                try { Thread.sleep(1000) } catch (_: Exception) { break }
            }
            // The openvpn3 engine publishes no byte counters: when it is the
            // live engine, socket probes EPERM'd, and CONNECTED was received,
            // we have NO way to disprove health — ovpn3 only reports CONNECTED
            // once its own data channel is up. Tearing the session down here
            // (the old behaviour) killed working tunnels on those OEMs.
            if (engineStartIn < 0) {
                emitLog("Connectivity verified (openvpn3 CONNECTED; counters unavailable)")
                return true
            }
            Log.w(TAG, "OpenVPN CONNECTED but data-channel probe failed — tunnel carries no traffic")
            emitLog("Connected, but no internet through tunnel (data channel dead)")
            return false
        }

        // HTTP-over-SOCKS probe targets (= the watchdog list: port 80 AND TLS
        // 443 variants); any one success counts. A gate that only tried plain
        // 80 to one 204 host failed every connect through relays that block
        // it, even though the tunnel itself worked fine.
        val targets = livenessProbeTargets
        // Generous window: dnstt / slow SSH handshakes can take a while.
        val deadline = System.currentTimeMillis() + 30_000L
        var attempt = 0
        while (System.currentTimeMillis() < deadline) {
            attempt++
            for ((host, path, port) in targets) {
                if (httpGet204ThroughSocks(host, path, port)) {
                    Log.i(TAG, "E2E probe OK via $host:$port (attempt $attempt)")
                    emitLog("Connectivity verified through tunnel ($host)")
                    return true
                }
            }
            if (attempt % 3 == 0) {
                emitLog("Probing real connectivity… attempt $attempt")
            }
            try { Thread.sleep(1200) } catch (_: Exception) { break }
        }
        Log.w(TAG, "E2E probe failed after $attempt attempts — no internet through tunnel")
        return false
    }

    /**
     * Minimal plain-HTTP GET over a SOCKS-proxied socket. Returns true only if
     * the remote answered with an HTTP status line (any 2xx/3xx counts for the
     * non-204 fallbacks; generate_204 endpoints answer 204).
     */
    /**
     * Real data-channel probe for the OpenVPN path. Unlike the SOCKS probe, the
     * OpenVPN engine exposes a TUN (no local SOCKS), so we bind the socket to the
     * VPN network directly via its socket factory and resolve the host through
     * the tunnel's DNS. Returns true only if the remote answered with an HTTP
     * status line — proving bytes actually round-trip through the tunnel.
     */
    /**
     * Probe failures repeat once per target per round; only the FIRST one is
     * worth a log line (the OpenVPN loop retries against 7 targets — without
     * this gate an EPERM-ing OEM floods the log with identical lines).
     */
    private var probeFailureLogged = false

    private fun probeFail(msg: String) {
        if (probeFailureLogged) return
        probeFailureLogged = true
        emitLog(msg)
    }

    private fun probeHttpThroughVpnNetwork(host: String, path: String, port: Int = 80): Boolean {
        val vpnNetwork = vpnNetworkRef() ?: run {
            probeFail("probe: no VPN network found")
            return false
        }
        var sock: Socket? = null
        return try {
            // Raw IPv4 literals skip DNS entirely (DNS over the tunnel may be
            // slow/blocked); hostnames resolve through the tunnel's resolvers.
            val inet = resolveOn(vpnNetwork, host) ?: run {
                probeFail("probe: DNS failed for $host through tunnel")
                return false
            }
            var conn: Socket = vpnNetwork.socketFactory.createSocket()
            conn.soTimeout = 6000
            conn.connect(InetSocketAddress(inet, port), 6000)
            // Port 443: wrap in TLS (trust-all — we only need round-trip proof).
            if (port == 443) conn = tlsWrapProbe(conn, host, port)
            sock = conn
            val out = conn.getOutputStream()
            out.write(("GET $path HTTP/1.1\r\nHost: $host\r\nUser-Agent: SnapDarkTunnel/1.0 probe\r\nConnection: close\r\n\r\n").toByteArray())
            out.flush()
            val reader = java.io.BufferedReader(java.io.InputStreamReader(conn.getInputStream()))
            val statusLine = reader.readLine() ?: run {
                probeFail("probe: $host:$port connected but no HTTP response")
                return false
            }
            val code = statusLine.split(" ").getOrNull(1)?.trim()?.toIntOrNull() ?: 0
            emitLog("probe[$host:$port] -> $statusLine")
            code in 200..399
        } catch (e: Exception) {
            probeFail("probe[$host:$port] failed: ${e.javaClass.simpleName}: ${e.message}")
            false
        } finally {
            try { sock?.close() } catch (_: Exception) {}
        }
    }

    /**
     * Downlink bytes the OpenVPN engine has pulled through the tunnel, or -1
     * when no engine that publishes counters is running (openvpn3 exposes
     * none) — callers must treat -1 as "inconclusive", never as "dead".
     */
    private fun ovpnBytesIn(): Long =
        openVpn2Engine?.bytesIn ?: -1L

    /**
     * Shared probe targets for the watchdog and the connect gate: 204 checks /
     * plain paths across ports 80 AND 443 (TLS). Plain-80 204 hosts are
     * blocked by a real share of relays and mobile networks — a single-target
     * probe killed perfectly healthy tunnels 3×/minute and made honest
     * connections fail their own connect gate. Any one answer = alive.
     */
    private val livenessProbeTargets = listOf(
        Triple("connectivitycheck.gstatic.com", "/generate_204", 80),
        Triple("cp.cloudflare.com", "/generate_204", 80),
        Triple("www.gstatic.com", "/generate_204", 80),
        Triple("www.cloudflare.com", "/", 443),
        Triple("cp.cloudflare.com", "/generate_204", 443),
    )

    /**
     * One watchdog pass of "does the tunnel actually still carry traffic?".
     *
     *  · xray / SSH: an HTTP-over-SOCKS sweep exercises the whole chain
     *    (proxy → engine → remote → internet) — first answering target wins,
     *    only a full sweep failure counts toward a kill decision.
     *  · OpenVPN: the app process is deliberately NOT bound to the VPN network
     *    anymore, so probes dial through its socket factory explicitly
     *    ([probeHttpThroughVpnNetwork]). On OEMs where the owner-UID socket is
     *    refused (EPERM) the fallback is the engine's own byte counters; the
     *    openvpn3 engine publishes none, so there a failing probe cannot
     *    disprove health and we defer to the engine's internal reconnect
     *    instead of tearing a working tunnel down.
     */
    private fun livenessLooksAlive(): Boolean {
        if (!isOpenvpn) {
            for ((host, path, port) in livenessProbeTargets) {
                if (httpGet204ThroughSocks(host, path, port)) return true
            }
            return false
        }
        for ((host, path, port) in livenessProbeTargets) {
            if (probeHttpThroughVpnNetwork(host, path, port)) return true
        }
        val eng = openVpn2Engine
        if (eng == null) {
            // openvpn3 engine (or none): no counters — openvpn3 only reports
            // CONNECTED once its data channel is up and re-kicks itself
            // internally; a blocked probe can neither disprove nor improve
            // that, so don't burn a live tunnel on it.
            return true
        }
        val total = eng.bytesIn + eng.bytesOut
        val grew = total - lastEngineBytes > 2_000L
        lastEngineBytes = total
        return grew
    }

    /** Any NON-VPN network offering INTERNET — the hard signal, no probing. */
    private fun physicalNetworkPresent(): Boolean {
        val cm = getSystemService(ConnectivityManager::class.java) ?: return true
        return cm.allNetworks.any { n ->
            val c = cm.getNetworkCapabilities(n) ?: return@any false
            !c.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN) &&
                c.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET)
        }
    }

    /**
     * "Can this device reach the internet at all RIGHT NOW?" gate for a LIVE
     * session decision. Hard signal first; if a network exists but the OS has
     * not validated it (captive portals, OEM quirks), one short sweep of the
     * shared probe targets over the PHYSICAL network decides — the app's own
     * sockets are never tunnel-bound, so a plain socket IS the physical path.
     * A captive portal answering with a redirect still counts: reachability,
     * not cleanliness, is what a dial needs.
     */
    private fun physicalInternetOk(): Boolean {
        if (!physicalNetworkPresent()) return false
        val cm = getSystemService(ConnectivityManager::class.java) ?: return true
        val validated = cm.allNetworks.any { n ->
            val c = cm.getNetworkCapabilities(n) ?: return@any false
            !c.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN) &&
                c.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        }
        if (validated) return true
        for ((host, path, port) in livenessProbeTargets.take(4)) {
            if (directHttpProbe(host, path, port, 1500)) return true
        }
        return false
    }

    /** Plain-socket HTTP probe — no SOCKS, no VPN network: physical only. */
    private fun directHttpProbe(
        host: String,
        path: String,
        port: Int,
        timeoutMs: Int,
    ): Boolean {
        var sock: Socket? = null
        return try {
            sock = Socket()
            sock.soTimeout = timeoutMs
            sock.connect(InetSocketAddress(host, port), timeoutMs)
            val io: Socket =
                if (port == 443) tlsWrapProbe(sock, host, port).also { sock = it } else sock
            io.getOutputStream().apply {
                write(("GET $path HTTP/1.1\r\nHost: $host\r\nUser-Agent: SnapDarkTunnel/1.0 probe\r\nConnection: close\r\n\r\n").toByteArray())
                flush()
            }
            val statusLine = io.getInputStream().bufferedReader().readLine() ?: return false
            val code = statusLine.split(" ").getOrNull(1)?.trim()?.toIntOrNull() ?: 0
            code in 200..399
        } catch (_: Exception) {
            false
        } finally {
            try { sock?.close() } catch (_: Exception) {}
        }
    }

    /** Trust-all TLS wrapper — probes only need round-trip proof, not identity. */
    private fun tlsWrapProbe(conn: Socket, host: String, port: Int): javax.net.ssl.SSLSocket {
        val ctx = javax.net.ssl.SSLContext.getInstance("TLS")
        ctx.init(null, arrayOf<javax.net.ssl.X509TrustManager>(object : javax.net.ssl.X509TrustManager {
            override fun checkClientTrusted(chain: Array<out java.security.cert.X509Certificate>?, authType: String?) {}
            override fun checkServerTrusted(chain: Array<out java.security.cert.X509Certificate>?, authType: String?) {}
            override fun getAcceptedIssuers(): Array<java.security.cert.X509Certificate> = arrayOf()
        }), null)
        val tls = ctx.socketFactory.createSocket(conn, host, port, true) as javax.net.ssl.SSLSocket
        tls.soTimeout = 5000
        tls.startHandshake()
        return tls
    }

    private fun httpGet204ThroughSocks(host: String, path: String, port: Int = 80): Boolean {
        var sock: Socket? = null
        return try {
            val proxyAddr = InetSocketAddress("127.0.0.1", 10808)
            val plain = Socket(Proxy(Proxy.Type.SOCKS, proxyAddr))
            plain.soTimeout = 4500
            // Unresolved: the hostname is sent to the SOCKS server so DNS is
            // resolved remotely through the tunnel (local DNS may be broken).
            plain.connect(InetSocketAddress.createUnresolved(host, port), 5000)
            sock = plain
            val io: Socket = if (port == 443) tlsWrapProbe(plain, host, port).also { sock = it } else plain
            val out = io.getOutputStream()
            out.write(("GET $path HTTP/1.1\r\nHost: $host\r\nUser-Agent: SnapDarkTunnel/1.0 probe\r\nConnection: close\r\n\r\n").toByteArray())
            out.flush()
            val reader = java.io.BufferedReader(java.io.InputStreamReader(io.getInputStream()))
            val statusLine = reader.readLine() ?: return false
            val code = statusLine.split(" ").getOrNull(1)?.trim()?.toIntOrNull() ?: 0
            Log.d(TAG, "probe[$host:$port] -> $statusLine")
            code in 200..399
        } catch (e: Exception) {
            Log.d(TAG, "probe[$host:$port] failed: ${e.message}")
            false
        } finally {
            try { sock?.close() } catch (_: Exception) {}
        }
    }

    override fun onDestroy() {
        if (running.get()) {
            Log.w(TAG, "Service destroyed while VPN running; Android/OEM killed foreground service")
        }
        instanceRef = null
        super.onDestroy()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        if (!running.get()) return
        Log.w(TAG, "App task removed while VPN running; keeping foreground VPN service alive")
        showNotification()
    }

    override fun onRevoke() {
        Log.w(TAG, "VPN permission revoked")
        stopVpn()
        super.onRevoke()
    }

    /**
     * Android never routes the VPN-OWNING app's traffic through its own TUN,
     * and that default is what we WANT: the app's own requests (config
     * refresh, update checks, worker calls) belong on the user's PHYSICAL
     * network so they keep working even when the tunnel is slow, blocked or
     * dead. The old code bound the whole process to the VPN network on
     * connect — that made the app die with its own tunnel: config feed stopped
     * updating, ping badges went blank, and every HTTP call rode a half-dead
     * session. Probes that MUST measure the tunnel use the VPN network's
     * socket factory explicitly ([vpnNetworkRef]) instead of a global bind.
     * The speed-test sheet is the one place that still wants tunneled bytes;
     * it binds explicitly via [setSelfTrafficThroughVpn] for its lifetime.
     */
    private fun noteVpnNetworkHandle() {
        // Discover (and cache) the VPN network without binding to it, so the
        // socket-factory probes and httpPing have a handle the moment the
        // first watchdog tick fires.
        val cm = getSystemService(ConnectivityManager::class.java) ?: return
        for (attempt in 1..5) {
            val vpnNetwork = cm.allNetworks.firstOrNull { n ->
                cm.getNetworkCapabilities(n)?.hasTransport(
                    android.net.NetworkCapabilities.TRANSPORT_VPN
                ) == true
            }
            if (vpnNetwork != null) {
                boundVpnNetwork = vpnNetwork
                Log.i(TAG, "VPN network handle cached (attempt $attempt)")
                SnapDarkTunnelVpnService.emitLog("App self-network → physical (own traffic bypasses tunnel)")
                return
            } else {
                Log.d(TAG, "VPN network not found yet (attempt $attempt)")
            }
            try { Thread.sleep(300) } catch (_: InterruptedException) {}
        }
        // Not fatal: probes fall back to a fresh allNetworks lookup + engine
        // counters; the app's own traffic never needed the handle anyway.
        Log.w(TAG, "VPN network handle not found after retries")
    }

    /**
     * Explicitly route (or restore) the app's OWN traffic through the VPN
     * network. Used ONLY by the speed-test sheet so fast.com measures the
     * tunnel; everything else stays on the physical network. Returns false
     * when there is no session or the OEM refuses the bind.
     */
    fun setSelfTrafficThroughVpn(on: Boolean): Boolean {
        val cm = getSystemService(ConnectivityManager::class.java) ?: return false
        if (!on) {
            return try {
                cm.bindProcessToNetwork(null)
                true
            } catch (_: Exception) {
                false
            }
        }
        if (!Companion.isRunning) return false
        val net = vpnNetworkRef() ?: return false
        return try {
            cm.bindProcessToNetwork(net)
            true
        } catch (e: Exception) {
            Log.w(TAG, "self-through-vpn bind refused: ${e.message}")
            false
        }
    }
}
