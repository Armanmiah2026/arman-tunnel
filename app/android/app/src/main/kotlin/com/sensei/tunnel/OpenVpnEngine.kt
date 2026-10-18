package com.sensei.tunnel

import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.util.Log
import java.io.File
import java.io.IOException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import ph.yooh.novpn.ClientAPI_Config
import ph.yooh.novpn.ClientAPI_Event
import ph.yooh.novpn.ClientAPI_AppCustomControlMessageEvent
import ph.yooh.novpn.ClientAPI_ExternalPKICertRequest
import ph.yooh.novpn.ClientAPI_ExternalPKISignRequest
import ph.yooh.novpn.ClientAPI_LogInfo
import ph.yooh.novpn.ClientAPI_OpenVPNClient
import ph.yooh.novpn.ClientAPI_ProvideCreds
import ph.yooh.novpn.ClientAPI_StringVec
import ph.yooh.novpn.DnsOptions

/**
 * Self-signed throwaway client cert + key, appended to profiles that have no
 * client certificate of their own (see [prepareProfile]). The server
 * authenticates via auth-user-pass and ignores it; it only exists to keep
 * OpenVPN3's external-PKI path disabled.
 */
private val DUMMY_CLIENT_CERT = """
<cert>
-----BEGIN CERTIFICATE-----
MIICxzCCAa+gAwIBAgIIWTLPKCu8EmcwDQYJKoZIhvcNAQELBQAwHDEaMBgGA1UE
AxMRU2Vuc2VpRHVtbXlDbGllbnQwHhcNMjYwODI4MDg1OTU5WhcNMzYwODI1MDg1
OTU5WjAcMRowGAYDVQQDExFTZW5zZWlEdW1teUNsaWVudDCCASIwDQYJKoZIhvcN
AQEBBQADggEPADCCAQoCggEBAJrF+bwINYZ7maCBYMG6THR8C0MkDhPVN3PiIu82
6oafng1L8W6aIlRkTGtrpR+25+LVD/BfB+8J1YeMtG2nuI02HEc8gADa2O3Nb/aV
sL9oiOlnmyxgeO+Myt57JzUUbyrCe9YVB1/Fgz06l7V4VYpzlvWaKiNXpyIuRqxg
stqWEEHFQvMnTi2EkZClWoT9M7gdLG/nRhzVOvXdaFjj298RREPQdzCnFs/tjqgv
3JyyVw8ZWN7JFs4JJ+8JcIhBMeeAv5Yng4JD0C/r7yRtWQMQJ63fhc2fCf3uq7dP
YTRn/KP+9AxgXEggeYrKVtQLt++Du7ULgTLTUgux2Wb8Vy0CAwEAAaMNMAswCQYD
VR0TBAIwADANBgkqhkiG9w0BAQsFAAOCAQEAIxdZr0FyVLPPW4E0fLdU00h5/L1j
M0TCbcVeZ3isECI9gUJ1Ad4PB1Is5c86gGnrAuGnK9ENOl1KOLKe8KhOnliIJ/3q
tQ5XqhN6HF4X/7JR5lebYhZrCOQ8goQwEjqRpV3nNAi5d7mbiaoG62bFkr30sq6R
Jh7+4yrvabn0C9QhL7ICGryPst1w45Nh/Ys2w9jNTOdfXyzrI2JFIhMmWgGALBZY
BIVw/CmPv7bVilLLxAVri65gMypi2FnkVeaqfF2aVPfo3F5QEKVcl4AzeXSjjjt7
tzPB2fviD5pLcfaZk+TmSrll4y6nGMJ6uz3iOAKN5GJFrP72dCkuFWkETA==
-----END CERTIFICATE-----
</cert>
<key>
-----BEGIN PRIVATE KEY-----
MIIEvAIBADANBgkqhkiG9w0BAQEFAASCBKYwggSiAgEAAoIBAQCaxfm8CDWGe5mg
gWDBukx0fAtDJA4T1Tdz4iLvNuqGn54NS/FumiJUZExra6Uftufi1Q/wXwfvCdWH
jLRtp7iNNhxHPIAA2tjtzW/2lbC/aIjpZ5ssYHjvjMreeyc1FG8qwnvWFQdfxYM9
Ope1eFWKc5b1miojV6ciLkasYLLalhBBxULzJ04thJGQpVqE/TO4HSxv50Yc1Tr1
3WhY49vfEURD0HcwpxbP7Y6oL9ycslcPGVjeyRbOCSfvCXCIQTHngL+WJ4OCQ9Av
6+8kbVkDECet34XNnwn97qu3T2E0Z/yj/vQMYFxIIHmKylbUC7fvg7u1C4Ey01IL
sdlm/FctAgMBAAECggEAAOyKJWJ6KVOfEut6z6VEVBSyf4PdVqZ49obk1P9DrqqQ
x70Kk7G1X0IbB7Akk/gkUcEaX4G9uyJYpT7Ei/wKmMM4L3+vtvGXhnHpx3PU0ou1
94jADyeDSVDSnDnpfcJhuIRhN2G4Qczcz/aD1dhCUHmIru4s7rmU/JoAn4JTRwVI
cqB9HqWMFpwkFmUSYQbJHO/V6r8A4hS0f8hk1svVC7Ul12S9YmvD9WHQsY/+7hrZ
YmJOISm5B0/bawYt6nYzR8jkSEF4BfrvH3FeavJV+3z6PKEEE4efzOxA2DREwq8A
QX7ez7QKy1MqcjKoDGTHlF/b8AykKBFjEiSgZzgTsQKBgQDHtebu8//ZF9Awhe5O
dk0UL6B2q85g289hhnD+rNYxCiOuEBRneb3U+Gq42WJ6Q8zObY9wZJEtYz4dEH0y
DeB250WEaFST0/EVAPBOLlS/wqf823AufAWvRuDmqpuCMYHTa8H5w0Zofa6xhZpA
Jwv0BKxcjerq7UuP0PcOE42vXQKBgQDGZaH4TeO+61n0ZwhUdU6z6qrvSsY0NQYf
yCcjsyOG0YelOWggnxgek3JthmByJgEvfesQky3O5Q+YR1Z3T5ufsXAF62kVApgF
XXHSz1NepGEmVfM25nzW1xR3DPSr17T2rR00zGMSy0nawePdED1zqcb5I83YYkqn
OCWUoNFaEQKBgCHbxh5HAd5leidv3Xox9llwxay47hFf0uX+7BNRbDL+PBRbp4nv
iu6be0SBnn+KFSP+US5F7pMaW0KENCWTUrX1+cQ8B/LUIPBlq1gl5LpqHx7weTF4
V2JjCugwjpLhH9ifUVCt+bbncAGq2/76X71sOWirquNPfdsRG4GocQIFAoGAc7Xs
7JQJA13inh/FhPTSDS8NuPikduiCBOFIqpKdYtErytqbd4MynwqiD2zzLUArKtbG
1Wjxq5x/JvJcZMPCYTYsvtcY948GuQJSE4CmACnhG2m/q0JshyT0I6cjwGHTgpde
1F9sXRbBoVu6GUGShbX8fWw7bzuMjNC7Yl8VGvECgYB62vplJBKV+2p9+UXigPqA
MZxnbJAfqMtR8cvV5Rqd8mYp2Z6FJ4tAEV9OqikeVPmdoHpZzM+CVhxr3rqbNvM8
OoweNhWJQJsbSJVPu8zMZYZouEYK9ns/80AoaKuhjWHbgeorPybFrUIhebXNkml7
XPOnKfjPq9Xn47uKqZckLg==
-----END PRIVATE KEY-----
</key>
""".trimIndent()

/**
 * Drives a libovpncli.so (OpenVPN3 ClientAPI, SWIG package ph.yooh.novpn)
 * session against a [VpnService].
 *
 * Flow:
 *   1. eval_config() validates the .ovpn text and builds a Config.
 *   2. provide_creds() if the profile needs auth-user-pass (read from the
 *      creds file the service references, or inline).
 *   3. connect() runs on a worker thread; openvpn3 drives the tun_builder_*
 *      director callbacks (overridden below) to materialize a VpnService.Builder
 *      and hand the TUN fd back via tun_builder_establish().
 *   4. socket_protect() protects the transport socket from the tunnel (no loop).
 *   5. stop() tears it down.
 */
class OpenVpnEngine(
    private val vpnService: VpnService,
    private val profileText: String,
    private val sessionName: String,
    private val mtu: Int,
    private val dnsPrimary: String,
    private val dnsSecondary: String,
    private val keepAlivePingSec: Int = 30,
) {
    companion object {
        private const val TAG = "OpenVpnEngine"
    }

    /**
     * Run a director callback so NOTHING escapes into C++.
     *
     * These methods are upcalls from libovpncli's SWIG director. A Java
     * Throwable crossing that boundary aborts the whole process (SIGABRT/
     * SIGSEGV) — no stack trace, no crash dialog, the app just vanishes. Every
     * callback body therefore runs inside this guard, which logs the failure and
     * returns [fallback] instead.
     */
    private fun <T> guard(what: String, fallback: T, body: () -> T): T {
        return try {
            body()
        } catch (t: Throwable) {
            val msg = "ovpn callback $what failed: ${t.javaClass.simpleName}: ${t.message}"
            Log.w(TAG, msg, t)
            SenseiTunnelVpnService.emitLog(msg)
            fallback
        }
    }

    /** [guard] for the common `Boolean` callbacks (failure ⇒ false). */
    private fun guard(what: String, body: () -> Boolean): Boolean = guard(what, false, body)

    /**
     * Monotonic crash breadcrumbs. Each director upcall (and the pre-upcall
     * steps eval_config / provide_creds / connect) stamps the phase file with
     * the *furthest* milestone reached. Because they only ever advance, the
     * frequent log()/event() calls cannot downgrade a later milestone back to an
     * earlier one — so the last persisted marker is exactly where connect()
     * died. The next launch's reportPreviousCrash() surfaces it.
     */
    private val phaseOrder = listOf(
        "ovpn:eval_ok", "ovpn:creds_ok", "ovpn:connect",
        "ovpn:cb_log", "ovpn:cb_event", "ovpn:cb_socket_protect",
        "ovpn:cb_new", "ovpn:cb_address", "ovpn:cb_reroute", "ovpn:cb_route",
        "ovpn:cb_local_nets", "ovpn:cb_exclude", "ovpn:cb_establish", "ovpn:done",
    )
    private var phaseIdx = -1
    private fun markPhase(phase: String) {
        val idx = phaseOrder.indexOf(phase)
        if (idx <= phaseIdx) return
        phaseIdx = idx
        try {
            File(vpnService.filesDir, "sensei_phase.txt")
                .writeText("$phase|$sessionName|${System.currentTimeMillis()}")
        } catch (_: Throwable) {}
    }

    private val builder = AtomicReference<VpnService.Builder?>(null)
    private val lastEstablishedFd = AtomicReference<Int?>(null)
    private val fatalError = AtomicReference<String?>(null)
    private val tunnelConnected = AtomicBoolean(false)
    private var sessionThread: Thread? = null
    // Track whether openvpn3 allowed IPv6 (set via tun_builder_set_allow_family).
    // block-ipv6 in the profile makes it call set_allow_family(AF_INET6, false).
    private var ipv6Allowed = true
    // DNS the server pushes via `dhcp-option DNS` (delivered through
    // tun_builder_set_dns_options). openvpn3 does NOT apply these to the
    // Builder for us, so we capture and re-apply them in tun_builder_establish.
    private val pushedDnsServers = mutableListOf<String>()
    private val pushedSearchDomains = mutableListOf<String>()

    /**
     * SWIG director subclass. openvpn3 routes its C++ virtual tun_builder,
     * log, event and socket_protect calls into these overrides.
     */
    private val client = object : ClientAPI_OpenVPNClient() {

        override fun tun_builder_new(): Boolean {
            markPhase("ovpn:cb_new")
            return guard("tun_builder_new") {
                // Fresh connection: clear any DNS pushed on a previous attempt.
                pushedDnsServers.clear()
                pushedSearchDomains.clear()
                val b = vpnService.Builder().setSession(sessionName).setMtu(mtu)
                try { b.addDisallowedApplication(vpnService.packageName) } catch (_: Throwable) {}
                builder.set(b)
                true
            }
        }

        override fun tun_builder_set_session_name(name: String): Boolean {
            return guard("tun_builder_set_session_name") {
                builder.get()?.setSession(name); true
            }
        }

        override fun tun_builder_set_mtu(m: Int): Boolean {
            return guard("tun_builder_set_mtu") {
                builder.get()?.setMtu(m); true
            }
        }

        override fun tun_builder_add_address(
            address: String, prefix: Int, gateway: String, ipv6: Boolean, net30: Boolean,
        ): Boolean {
            markPhase("ovpn:cb_address")
            return guard("tun_builder_add_address($address/$prefix)") {
                if (ipv6 && !ipv6Allowed) {
                    // block-ipv6: never hand an IPv6 address to an IPv4-only
                    // TUN — writing an IPv6 packet into it dies with EINVAL
                    // ("TUN write exception: write_some: Invalid argument").
                    return@guard true
                }
                builder.get()?.addAddress(address, prefix); true
            }
        }

        override fun tun_builder_reroute_gw(ipv4: Boolean, ipv6: Boolean, flags: Long): Boolean {
            markPhase("ovpn:cb_reroute")
            return guard("tun_builder_reroute_gw") {
                val b = builder.get() ?: return@guard false
                if (ipv4) try { b.addRoute("0.0.0.0", 0) } catch (_: Throwable) {}
                // Only redirect v6 if the TUN is actually allowed to carry it;
                // otherwise the default v6 route drags IPv6 traffic into a
                // device that can't write it back out (EINVAL).
                if (ipv6 && ipv6Allowed) try { b.addRoute("::", 0) } catch (_: Throwable) {}
                true
            }
        }

        override fun tun_builder_add_route(
            address: String, prefix: Int, metric: Int, ipv6: Boolean,
        ): Boolean {
            markPhase("ovpn:cb_route")
            return guard("tun_builder_add_route($address/$prefix)") {
                if (ipv6 && !ipv6Allowed) return@guard true
                builder.get()?.addRoute(address, prefix); true
            }
        }

        override fun tun_builder_exclude_route(
            address: String, prefix: Int, metric: Int, ipv6: Boolean,
        ): Boolean {
            markPhase("ovpn:cb_exclude")
            // Builder.excludeRoute + IpPrefix are API 33+. Calling them on an
            // older device threw NoSuchMethodError — an Error, not an Exception,
            // so the old `catch (e: Exception)` let it escape into the C++
            // director and abort the process. Returning false just tells
            // openvpn3 the exclusion could not be installed.
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return false
            return guard("tun_builder_exclude_route($address/$prefix)") {
                if (ipv6 && !ipv6Allowed) return@guard true
                val inet = java.net.InetAddress.getByName(address)
                builder.get()?.excludeRoute(android.net.IpPrefix(inet, prefix)); true
            }
        }

        override fun tun_builder_set_layer(layer: Int): Boolean = true

        override fun tun_builder_set_remote_address(address: String, ipv6: Boolean): Boolean = true

        override fun tun_builder_set_route_metric_default(metric: Int): Boolean = true

        override fun tun_builder_set_dns_options(dns: DnsOptions): Boolean {
            return guard("tun_builder_set_dns_options") {
                // openvpn3 hands us the full resolved DNS config here; capture every
                // server address (keyed by priority) and every search domain so we can
                // install them on the Builder in tun_builder_establish. Without this the
                // server-pushed `dhcp-option DNS` is silently dropped.
                val servers = dns.getServers()
                for ((_, srv) in servers.entries.sortedBy { it.key }) {
                    val addrs = srv.getAddresses()
                    for (i in 0 until addrs.size) {
                        val a = addrs.get(i).address
                        if (a.isNotBlank() && !pushedDnsServers.contains(a)) pushedDnsServers.add(a)
                    }
                    val doms = srv.getDomains()
                    for (i in 0 until doms.size) {
                        val d = doms.get(i).domain
                        if (d.isNotBlank() && !pushedSearchDomains.contains(d)) pushedSearchDomains.add(d)
                    }
                }
                val sd = dns.getSearch_domains()
                for (i in 0 until sd.size) {
                    val d = sd.get(i).domain
                    if (d.isNotBlank() && !pushedSearchDomains.contains(d)) pushedSearchDomains.add(d)
                }
                SenseiTunnelVpnService.emitLog("ovpn pushed DNS: ${pushedDnsServers.joinToString()} domains: ${pushedSearchDomains.joinToString()}")
                true
            }
        }

        override fun tun_builder_add_proxy_bypass(bypassHost: String): Boolean = true

        override fun tun_builder_set_proxy_auto_config_url(url: String): Boolean = true

        override fun tun_builder_set_proxy_http(host: String, port: Int): Boolean = true

        override fun tun_builder_set_proxy_https(host: String, port: Int): Boolean = true

        override fun tun_builder_add_wins_server(address: String): Boolean = true

        override fun tun_builder_set_allow_family(af: Int, allow: Boolean): Boolean {
            // Linux AF_INET6 == 10. Record it so the address/route callbacks can
            // keep IPv6 out of an IPv4-only TUN (block-ipv6 => allow=false).
            if (af == 10) ipv6Allowed = allow
            return true
        }

        override fun tun_builder_set_allow_local_dns(allow: Boolean): Boolean = true

        override fun tun_builder_establish(): Int {
            markPhase("ovpn:cb_establish")
            return guard("tun_builder_establish", -1) {
                SenseiTunnelVpnService.emitLog("ovpn tun_builder_establish called")
                val b = builder.get()
                if (b == null) {
                    SenseiTunnelVpnService.emitLog("ovpn tun_builder_establish: Builder is NULL — cannot create TUN")
                    return@guard -1
                }
                // openvpn3's DnsOptions are not parsed here; add our resolvers and
                // any DNS the server pushed (dhcp-option DNS) before establishing so
                // the tunnel has working name resolution.
                for (dns in listOf(dnsPrimary, dnsSecondary)) {
                    if (dns.isNotBlank()) try { b.addDnsServer(dns) } catch (_: Throwable) {}
                }
                for (dns in serverDnsServers()) {
                    try { b.addDnsServer(dns) } catch (_: Throwable) {}
                }
                // Server-pushed DNS (dhcp-option DNS) captured above — these win over
                // the static defaults when present.
                for (dns in pushedDnsServers) {
                    try { b.addDnsServer(dns) } catch (_: Throwable) {}
                }
                for (domain in pushedSearchDomains) {
                    try { b.addSearchDomain(domain) } catch (_: Throwable) {}
                }
                val pfd = b.establish()
                if (pfd == null) {
                    // VpnService.Builder.establish() fails silently (null) when the
                    // interface parameters are rejected — log it loudly instead of
                    // letting ovpn3 carry on believing it has a TUN.
                    SenseiTunnelVpnService.emitLog(
                        "ovpn tun_builder_establish: Builder.establish() returned NULL " +
                            "(interface rejected by the system)",
                    )
                    return@guard -1
                }
                val fd = pfd.detachFd()
                lastEstablishedFd.set(fd)
                // OpenVPN3 brings the TUN up only after the control channel is
                // established, so a successful establish is a reliable "connected"
                // signal — don't depend solely on the CONNECTED event name.
                tunnelConnected.set(true)
                markPhase("ovpn:done")
                SenseiTunnelVpnService.emitLog("ovpn tun fd=$fd acquired")
                fd
            }
        }

        override fun tun_builder_persist(): Boolean = true

        override fun tun_builder_establish_lite() {
            tun_builder_establish()
        }

        /**
         * MUST return a real (non-NULL) `std::vector<std::string>`.
         *
         * The SWIG director for this method takes the returned wrapper's
         * `swigCPtr` and **dereferences it** to copy the vector out. The old
         * `ClientAPI_StringVec(0, false)` looked like "an empty vector we don't
         * own", but that constructor is `(cPtr, cMemOwn)` — it wrapped a NULL
         * C++ pointer, so the copy segfaulted inside libovpncli. A SIGSEGV kills
         * the process outright: no Java exception, no log line, no crash dialog —
         * exactly the "app closes instantly on connect" report.
         *
         * openvpn3 calls this while emulating exclude-routes, which the server's
         * pushed `redirect-gateway def1 bypass-dhcp` triggers — i.e. only after a
         * handshake that actually succeeded. That is why it looked SNI-specific:
         * the SNI/TLS path is the only one that gets far enough to reach it.
         *
         * An empty (but valid) vector means "no local networks to exclude",
         * which keeps the full tunnel intact.
         */
        override fun tun_builder_get_local_networks(ipv6: Boolean): ClientAPI_StringVec {
            markPhase("ovpn:cb_local_networks")
            // Public no-arg ctor wraps a fresh owned (non-NULL) C++ vector,
            // which is exactly what openvpn3 needs here. (The raw
            // (cPtr, cMemOwn) ctor is protected in the regenerated SWIG Java,
            // so use the public empty-vector ctor instead.)
            return ClientAPI_StringVec()
        }

        override fun tun_builder_teardown(disconnect: Boolean) {
            builder.set(null)
        }

        // Protect the transport socket so traffic to the VPN server itself
        // does NOT get routed back into the tunnel (avoids a routing loop).
        override fun socket_protect(socket: Int, remote: String, ipv6: Boolean): Boolean {
            markPhase("ovpn:cb_socket_protect")
            return guard("socket_protect($socket)") { vpnService.protect(socket) }
        }

        override fun log(loginfo: ClientAPI_LogInfo) {
            markPhase("ovpn:cb_log")
            guard("log", Unit) {
                val text = loginfo.text?.trimEnd() ?: return@guard
                Log.d(TAG, "ovpn: $text")
                SenseiTunnelVpnService.emitLog("ovpn: $text")
            }
        }

        override fun event(apiEvent: ClientAPI_Event) {
            markPhase("ovpn:cb_event")
            guard("event", Unit) {
                val name = apiEvent.name ?: ""
                val info = apiEvent.info ?: ""
                val msg = "ovpn-event: $name ${if (info.isNotEmpty()) "($info)" else ""}"
                Log.i(TAG, msg)
                SenseiTunnelVpnService.emitLog(msg)
                if (apiEvent.error || apiEvent.fatal) {
                    fatalError.compareAndSet(null, if (info.isNotBlank()) "$name: $info" else name)
                }
                if (name == "CERT_VERIFY_FAIL") {
                    SenseiTunnelVpnService.emitLog(
                        "ovpn: The profile's <ca> does not match the server's current " +
                            "certificate (server certs re-issued 2026-08-27). Re-import the " +
                            "latest .ovpn — the same file OpenVPN Lite uses (export it from " +
                            "Lite or re-download from the panel).",
                    )
                }
                if (name == "CONNECTED") {
                    tunnelConnected.set(true)
                }
            }
        }

        override fun acc_event(accEvent: ClientAPI_AppCustomControlMessageEvent) {}

        override fun external_pki_cert_request(req: ClientAPI_ExternalPKICertRequest) {}

        override fun external_pki_sign_request(req: ClientAPI_ExternalPKISignRequest) {}

        override fun pause_on_connection_timeout(): Boolean = false
    }

    fun start() {
        Log.i(TAG, "Loading libovpncli.so and parsing profile")

        val config = ClientAPI_Config()
        config.setContent(prepareProfile(profileText))
        // Compression negotiation. This libovpncli.so build's ClientAPI
        // compressionMode parser accepts ONLY "no" | "yes" | "asym" — "maybe"
        // fails eval_config outright with ERR_INVALID_OPTION_VAL ("error
        // parsing compression mode: maybe"; the token is absent from the .so
        // while no/yes/asym are present in its strings).
        //
        // "no" (CompressNull) is the only mode that adds ZERO framing.
        //
        // History — both other modes broke the data channel on a server that
        // pushes no compression at all (ours: PROTOCOL OPTIONS shows only
        // "data channel: cipher AES-256-GCM, peer-id 0"):
        //  - "yes" (LZO) compressed every uplink packet; the server could not
        //    decode them and dropped them silently -> KEEPALIVE_TIMEOUT.
        //  - "asym" still installs a CompressStub, and a stub compressor is not
        //    a no-op: it prepends a one-byte compression opcode to every
        //    outgoing packet. With compression fully absent server-side, that
        //    byte shifts the inner IP header by one, so every uplink packet is
        //    malformed and dropped -> 16KB up / 0B down, "connected but no
        //    internet". This survived swapping the whole TLS backend
        //    (OpenSSL 4.0/TLS1.3 -> mbedTLS/TLS1.2), which is what proved the
        //    fault was in the data plane and not in TLS.
        //
        // Cost of "no": a server that *pushes* compression is now refused with
        // "server pushed compression settings that are not allowed and will
        // result in a non-working connection" instead of silently half-working.
        // That is a legible failure, and such servers are vanishingly rare now
        // (compression is a security hole — VORACLE — and is off by default in
        // OpenVPN 2.5+).
        config.setCompressionMode("no")
        // TLS handshake trace. Level 3 dumps every mbedTLS record (thousands of
        // lines per connect) and was only needed while the handshake itself was
        // failing ("unknown CA" / CERT_VERIFY_FAIL). It succeeds reliably now,
        // so keep level 1: fatal alerts and verify errors still surface, the
        // per-record spam does not.
        config.setSslDebugLevel(1)

        // Auth-user-pass profiles without a client cert used to flip eval's
        // externalPki path ("Missing External PKI alias"). The dummy-cert append
        // in prepareProfile papers over eval, but the SSL setup can still route
        // through external PKI — which leaves the CA store empty and every
        // handshake dies with "[self-signed certificate]" even when the profile
        // carries the correct <ca>. disableClientCert is what OpenVPN Connect
        // sets for user/pass-only profiles; it forces the inline-CA path.
        val needsUserPass = Regex("(?im)^\\s*auth-user-pass").containsMatchIn(profileText) ||
            Regex("(?is)<auth-user-pass>").containsMatchIn(profileText)
        if (needsUserPass) config.setDisableClientCert(true)

        val eval = try {
            client.eval_config(config)
        } catch (e: Throwable) {
            throw IOException("eval_config failed: ${e.message}", e)
        }
        if (eval.error) {
            throw IOException("OpenVPN profile invalid: ${eval.message}")
        }
        markPhase("ovpn:eval_ok")
        // Diagnostics: did eval flip the external-PKI path, and did it actually
        // parse the profile CA (eval.vpnCa echoes it back)? Empty vpnCa + a
        // "self-signed certificate" verify failure = the store never got the CA.
        SenseiTunnelVpnService.emitLog(
            "ovpn eval: externalPki=${eval.externalPki}, " +
                "vpnCa=${if (eval.vpnCa.isNullOrBlank()) "EMPTY" else "${eval.vpnCa.length} chars"}" +
                (eval.message?.takeIf { it.isNotBlank() }?.let { ", message=$it" } ?: ""),
        )

        // Supply credentials when the profile asks for auth-user-pass.
        extractCreds()?.let { (user, pass) ->
            val creds = ClientAPI_ProvideCreds()
            creds.setUsername(user)
            creds.setPassword(pass)
            val st = try { client.provide_creds(creds) } catch (e: Throwable) {
                throw IOException("provide_creds failed: ${e.message}", e)
            }
            if (st.error) throw IOException("OpenVPN credentials rejected: ${st.message}")
        }
        markPhase("ovpn:creds_ok")

        val errors = AtomicReference<Throwable?>(null)

        sessionThread = Thread {
            try {
                markPhase("ovpn:connect")
                val status = client.connect()
                val err = status.message
                if (status.error && !err.isNullOrEmpty()) {
                    errors.set(IOException("OpenVPN connect error: $err"))
                }
            } catch (t: Throwable) {
                errors.set(t)
            }
        }.apply {
            isDaemon = false
            name = "ovpn3-session"
            start()
        }

        // elapsedRealtime, not wall clock: an NTP sync right after the network
        // comes up can jump the clock and silently cut a wall-clock deadline.
        val deadline = SystemClock.elapsedRealtime() + 20_000L
        SenseiTunnelVpnService.emitLog("ovpn waiting up to 20s for tun_builder_establish…")
        var lastTick = 0L
        while (SystemClock.elapsedRealtime() < deadline) {
            lastEstablishedFd.get()?.let {
                Log.i(TAG, "OpenVPN TUN established, fd=$it")
                return
            }
            errors.get()?.let { throw IOException("OpenVPN connect failed early: ${it.message}", it) }
            fatalError.get()?.let { throw IOException("OpenVPN failed: $it") }
            val waited = 20_000L - (deadline - SystemClock.elapsedRealtime())
            if (waited - lastTick >= 5_000L) {
                lastTick = waited
                SenseiTunnelVpnService.emitLog(
                    "ovpn still waiting for TUN establish (t=${waited / 1000}s," +
                        " engineRunning=${isRunning()})",
                )
            }
            Thread.sleep(50)
        }
        throw IOException(
            "OpenVPN tunnel never established (tun_builder_establish not called)" +
                (fatalError.get()?.let { "; last event: $it" } ?: ""),
        )
    }

    /**
     * OpenVPN3 is stricter than desktop OpenVPN about a few legacy directives.
     * Strip Windows-only / unsupported lines before eval_config, but keep the
     * tunnel material (remote, cert, key, routes, tls-auth/tls-crypt) intact.
     *
     * Compression is the #1 reason imported .ovpn files fail on OpenVPN3: it
     * rejects `comp-lzo`/`compress` and refuses server-pushed compression by
     * default. Strip those lines and assert `allow-compression no` — a stub
     * compressor still frames every uplink packet with a compression opcode
     * byte, which a compression-less server drops (see setCompressionMode).
     *
     * `cipher none` / `auth none` (plaintext data channel) are dropped too:
     * openvpn3 refuses a none cipher for the data channel ("bad cipher for
     * data channel use"), and with NCP any 2.4+ server negotiates a real AEAD
     * cipher anyway — where `auth` is unused. This keeps such profiles
     * connectable instead of failing eval_config.
     *
     * `auth-user-pass` is intentionally NOT stripped here: OpenVPN3 reads inline
     * `<auth-user-pass>` blocks and creds files natively. The service only
     * injects its own `auth-user-pass <file>` in startOpenVpn when the user
     * supplied credentials, replacing any bare line there.
     */
    /**
     * OpenVPN3 core has a long-standing bug: a profile that authenticates with
     * `auth-user-pass` (no client certificate) but uses `remote-cert-tls server`
     * makes [ClientAPI_Config.eval_config] set `externalPki=true`, and
     * [client.connect] then dies with "Missing External PKI alias" — it expects a
     * client cert from the Android Keystore that we never provided. The documented
     * workaround (IBM / OpenVPN Connect) is to supply *a* client cert so the core
     * takes the inline path instead of the external-PKI path. The server auths via
     * user/pass and ignores the dummy cert, so a self-signed throwaway is enough.
     * Only append it when the profile genuinely has no client cert of its own.
     */
    private fun prepareProfile(raw: String): String {
        var p = sanitizeProfile(raw)
        val hasClientCert = Regex("(?i)<cert\\b").containsMatchIn(p) ||
            Regex("(?im)^\\s*cert\\s+\\S+").containsMatchIn(p)
        if (!hasClientCert) {
            p = p.trimEnd() + "\n" + DUMMY_CLIENT_CERT
        }
        // OpenVPN Lite (ovpn3 3.12 release, GUI ph.yooh.ovpn.android) negotiates
        // TLSv1.2 against the same server, while our libovpncli.so (3.12 master,
        // OpenSSL 3.x) goes TLS 1.3 and dies with "unknown CA" (server-side alert
        // log 2026-08-28 17:23 UTC) even with the CORRECT <ca> loaded. Force the
        // proven-working TLS 1.2 path unless the profile pins it already.
        // tls-version-min is honoured by this build; tls-version-max is parsed
        // but appears in eval's "options that were not used" list, so pinning
        // the max is pointless here — don't add it.
        if (!Regex("(?im)^\\s*tls-version-min\\b").containsMatchIn(p)) p += "\ntls-version-min 1.2"
        // Last-verb-wins: raise verbosity so sslDebugLevel lines survive filtering.
        p += "\nverb 4"
        // Keep the data channel alive: through the injector's outer TLS the
        // session is otherwise completely idle after CONNECTED, and any ~7s
        // idle timeout on the server/front-end kills it (NETWORK_EOF_ERROR).
        // The app-level Keepalive setting controls this injected ping. Some
        // devices need aggressive idle traffic; others pay for it in battery.
        if (keepAlivePingSec > 0 &&
            !Regex("(?im)^\\s*(keepalive|ping)\\b").containsMatchIn(p)
        ) p += "\nping $keepAlivePingSec"
        // Never let IPv6 touch the TUN: this ovpn3 build writes whatever the
        // data channel hands it into the (IPv4-only) TUN fd, and the kernel
        // rejects an IPv6 frame there with EINVAL — the "TUN write exception:
        // write_some: Invalid argument" that precedes KEEPALIVE_TIMEOUT. OpenVPN
        // Lite's server pushes the same `block-ipv6`; mirror it client-side so
        // it holds even if the server never pushes it. (TUN-builder gating
        // above is the backstop when this build ignores the directive.)
        if (!Regex("(?im)^\\s*block-ipv6\\b").containsMatchIn(p)) p += "\nblock-ipv6"
        return p
    }

    private fun sanitizeProfile(raw: String): String {
        val lines = raw.replace("\r\n", "\n").replace("\r", "\n").lines()
        var strippedCompression = false
        val out = lines
            .map { it.trimEnd() }
            .filterNot { line ->
                val opt = line.trim().lowercase()
                val drop = opt.startsWith("comp-lzo") ||
                    opt.startsWith("compress") ||
                    opt.startsWith("allow-compression") ||
                    opt == "cipher none" ||
                    opt == "auth none" ||
                    opt.startsWith("fragment") ||
                    opt == "block-outside-dns" ||
                    opt.startsWith("route-method") ||
                    opt.startsWith("script-security") ||
                    opt.startsWith("setenv opt block-outside-dns")
                if (drop && (opt.startsWith("comp-lzo") ||
                        opt.startsWith("compress") ||
                        opt.startsWith("allow-compression"))
                ) {
                    strippedCompression = true
                }
                drop
            }
            .toMutableList()
        // Match setCompressionMode("no"): a stub compressor is NOT a no-op — it
        // prepends a compression opcode byte to every uplink packet, which a
        // server with compression disabled reads as part of the IP header and
        // drops. Re-adding `allow-compression asym` here would fight the
        // ClientAPI mode, so we assert "no" instead.
        if (strippedCompression) out.add("allow-compression no")
        return out.joinToString("\n").trim()
    }

    /**
     * DNS servers the server pushes via `dhcp-option DNS <ip>` — added to the
     * TUN so the tunnel resolves names through the server's resolvers.
     */
    private fun serverDnsServers(): List<String> {
        return Regex("(?im)^\\s*dhcp-option\\s+DNS\\s+(\\S+)\\s*$")
            .findAll(profileText)
            .mapNotNull { it.groupValues.getOrNull(1)?.takeIf { ip -> ip.isNotBlank() } }
            .toList()
    }

    /**
     * Pull username/password for provide_creds from the profile: either an
     * `auth-user-pass <file>` directive (the service writes such a file) or an
     * inline `<auth-user-pass>user\npass</auth-user-pass>` block. Returns null
     * when the profile carries no user/pass auth.
     */
    private fun extractCreds(): Pair<String, String>? {
        // Inline <auth-user-pass>user\npass</auth-user-pass> block first.
        val inline = Regex("(?is)<auth-user-pass>\\s*(.+?)\\s*</auth-user-pass>")
            .find(profileText)?.groupValues?.getOrNull(1)
        if (inline != null) {
            val lines = inline.trim().lines().filter { it.isNotBlank() }
            if (lines.size >= 2) return lines[0].trim() to lines[1].trim()
        }
        // External creds file referenced by `auth-user-pass <path>`.
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

    fun isRunning(): Boolean = sessionThread?.isAlive == true

    /** True once the engine reported the CONNECTED event (control channel up). */
    fun isTunnelConnected(): Boolean = tunnelConnected.get()

    fun stop() {
        try { client.stop() } catch (e: Throwable) { Log.w(TAG, "stop: ${e.message}") }
        sessionThread?.interrupt()
        sessionThread = null
    }
}
