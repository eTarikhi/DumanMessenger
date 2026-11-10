package com.example.duman_messenger.identity

import android.os.Build
import android.security.keystore.KeyProperties
import javax.crypto.KeyGenerator

/**
 * G2-D capability probe.
 *
 * Everything reported here was **measured on this device**, in this process,
 * against the real Android Keystore. Nothing is inferred from `Build.VERSION`:
 * the API level is reported as a fact, and every capability is reported
 * separately so that a caller cannot read one as a substitute for another.
 *
 * The distinctions that matter:
 *
 * * `aesGcmSupported` — the Keystore offers an AES key generator. This is
 *   *availability*, not protection.
 * * `probeKeyGenerated` — a key was actually created.
 * * `roundTripVerified` — that key actually encrypted and decrypted 32 bytes
 *   with a matching result, under associated data, with a fresh iv.
 * * `probeKeyHardwareBacked` — the platform's own [KeyInfo.isInsideSecureHardware]
 *   answer for that key. This is the *only* source of a hardware claim.
 * * `strongBoxKeyCreated` — a separate StrongBox attempt (API 28+ only) actually
 *   produced a StrongBox key. Absence is reported as absence, never as failure
 *   of the platform.
 *
 * A probe key is created for the measurement and deleted immediately afterwards,
 * in a `finally` block, so a probe never leaves key material behind and never
 * touches the wrapping key that protects real data.
 */
internal class G2dCapabilityProbe(private val keyring: G2dIdentityKeyring) {

    @Volatile
    private var cached: Map<String, Any?>? = null

    /** Cached per process; [forceRefresh] re-measures. */
    fun probe(forceRefresh: Boolean = false): Map<String, Any?> {
        val current = cached
        if (current != null && !forceRefresh) {
            return current
        }
        val measured = runProbe()
        cached = measured
        return measured
    }

    private fun runProbe(): Map<String, Any?> {
        val notes = ArrayList<String>()
        var failure: String? = null

        var aesGcmSupported = false
        try {
            KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, G2D_KEYSTORE_PROVIDER)
            aesGcmSupported = true
        } catch (error: Exception) {
            failure = describe(error)
            notes.add("The Keystore does not offer an AES key generator on this device.")
        }

        var probeKeyGenerated = false
        var roundTripVerified = false
        var probeKeyHardwareBacked = false
        var probeKeySizeBits = 0

        if (aesGcmSupported) {
            try {
                keyring.deleteKeyIfPresent(G2D_PROBE_KEY_ALIAS)
                keyring.createKey(G2D_PROBE_KEY_ALIAS, strongBox = false)
                probeKeyGenerated = true

                val facts = keyring.inspectKey(G2D_PROBE_KEY_ALIAS)
                if (facts != null) {
                    probeKeyHardwareBacked = facts.hardwareBacked
                    probeKeySizeBits = facts.keySizeBits
                    if (facts.keySizeBits != G2D_KEY_SIZE_BITS) {
                        notes.add("The probe key is ${facts.keySizeBits} bits, not $G2D_KEY_SIZE_BITS.")
                    }
                } else {
                    notes.add("The platform would not describe the probe key; hardware backing is unverified.")
                }

                val probeKey = keyring.ensureKey(G2D_PROBE_KEY_ALIAS, allowCreate = false)
                val expected = ByteArray(32) { index -> (index * 7).toByte() }
                val plaintext = expected.copyOf()
                val associatedData = buildAssociatedData(G2D_PROBE_DOMAIN, 0L, ByteArray(G2D_KEY_ID_BYTES))
                var verified = false
                try {
                    val sealed = keyring.encrypt(probeKey, plaintext, associatedData)
                    val opened = keyring.decrypt(probeKey, sealed.iv, sealed.ciphertext, associatedData)
                    verified = opened.contentEquals(expected)
                    opened.fill(0)
                } finally {
                    plaintext.fill(0)
                    expected.fill(0)
                }
                roundTripVerified = verified
                if (!roundTripVerified) {
                    notes.add("The AES-GCM round trip did not reproduce the probe plaintext.")
                }
            } catch (error: Exception) {
                if (failure == null) {
                    failure = describe(error)
                }
                notes.add("The Keystore probe failed: ${describe(error)}")
            } finally {
                try {
                    keyring.deleteKeyIfPresent(G2D_PROBE_KEY_ALIAS)
                } catch (ignored: Exception) {
                    notes.add("The probe key could not be removed from the Keystore.")
                }
            }
        }

        var strongBoxRequested = false
        var strongBoxKeyCreated = false
        if (aesGcmSupported && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            strongBoxRequested = true
            try {
                keyring.deleteKeyIfPresent(G2D_STRONGBOX_PROBE_ALIAS)
                keyring.createKey(G2D_STRONGBOX_PROBE_ALIAS, strongBox = true)
                strongBoxKeyCreated = true
            } catch (error: Exception) {
                // Optional hardware. Its absence is a fact about the device, not a failure.
                notes.add("StrongBox is not available: ${describe(error)}")
            } finally {
                try {
                    keyring.deleteKeyIfPresent(G2D_STRONGBOX_PROBE_ALIAS)
                } catch (ignored: Exception) {
                    notes.add("The StrongBox probe key could not be removed from the Keystore.")
                }
            }
        } else if (aesGcmSupported) {
            notes.add("StrongBox requires Android 9 (API 28) or newer; not attempted.")
        }

        var wrappingKeyPresent = false
        var wrappingKeyHardwareBacked: Boolean? = null
        try {
            wrappingKeyPresent = keyring.hasKey(G2D_WRAPPING_KEY_ALIAS)
            if (wrappingKeyPresent) {
                wrappingKeyHardwareBacked = keyring.inspectKey(G2D_WRAPPING_KEY_ALIAS)?.hardwareBacked
            }
        } catch (error: Exception) {
            notes.add("The wrapping key state could not be inspected: ${describe(error)}")
        }

        val result = LinkedHashMap<String, Any?>()
        result["apiLevel"] = Build.VERSION.SDK_INT
        result["keystoreProvider"] = G2D_KEYSTORE_PROVIDER
        result["aesGcmSupported"] = aesGcmSupported
        result["probeKeyGenerated"] = probeKeyGenerated
        result["roundTripVerified"] = roundTripVerified
        result["probeKeyHardwareBacked"] = probeKeyHardwareBacked
        result["probeKeySizeBits"] = probeKeySizeBits
        result["strongBoxRequested"] = strongBoxRequested
        result["strongBoxKeyCreated"] = strongBoxKeyCreated
        result["wrappingKeyPresent"] = wrappingKeyPresent
        result["wrappingKeyHardwareBacked"] = wrappingKeyHardwareBacked
        result["notes"] = ArrayList(notes)
        result["failure"] = failure
        return result
    }

    /**
     * Short, non-secret description of a failure.
     *
     * Deliberately limited to the exception type and a truncated message: no key
     * bytes, ivs or ciphertext exist in a Keystore exception message, and this
     * function is where that stays true.
     */
    private fun describe(error: Throwable): String {
        val name = error.javaClass.simpleName
        val message = error.message?.take(120)
        return if (message.isNullOrBlank()) name else "$name: $message"
    }
}
