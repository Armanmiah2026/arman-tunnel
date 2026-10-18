package com.sensei.tunnel

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build

/**
 * Config-confidentiality + tamper layer.
 *
 * **Everything happens in `libsenseicrypto.so`** — this file contains no crypto
 * logic and no secrets. The native library computes the cert hash, enforces the
 * signature gate (v3 key is derived from the running signing cert, so a
 * re-signed clone cannot decrypt), detects the envelope version and decrypts.
 *
 * JNI surface (defined in `src/main/cpp/senseicrypto.c`):
 *  - nativeCertSha256(cert[B) : String
 *  - nativeIntegrityOk(cert[B) : Boolean
 *  - nativeDecrypt(expected:Ljava/lang/String;cert[B;body:Ljava/lang/String;) : String?
 *  - nativeVipIssue(cert[B;configId:Ljava/lang/String;durationMs:J) : String?
 *  - nativeVipVerify(cert[B;ticket:Ljava/lang/String;configId:Ljava/lang/String;) : Long
 *
 * The expected signing-cert hash is baked into the .so at compile time
 * (-DSENSEI_EXPECTED_CERT_SHA256 via CMake); it is not in BuildConfig, so the
 * DEX carries zero key material.
 *
 * THREAT MODEL (honest): client-side crypto can be beaten by runtime
 * instrumentation (Frida) or a same-signature patched build. What this stops
 * effectively: **re-signed clones** and casual DEX decompilers — there is
 * nothing to read in the DEX.
 */
object AppSecurity {

    init {
        System.loadLibrary("senseicrypto")
    }

    private external fun nativeCertSha256(cert: ByteArray): String
    private external fun nativeIntegrityOk(cert: ByteArray): Boolean
    private external fun nativeDecrypt(
        expected: String?,
        cert: ByteArray,
        body: String,
    ): String?
    private external fun nativeVipIssue(
        cert: ByteArray,
        configId: String,
        durationMs: Long,
    ): String?
    private external fun nativeVipVerify(
        cert: ByteArray,
        ticket: String,
        configId: String,
    ): Long

    /** Signing-cert DER bytes (public — the cert ships in the APK anyway). */
    private fun certBytes(context: Context): ByteArray {
        return try {
            val pm = context.packageManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                @Suppress("DEPRECATION")
                val info = pm.getPackageInfo(context.packageName, PackageManager.GET_SIGNING_CERTIFICATES)
                info.signingInfo?.apkContentsSigners?.firstOrNull()?.toByteArray() ?: ByteArray(0)
            } else {
                @Suppress("DEPRECATION")
                pm.getPackageInfo(context.packageName, PackageManager.GET_SIGNATURES)
                    .signatures?.firstOrNull()?.toByteArray() ?: ByteArray(0)
            }
        } catch (e: Exception) {
            ByteArray(0)
        }
    }

    /** Lowercase hex SHA-256 of the app's signing certificate (DER). */
    fun certSha256(context: Context): String =
        try { nativeCertSha256(certBytes(context)) } catch (e: Throwable) { "" }

    /** True if the running app's signature matches the expected one (or gate disabled). */
    fun integrityOk(context: Context): Boolean =
        try { nativeIntegrityOk(certBytes(context)) } catch (e: Throwable) { false }

    /** Decrypt a config envelope (v3/v2/v1). Returns plaintext JSON or null. */
    fun decryptConfig(context: Context, body: String?): String? {
        if (body == null) return null
        return try {
            // No hash crosses JNI — native falls back to its baked-in value.
            nativeDecrypt(null, certBytes(context), body.trim())
        } catch (e: Throwable) {
            null
        }
    }

    /**
     * Issue a cert-bound VIP unlock ticket for [configId], valid [durationMs].
     * Returns a `sensei:vip:` envelope string, or null if integrity is off.
     */
    fun issueVipTicket(context: Context, configId: String, durationMs: Long): String? =
        try { nativeVipIssue(certBytes(context), configId, durationMs) } catch (e: Throwable) { null }

    /**
     * Verify a VIP unlock ticket for [configId]. Returns the expiry epoch
     * milliseconds when the ticket is authentic and unexpired, or -1. An
     * edited SharedPreferences line cannot produce a value that decrypts.
     */
    fun verifyVipTicket(context: Context, ticket: String?, configId: String): Long =
        try { if (ticket.isNullOrBlank()) -1 else nativeVipVerify(certBytes(context), ticket, configId) }
        catch (e: Throwable) { -1 }
}
