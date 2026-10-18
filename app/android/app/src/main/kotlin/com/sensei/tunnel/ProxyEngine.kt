package com.sensei.tunnel

import android.net.VpnService
import android.os.ParcelFileDescriptor
import java.io.File
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket

class ProxyEngine(
    private val vpnService: VpnService,
    private val mode: String,
    private val host: String,
    private val port: Int,
    private val user: String,
    private val pass: String,
    private val onExit: (String?) -> Unit,
) {
    private var tun: ParcelFileDescriptor? = null
    private var serverSocket: ServerSocket? = null
    private var running = false

    fun start(): Boolean {
        return try {
            val builder = vpnService.Builder()
                .setSession("SenseiProxy")
                .addAddress("10.0.0.2", 32)
                .addDnsServer("1.1.1.1")
                .addRoute("0.0.0.0", 0)
            tun = builder.establish()

            serverSocket = ServerSocket(10808)
            running = true
            Thread { acceptLoop() }.apply { isDaemon = true; name = "proxy-accept" }.start()
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
            val upstream = Socket()
            vpnService.protect(upstream)
            upstream.connect(InetSocketAddress(host, port), 10000)

            if (mode == "socks") {
                handleSocksHandshake(client, upstream)
            } else {
                handleHttpProxy(client, upstream)
            }

            val clientIn = client.getInputStream()
            val clientOut = client.getOutputStream()
            val upIn = upstream.getInputStream()
            val upOut = upstream.getOutputStream()

            val t1 = Thread { copyStream(clientIn, upOut) }.apply { isDaemon = true }
            val t2 = Thread { copyStream(upIn, clientOut) }.apply { isDaemon = true }
            t1.start(); t2.start()
            t1.join(); t2.join()
        } catch (_: Exception) {
        } finally {
            try { client.close() } catch (_: Exception) {}
        }
    }

    private fun handleSocksHandshake(client: Socket, upstream: Socket) {
        val input = client.getInputStream()
        val output = client.getOutputStream()
        val ver = input.read()
        if (ver != 0x05) { client.close(); return }
        val nMethods = input.read()
        val methods = ByteArray(nMethods)
        input.read(methods)
        output.write(byteArrayOf(0x05, 0x00))
        output.flush()
        val reqVer = input.read()
        val cmd = input.read()
        val atyp = input.read()
        val addr = when (atyp) {
            0x01 -> ByteArray(4).also { input.read(it) }
            0x03 -> {
                val len = input.read()
                ByteArray(len).also { input.read(it) }
            }
            else -> ByteArray(0)
        }
        val portHi = input.read()
        val portLo = input.read()
        val dstPort = (portHi shl 8) or portLo
        val dstAddr = when (atyp) {
            0x01 -> addr.joinToString(".") { (it.toInt() and 0xFF).toString() }
            0x03 -> String(addr)
            else -> ""
        }
        upstream.getOutputStream().write(0x05)
        upstream.getOutputStream().flush()
    }

    private fun handleHttpProxy(client: Socket, upstream: Socket) {
        val input = client.getInputStream()
        val output = client.getOutputStream()
        val request = StringBuilder()
        var prev = -1
        var cur = -1
        while (true) {
            cur = input.read()
            if (cur == -1) break
            request.append(cur.toChar())
            if (prev == '\r'.code && cur == '\n'.code) {
                val lastTwo = request.length >= 2 && request[request.length - 2] == '\r'
                if (lastTwo && request.length >= 4 && request.substring(request.length - 4) == "\r\n\r\n") break
            }
            prev = cur
        }
        val auth = if (user.isNotEmpty()) {
            val token = android.util.Base64.encodeToString("$user:$pass".toByteArray(), android.util.Base64.NO_WRAP)
            "Proxy-Authorization: Basic $token\r\n"
        } else ""
        val modified = request.toString().replaceFirst("CONNECT", "CONNECT")
        upstream.getOutputStream().write((modified + auth).toByteArray())
        upstream.getOutputStream().flush()
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
