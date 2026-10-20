package com.snapdark.tunnel

import android.net.VpnService
import android.os.ParcelFileDescriptor
import java.io.File

class WireGuardEngine(
    private val vpnService: VpnService,
    private val config: String,
    private val onExit: (String?) -> Unit,
) {
    private var tun: ParcelFileDescriptor? = null
    private var process: Process? = null

    fun start(): Boolean {
        return try {
            val wgConf = File(vpnService.filesDir, "wg.conf")
            wgConf.writeText(config)

            val builder = vpnService.Builder()
                .setSession("SnapDarkWireGuard")
                .addAddress("10.0.0.2", 32)
                .addDnsServer("1.1.1.1")
                .addRoute("0.0.0.0", 0)
            tun = builder.establish()

            val wgBin = File(vpnService.applicationInfo.nativeLibraryDir, "libwireguard.so")
            if (!wgBin.exists()) {
                onExit("WireGuard binary not found")
                return false
            }

            val pb = ProcessBuilder(
                wgBin.absolutePath,
                "-f", "wg0",
            )
            pb.redirectErrorStream(true)
            process = pb.start()
            true
        } catch (e: Exception) {
            onExit(e.message)
            false
        }
    }

    fun stop() {
        try { process?.destroy() } catch (_: Exception) {}
        try { tun?.close() } catch (_: Exception) {}
        process = null
        tun = null
    }
}
