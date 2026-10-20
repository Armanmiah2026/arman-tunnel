package com.snapdark.tunnel

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import android.util.Base64
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

/**
 * THE share envelope (v48) — `snapdarktunnel://base64/48/<mode>/<payload>`.
 *
 * Open share (no security options ticked):
 *   snapdarktunnel://base64/48/open/<base64url(json)>
 *   Plain base64url of the config JSON — importable, editable. Base64 is
 *   ENCODING here, not security, and none is claimed.
 *
 * Locked share (any of: Lock All / HWID / Password / Expiry / Block Root /
 * Block Apps / Note):
 *   snapdarktunnel://base64/48/lock/<b64u(header)>.<b64u(iv(12)+ciphertext+tag)>
 *
 *   header (authenticated as AES-GCM AAD, NOT encrypted — receivers can see
 *   WHAT is restricted, never the config itself):
 *     v, flags {lock,hwid,pin,exp,root,apps}, exp (epoch ms), apps [pkgs],
 *     hwid (device binding hash), note (HTML), salt, iter, pinChk
 *
 *   payload: AES-256-GCM over the config JSON.
 *
 * Key derivation — nothing is a single hardcoded key:
 *   material = PBKDF2-HMAC-SHA256(secret, randomSalt, 120000 iters)
 *     secret = password (when set) — folded with the app seed + signing
 *              cert, so an envelope opens only in a genuine install AND
 *              with the password
 *            = app seed + signing cert otherwise (install-bound)
 *   if HWID: material = HMAC-SHA256(material, hwid) — the DEVICE is folded
 *   into the key itself: another device cannot decrypt, let alone edit.
 *
 * Enforcement (openShareEnvelope): AES-GCM tag → any tampering with header
 * OR ciphertext fails decryption; HWID → decryption itself fails on another
 * device; expiry / root / blocked-apps → checked against the authenticated
 * header before decryption is attempted, AND re-checked by the app at use
 * (the imported config carries expiresAt; the app already gates connect).
 */
object ShareEnvelope {
    const val SCHEME = "snapdarktunnel://base64/48/"
    private const val VERSION = 48
    private const val PBKDF2_ITERATIONS = 120_000
    private const val KEY_BITS = 256

    // Same app seed the v2 locked-config scheme uses — paired with the
    // signing cert it makes every envelope build/install-bound.
    private const val APP_SEED = "ArmanTunnel:Armanmiah2026:v2"

    // ------------------------------------------------------------------ //
    // Device identity / environment
    // ------------------------------------------------------------------ //

    /** Stable device id: ANDROID_ID (stable per app-signing-key + device,
     *  since Oreo) + build fingerprint — folded with the install cert. */
    fun deviceHwid(context: Context): String {
        val md = MessageDigest.getInstance("SHA-256")
        val androidId = try {
            Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID) ?: ""
        } catch (_: Exception) { "" }
        md.update(androidId.toByteArray())
        md.update(Build.FINGERPRINT?.toByteArray() ?: ByteArray(0))
        md.update(AppSecurity.certSha256(context).toByteArray())
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    /** Best-effort root heuristics — checked at import when Block Root is on. */
    fun isRooted(context: Context): Boolean {
        val paths = arrayOf(
            "/system/bin/su", "/system/xbin/su", "/sbin/su",
            "/system/app/Superuser.apk", "/system/bin/magisk",
            "/system/xbin/magisk", "/data/adb/magisk",
        )
        if (paths.any { File(it).exists() }) return true
        if (Build.TAGS?.contains("test-keys") == true) return true
        // A su binary on PATH counts too.
        return try {
            Runtime.getRuntime().exec(arrayOf("which", "su")).inputStream.readBytes().isNotEmpty()
        } catch (_: Exception) { false }
    }

    /** Which of the given packages are installed on this device. */
    fun installedOf(context: Context, packages: List<String>): List<String> {
        val pm = context.packageManager
        return packages.filter { pkg ->
            try {
                @Suppress("DEPRECATION")
                pm.getPackageInfo(pkg, 0)
                true
            } catch (_: PackageManager.NameNotFoundException) {
                false
            }
        }
    }

    // ------------------------------------------------------------------ //
    // Key derivation
    // ------------------------------------------------------------------ //

    private fun pbkdf2(secret: String, salt: ByteArray, iterations: Int): ByteArray {
        val spec = PBEKeySpec(secret.toCharArray(), salt, iterations, KEY_BITS)
        val factory = javax.crypto.SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256")
        return factory.generateSecret(spec).encoded
    }

    /** Fold the device binding INTO the key (HMAC with the material as key). */
    private fun foldHwid(material: ByteArray, hwid: String): ByteArray {
        val mac = javax.crypto.Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(material, "HmacSHA256"))
        return mac.doFinal(hwid.toByteArray())
    }

    private fun envelopeKey(
        context: Context,
        password: String?,
        salt: ByteArray,
        iterations: Int,
        bindHwid: Boolean,
        hwid: String,
    ): ByteArray {
        val installSecret = APP_SEED + "|" + AppSecurity.certSha256(context)
        val secret = if (!password.isNullOrEmpty()) {
            "$installSecret|pin|$password"
        } else {
            installSecret
        }
        var material = pbkdf2(secret, salt, iterations)
        if (bindHwid) material = foldHwid(material, hwid)
        return material
    }

    /** Non-reversible PIN check so import can verify before full decrypt. */
    private fun pinCheck(context: Context, password: String, salt: ByteArray, iterations: Int): String {
        val key = envelopeKey(context, password, salt, iterations, bindHwid = false, hwid = "")
        return key.joinToString("") { "%02x".format(it) }.take(16)
    }

    // ------------------------------------------------------------------ //
    // Build
    // ------------------------------------------------------------------ //

    /**
     * Build a share string. [options]:
     *   lock (bool) — read-only after import
     *   hwid (bool) — bind to THIS device
     *   password (String?) — recipient must supply it
     *   expiresAt (Long, epoch ms, 0 = off)
     *   blockRoot (bool)
     *   blockApps (List<String> — package names)
     *   note (String — HTML)
     */
    fun build(context: Context, configJson: String, options: Map<String, Any?>): String? {
        return try {
            val lock = options["lock"] == true
            val hwid = options["hwid"] == true
            val password = options["password"]?.toString() ?: ""
            val expiresAt = (options["expiresAt"] as? Number)?.toLong() ?: 0L
            val blockRoot = options["blockRoot"] == true
            @Suppress("UNCHECKED_CAST")
            val blockApps = (options["blockApps"] as? List<String>) ?: emptyList()
            val note = options["note"]?.toString() ?: ""

            val anySecurity = lock || hwid || password.isNotEmpty() ||
                expiresAt > 0 || blockRoot || blockApps.isNotEmpty()

            if (!anySecurity) {
                // Open share — plain base64url, editable after import.
                val payload = b64uEncode(configJson.toByteArray(Charsets.UTF_8))
                return SCHEME + "open/" + payload
            }

            // Locked share.
            val salt = ByteArray(16).also { java.security.SecureRandom().nextBytes(it) }
            val iter = PBKDF2_ITERATIONS
            val deviceH = deviceHwid(context)
            val header = JSONObject().apply {
                put("v", VERSION)
                put("lock", lock)
                put("hwid", hwid)
                put("hwidHash", if (hwid) sha256Hex(deviceH) else "")
                put("pin", password.isNotEmpty())
                put("pinChk", if (password.isNotEmpty()) pinCheck(context, password, salt, iter) else "")
                put("exp", expiresAt)
                put("root", blockRoot)
                put("apps", org.json.JSONArray(blockApps))
                put("note", note)
                put("salt", b64uEncode(salt))
                put("iter", iter)
            }
            val headerBytes = header.toString().toByteArray(Charsets.UTF_8)
            val key = envelopeKey(context, password, salt, iter, bindHwid = hwid, hwid = deviceH)
            val iv = ByteArray(12).also { java.security.SecureRandom().nextBytes(it) }
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(
                Cipher.ENCRYPT_MODE,
                SecretKeySpec(key, "AES"),
                GCMParameterSpec(128, iv),
            )
            // The header is AAD: authenticated, not encrypted.
            cipher.updateAAD(headerBytes)
            val ct = cipher.doFinal(configJson.toByteArray(Charsets.UTF_8))
            val body = iv + ct
            return SCHEME + "lock/" + b64uEncode(headerBytes) + "." + b64uEncode(body)
        } catch (_: Exception) {
            null
        }
    }

    // ------------------------------------------------------------------ //
    // Open
    // ------------------------------------------------------------------ //

    /**
     * Open a share string, enforcing every restriction. Returns a result
     * map: {ok, config (json string)|null, error, needsPassword, flags{...}}.
     *
     * [password] is supplied on the retry pass after the UI asked for it
     * (needsPassword=true).
     */
    fun open(context: Context, text: String, password: String?): Map<String, Any?> {
        val trimmed = text.trim()
        if (!trimmed.startsWith(SCHEME)) {
            return result(ok = false, error = "Not a SnapDarkTunnel share")
        }
        val rest = trimmed.removePrefix(SCHEME)
        return try {
            val slash = rest.indexOf('/')
            if (slash < 0) return result(ok = false, error = "Malformed share")
            val mode = rest.substring(0, slash)
            val payload = rest.substring(slash + 1)

            if (mode == "open") {
                val json = String(b64uDecode(payload), Charsets.UTF_8)
                return result(ok = true, config = json)
            }
            if (mode != "lock") return result(ok = false, error = "Unknown share mode")

            val dot = payload.indexOf('.')
            if (dot < 0) return result(ok = false, error = "Malformed share")
            val header = JSONObject(String(b64uDecode(payload.substring(0, dot)), Charsets.UTF_8))
            val body = b64uDecode(payload.substring(dot + 1))
            if (body.size <= 12) return result(ok = false, error = "Corrupt share")
            val iv = body.copyOfRange(0, 12)
            val ct = body.copyOfRange(12, body.size)

            val flags = mapOf(
                "lock" to (header.optBoolean("lock", false)),
                "hwid" to (header.optBoolean("hwid", false)),
                "pin" to (header.optBoolean("pin", false)),
                "exp" to (header.optLong("exp", 0L) > 0L),
                "root" to (header.optBoolean("root", false)),
                "apps" to (header.optJSONArray("apps")?.length() ?: 0 > 0),
            )

            // --- Enforced restrictions (from the AUTHENTICATED header) ---
            val exp = header.optLong("exp", 0L)
            if (exp > 0 && System.currentTimeMillis() > exp) {
                return result(ok = false, error = "This share expired", flags = flags)
            }
            if (header.optBoolean("root", false) && isRooted(context)) {
                return result(ok = false, error = "This share is blocked on rooted devices", flags = flags)
            }
            val apps = ArrayList<String>()
            val arr = header.optJSONArray("apps")
            if (arr != null) for (i in 0 until arr.length()) apps.add(arr.optString(i))
            if (apps.isNotEmpty()) {
                val present = installedOf(context, apps)
                if (present.isNotEmpty()) {
                    return result(ok = false,
                        error = "Blocked app installed: ${present.joinToString()}", flags = flags)
                }
            }
            if (header.optBoolean("hwid", false)) {
                val mine = sha256Hex(deviceHwid(context))
                val bound = header.optString("hwidHash", "")
                if (bound.isNotEmpty() && mine != bound) {
                    return result(ok = false,
                        error = "This share is bound to another device", flags = flags)
                }
            }

            // --- Password gate ---
            val needsPassword = header.optBoolean("pin", false) && password.isNullOrEmpty()
            if (needsPassword) {
                return result(ok = false, needsPassword = true, flags = flags)
            }
            val pin = password ?: ""
            if (header.optBoolean("pin", false)) {
                val expected = header.optString("pinChk", "")
                if (expected.isNotEmpty() && pinCheck(context, pin, b64uDecode(header.optString("salt")), header.optInt("iter", PBKDF2_ITERATIONS)) != expected) {
                    return result(ok = false, error = "Wrong password", flags = flags)
                }
            }

            // --- Decrypt (GCM authenticates header + payload together) ---
            val salt = b64uDecode(header.optString("salt"))
            val iter = header.optInt("iter", PBKDF2_ITERATIONS)
            val key = envelopeKey(
                context, pin, salt, iter,
                bindHwid = header.optBoolean("hwid", false),
                hwid = deviceHwid(context),
            )
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, iv))
            cipher.updateAAD(header.toString().toByteArray(Charsets.UTF_8))
            val plain = cipher.doFinal(ct)
            val json = String(plain, Charsets.UTF_8)

            // Carry the restrictions onto the imported config so they stay
            // enforced at USE time too (not just import): locked, expiry.
            val cfg = JSONObject(json)
            if (header.optBoolean("lock", false)) {
                cfg.put("locked", true)
                cfg.put("lockMessage", header.optString("note", "").ifEmpty { "Shared locked config" })
            }
            if (exp > 0) cfg.put("expiresAt", exp)
            result(ok = true, config = cfg.toString(), flags = flags,
                note = header.optString("note", ""))
        } catch (_: Exception) {
            // Wrong password/device/tampering all land here via the GCM tag.
            result(ok = false, error = "Could not open this share (wrong password, wrong device, or it was modified)")
        }
    }

    /** Fast sniff: does this text carry a password gate? (UI asks first.) */
    fun needsPassword(text: String): Boolean {
        return try {
            val rest = text.trim().removePrefix(SCHEME)
            if (!rest.startsWith("lock/")) return false
            val payload = rest.removePrefix("lock/")
            val dot = payload.indexOf('.')
            if (dot < 0) return false
            val header = JSONObject(String(b64uDecode(payload.substring(0, dot)), Charsets.UTF_8))
            header.optBoolean("pin", false)
        } catch (_: Exception) { false }
    }

    /** True when the text is a v48 share (either mode). */
    fun isShare(text: String): Boolean = text.trim().startsWith(SCHEME)

    // ------------------------------------------------------------------ //
    // Encoding helpers
    // ------------------------------------------------------------------ //

    private fun b64uEncode(bytes: ByteArray): String =
        Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)

    private fun b64uDecode(s: String): ByteArray =
        Base64.decode(s, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)

    private fun sha256Hex(s: String): String =
        MessageDigest.getInstance("SHA-256").digest(s.toByteArray())
            .joinToString("") { "%02x".format(it) }

    private fun result(
        ok: Boolean,
        config: String? = null,
        error: String? = null,
        needsPassword: Boolean = false,
        flags: Map<String, Boolean>? = null,
        note: String? = null,
    ): Map<String, Any?> = mapOf(
        "ok" to ok,
        "config" to config,
        "error" to error,
        "needsPassword" to needsPassword,
        "flags" to flags,
        "note" to note,
    )
}
