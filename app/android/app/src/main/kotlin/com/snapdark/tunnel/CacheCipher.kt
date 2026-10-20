package com.snapdark.tunnel

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * AES-256-GCM cache encryption backed by AndroidKeyStore (hardware-backed
 * on modern devices). Covers the *in-transit-to-disk* window: the decrypted
 * server list written to SharedPreferences is encrypted, so a rooted-device
 * file dump no longer yields plaintext configs.
 *
 * Wire format:  `sek1:` + Base64(NO_WRAP) of `[12-byte IV][ciphertext + 16-byte GCM tag]`
 *
 * Key lifecycle:
 *  - Generated once per key alias on first use.
 *  - Stored in AndroidKeyStore (never leaves secure hardware).
 *  - `setUserAuthenticationRequired(false)` so the key works before the user
 *    unlocks the screen (app refreshes on start).
 *  - On Keystore invalidation (e.g. device-owner wipe) the decrypt path
 *    returns null; the caller clears the cache and re-fetches.
 *
 * If the key cannot be created/read (broken Keystore), `encrypt`/`decrypt`
 * return null so callers fall back gracefully.
 */
object CacheCipher {

    private const val KEYSTORE = "AndroidKeyStore"
    private const val ALIAS = "snapdark_cache_v1"
    private const val IV_LEN = 12
    private const val TAG_LEN = 128
    private const val PREFIX = "sek1:"

    /** Whether this blob was written by us (encrypted) vs legacy plaintext JSON. */
    fun isEncrypted(blob: String): Boolean = blob.startsWith(PREFIX)

    /** Encrypt plaintext; returns `sek1:<base64>` or null on failure. */
    fun encrypt(context: Context, plain: String): String? {
        return try {
            val key = getOrCreateKey() ?: return null
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            // Randomized GCM: a fresh random IV is generated per encrypt.
            cipher.init(Cipher.ENCRYPT_MODE, key)
            val ct = cipher.doFinal(plain.toByteArray(Charsets.UTF_8))
            val iv = cipher.iv
            require(iv.size == IV_LEN) { "unexpected IV length ${iv.size}" }
            val blob = iv + ct // 12-byte IV + ciphertext + 16-byte GCM tag
            PREFIX + Base64.encodeToString(blob, Base64.NO_WRAP)
        } catch (_: Throwable) {
            null
        }
    }

    /** Decrypt `sek1:<base64>` blob; returns plaintext or null. */
    fun decrypt(context: Context, blob: String): String? {
        if (!isEncrypted(blob)) return null
        return try {
            val raw = Base64.decode(blob.removePrefix(PREFIX), Base64.NO_WRAP)
            require(raw.size > IV_LEN + TAG_LEN) { "ciphertext too short" }
            val iv = raw.copyOfRange(0, IV_LEN)
            val ct = raw.copyOfRange(IV_LEN, raw.size)
            val key = getOrCreateKey() ?: return null
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_LEN, iv))
            String(cipher.doFinal(ct), Charsets.UTF_8)
        } catch (_: Throwable) {
            null
        }
    }

    /** Retrieve the existing key or generate a new one; returns null on fatal Keystore error. */
    private fun getOrCreateKey(): SecretKey? {
        return try {
            val ks = KeyStore.getInstance(KEYSTORE).apply { load(null) }
            (ks.getEntry(ALIAS, null) as? KeyStore.SecretKeyEntry)?.secretKey
                ?: createKey()
        } catch (_: Throwable) {
            try { createKey() } catch (_: Throwable) { null }
        }
    }

    private fun createKey(): SecretKey {
        val kg = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        kg.init(
            KeyGenParameterSpec.Builder(
                ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(true)
                .build()
        )
        return kg.generateKey()
    }
}