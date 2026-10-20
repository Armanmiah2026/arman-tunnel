package com.snapdark.tunnel

import android.app.Activity
import android.app.DownloadManager
import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.Environment
import android.telephony.SubscriptionManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import android.util.Base64
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Lean Flutter host. All UI lives in Dart (lib/). This activity only bridges
 * Dart <-> the native VPN engine via one MethodChannel and two EventChannels,
 * and brokers the system VPN-permission consent dialog.
 */
class MainActivity : FlutterActivity() {

    companion object {
        /**
         * True while this activity (the Flutter UI) is alive. The VPN service
         * reads it to tell a USER-initiated connect apart from a system
         * START_REDELIVER_INTENT restart after the process was killed: only
         * the redelivered one continues the previous session's timer.
         */
        @JvmStatic var uiAlive = false
    }

    private val VPN_CHANNEL = "com.snapdark.tunnel/vpn"
    private val STATE_CHANNEL = "com.snapdark.tunnel/vpn_state"
    private val STATS_CHANNEL = "com.snapdark.tunnel/vpn_stats"
    private val VPN_REQUEST_CODE = 0x5454
    private val NOTIF_REQUEST_CODE = 0x5455
    private val REQUEST_READ_PHONE_STATE = 0x5456

    // AES-GCM locked-config scheme, kept byte-compatible with the Dart/Worker "sensei:v2:" format.
    private val lockKeySeed = "ArmanTunnel:Armanmiah2026:v2"

    private var methodChannel: MethodChannel? = null

    // Holds a start request that is waiting on the VPN consent dialog.
    private var pendingStartArgs: Map<String, Any?>? = null
    private var pendingStartResult: MethodChannel.Result? = null

    /** The custom SIM-picker dialog, so it can be dismissed on selection. */
    private var simPickerDialog: android.app.Dialog? = null

    /** Which flow requested the phone permission (APN vs 4G/5G switcher). */
    private var phonePermissionForNetworkMode = false

    /** Serial background executor for channel handlers that touch the disk,
     *  PackageManager or content providers. */
    private val ioExecutor =
        java.util.concurrent.Executors.newSingleThreadExecutor { r ->
            Thread(r, "snapdark-io").apply { isDaemon = true }
        }

    /** Deep link / share / file-open received BEFORE the Dart side registered
     *  its method-call handler (cold start). Flushed when Dart calls
     *  "flutterReady" — previously these messages hit an unregistered handler
     *  and vanished, so tapping a vless:// link with the app dead opened the
     *  app and imported nothing. */
    private var dartReady = false
    private val pendingLaunches = ArrayList<Pair<String, Any?>>()

    private fun dispatchToFlutter(method: String, payload: Any?) {
        if (!dartReady) {
            pendingLaunches.add(method to payload)
            return
        }
        methodChannel?.invokeMethod(method, payload)
    }

    private fun flushPendingLaunches() {
        if (pendingLaunches.isEmpty()) return
        val queue = ArrayList(pendingLaunches)
        pendingLaunches.clear()
        for ((m, p) in queue) methodChannel?.invokeMethod(m, p)
    }

    
    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        uiAlive = true
        handleIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        // Coming back to the app after a sleep/freeze window: don't trust the
        // last known state — make the watchdog prove the tunnel on its next
        // tick (≈1s) instead of up to 60s later.
        SnapDarkTunnelVpnService.instance()?.forceLivenessCheck()
    }

    override fun onDestroy() {
        uiAlive = false
        dartReady = false
        // A consent dialog that never comes back must not strand the Dart
        // Future waiting on this result forever.
        pendingStartResult?.let {
            try { it.error("activity_destroyed", "Activity destroyed", null) } catch (_: Exception) {}
        }
        pendingStartResult = null
        pendingStartArgs = null
        try { simPickerDialog?.dismiss() } catch (_: Exception) {}
        simPickerDialog = null
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        when (intent?.action) {
            Intent.ACTION_VIEW -> {
                val data = intent.dataString ?: return
                // Every scheme the app can actually import — forwarding only
                // darktunnel:// used to make vless:// links open the app and
                // silently do nothing.
                val schemes = listOf("darktunnel://", "vless://", "vmess://", "trojan://", "ss://")
                if (schemes.any { data.startsWith(it) }) {
                    dispatchToFlutter("onDeepLink", data)
                    return
                }
                // A tapped config FILE (.st/.txt/.cfg): hand the URI over and
                // let the Dart side read it via the file-picker channel.
                val uri = intent.data ?: return
                dispatchToFlutter("onConfigFile", uri.toString())
            }
            Intent.ACTION_SEND -> {
                // "Share to SnapDarkTunnel": config text straight from a chat app.
                val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: return
                if (text.isNotBlank()) {
                    dispatchToFlutter("onSharedText", text)
                }
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        methodChannel = MethodChannel(messenger, VPN_CHANNEL).also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "startVpn" -> handleStart(call.arguments as? Map<String, Any?> ?: emptyMap(), result)
                    "stopVpn" -> { sendServiceAction(SnapDarkTunnelVpnService.ACTION_STOP); result.success(true) }
                    "isVpnRunning" -> result.success(SnapDarkTunnelVpnService.isRunning)
                    "getDeviceId" -> {
                        // Stable hardware id for the BDIX trial system:
                        // ANDROID_ID + build fingerprint + install cert. Survives
                        // an app delete + reinstall, so a reinstall cannot farm a
                        // fresh trial. Never leaves the device unhashed.
                        try {
                            result.success(ShareEnvelope.deviceHwid(this))
                        } catch (e: Exception) {
                            result.error("device_id_failed", e.message, null)
                        }
                    }
                    "getDeviceInfo" -> {
                        // Platform info for the admin panel's user management:
                        // Android release + device model + SDK int.
                        try {
                            val info: Map<String, Any> = mapOf(
                                "platform" to "Android ${android.os.Build.VERSION.RELEASE} (${android.os.Build.MODEL})",
                                "sdkInt" to android.os.Build.VERSION.SDK_INT,
                            )
                            result.success(info)
                        } catch (e: Exception) {
                            result.error("device_info_failed", e.message, null)
                        }
                    }
                    "sessionInfo" -> result.success(
                        SnapDarkTunnelVpnService.sessionInfo()
                    )
                    "requestVpnPermission" -> result.success(prepareVpn())
                    "measureDelay" -> result.success(SnapDarkTunnelVpnService.lastDelay.toInt())
                    "pingHost" -> {
                        // Blocking socket work MUST leave the main thread:
                        // NetworkOnMainThreadException made every probe
                        // return -1 before this ran on an executor.
                        val host = call.argument<String>("host")
                            ?: "connectivitycheck.gstatic.com"
                        val port = call.argument<Int>("port") ?: 80
                        val tv = call.argument<Boolean>("throughVpn") ?: true
                        SnapDarkTunnelVpnService.pingExecutor.execute {
                            val ms = SnapDarkTunnelVpnService.pingHost(host, port, tv)
                            runOnUiThread { result.success(ms) }
                        }
                    }
                    "pingHosts" -> {
                        // Bulk sweep for the per-card latency badges: one call
                        // for the whole visible server list, probed in parallel
                        // off the main thread. Targets are "host:port" strings;
                        // the reply is the ms per target in the same order.
                        // throughVpn routes each probe through the running
                        // tunnel (real usable latency) — direct when none is up.
                        val raw = call.argument<List<String>>("targets") ?: emptyList()
                        val tv = call.argument<Boolean>("throughVpn") ?: true
                        SnapDarkTunnelVpnService.pingExecutor.execute {
                            val pairs = raw.mapNotNull { s ->
                                val i = s.lastIndexOf(':')
                                if (i <= 0) null else {
                                    val p = s.substring(i + 1).toIntOrNull()
                                    if (p == null) null else s.substring(0, i) to p
                                }
                            }
                            val ms = SnapDarkTunnelVpnService.pingHosts(pairs, tv)
                            runOnUiThread {
                                val list = ArrayList<Any>(ms.size)
                                ms.forEach { list.add(it) }
                                result.success(list)
                            }
                        }
                    }
                    "httpPing" -> {
                        // HTTP-level probe: returns ms + the response status, so
                        // the UI can show what actually answered instead of only
                        // proving a socket opened.
                        val host = call.argument<String>("host")
                            ?: "connectivitycheck.gstatic.com/generate_204"
                        val port = call.argument<Int>("port") ?: 0
                        val tv = call.argument<Boolean>("throughVpn") ?: true
                        val https = call.argument<Boolean>("https") ?: false
                        SnapDarkTunnelVpnService.pingExecutor.execute {
                            val res = SnapDarkTunnelVpnService.httpPing(host, port, tv, https)
                            runOnUiThread { result.success(res) }
                        }
                    }
                    "setSelfThroughVpn" -> {
                        // Speed-test sheet only: route the APP's own traffic
                        // through the VPN network while the sheet is open, and
                        // hand it back to the physical network on close.
                        // Everything outside the sheet stays on the user's own
                        // network by design.
                        val on = call.argument<Boolean>("on") ?: false
                        result.success(
                            SnapDarkTunnelVpnService.instance()?.setSelfTrafficThroughVpn(on) ?: false
                        )
                    }
                    "getLastError" -> result.success(SnapDarkTunnelVpnService.lastError)
                    // v48 share envelope — build/open the protected share format.
                    "shareEnvelopeBuild" -> result.success(
                        ShareEnvelope.build(
                            applicationContext,
                            call.argument<String>("config") ?: "",
                            call.arguments as? Map<String, Any?> ?: emptyMap(),
                        )
                    )
                    "shareEnvelopeOpen" -> result.success(
                        ShareEnvelope.open(
                            applicationContext,
                            call.argument<String>("text") ?: "",
                            call.argument<String>("password"),
                        )
                    )
                    "shareEnvelopeNeedsPassword" -> result.success(
                        ShareEnvelope.needsPassword(call.argument<String>("text") ?: "")
                    )
                    "flutterReady" -> {
                        dartReady = true
                        flushPendingLaunches()
                        result.success(true)
                    }
                    "shareEnvelopeIsShare" -> result.success(
                        ShareEnvelope.isShare(call.argument<String>("text") ?: "")
                    )
                    "deviceHwid" -> result.success(ShareEnvelope.deviceHwid(applicationContext))
                    "parseLockedConfig" -> {
                        // Two contracts the old code broke: (a) the PIN never
                        // reached parseLocked(), so a sensei:v2p: share could
                        // NEVER open — even with the correct one; (b) the reply
                        // was the raw decrypted String (or the untouched body
                        // for unknown text) while Dart awaits a Map — so every
                        // successful decrypt threw a TypeError in
                        // invokeMethod<Map> and locked imports were impossible.
                        val body = call.argument<String>("config") ?: ""
                        val plain = parseLocked(body, call.argument<String>("pin"))
                        result.success(
                            if (plain == null) mapOf("ok" to false)
                            else try {
                                JSONObject(plain).toMap() + ("ok" to true)
                            } catch (_: Exception) {
                                mapOf("ok" to false) // not JSON (e.g. plain text echo)
                            },
                        )
                    }
                    "encryptLockedConfig" -> {
                        @Suppress("UNCHECKED_CAST")
                        result.success(
                            encryptLocked(
                                call.arguments as? Map<String, Any?>,
                                call.argument<String>("pin"),
                            )
                        )
                    }
                    "deriveLockCheck" -> result.success(
                        deriveLockCheck(call.argument<String>("pin") ?: "")
                    )
                    "decryptConfig" -> result.success(
                        AppSecurity.decryptConfig(applicationContext, call.argument<String>("body"))
                    )
                    "appCertSha256" -> result.success(AppSecurity.certSha256(applicationContext))
                    "verifyIntegrity" -> result.success(AppSecurity.integrityOk(applicationContext))
                    "vipIssue" -> result.success(
                        AppSecurity.issueVipTicket(
                            applicationContext,
                            call.argument<String>("configId") ?: "",
                            (call.argument<Double>("durationMs") ?: 0.0).toLong(),
                        )
                    )
                    "vipVerify" -> result.success(
                        AppSecurity.verifyVipTicket(
                            applicationContext,
                            call.argument<String>("ticket"),
                            call.argument<String>("configId") ?: "",
                        )
                    )
                    "installedPackageInfo" -> {
                        // Runtime build facts for the Dart-side force-update gate and
                        // the About screen. versionCode is the REAL installed code
                        // (per-ABI split APKs report 591/592, not the compile-time 59);
                        // comparing update gates against the baked kAppBuildNumber
                        // would misfire. is64Bit = 64-bit process (arm64 APK).
                        val info = try {
                            packageManager.getPackageInfo(packageName, 0)
                        } catch (e: Exception) {
                            null
                        }
                        result.success(
                            mapOf(
                                "versionCode" to (info?.longVersionCode ?: 0L),
                                "versionName" to (info?.versionName ?: ""),
                                "supportedAbis" to Build.SUPPORTED_ABIS.toList(),
                                "is64Bit" to (Build.SUPPORTED_64_BIT_ABIS.isNotEmpty()),
                            )
                        )
                    }
                    // At-rest server-cache encryption (AndroidKeyStore AES-256-GCM).
                    // A re-signed clone that fails integrity never reaches here;
                    // even reading the prefs file yields only ciphertext.
                    "encryptCache" -> result.success(
                        CacheCipher.encrypt(applicationContext, call.argument<String>("plain") ?: "")
                    )
                    "decryptCache" -> result.success(
                        CacheCipher.decrypt(applicationContext, call.argument<String>("blob") ?: "")
                    )
                    "installedApps" -> {
                        // PackageManager enumeration + per-APK label loads
                        // (hundreds of disk/resource reads on low-end devices)
                        // must not run on the platform thread — the split
                        // tunnel picker janked to an ANR there.
                        ioExecutor.execute {
                            val apps = try { installedApps() } catch (e: Exception) { emptyList<Map<String, Any>>() }
                            runOnUiThread { result.success(apps) }
                        }
                    }
                    "getProxyStats" -> {
                        // /proc/net/tcp + tcp6 parsed every ~3s from the
                        // hotspot tab — off the main thread.
                        ioExecutor.execute {
                            val stats = try { proxyStats() } catch (e: Exception) { emptyMap<String, Any>() }
                            runOnUiThread { result.success(stats) }
                        }
                    }
                    "downloadAndInstallApk" -> downloadAndInstallApk(
                        call.argument<String>("url") ?: "",
                        result,
                    )
                    "showToast" -> {
                        val msg = call.argument<String>("msg") ?: ""
                        val long = call.argument<Boolean>("long") ?: false
                        showNativeToast(msg, long)
                        result.success(true)
                    }
                    "ignoreBatteryOptimization" -> { openIgnoreBattery(); result.success(true) }
                    "openApnSettings" -> { openSimSettingsSmart(forNetworkMode = false); result.success(true) }
                    // 4G/5G switcher: no SIM selection and no permission —
                    // the testing menus are device-wide (their dropdown lists
                    // per-SIM entries on dual-SIM phones anyway).
                    "openNetworkModeSettings" -> {
                        Thread { openApnSettingsChain(forNetworkMode = true) }.start()
                        result.success(true)
                    }
                    "openAppSettings" -> { openAppDetails(); result.success(true) }
                    "getWallpaper" -> {
                        // Device wallpaper (HOME or LOCK screen) as PNG bytes.
                        // Best-effort: some OEMs deny it, then null = "no
                        // wallpaper available".
                        val which = call.argument<String>("which") ?: "home"
                        SnapDarkTunnelVpnService.pingExecutor.execute {
                            val bytes = readDeviceWallpaper(which == "lock")
                            runOnUiThread { result.success(bytes) }
                        }
                    }
                    "readConfigFile" -> {
                        val uri = call.argument<String>("uri") ?: ""
                        if (uri.isEmpty()) {
                            result.success(null)
                        } else {
                            // content:// providers can be network-backed (Drive,
                            // MTP, remote FS managers) — a blocking readText()
                            // on the platform thread is a textbook ANR.
                            ioExecutor.execute {
                                val text = try {
                                    contentResolver
                                        .openInputStream(android.net.Uri.parse(uri))
                                        ?.bufferedReader(Charsets.UTF_8)
                                        ?.use { it.readText() }
                                } catch (e: Exception) {
                                    null
                                }
                                runOnUiThread { result.success(text) }
                            }
                        }
                    }
                    "shareText" -> {
                        // Plain-text share sheet (ACTION_SEND chooser) — how
                        // configs leave the app: chat apps, Files, Bluetooth,
                        // whatever the user has. Works from the main thread;
                        // startActivity off the chooser needs no result.
                        val text = call.argument<String>("text") ?: ""
                        val title = call.argument<String>("title") ?: "Share config"
                        if (text.isEmpty()) {
                            result.success(false)
                        } else {
                            try {
                                val send = Intent(Intent.ACTION_SEND).apply {
                                    type = "text/plain"
                                    putExtra(Intent.EXTRA_TEXT, text)
                                    putExtra(Intent.EXTRA_SUBJECT, title)
                                }
                                startActivity(Intent.createChooser(send, title))
                                result.success(true)
                            } catch (e: Exception) {
                                result.success(false)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }

        EventChannel(messenger, STATE_CHANNEL).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                SnapDarkTunnelVpnService.stateEventSink = sink
                sink?.success(if (SnapDarkTunnelVpnService.isRunning) "connected" else "disconnected")
            }
            override fun onCancel(arguments: Any?) { SnapDarkTunnelVpnService.stateEventSink = null }
        })

        EventChannel(messenger, STATS_CHANNEL).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) { SnapDarkTunnelVpnService.statsEventSink = sink }
            override fun onCancel(arguments: Any?) { SnapDarkTunnelVpnService.statsEventSink = null }
        })
    }

    /** Returns the consent Intent (non-null) when permission is still needed. */
    private fun prepareVpn(): Boolean {
        val intent = VpnService.prepare(this)
        if (intent != null) {
            startActivityForResult(intent, VPN_REQUEST_CODE)
            return false
        }
        return true
    }

    private fun handleStart(args: Map<String, Any?>, result: MethodChannel.Result) {
        // Android 13+ hides ALL notifications (even the foreground one) until
        // POST_NOTIFICATIONS is granted. Ask up front so the connected
        // notification with Stop/Reconnect is actually visible.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIF_REQUEST_CODE)
        }

        val consent = VpnService.prepare(this)
        if (consent != null) {
            // Defer until the user accepts the system dialog.
            pendingStartArgs = args
            pendingStartResult = result
            startActivityForResult(consent, VPN_REQUEST_CODE)
            return
        }
        launchService(args)
        result.success(true)
    }

    private fun launchService(args: Map<String, Any?>) {
        fun str(k: String) = args[k] as? String ?: ""
        val intent = Intent(this, SnapDarkTunnelVpnService::class.java).apply {
            action = SnapDarkTunnelVpnService.ACTION_START
            putExtra("config", str("config"))
            putExtra("serverName", str("serverName"))
            putExtra("isSsh", (args["isSsh"] as? Boolean) ?: false)
            putExtra("isOpenvpn", (args["isOpenvpn"] as? Boolean) ?: false)
            putExtra("isWireguard", (args["isWireguard"] as? Boolean) ?: false)
            putExtra("isProxy", (args["isProxy"] as? Boolean) ?: false)
            putExtra("isPsiphon", (args["isPsiphon"] as? Boolean) ?: false)
            putExtra("isHysteria", (args["isHysteria"] as? Boolean) ?: false)
            putExtra("wireguardConfig", str("wireguardConfig"))
            putExtra("proxyMode", str("proxyMode"))
            putExtra("psiphonRegion", str("psiphonRegion"))
            putExtra("ovpnConfig", str("ovpnConfig"))
            // Engine choice: default is OpenVPN 2.x; true = openvpn3 fallback.
            putExtra("ovpnUseOvpn3", (args["ovpnUseOvpn3"] as? Boolean) ?: false)
            putExtra("mode", str("mode"))
            putExtra("sshUser", str("sshUser"))
            putExtra("sshPass", str("sshPass"))
            putExtra("sni", str("sni"))
            putExtra("injectMode", str("injectMode"))
            putExtra("payload", str("payload"))
            putExtra("injectHost", str("injectHost"))
            putExtra("injectPort", str("injectPort"))
            putExtra("dnsttServer", str("dnsttServer"))
            putExtra("dnsttKey", str("dnsttKey"))
            putExtra("dnsttResolver", str("dnsttResolver"))
            putExtra("address", str("sshHost").ifBlank { str("address") })
            putExtra("port", asInt(args["sshPort"] ?: args["port"], 443))
            // Per-config tunnel tweaks. These MUST be forwarded: the service
            // gates the V2Ray payload relay on `v2rayInject`, so dropping it
            // leaves xray dialling a dead local port (see toXrayConfig).
            putExtra("payloadEnhanced", (args["payloadEnhanced"] as? Boolean) ?: false)
            putExtra("sshCompression", (args["sshCompression"] as? Boolean) ?: false)
            putExtra("v2rayInject", (args["v2rayInject"] as? Boolean) ?: false)
            // Settings
            putExtra("mtu", asInt(args["mtu"], 1500))
            // The whole ordered resolver list (Android's Builder takes any number of
            // addDnsServer calls). A StringList is used rather than a parallel
            // dnsPrimary/dnsSecondary pair so adding a third resolver needs no
            // new Intent extra and no new Dart-side named argument.
            val dnsList = (args["dnsServers"] as? List<*>)
                ?.mapNotNull { (it as? String)?.trim() }
                ?.filter { it.isNotEmpty() }
                ?: emptyList()
            putExtra("dnsServers", ArrayList(dnsList))
            // Kept for the OpenVPN engines, which take exactly two.
            putExtra("dnsPrimary", dnsList.firstOrNull() ?: "8.8.8.8")
            putExtra("dnsSecondary", dnsList.getOrNull(1) ?: (dnsList.firstOrNull() ?: "8.8.8.8"))
            putExtra("bypassLan", (args["bypassLan"] as? Boolean) ?: true)
            putExtra("wakeLock", (args["wakeLock"] as? Boolean) ?: false)
            putExtra("autoReconnect", (args["autoReconnect"] as? Boolean) ?: false)
            putExtra("killSwitch", (args["killSwitch"] as? Boolean) ?: false)
            putExtra("hotspotShare", (args["hotspotShare"] as? Boolean) ?: true)
            putExtra("keepAliveMode", asInt(args["keepAliveMode"], 1).coerceIn(0, 2))
            // Split tunnel: mode + selected package names.
            putExtra("splitMode", str("splitMode").ifBlank { "off" })
            @Suppress("UNCHECKED_CAST")
            val apps = (args["splitApps"] as? List<Any?>)?.mapNotNull { it as? String } ?: emptyList()
            putStringArrayListExtra("splitApps", ArrayList(apps))
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(intent) else startService(intent)
    }

    private fun sendServiceAction(action: String) {
        startService(Intent(this, SnapDarkTunnelVpnService::class.java).apply { this.action = action })
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != VPN_REQUEST_CODE) return
        val granted = resultCode == Activity.RESULT_OK
        val args = pendingStartArgs
        val result = pendingStartResult
        pendingStartArgs = null
        pendingStartResult = null
        if (args != null) {
            if (granted) { launchService(args); result?.success(true) }
            else result?.success(false)
        }
    }

    /**
     * Launchable, internet-capable apps for the split-tunnel picker.
     * Returns a list of {package, name, system}, our own package excluded,
     * sorted user-apps-first then alphabetically by label.
     */
    /**
     * Scan /proc/net/tcp(/6) for ESTABLISHED sockets whose local port is one of
     * the tunnel's proxy endpoints (SOCKS 10808, HTTP 10809, DNS 7353). Returns
     * the live connection count plus the distinct NON-loopback remote peer IPs
     * — i.e. how many other devices are actively using the proxy right now.
     * Handles v4 + v4-mapped-in-v6 since the engines bind 0.0.0.0.
     */
    private fun proxyStats(): Map<String, Any?> {
        val localPorts = setOf(10808, 10809, 7353)
        val peers = LinkedHashSet<String>()
        var count = 0
        for (path in listOf("/proc/net/tcp", "/proc/net/tcp6")) {
            try {
                val lines = java.io.File(path).readLines()
                for (line in lines.drop(1)) {
                    val f = line.trim().split(Regex("\\s+"))
                    if (f.size < 4) continue
                    val state = f[3].substringBefore(":")
                    if (state != "01") continue // ESTABLISHED
                    val local = f[1] // local addr hex: "00000000:2A38"
                    val localColon = local.lastIndexOf(':')
                    val localPort = local.substring(localColon + 1).toIntOrNull(16) ?: continue
                    if (localPort !in localPorts) continue
                    count++
                    val rem = f[2] // remote addr hex: "0100007F:2A30"
                    val colon = rem.lastIndexOf(':')
                    val ipHex = rem.substring(0, colon)
                    val ip = if (path.endsWith("6"))
                        ipv6HexToIp(ipHex) else ipv4HexToIp(ipHex)
                    // Skip the phone's own loopback / local hosting.
                    if (!ip.isNullOrEmpty() && !ip.startsWith("127.") && ip != "::1") {
                        peers.add(ip)
                    }
                }
            } catch (_: Exception) {}
        }
        return mapOf(
            "count" to count,
            "devices" to peers.toList(),
        )
    }

    private fun downloadAndInstallApk(url: String, result: MethodChannel.Result) {
        if (url.isBlank()) {
            result.error("bad_url", "Update URL is empty", null)
            return
        }
        val uri = try {
            Uri.parse(url)
        } catch (_: Exception) {
            result.error("bad_url", "Invalid update URL", null)
            return
        }
        Thread {
            try {
                val dm = getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
                val fileName = "SnapDarkTunnel-update.apk"
                val request = DownloadManager.Request(uri)
                    .setTitle("SnapDark Tunnel update")
                    .setDescription("Downloading latest APK")
                    .setNotificationVisibility(
                        DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED,
                    )
                    .setAllowedOverMetered(true)
                    .setAllowedOverRoaming(true)
                    .setMimeType("application/vnd.android.package-archive")
                    .setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, fileName)
                val id = dm.enqueue(request)
                var status = DownloadManager.STATUS_PENDING
                var reason = 0
                // Bounded wait: a cleared/hidden download row (the system
                // Downloads UI lets the user delete it) used to leave
                // moveToFirst() false forever — status stayed PENDING, the
                // loop never broke, and the update sheet hung on
                // "Downloading…" for the rest of the process.
                val deadline = System.currentTimeMillis() + 10 * 60_000L
                var rowGone = false
                while (System.currentTimeMillis() < deadline && !rowGone) {
                    Thread.sleep(500)
                    dm.query(DownloadManager.Query().setFilterById(id)).use { c ->
                        if (c.moveToFirst()) {
                            status = c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
                            reason = c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON))
                        } else {
                            rowGone = true
                        }
                    }
                    if (status == DownloadManager.STATUS_SUCCESSFUL || status == DownloadManager.STATUS_FAILED) break
                }
                if (status != DownloadManager.STATUS_SUCCESSFUL) {
                    runOnUiThread { result.error("download_failed", "Download failed ($reason)", null) }
                    return@Thread
                }
                val apkUri = dm.getUriForDownloadedFile(id)
                if (apkUri == null) {
                    runOnUiThread { result.error("missing_apk", "Downloaded APK not found", null) }
                    return@Thread
                }
                val install = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(apkUri, "application/vnd.android.package-archive")
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                runOnUiThread {
                    try {
                        startActivity(install)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("install_failed", e.message, null)
                    }
                }
            } catch (e: Exception) {
                runOnUiThread { result.error("download_failed", e.message, null) }
            }
        }.start()
    }

    private fun ipv4HexToIp(hex: String): String {
        return try {
            val v = hex.toLong(16)
            val a = (v shl 24 ushr 24)
            val b = (v shl 16 ushr 24)
            val c = (v shl 8 ushr 24)
            val d = (v ushr 24)
            "$a.$b.$c.$d"
        } catch (_: Exception) {
            ""
        }
    }

    /** Decode a v4-mapped address from /proc/net/tcp6 (8 little-endian words). */
    private fun ipv6HexToIp(hex: String): String {
        return try {
            val g = hex.chunked(8)
            if (g.size < 4) return ""
            val words = g.map { it.toLong(16) }
            // ::ffff:a.b.c.d is stored as [...0,0xFFFF0000, <v4-hex-le>].
            if (words[2] == 0xFFFF0000L) {
                val v = words[3].let {
                    val a = it and 0xFF
                    val b = (it shr 8) and 0xFF
                    val c = (it shr 16) and 0xFF
                    val d = (it shr 24) and 0xFF
                    "$a.$b.$c.$d"
                }
                v
            } else {
                words.joinToString(":") { it.toString(16) }
            }
        } catch (_: Exception) {
            ""
        }
    }

    /** Read the system HOME/LOCK wallpaper into PNG bytes. Never throws. */
    private fun readDeviceWallpaper(lock: Boolean): ByteArray? {
        return try {
            val wm = android.app.WallpaperManager.getInstance(this)
            val res = wm.peekDrawable() ?: wm.drawable ?: return null
            val bmp = android.graphics.Bitmap.createBitmap(
                res.intrinsicWidth.coerceAtLeast(1),
                res.intrinsicHeight.coerceAtLeast(1),
                android.graphics.Bitmap.Config.ARGB_8888,
            )
            val canvas = android.graphics.Canvas(bmp)
            res.setBounds(0, 0, canvas.width, canvas.height)
            res.draw(canvas)
            val out = java.io.ByteArrayOutputStream()
            bmp.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, out)
            bmp.recycle()
            out.toByteArray()
        } catch (e: Exception) {
            null
        }
    }

    private fun installedApps(): List<Map<String, Any>> {
        val pm = packageManager
        val launchable = HashSet<String>()
        try {
            val main = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
            for (ri in pm.queryIntentActivities(main, 0)) {
                ri.activityInfo?.packageName?.let { launchable.add(it) }
            }
        } catch (_: Exception) {}

        val out = ArrayList<Map<String, Any>>()
        val pkgs = try { pm.getInstalledApplications(0) } catch (_: Exception) { emptyList() }
        for (ai in pkgs) {
            val pkg = ai.packageName ?: continue
            if (pkg == packageName) continue
            val isSystem = (ai.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0
            // Keep system apps only if they are launchable (e.g. browser, store);
            // always keep user-installed apps.
            if (isSystem && !launchable.contains(pkg)) continue
            // Must be able to use the internet to be worth tunnelling.
            val hasInternet = try {
                pm.checkPermission(android.Manifest.permission.INTERNET, pkg) ==
                    android.content.pm.PackageManager.PERMISSION_GRANTED
            } catch (_: Exception) { true }
            if (!hasInternet) continue
            val label = try { pm.getApplicationLabel(ai).toString() } catch (_: Exception) { pkg }
            out.add(mapOf("package" to pkg, "name" to label, "system" to isSystem))
        }
        out.sortWith(compareBy({ it["system"] as Boolean }, { (it["name"] as String).lowercase() }))
        return out
    }

    private fun openSetting(action: String) {
        try {
            startActivity(Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (e: Exception) { /* device may block it */ }
    }

    /**
     * APN settings, SIM-AWARE entry point. Dual-SIM devices open the APN
     * screen for ONE subscription: launching the bare action leaves the SIM
     * unselected and several OEM firmwares (vivo/oppo…) then show an empty
     * or broken screen. Flow:
     *   1. READ_PHONE_STATE granted (legacy installs that still hold it) →
     *      real subscription list. One SIM opens APN directly for it; several
     *      show a picker (SIM 1 · Robi…) and the chosen subscription id rides
     *      along as the SUB_ID extra.
     *   2. No permission (current builds never declare it — dropped for
     *      Play's phone-permission policy) → generic verified chain, no SIM
     *      pre-selection.
     */
    private fun openSimSettingsSmart(forNetworkMode: Boolean) {
        phonePermissionForNetworkMode = forNetworkMode
        if (checkSelfPermission(Manifest.permission.READ_PHONE_STATE)
            == PackageManager.PERMISSION_GRANTED) {
            Thread { pickSimAndOpenSettings(forNetworkMode) }.start()
        } else {
            openApnSettingsChain(forNetworkMode)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_READ_PHONE_STATE) return
        val ok = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        SnapDarkTunnelVpnService.emitLog(
            "Network settings: phone permission " + (if (ok) "granted" else "denied"))
        val forNetworkMode = phonePermissionForNetworkMode
        if (ok) {
            Thread { pickSimAndOpenSettings(forNetworkMode) }.start()
        } else {
            showNativeToast(
                "Phone permission is needed to pre-select the SIM — opening the general settings",
                true,
            )
            openApnSettingsChain(forNetworkMode)
        }
    }

    /** Background thread: enumerate the SIMs and open the flow for one. */
    private fun pickSimAndOpenSettings(forNetworkMode: Boolean) {
        @Suppress("DEPRECATION")
        val subs = try {
            getSystemService(SubscriptionManager::class.java)
                ?.activeSubscriptionInfoList
                ?.filter { it.simSlotIndex >= 0 }
                .orEmpty()
        } catch (_: SecurityException) { emptyList() }
        when (subs.size) {
            0 -> {
                SnapDarkTunnelVpnService.emitLog(
                    "Network settings: no active SIM — falling back to the general chain")
                openApnSettingsChain(forNetworkMode)
            }
            1 -> launchSettingsForSub(subs[0].subscriptionId, forNetworkMode)
            else -> {
                val sorted = subs.sortedBy { it.simSlotIndex }
                runOnUiThread { showSimPicker(sorted, forNetworkMode) }
            }
        }
    }

    /**
     * Custom SnapDark-styled SIM picker: dark glassy card, neon-green accents,
     * rounded SIM rows (slot badge, carrier name, number when known) — the
     * stock AlertDialog looked jarringly generic next to the app's UI.
     */
    private fun showSimPicker(
        subs: List<android.telephony.SubscriptionInfo>,
        forNetworkMode: Boolean,
    ) {
        val density = resources.displayMetrics.density
        fun dp(v: Int) = (v * density).toInt()

        val bgDark = 0xF20B0F0C.toInt()
        val surface = 0xFF121A15.toInt()
        val border = 0xFF25322B.toInt()
        val accent = 0xFF00E676.toInt()
        val onAccent = 0xFF04170D.toInt()
        val ink = 0xFFF1F7F3.toInt()
        val inkMuted = 0xFF9BB0A2.toInt()

        val root = android.widget.LinearLayout(this).apply {
            orientation = android.widget.LinearLayout.VERTICAL
            setPadding(dp(20), dp(18), dp(20), dp(12))
        }

        root.addView(android.widget.TextView(this).apply {
            text = "SELECT SIM"
            setTextColor(accent)
            setTextSize(android.util.TypedValue.COMPLEX_UNIT_SP, 12f)
            letterSpacing = 0.18f
            typeface = android.graphics.Typeface.create("sans-serif", android.graphics.Typeface.BOLD)
        })
        root.addView(android.widget.TextView(this).apply {
            text = if (forNetworkMode)
                "Choose which SIM's network mode (4G/5G) to switch"
            else
                "Choose which SIM's APN settings to open"
            setTextColor(inkMuted)
            setTextSize(android.util.TypedValue.COMPLEX_UNIT_SP, 13f)
            setPadding(0, dp(4), 0, dp(14))
        })

        subs.forEachIndexed { idx, sub ->
            val slot = sub.simSlotIndex + 1
            val carrier = sub.displayName?.toString().orEmpty().ifBlank { "SIM $slot" }
            val number = sub.number?.takeIf { it.isNotBlank() }

            val row = android.widget.LinearLayout(this).apply {
                orientation = android.widget.LinearLayout.HORIZONTAL
                gravity = android.view.Gravity.CENTER_VERTICAL
                setPadding(dp(14), dp(12), dp(14), dp(12))
                background = android.graphics.drawable.GradientDrawable().apply {
                    setColor(if (idx == 0) 0x2600E676 else surface)
                    cornerRadius = dp(14).toFloat()
                    setStroke(dp(1), if (idx == 0) accent else border)
                }
                val lp = android.widget.LinearLayout.LayoutParams(
                    android.widget.LinearLayout.LayoutParams.MATCH_PARENT,
                    android.widget.LinearLayout.LayoutParams.WRAP_CONTENT,
                )
                lp.bottomMargin = dp(8)
                layoutParams = lp
            }

            // Slot badge — filled accent circle with the slot number.
            row.addView(android.widget.TextView(this).apply {
                text = slot.toString()
                setTextColor(onAccent)
                setTextSize(android.util.TypedValue.COMPLEX_UNIT_SP, 15f)
                gravity = android.view.Gravity.CENTER
                typeface = android.graphics.Typeface.create("sans-serif", android.graphics.Typeface.BOLD)
                background = android.graphics.drawable.GradientDrawable().apply {
                    shape = android.graphics.drawable.GradientDrawable.OVAL
                    setColor(accent)
                }
                val lp = android.widget.LinearLayout.LayoutParams(dp(34), dp(34))
                lp.marginEnd = dp(12)
                layoutParams = lp
            })

            val mid = android.widget.LinearLayout(this).apply {
                orientation = android.widget.LinearLayout.VERTICAL
                layoutParams = android.widget.LinearLayout.LayoutParams(
                    0, android.widget.LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
            }
            mid.addView(android.widget.TextView(this).apply {
                text = carrier
                setTextColor(ink)
                setTextSize(android.util.TypedValue.COMPLEX_UNIT_SP, 15f)
                typeface = android.graphics.Typeface.create("sans-serif", android.graphics.Typeface.BOLD)
            })
            if (number != null) {
                mid.addView(android.widget.TextView(this).apply {
                    text = number
                    setTextColor(inkMuted)
                    setTextSize(android.util.TypedValue.COMPLEX_UNIT_SP, 12f)
                })
            }
            row.addView(mid)

            row.addView(android.widget.ImageView(this).apply {
                setImageResource(android.R.drawable.ic_menu_more)
                setColorFilter(accent)
                layoutParams = android.widget.LinearLayout.LayoutParams(
                    dp(20), dp(20))
            })

            row.setOnClickListener {
                simPickerDialog?.dismiss()
                simPickerDialog = null
                launchSettingsForSub(sub.subscriptionId, forNetworkMode)
            }
            root.addView(row)
        }

        // Cancel — quiet text button aligned right.
        root.addView(android.widget.TextView(this).apply {
            text = "CANCEL"
            setTextColor(inkMuted)
            setTextSize(android.util.TypedValue.COMPLEX_UNIT_SP, 13f)
            typeface = android.graphics.Typeface.create("sans-serif", android.graphics.Typeface.BOLD)
            setPadding(dp(12), dp(10), dp(12), dp(6))
            layoutParams = android.widget.LinearLayout.LayoutParams(
                android.widget.LinearLayout.LayoutParams.WRAP_CONTENT,
                android.widget.LinearLayout.LayoutParams.WRAP_CONTENT
            ).apply { gravity = android.view.Gravity.END }
            setOnClickListener {
                simPickerDialog?.dismiss()
                simPickerDialog = null
            }
        })

        simPickerDialog = android.app.Dialog(this).apply {
            setContentView(root)
            window?.setBackgroundDrawable(
                android.graphics.drawable.GradientDrawable().apply {
                    setColor(bgDark)
                    cornerRadius = dp(24).toFloat()
                    setStroke(dp(1), border)
                })
            window?.setLayout(
                (resources.displayMetrics.widthPixels * 0.86f).toInt(),
                android.view.ViewGroup.LayoutParams.WRAP_CONTENT,
            )
            setCanceledOnTouchOutside(true)
            show()
        }
    }

    /**
     * The launch chain, SIM-first: every network-settings action is tried
     * WITH the selected subscription id first (hidden Settings extra; vivo /
     * oppo / xiaomi firmwares open the per-SIM page from it), then the
     * generic verified chain without it. Actions ordered by how likely they
     * land on an APN-reachable screen:
     *   APN → MOBILE_NETWORK → NETWORK_OPERATOR → DATA_ROAMING → DATA_USAGE
     *   → WIRELESS → SETTINGS home.
     */
    /** One launch target in a settings chain: what it is + how to build it. */
    private class LaunchTarget(val step: String, val make: () -> Intent)

    /** Settings screens that can land on (or near) the APN list. */
    private fun apnTargets(): List<LaunchTarget> = listOf(
        LaunchTarget("APN settings") { Intent("android.settings.APN_SETTINGS") },
        LaunchTarget("mobile network list") {
            Intent().setClassName("com.android.settings",
                "com.android.settings.Settings\$MobileNetworkListActivity")
        },
        LaunchTarget("mobile network settings") { Intent("android.settings.MOBILE_NETWORK_SETTINGS") },
        LaunchTarget("network operator settings") { Intent("android.settings.NETWORK_OPERATOR_SETTINGS") },
        LaunchTarget("data roaming settings") { Intent("android.settings.DATA_ROAMING_SETTINGS") },
        LaunchTarget("data usage settings") { Intent("android.settings.DATA_USAGE_SETTINGS") },
        LaunchTarget("network dashboard") {
            Intent().setClassName("com.android.settings",
                "com.android.settings.Settings\$NetworkDashboardActivity")
        },
        LaunchTarget("wireless settings") { Intent("android.settings.WIRELESS_SETTINGS") },
        LaunchTarget("settings home") { Intent("android.settings.SETTINGS") },
    )

    /**
     * 4G/5G switcher targets — the hidden testing menus carry the "Set
     * preferred network type" dropdown (the actual switch), and the per-SIM
     * mobile network page has the same toggle in the Settings UI. Ordered:
     * the phone-settings RadioInfo first (the classic *#*#4636#*#* Phone
     * info screen, verified present on vivo/Qualcomm), then the Settings
     * testing activity, then the reachable Settings pages.
     */
    private fun networkModeTargets(): List<LaunchTarget> = listOf(
        LaunchTarget("phone info (com.android.phone RadioInfo)") {
            Intent().setClassName("com.android.phone", "com.android.phone.settings.RadioInfo")
        },
        LaunchTarget("testing menu (Settings\$TestingSettingsActivity)") {
            Intent().setClassName(
                "com.android.settings", "com.android.settings.Settings\$TestingSettingsActivity")
        },
        LaunchTarget("testing menu (com.android.settings RadioInfo)") {
            Intent().setClassName("com.android.settings", "com.android.settings.RadioInfo")
        },
        LaunchTarget("testing menu (legacy TestingSettings)") {
            Intent().setClassName("com.android.settings", "com.android.settings.TestingSettings")
        },
        LaunchTarget("mobile network list") {
            Intent().setClassName("com.android.settings",
                "com.android.settings.Settings\$MobileNetworkListActivity")
        },
        LaunchTarget("mobile network page") {
            Intent().setClassName("com.android.settings",
                "com.android.settings.Settings\$MobileNetworkActivity")
        },
        LaunchTarget("mobile network settings") { Intent("android.settings.MOBILE_NETWORK_SETTINGS") },
        LaunchTarget("network operator settings") { Intent("android.settings.NETWORK_OPERATOR_SETTINGS") },
        LaunchTarget("network dashboard") {
            Intent().setClassName("com.android.settings",
                "com.android.settings.Settings\$NetworkDashboardActivity")
        },
    )

    /** Launch the per-SIM screen; fall back to the generic chain. */
    private fun launchSettingsForSub(subId: Int, forNetworkMode: Boolean) {
        Thread {
            // Hidden Settings extras naming the subscription (not in the
            // public SDK, hence the literals). Both spellings — several OEM
            // forks read "sub_id", AOSP reads the qualified extra.
            var opened = false
            for (target in if (forNetworkMode) networkModeTargets() else apnTargets()) {
                val intent = target.make().addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                intent.putExtra("android.provider.extra.SUB_ID", subId)
                intent.putExtra("sub_id", subId)
                if (tryLaunchVerified(intent, "${target.step} (SIM $subId)")) {
                    opened = true
                    break
                }
            }
            if (!opened) {
                SnapDarkTunnelVpnService.emitLog(
                    "Network settings: SIM-specific launch failed everywhere — generic chain")
                openApnSettingsChain(forNetworkMode)
            }
        }.start()
    }

    /**
     * APN / network settings with an OEM-proof, VERIFIED fallback chain:
     *
     *   APN flow:  APN → MOBILE_NETWORK → NETWORK_OPERATOR → DATA_ROAMING
     *              → DATA_USAGE → WIRELESS → SETTINGS, then the hidden
     *              testing menus, Samsung screens, and the dialer code.
     *   4G/5G flow: com.android.phone/.RadioInfo → Settings$TestingSettings
     *              → .RadioInfo → MOBILE_NETWORK → NETWORK_OPERATOR, then
     *              Samsung screens and the dialer code.
     *
     * VERIFIED means each startActivity is confirmed by our activity
     * actually PAUSING (something really came to the foreground). Some OEM
     * builds accept the start with no exception yet never show the screen —
     * a silent dud this walks past automatically. Every step's outcome is
     * written to the in-app Logs tab, so field reports say exactly where the
     * chain stopped.
     */
    private fun openApnSettingsChain(forNetworkMode: Boolean = false) {
        // Off the main thread: each verified attempt waits up to 700 ms for
        // the launch to land, and the whole chain can take a few seconds.
        // NOTE: resolveActivity() is NOT used — Android 11+ package
        // visibility makes it return null for the settings app unless a
        // <queries> declaration exists, which would skip working actions.
        Thread {
            val candidates = mutableListOf<LaunchTarget>()
            candidates.addAll(if (forNetworkMode) networkModeTargets() else apnTargets())
            if (!forNetworkMode) {
                // The hidden testing menus double as APN fallbacks on OEMs
                // that hide or break the APN activity.
                candidates.addAll(networkModeTargets().take(4))
            }
            // Dialer with the secret code prefilled — works on legacy and
            // some OEM builds where every direct launch is blocked (the
            // user just presses call).
            candidates.add(
                LaunchTarget("dialer code *#*#4636#*#*") {
                    Intent(Intent.ACTION_DIAL, Uri.parse("tel:*#*#4636#*#*"))
                })
            // MTK engineering mode (*#*#3646633#*#*) — MediaTek phones.
            candidates.add(
                LaunchTarget("MTK engineering mode") {
                    Intent(Intent.ACTION_DIAL, Uri.parse("tel:*#*#3646633#*#*"))
                })
            // OEM-specific hidden screens (present only on their ROMs; the
            // verified launch skips the absent ones instantly).
            candidates.addAll(listOf(
                LaunchTarget("Samsung hidden network settings") {
                    Intent().setClassName(
                        "com.samsung.android.app.telephonyui",
                        "com.samsung.android.app.telephonyui.hiddennetworksetting.MainActivity")
                },
                LaunchTarget("Samsung service mode") {
                    Intent().setClassName(
                        "com.sec.android.RilServiceModeApp",
                        "com.sec.android.RilServiceModeApp.ServiceModeApp")
                },
                LaunchTarget("MIUI network settings") {
                    Intent().setClassName(
                        "com.android.phone",
                        "com.android.phone.settings.OperatorsSettingsActivity")
                },
            ))
            // Absolute last resort: the settings home / wireless dashboards.
            candidates.addAll(listOf(
                LaunchTarget("network dashboard") {
                    Intent().setClassName("com.android.settings",
                        "com.android.settings.Settings\$NetworkDashboardActivity")
                },
                LaunchTarget("wireless settings") { Intent("android.settings.WIRELESS_SETTINGS") },
                LaunchTarget("settings home") { Intent("android.settings.SETTINGS") },
            ))
            for (c in candidates) {
                if (tryLaunchVerified(c.make(), c.step)) return@Thread
            }
            runOnUiThread {
                showNativeToast("Could not open settings — please open your phone's settings manually", true)
            }
        }.start()
    }

    /** One verified launch attempt (see [openApnSettingsChain]). */
    private fun tryLaunchVerified(intent: Intent, step: String): Boolean {
        val paused = java.util.concurrent.atomic.AtomicBoolean(false)
        val callbacks = object : android.app.Application.ActivityLifecycleCallbacks {
            override fun onActivityPaused(activity: Activity) {
                if (activity === this@MainActivity) paused.set(true)
            }
            override fun onActivityCreated(activity: Activity, savedInstanceState: android.os.Bundle?) {}
            override fun onActivityResumed(activity: Activity) {}
            override fun onActivityStarted(activity: Activity) {}
            override fun onActivityStopped(activity: Activity) {}
            override fun onActivitySaveInstanceState(activity: Activity, outState: android.os.Bundle) {}
            override fun onActivityDestroyed(activity: Activity) {}
        }
        return try {
            application.registerActivityLifecycleCallbacks(callbacks)
            try {
                startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                val deadline = System.currentTimeMillis() + 700
                while (!paused.get() && System.currentTimeMillis() < deadline) {
                    Thread.sleep(50)
                }
                if (paused.get()) {
                    SnapDarkTunnelVpnService.emitLog("Network settings: opened via $step")
                    true
                } else {
                    SnapDarkTunnelVpnService.emitLog("Network settings: $step was accepted but nothing opened — trying the next target")
                    false
                }
            } finally {
                application.unregisterActivityLifecycleCallbacks(callbacks)
            }
        } catch (e: Exception) {
            SnapDarkTunnelVpnService.emitLog("Network settings: $step failed (${e.javaClass.simpleName}: ${e.message})")
            false
        }
    }

    /** Real Android toast — same widget every Android app uses. */
    private fun showNativeToast(message: String, long: Boolean) {
        if (message.isBlank()) return
        val duration = if (long) android.widget.Toast.LENGTH_LONG else android.widget.Toast.LENGTH_SHORT
        try {
            runOnUiThread { android.widget.Toast.makeText(this, message, duration).show() }
        } catch (_: Exception) {}
    }

    private fun openAppDetails() {
        try {
            startActivity(Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:$packageName")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (e: Exception) {}
    }

    private fun openIgnoreBattery() {
        // Same OEM-proof chain as the APN item: the direct OS dialog first
        // (needs the REQUEST_IGNORE_BATTERY_OPTIMIZATIONS permission), then
        // the optimization list, then this app's page (manual toggle), then
        // the settings home.
        try {
            @Suppress("BatteryLife")
            startActivity(Intent(android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                Uri.parse("package:$packageName")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            return
        } catch (_: Exception) { }
        try {
            startActivity(Intent(android.provider.Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            return
        } catch (_: Exception) { }
        try {
            // This app's page — the user can reach the battery toggle from
            // here on OEMs that hide both dedicated screens.
            startActivity(Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:$packageName")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            return
        } catch (_: Exception) { }
        try {
            startActivity(Intent(android.provider.Settings.ACTION_SETTINGS)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (_: Exception) {
            showNativeToast("Could not open settings — please open your phone's settings manually", true)
        }
    }

    private fun asInt(value: Any?, fallback: Int): Int = when (value) {
        is Int -> value
        is Long -> value.toInt()
        is String -> value.toIntOrNull() ?: fallback
        else -> fallback
    }

    private fun aesKey(): SecretKeySpec =
        SecretKeySpec(MessageDigest.getInstance("SHA-256").digest(lockKeySeed.toByteArray()), "AES")

    private fun JSONObject.toMap(): Map<String, Any?> {
        val out = LinkedHashMap<String, Any?>()
        val it = keys()
        while (it.hasNext()) {
            val k = it.next()
            out[k] = when (val v = opt(k)) {
                is JSONObject -> v.toMap()
                is org.json.JSONArray -> List(v.length()) { i ->
                    when (val e = v.opt(i)) {
                        is JSONObject -> e.toMap()
                        else -> e
                    }
                }
                else -> v
            }
        }
        return out
    }

    private fun parseLocked(body: String?, pin: String? = null): String? {
        if (body == null) return null
        return try {
            if (body.startsWith("sensei:v2p:")) {
                // User-locked envelope: only the lock PIN can open it.
                if (pin.isNullOrEmpty()) return null
                val raw = Base64.decode(body.removePrefix("sensei:v2p:"), Base64.DEFAULT)
                if (raw.size <= 28) return null
                val iv = raw.copyOfRange(0, 12)
                val cipherText = raw.copyOfRange(12, raw.size)
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(Cipher.DECRYPT_MODE, lockEnvelopeKey(pin), GCMParameterSpec(128, iv))
                String(cipher.doFinal(cipherText), Charsets.UTF_8)
            } else if (!body.startsWith("sensei:v2:")) {
                return body
            } else {
                val raw = Base64.decode(body.removePrefix("sensei:v2:"), Base64.DEFAULT)
                if (raw.size <= 28) return null
                val iv = raw.copyOfRange(0, 12)
                val cipherText = raw.copyOfRange(12, raw.size)
                val cipher = Cipher.getInstance("AES/GCM/NoPadding")
                cipher.init(Cipher.DECRYPT_MODE, aesKey(), GCMParameterSpec(128, iv))
                String(cipher.doFinal(cipherText), Charsets.UTF_8)
            }
        } catch (e: Exception) {
            null
        }
    }

    /**
     * AES key for USER-locked envelopes — TWO independent layers folded into
     * one digest: the PIN the sharer chose, the app's own secret seed, and the
     * running build's signing-certificate SHA-256. An envelope therefore opens
     * only in a genuine install AND with the PIN — a re-signed or patched APK
     * cannot decrypt it even with the PIN, and knowing the seed alone says
     * nothing without the PIN.
     */
    private fun lockEnvelopeKey(pin: String): SecretKeySpec {
        val md = MessageDigest.getInstance("SHA-256")
        md.update(
            MessageDigest.getInstance("SHA-256")
                .digest("$lockKeySeed:pin:$pin".toByteArray())
        )
        md.update(aesKey().encoded)
        md.update(AppSecurity.certSha256(applicationContext).toByteArray())
        return SecretKeySpec(md.digest(), "AES")
    }

    /** Non-reversible marker so a receiver can check a PIN before full import.
     * Derived from the same two-layer material as the envelope key, so only a
     * genuine install + the right PIN produces the expected check. */
    private fun deriveLockCheck(pin: String): String =
        lockEnvelopeKey(pin).encoded
            .joinToString("") { "%02x".format(it) }
            .take(16)

    private fun encryptLocked(config: Map<String, Any?>?, pin: String?): String? {
        if (config == null) return null
        return try {
            // The channel wrapper carries the PIN alongside the config fields —
            // it must never end up inside the encrypted payload itself.
            val payload = HashMap(config)
            payload.remove("pin")
            val plain = org.json.JSONObject(payload).toString().toByteArray(Charsets.UTF_8)
            // 12-byte IV derived deterministically from the payload to avoid Math.random in this env;
            // GCM still authenticates. Real randomness is fine here in production.
            val iv = MessageDigest.getInstance("SHA-256").digest(plain).copyOfRange(0, 12)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            if (pin.isNullOrEmpty()) {
                cipher.init(Cipher.ENCRYPT_MODE, aesKey(), GCMParameterSpec(128, iv))
            } else {
                // User-locked share: two layers — the PIN plus this exact
                // app build (seed + signing cert) folded into one key.
                cipher.init(Cipher.ENCRYPT_MODE, lockEnvelopeKey(pin), GCMParameterSpec(128, iv))
            }
            val out = iv + cipher.doFinal(plain)
            (if (pin.isNullOrEmpty()) "sensei:v2:" else "sensei:v2p:") +
                Base64.encodeToString(out, Base64.NO_WRAP)
        } catch (e: Exception) {
            null
        }
    }
}
