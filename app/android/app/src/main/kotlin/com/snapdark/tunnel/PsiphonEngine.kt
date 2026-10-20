package com.snapdark.tunnel

import android.net.VpnService
import android.os.ParcelFileDescriptor
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket

class PsiphonEngine(
    private val vpnService: VpnService,
    private val region: String,
    private val onExit: (String?) -> Unit,
) {
    private var tun: ParcelFileDescriptor? = null
    private var serverSocket: ServerSocket? = null
    private var running = false

    private val psiphonServers = mapOf(
        "US" to listOf("psiphon.us", "psiphon.com"),
        "GB" to listOf("psiphon.uk", "psiphon.co.uk"),
        "DE" to listOf("psiphon.de", "psiphon.eu"),
        "JP" to listOf("psiphon.jp", "psiphon.asia"),
        "SG" to listOf("psiphon.sg", "psiphon.com.sg"),
    )

    fun start(): Boolean {
        return try {
            val builder = vpnService.Builder()
                .setSession("SnapDarkPsiphon")
                .addAddress("10.0.0.2", 32)
                .addDnsServer("1.1.1.1")
                .addRoute("0.0.0.0", 0)
            tun = builder.establish()

            serverSocket = ServerSocket(10808)
            running = true
            Thread { acceptLoop() }.apply { isDaemon = true; name = "psiphon-accept" }.start()
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
                Thread { handleClient(client) }.apply { isDaemon = true }.start()
            } catch (e: Exception) {
                if (running) onExit(e.message)
                break
            }
        }
    }

    private fun handleClient(client: Socket) {
        try {
            val servers = psiphonServers[region.uppercase()] ?: psiphonServers["US"]!!
            val upstream = Socket()
            vpnService.protect(upstream)
            upstream.connect(InetSocketAddress(servers.first(), 443), 10000)

            val clientIn = client.getInputStream()
            val clientOut = client.getOutputStream()
            val upIn = upstream.getInputStream()
            val upOut = upstream.getOutputStream()

            val connect = "CONNECT ${servers.first()}:443 HTTP/1.1\r\nHost: ${servers.first()}:443\r\n\r\n"
            upOut.write(connect.toByteArray())
            upOut.flush()

            val response = StringBuilder()
            var prev = -1
            var cur = -1
            while (true) {
                cur = upIn.read()
                if (cur == -1) break
                response.append(cur.toChar())
                if (prev == '\r'.code && cur == '\n'.code) {
                    if (response.length >= 4 && response.substring(response.length - 4) == "\r\n\r\n") break
                }
                prev = cur
            }

            val t1 = Thread { copyStream(clientIn, upOut) }.apply { isDaemon = true }
            val t2 = Thread { copyStream(upIn, clientOut) }.apply { isDaemon = true }
            t1.start(); t2.start()
            t1.join(); t2.join()
        } catch (_: Exception) {
        } finally {
            try { client.close() } catch (_: Exception) {}
        }
    }

    private fun copyStream(input: InputStream, output: OutputStream) {
        try {
            val buf = ByteArray(8192)
            while (true) {
                val n = input.read(buf)
                if (n == -1) break
                output.write(buf, 0, n)
                output.flush()
            }
        } catch (_: Exception) {}
    }

    fun stop() {
        running = false
        try { serverSocket?.close() } catch (_: Exception) {}
        try { tun?.close() } catch (_: Exception) {}
        serverSocket = null
        tun = null
    }
}
