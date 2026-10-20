package com.snapdark.tunnel

import android.net.LocalServerSocket
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.net.VpnService
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.system.Os
import android.util.Log
import java.io.File
import java.io.FileDescriptor
import java.io.IOException
import java.io.OutputStream
import java.net.Inet6Address
import java.net.InetAddress
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * Drives the **OpenVPN 2.x** engine (`libovpnexec.so` + `libopenvpn.so`, built
 * from ics-openvpn) as a child process, talking to it over OpenVPN's unix-socket
 * management interface.
 *
 * This is the engine HTTP Custom / most Android tunnel apps use, and it is
 * deliberately NOT the openvpn3 ClientAPI ([OpenVpnEngine]):
 *
 *  - openvpn3's data plane refused to work against our server. Its ClientAPI
 *    only exposes `compressionMode` = no|yes|asym, and every one of those either
 *    LZO-framed or stub-framed the uplink; the server (compression fully absent)
 *    read the extra opcode byte as part of the inner IP header and dropped every
 *    packet — 16KB up, 0B down, forever. Swapping the TLS backend
 *    (OpenSSL 4.0 -> mbedTLS) changed nothing, which is what proved the fault was
 *    in the data plane.
 *  - openvpn2 also *accepts the profile as written*: `cipher none`, `auth none`,
 *    `comp-lzo`, `http-proxy-option CUSTOM-HEADER`, `--fragment` — all the
 *    legacy directives openvpn3 rejects and we had to strip. HTTP Custom's log
 *    against this very server shows exactly that: `'--cipher none' was
 *    specified` + `local='cipher [null-cipher]'` and it completes
 *    `Initialization Sequence Completed`.
 *
 * Protocol flow (mirrors ics-openvpn's OpenVpnManagementThread):
 *   1. Bind a filesystem LocalSocket; the profile gets
 *      `management <path> unix` + `management-client` + `management-hold`.
 *   2. exec `libovpnexec.so --config stdin`, write the profile to its stdin.
 *   3. openvpn connects back to the socket. We send `version 3`, then
 *      `hold release` / `state on` / `bytecount`.
 *   4. It asks for everything it needs via `>NEED-OK` / `>PASSWORD`:
 *      PROTECTFD (fd over the socket -> [VpnService.protect]), IFCONFIG, ROUTE,
 *      DNSSERVER, DNSDOMAIN, then OPENTUN — at which point we build the
 *      [VpnService.Builder], establish it, and pass the TUN fd back as an
 *      ancillary file descriptor.
 *
 * The payload injector still fronts the connection as `http-proxy 127.0.0.1
 * <port>` exactly as before — openvpn2 speaks HTTP CONNECT natively.
 */
class OpenVpn2Engine(
    private val vpnService: VpnService,
    private val profileText: String,
    private val sessionName: String,
    private val mtu: Int,
    private val dnsPrimary: String,
    private val dnsSecondary: String,
) {
    companion object {
        private const val TAG = "OpenVpn2Engine"

        /**
         * `libovpnexec.so` is a PIE **executable** shipped in jniLibs (Android P+
         * forbids exec'ing anything written to a data dir, so the native library
         * dir is the only legal place). `libopenvpn.so` next to it is dlopen'd by
         * it via DT_NEEDED, which is why LD_LIBRARY_PATH must point there.
         */
        private const val EXEC_LIB = "libovpnexec.so"
    }

    private val builderRef = AtomicReference<VpnService.Builder?>(null)
    private val tunnelConnected = AtomicBoolean(false)
    private val fatalError = AtomicReference<String?>(null)
    private val establishedFd = AtomicReference<Int?>(null)
    private val running = AtomicBoolean(false)

    private var process: Process? = null
    private var processThread: Thread? = null
    private var mgmtThread: Thread? = null
    private var serverSocket: LocalServerSocket? = null
    private var serverSocketLocal: LocalSocket? = null
    private var mgmtSocket: LocalSocket? = null
    private var stdin: OutputStream? = null

    // Ancillary file descriptors openvpn hands us (for PROTECTFD).
    private val pendingFds = ArrayDeque<FileDescriptor>()

    // TUN parameters accumulated from the management dialogue, applied on OPENTUN.
    private var localIp: String? = null
    private var localPrefix = 0
    private var localIpv6: String? = null
    private var pushedMtu = 0
    private var remoteGw: String? = null
    private val routes = mutableListOf<Pair<String, Int>>()
    private val routes6 = mutableListOf<Pair<String, Int>>()
    private val dnsServers = mutableListOf<String>()
    private val searchDomains = mutableListOf<String>()

    /** Byte counters straight from `>BYTECOUNT` (real tunnel traffic). */
    @Volatile var bytesIn: Long = 0L
        private set

    @Volatile var bytesOut: Long = 0L
        private set

    /**
     * Reconnect-storm circuit breaker. When the front/relay resets the
     * ESTABLISHED tunnel TCP (openvpn reports RECONNECTING/connection-reset),
     * openvpn2's own retry loop silently relinks every ~4 s forever — the
     * "connected but reconnecting over and over" log flood: the session never
     * carries data, but the process looks alive, so neither watchdog notices.
     * Three RECONNECTING events inside 15 s trip this flag; the service then
     * ends the session through the supervised reconnect ladder instead.
     */
    @Volatile var resetStorm = false
        private set
    private var lastResetAt = 0L
    private var resetsInWindow = 0

    fun isRunning(): Boolean = running.get() && process?.isAlive() == true

    fun isTunnelConnected(): Boolean = tunnelConnected.get()

    fun start() {
        val nativeDir = vpnService.applicationInfo.nativeLibraryDir
        val exec = File(nativeDir, EXEC_LIB)
        if (!exec.exists()) {
            throw IOException(
                "$EXEC_LIB missing from $nativeDir — the OpenVPN 2.x native libs " +
                    "are not packaged in this build",
            )
        }

        val socketPath = File(vpnService.cacheDir, "ovpn2-mgmt").absolutePath
        openManagementSocket(socketPath)

        val profile = prepareProfile(profileText, socketPath)

        running.set(true)
        startProcess(exec, nativeDir, profile)
        startManagementThread()

        // openvpn only calls OPENTUN after the handshake and the pushed config,
        // so a materialised TUN fd is the reliable "we are up" signal.
        val deadline = SystemClock.elapsedRealtime() + 40_000L
        var lastTick = 0L
        SnapDarkTunnelVpnService.emitLog("ovpn2 waiting up to 40s for the tunnel…")
        while (SystemClock.elapsedRealtime() < deadline) {
            establishedFd.get()?.let {
                Log.i(TAG, "OpenVPN2 TUN established, fd=$it")
                return
            }
            fatalError.get()?.let { throw IOException("OpenVPN2 failed: $it") }
            if (process?.isAlive() != true) {
                throw IOException(
                    "OpenVPN2 process exited early" +
                        (fatalError.get()?.let { "; $it" } ?: ""),
                )
            }
            val waited = 40_000L - (deadline - SystemClock.elapsedRealtime())
            if (waited - lastTick >= 8_000L) {
                lastTick = waited
                SnapDarkTunnelVpnService.emitLog("ovpn2 still connecting (t=${waited / 1000}s)")
            }
            Thread.sleep(50)
        }
        throw IOException(
            "OpenVPN2 tunnel never established (no OPENTUN within 40s)" +
                (fatalError.get()?.let { "; last error: $it" } ?: ""),
        )
    }

    fun stop() {
        running.set(false)
        // SIGINT via the management interface is the clean shutdown; the process
        // then exits on its own and releases the TUN.
        sendCommand("signal SIGINT\n")
        try { Thread.sleep(120) } catch (_: InterruptedException) {}
        try { mgmtSocket?.close() } catch (_: Exception) {}
        try { serverSocket?.close() } catch (_: Exception) {}
        try { serverSocketLocal?.close() } catch (_: Exception) {}
        try { stdin?.close() } catch (_: Exception) {}
        try { process?.destroy() } catch (_: Exception) {}
        mgmtThread?.interrupt()
        processThread?.interrupt()
        mgmtThread = null
        processThread = null
        process = null
        builderRef.set(null)
    }

    // ------------------------------------------------------------------ process

    private fun openManagementSocket(path: String) {
        // A stale socket file from a previous run makes bind() fail with EADDRINUSE.
        try { File(path).delete() } catch (_: Exception) {}
        val local = LocalSocket()
        var tries = 8
        while (tries > 0 && !local.isBound) {
            try {
                local.bind(LocalSocketAddress(path, LocalSocketAddress.Namespace.FILESYSTEM))
            } catch (e: IOException) {
                try { Thread.sleep(300) } catch (_: InterruptedException) {}
            }
            tries--
        }
        if (!local.isBound) throw IOException("Could not bind OpenVPN2 management socket at $path")
        serverSocketLocal = local
        serverSocket = LocalServerSocket(local.fileDescriptor)
    }

    private fun startProcess(exec: File, nativeDir: String, profile: String) {
        // `--config stdin` keeps the profile (and its inline keys/creds) off the
        // filesystem entirely.
        val pb = ProcessBuilder(listOf(exec.absolutePath, "--config", "stdin"))
        pb.environment()["LD_LIBRARY_PATH"] = nativeDir
        pb.environment()["TMPDIR"] = vpnService.cacheDir.absolutePath
        pb.redirectErrorStream(true)
        val proc = pb.start()
        process = proc
        stdin = proc.outputStream

        // Feed the profile, then close stdin so openvpn stops reading config.
        try {
            proc.outputStream.write(profile.toByteArray())
            proc.outputStream.flush()
            proc.outputStream.close()
        } catch (e: Exception) {
            throw IOException("Could not write profile to OpenVPN2 stdin: ${e.message}", e)
        }

        processThread = Thread {
            try {
                proc.inputStream.bufferedReader().forEachLine { line ->
                    if (line.isNotBlank()) {
                        // machine-readable-output prefixes every line with
                        // "<unixtime> <hexflags> " — strip it so the log reads
                        // like the openvpn console output users expect.
                        val msg = stripLogPrefix(line)
                        Log.d(TAG, "ovpn2: $msg")
                        SnapDarkTunnelVpnService.emitLog("ovpn2: $msg")
                    }
                }
            } catch (e: Exception) {
                if (running.get()) Log.w(TAG, "stdout reader: ${e.message}")
            } finally {
                val exit = try { proc.waitFor() } catch (_: Exception) { -1 }
                Log.i(TAG, "OpenVPN2 process exited ($exit)")
                if (running.get()) {
                    SnapDarkTunnelVpnService.emitLog("ovpn2: process exited ($exit)")
                    fatalError.compareAndSet(null, "process exited with $exit")
                }
                running.set(false)
            }
        }.apply {
            isDaemon = true
            name = "ovpn2-stdout"
            start()
        }
    }

    private val logPrefixRe = Regex("^\\d+\\.\\d+ [0-9a-f]+ ")

    private fun stripLogPrefix(line: String): String = logPrefixRe.replace(line, "")

    // --------------------------------------------------------------- management

    private fun startManagementThread() {
        mgmtThread = Thread {
            try {
                val sock = serverSocket?.accept() ?: return@Thread
                mgmtSocket = sock
                // Only one client ever connects; close the listener so a crash
                // cannot leave a second openvpn attaching to us.
                try { serverSocket?.close() } catch (_: Exception) {}

                // version 3 enables the multiline/extended command set that
                // carries fds and the `>NEED-OK` dialogue.
                sendCommand("version 3\n")

                val input = sock.inputStream
                val buf = ByteArray(4096)
                var pending = ""
                while (running.get()) {
                    val n = input.read(buf)
                    if (n < 0) break
                    // Ancillary fds arrive alongside the bytes that announce them,
                    // so drain them on every read.
                    try {
                        sock.ancillaryFileDescriptors?.forEach { fd ->
                            if (fd != null) pendingFds.addLast(fd)
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "ancillary fds: ${e.message}")
                    }
                    pending += String(buf, 0, n, Charsets.UTF_8)
                    while (pending.contains("\n")) {
                        val parts = pending.split(Regex("\\r?\\n"), 2)
                        processLine(parts[0])
                        pending = if (parts.size == 1) "" else parts[1]
                    }
                }
            } catch (e: Exception) {
                if (running.get()) Log.w(TAG, "management thread: ${e.message}")
            }
        }.apply {
            isDaemon = true
            name = "ovpn2-mgmt"
            start()
        }
    }

    private fun sendCommand(cmd: String): Boolean {
        return try {
            val out = mgmtSocket?.outputStream ?: return false
            out.write(cmd.toByteArray())
            out.flush()
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun processLine(line: String) {
        if (line.isEmpty()) return
        if (line.startsWith(">NEED-OK")) {
            // Diagnostics: see the raw route/config dialogue from openvpn.
            SnapDarkTunnelVpnService.emitLog("ovpn2 mgmt: $line")
        }
        if (line.startsWith(">") && line.contains(":")) {
            val cmd = line.substringBefore(":").substring(1)
            val arg = line.substringAfter(":")
            when (cmd) {
                "INFO" -> {}
                "HOLD" -> releaseHold()
                "PASSWORD" -> handlePassword(arg)
                "NEED-OK" -> handleNeedOk(arg)
                "STATE" -> handleState(arg)
                "BYTECOUNT" -> handleByteCount(arg)
                "LOG" -> handleLog(arg)
                "PROXY" -> {
                    // We never use openvpn's management-driven proxy selection —
                    // the profile carries a literal `http-proxy` line when the
                    // injector fronts the connection.
                    sendCommand("proxy NONE\n")
                }
                "INFOMSG" -> SnapDarkTunnelVpnService.emitLog("ovpn2: $arg")
                "PK_SIGN", "NEED-CERT" -> {
                    // External PKI is not used: profiles carry inline keys.
                    Log.w(TAG, "unexpected external-PKI request: $line")
                }
                else -> Log.d(TAG, "mgmt unhandled: $line")
            }
        } else if (line.startsWith("PROTECTFD:")) {
            pendingFds.removeFirstOrNull()?.let { protectFd(it) }
        } else if (line.startsWith("SUCCESS:") || line.startsWith("ERROR:")) {
            Log.d(TAG, "mgmt: $line")
        }
    }

    private fun releaseHold() {
        sendCommand("hold release\n")
        // 2s byte counters feed the stats channel; `state on` gives us the
        // CONNECTED transition.
        sendCommand("bytecount 2\n")
        sendCommand("state on\n")
    }

    private fun handleLog(arg: String) {
        // >LOG:<time>,<flags>,<message>
        val parts = arg.split(",", limit = 3)
        val msg = if (parts.size >= 3) parts[2] else arg
        if (msg.isBlank()) return
        Log.d(TAG, "ovpn2: $msg")
        SnapDarkTunnelVpnService.emitLog("ovpn2: $msg")
    }

    private fun handleState(arg: String) {
        // >STATE:<time>,<state>,<detail>,<localip>,<remoteip>,...
        val parts = arg.split(",")
        val state = parts.getOrNull(1) ?: return
        val detail = parts.getOrNull(2)?.takeIf { it.isNotBlank() && it != "," } ?: ""
        SnapDarkTunnelVpnService.emitLog("ovpn2-state: $state${if (detail.isNotEmpty()) " ($detail)" else ""}")
        when (state) {
            "CONNECTED" -> tunnelConnected.set(true)
            "RECONNECTING" -> {
                // Honest state during a relink: the connect/liveness gates must
                // wait for the NEW CONNECTED instead of validating a dead
                // session, and the reset window below counts the relinks.
                tunnelConnected.set(false)
                if (running.get()) {
                    val now = System.currentTimeMillis()
                    if (now - lastResetAt > 15_000) resetsInWindow = 0
                    lastResetAt = now
                    resetsInWindow++
                    if (resetsInWindow >= 3 && !resetStorm) {
                        resetStorm = true
                        SnapDarkTunnelVpnService.emitLog(
                            "ovpn2: relay dropped the established tunnel 3x in 15s — reset storm" +
                                if (detail.isNotEmpty()) " ($detail)" else ""
                        )
                    }
                }
            }
            "AUTH_FAILED" -> fatalError.compareAndSet(null, "AUTH_FAILED: $detail")
            "EXITING" -> if (running.get()) {
                fatalError.compareAndSet(null, "EXITING: $detail")
            }
        }
    }

    private fun handleByteCount(arg: String) {
        val comma = arg.indexOf(',')
        if (comma <= 0) return
        bytesIn = arg.substring(0, comma).trim().toLongOrNull() ?: bytesIn
        bytesOut = arg.substring(comma + 1).trim().toLongOrNull() ?: bytesOut
        // Counters stay available for the connectivity probe's data-channel
        // check — the periodic line itself was log noise after CONNECTED.
    }

    private fun handlePassword(arg: String) {
        // ">PASSWORD:Need 'Auth' username/password" or
        // ">PASSWORD:Verification Failed: 'Auth'"
        if (arg.startsWith("Auth-Token:")) return
        if (arg.startsWith("Verification Failed")) {
            fatalError.compareAndSet(null, "auth rejected: $arg")
            SnapDarkTunnelVpnService.emitLog("ovpn2: $arg")
            return
        }
        val p1 = arg.indexOf('\'')
        val p2 = arg.indexOf('\'', p1 + 1)
        if (p1 < 0 || p2 < 0) return
        val needed = arg.substring(p1 + 1, p2)
        val creds = extractCreds()
        if (needed == "Auth" && creds != null) {
            sendCommand("username '$needed' ${escape(creds.first)}\n")
            sendCommand("password '$needed' ${escape(creds.second)}\n")
        } else {
            // Private Key / HTTP Proxy passwords are never set by us — answer with
            // an empty string so openvpn fails fast instead of hanging on hold.
            sendCommand("password '$needed' \"\"\n")
            SnapDarkTunnelVpnService.emitLog("ovpn2: no credentials available for '$needed'")
        }
    }

    /** OpenVPN management quoting: wrap in "" and backslash-escape " and \. */
    private fun escape(s: String): String {
        val sb = StringBuilder("\"")
        for (c in s) {
            if (c == '"' || c == '\\') sb.append('\\')
            sb.append(c)
        }
        return sb.append('"').toString()
    }

    private fun handleNeedOk(arg: String) {
        val p1 = arg.indexOf('\'')
        val p2 = arg.indexOf('\'', p1 + 1)
        if (p1 < 0 || p2 < 0) return
        val needed = arg.substring(p1 + 1, p2)
        val extra = arg.substringAfter(":", "")
        var status = "ok"

        when (needed) {
            "PROTECTFD" -> pendingFds.removeFirstOrNull()?.let { protectFd(it) }
            "DNSSERVER", "DNS6SERVER" -> if (extra.isNotBlank()) dnsServers.add(extra.trim())
            "DNSDOMAIN" -> if (extra.isNotBlank()) searchDomains.add(extra.trim())
            "IFCONFIG" -> {
                // "<local> <netmask> <mtu> <mode>"
                val f = extra.trim().split(Regex("\\s+"))
                if (f.size >= 3) {
                    localIp = f[0]
                    localPrefix = netmaskToPrefix(f[1], f[0], f.getOrNull(3) ?: "")
                    pushedMtu = f[2].toIntOrNull() ?: 0
                }
            }
            "IFCONFIG6" -> {
                // "<addr/prefix> <mtu>"
                val f = extra.trim().split(Regex("\\s+"))
                if (f.isNotEmpty()) localIpv6 = f[0]
                f.getOrNull(1)?.toIntOrNull()?.let { pushedMtu = it }
            }
            "ROUTE" -> {
                // "<network> <netmask> <gateway> [dev <iface>]"
                // The `dev` token arrives BEFORE the tun exists on Android. openvpn
                // reports it as "(null)" or "android-gw" — ics-openvpn's
                // isAndroidTunDevice treats both as tun devices. Dropping them (as
                // a naive `dev.startsWith("tun")` does) throws away every route,
                // leaving a TUN with no routes. The 0.0.0.0/0 fallback in buildTun
                // still saves us, but pushed routes (e.g. 10.8.0.1) are better
                // installed explicitly.
                val f = extra.trim().split(Regex("\\s+"))
                SnapDarkTunnelVpnService.emitLog("ovpn2 route: [$extra]")
                if (f.size >= 2) {
                    val dev = if (f.size == 5) f[4] else null
                    val isTun = dev == null || dev == "(null)" || dev == "android-gw" || dev.startsWith("tun")
                    if (isTun) {
                        routes.add(f[0] to netmaskToPrefix(f[1], f[0], ""))
                    } else {
                        SnapDarkTunnelVpnService.emitLog("ovpn2 route skipped (non-tun dev '$dev')")
                    }
                }
            }
            "ROUTE6" -> {
                val f = extra.trim().split(Regex("\\s+"))
                val net = f.getOrNull(0)
                if (net != null && net.contains("/")) {
                    val pfx = net.substringAfter("/").toIntOrNull()
                    if (pfx != null) routes6.add(net.substringBefore("/") to pfx)
                }
            }
            "PERSIST_TUN_ACTION" -> {
                // We never reuse a TUN across reconnects — always rebuild.
                status = "NOACTION"
            }
            "OPENTUN" -> {
                if (openTunAndSend(needed)) return
                status = "cancel"
            }
            "HTTPPROXY" -> {
                // openvpn resolved the proxy itself; nothing for us to do.
            }
            else -> {
                Log.w(TAG, "unknown needok: $arg")
                return
            }
        }
        sendCommand("needok '$needed' $status\n")
    }

    // ------------------------------------------------------------------ the TUN

    private fun openTunAndSend(needed: String): Boolean {
        val pfd = buildTun() ?: return false
        return sendCommandWithFd("needok '$needed' ok\n", pfd)
    }

    private fun buildTun(): ParcelFileDescriptor? {
        val ip = localIp
        if (ip == null) {
            SnapDarkTunnelVpnService.emitLog("ovpn2: OPENTUN with no IFCONFIG — cannot build TUN")
            return null
        }
        return try {
            val b = vpnService.Builder()
            b.setSession(sessionName)
            b.addAddress(ip, if (localPrefix in 1..32) localPrefix else 32)
            localIpv6?.let { v6 ->
                try {
                    val addr = v6.substringBefore("/")
                    val pfx = v6.substringAfter("/", "64").toIntOrNull() ?: 64
                    b.addAddress(addr, pfx)
                } catch (e: Exception) {
                    Log.w(TAG, "ipv6 addr $v6: ${e.message}")
                }
            }
            // Pushed MTU wins; the user setting is the fallback.
            val useMtu = if (pushedMtu in 576..9000) pushedMtu else mtu
            if (useMtu in 576..9000) b.setMtu(useMtu)

            if (routes.isEmpty()) {
                // No pushed routes at all (no redirect-gateway): still a full
                // tunnel, otherwise the TUN carries nothing.
                b.addRoute("0.0.0.0", 0)
            } else {
                for ((net, pfx) in routes) {
                    try { b.addRoute(net, pfx) } catch (e: Exception) {
                        Log.w(TAG, "route $net/$pfx: ${e.message}")
                    }
                }
            }
            if (localIpv6 != null) {
                for ((net, pfx) in routes6) {
                    try { b.addRoute(net, pfx) } catch (e: Exception) {
                        Log.w(TAG, "route6 $net/$pfx: ${e.message}")
                    }
                }
            }

            // Server-pushed resolvers first — they are the ones reachable inside
            // the tunnel; our defaults are only a fallback.
            val dns = LinkedHashSet<String>()
            dns.addAll(dnsServers.filter { it.isNotBlank() })
            if (dns.isEmpty()) {
                if (dnsPrimary.isNotBlank()) dns.add(dnsPrimary)
                if (dnsSecondary.isNotBlank()) dns.add(dnsSecondary)
            }
            for (d in dns) {
                // A pushed IPv6 resolver in an IPv4-only TUN makes establish()
                // return null; skip what the interface cannot route.
                if (isIpv6(d) && localIpv6 == null) continue
                try { b.addDnsServer(d) } catch (e: Exception) {
                    Log.w(TAG, "dns $d: ${e.message}")
                }
            }
            for (dom in searchDomains) {
                try { b.addSearchDomain(dom) } catch (_: Exception) {}
            }
            b.setBlocking(true)
            (vpnService as? SnapDarkTunnelVpnService)?.applySplitTunnel(b)

            builderRef.set(b)
            val pfd = b.establish()
            if (pfd == null) {
                SnapDarkTunnelVpnService.emitLog(
                    "ovpn2: VpnService.Builder.establish() returned NULL " +
                        "(interface params rejected: $ip/$localPrefix mtu=$useMtu)",
                )
                return null
            }
            establishedFd.set(pfd.fd)
            tunnelConnected.set(true)
            SnapDarkTunnelVpnService.emitLog(
                "ovpn2 tun up: $ip/$localPrefix mtu=$useMtu routes=${routes.size} dns=${dns.joinToString()}",
            )
            pfd
        } catch (e: Exception) {
            SnapDarkTunnelVpnService.emitLog("ovpn2: building TUN failed: ${e.message}")
            Log.e(TAG, "buildTun", e)
            null
        }
    }

    /**
     * Hand the TUN fd to openvpn as an ancillary fd on the management socket.
     *
     * `LocalSocket.setFileDescriptorsForSend` keeps resending the same fd on
     * every subsequent write, so it must be cleared immediately after the
     * command (ics-openvpn hit the same trap).
     */
    private fun sendCommandWithFd(cmd: String, pfd: ParcelFileDescriptor): Boolean {
        val sock = mgmtSocket ?: return false
        return try {
            // getFileDescriptor() is public API — no reflection needed.
            sock.setFileDescriptorsForSend(arrayOf(pfd.fileDescriptor))
            sendCommand(cmd)
            sock.setFileDescriptorsForSend(null)
            pfd.close()
            true
        } catch (e: Exception) {
            SnapDarkTunnelVpnService.emitLog("ovpn2: could not send TUN fd: ${e.message}")
            Log.e(TAG, "sendCommandWithFd", e)
            false
        }
    }

    /**
     * Keep openvpn's transport socket out of our own TUN (otherwise the tunnel
     * carries its own packets). openvpn passes the raw fd over the management
     * socket; `FileDescriptor.getInt$` is the only way to read the int back for
     * `VpnService.protect(int)`, and we must close our own copy afterwards.
     */
    private fun protectFd(fd: FileDescriptor) {
        try {
            val getInt = FileDescriptor::class.java.getDeclaredMethod("getInt$")
            val fdInt = getInt.invoke(fd) as Int
            if (!vpnService.protect(fdInt)) {
                SnapDarkTunnelVpnService.emitLog("ovpn2: could not protect socket fd=$fdInt")
            }
        } catch (e: Exception) {
            Log.w(TAG, "protectFd: ${e.message}")
        } finally {
            try { Os.close(fd) } catch (_: Exception) {}
        }
    }

    // ------------------------------------------------------------------ helpers

    private fun isIpv6(addr: String): Boolean =
        try { InetAddress.getByName(addr) is Inet6Address } catch (_: Exception) { addr.contains(":") }

    /**
     * Convert a dotted netmask to a prefix length.
     *
     * openvpn's `topology net30`/`p2p` hands us a *peer address* instead of a
     * real mask (e.g. local 10.8.0.14 mask 10.8.0.13), which as a mask parses to
     * nonsense. Detect that shape and use the /30 (or /31) the topology implies —
     * this is the same correction ics-openvpn applies in setLocalIP.
     */
    private fun netmaskToPrefix(mask: String, local: String, mode: String): Int {
        val asInt = ipToInt(mask)
        if (asInt == null) return 32
        // A genuine mask is a run of 1s followed by 0s.
        val inverted = asInt.inv() and 0xFFFFFFFFL.toInt()
        val isRealMask = (inverted.toLong() and (inverted.toLong() + 1L)) == 0L
        if (isRealMask) {
            return Integer.bitCount(asInt)
        }
        // Not a mask: net30/p2p peer address.
        val localInt = ipToInt(local) ?: return 32
        val net30Mask = 0xfffffffc.toInt()
        val p2pMask = 0xfffffffe.toInt()
        return when {
            mode.equals("net30", true) && (asInt and net30Mask) == (localInt and net30Mask) -> 30
            mode.equals("p2p", true) && (asInt and p2pMask) == (localInt and p2pMask) -> 31
            (asInt and net30Mask) == (localInt and net30Mask) -> 30
            (asInt and p2pMask) == (localInt and p2pMask) -> 31
            else -> 32
        }
    }

    private fun ipToInt(ip: String): Int? {
        val parts = ip.split(".")
        if (parts.size != 4) return null
        var v = 0
        for (p in parts) {
            val o = p.toIntOrNull() ?: return null
            if (o < 0 || o > 255) return null
            v = (v shl 8) or o
        }
        return v
    }

    private fun extractCreds(): Pair<String, String>? {
        val inline = Regex("(?is)<auth-user-pass>\\s*(.+?)\\s*</auth-user-pass>")
            .find(profileText)?.groupValues?.getOrNull(1)
        if (inline != null) {
            val lines = inline.trim().lines().filter { it.isNotBlank() }
            if (lines.size >= 2) return lines[0].trim() to lines[1].trim()
        }
        val path = Regex("(?im)^\\s*auth-user-pass\\s+(\\S+)\\s*$")
            .find(profileText)?.groupValues?.getOrNull(1)
        if (path != null) {
            try {
                val lines = File(path).readLines().filter { it.isNotBlank() }
                if (lines.size >= 2) return lines[0].trim() to lines[1].trim()
            } catch (e: Exception) {
                Log.w(TAG, "read creds file $path: ${e.message}")
            }
        }
        return null
    }

    /**
     * Wrap the user's profile with the management-interface plumbing.
     *
     * Unlike the openvpn3 path this does **almost no rewriting**: `cipher none`,
     * `auth none`, `comp-lzo`, `fragment`, `http-proxy-option CUSTOM-HEADER` and
     * friends are all valid here, and stripping them is what broke parity with
     * HTTP Custom / OpenVPN Lite in the first place. Only genuinely
     * incompatible-with-Android directives are removed.
     */
    private fun prepareProfile(raw: String, socketPath: String): String {
        val body = raw.replace("\r\n", "\n").replace("\r", "\n")
        val out = StringBuilder()

        out.append("# SnapDark Tunnel — OpenVPN 2.x (management-driven)\n")
        out.append("management ").append(socketPath).append(" unix\n")
        out.append("management-client\n")
        out.append("management-query-passwords\n")
        // Hold until we have attached and sent `hold release`, so we never miss
        // the early PROTECTFD/IFCONFIG dialogue.
        out.append("management-hold\n")
        // Timestamps + flags on stdout so the reader can classify lines.
        out.append("machine-readable-output\n")
        out.append("ifconfig-nowarn\n")
        // NB: no `route-noexec` / `ifconfig-noexec` here. openvpn on Android
        // never touches the interface itself — it asks US via `>NEED-OK
        // 'IFCONFIG'` / `'ROUTE'`, and route-noexec would suppress exactly those
        // callbacks, leaving the TUN with no routes at all.
        out.append("verb 4\n")

        val lines = body.lines()
        val dropped = mutableListOf<String>()
        for (line in lines) {
            val opt = line.trim().lowercase()
            val drop = when {
                // Ours; a second management/verb line would override it.
                opt.startsWith("management") -> true
                opt.startsWith("machine-readable-output") -> true
                opt.startsWith("verb ") -> true
                opt.startsWith("route-noexec") -> true
                // Impossible on Android: no root, no external scripts, no
                // persistent device, no /dev/net/tun of our own.
                opt.startsWith("dev-node") -> true
                opt.startsWith("user ") || opt.startsWith("group ") -> true
                opt.startsWith("chroot") -> true
                opt.startsWith("daemon") -> true
                opt.startsWith("script-security") -> true
                opt.startsWith("up ") || opt.startsWith("down ") -> true
                opt.startsWith("route-up") || opt.startsWith("route-pre-down") -> true
                opt.startsWith("ifconfig-noexec") -> true
                opt.startsWith("block-outside-dns") -> true
                opt.startsWith("register-dns") -> true
                opt.startsWith("log ") || opt.startsWith("log-append") -> true
                opt.startsWith("status ") -> true
                // `mute` hides openvpn's own diagnostics — without it every
                // important line drowns in "--mute triggered... N variation(s)
                // suppressed", so we could never see WHY the data channel died.
                opt.startsWith("mute ") -> true
                // We supply the tun fd ourselves.
                opt == "dev tun" -> false
                opt.startsWith("dev ") && !opt.startsWith("dev tun") -> true
                else -> false
            }
            if (drop) {
                if (opt.isNotEmpty() && !opt.startsWith("#") && !opt.startsWith(";")) {
                    dropped.add(line.trim())
                }
            } else {
                out.append(line).append('\n')
            }
        }
        if (!Regex("(?im)^\\s*dev\\s+tun").containsMatchIn(body)) out.append("dev tun\n")
        // OpenVPN 2.7's default `allow-compression` is `stub-only`, which makes it
        // REJECT a server that pushes `compress lz4-v2` ("server pushed compression
        // settings that are not allowed"). HTTP Custom / OpenVPN Lite accept the
        // server's LZ4v2 in asymmetric mode (receive/decompress, never send
        // compressed) and connect fine. So does ovpn2 with `allow-compression
        // asym` — the safe value: it only affects *received* packets, and servers
        // that push nothing are unaffected (no uplink framing is added).
        if (!Regex("(?im)^\\s*allow-compression\\b").containsMatchIn(body)) {
            out.append("allow-compression asym\n")
        }
        // 2.7 refuses a config that has no TLS at all unless explicitly allowed;
        // `cipher none` / `auth none` profiles trip the same check. With real TLS
        // present this flag is a harmless no-op, so it is safe to keep for the
        // null-cipher profiles our server actually expects (HTTP Custom logs
        // `local='cipher [null-cipher]'` against it).
        if (Regex("(?im)^\\s*(cipher|auth)\\s+none\\b").containsMatchIn(body)) {
            out.append("allow-deprecated-insecure-static-crypto\n")
        }
        if (dropped.isNotEmpty()) {
            Log.i(TAG, "ovpn2 dropped ${dropped.size} unsupported directives: $dropped")
            SnapDarkTunnelVpnService.emitLog(
                "ovpn2: ignored ${dropped.size} Android-incompatible option(s): " +
                    dropped.take(6).joinToString(", ") + if (dropped.size > 6) ", …" else "",
            )
        }
        return out.toString()
    }
}
