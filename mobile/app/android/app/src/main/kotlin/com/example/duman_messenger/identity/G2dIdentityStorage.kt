package com.example.duman_messenger.identity

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import org.json.JSONObject

/**
 * Non-secret storage index: which wrapping key protects the data, and which
 * generation was last committed.
 *
 * It is a hint for diagnostics and rollback detection, never the authority for
 * what the record says. Losing it degrades a check; it never loses identity data
 * and it never makes a corrupt record look valid.
 */
internal class G2dStorageIndex(val keyId: ByteArray, val generation: Long)

/**
 * G2-D identity storage on Android.
 *
 * Two alternating slots plus a two-phase write give crash safety without
 * journalling:
 *
 * 1. encrypt the payload with a fresh Keystore iv under generation `n + 1`;
 * 2. write slot `n % 2` to a temporary file, `fsync`, close;
 * 3. `rename` the temporary file onto the slot (atomic within one directory);
 * 4. update the index (best effort).
 *
 * A crash therefore leaves either the previous complete slot or the new complete
 * slot, never a half-written record. On load the highest generation that
 * authenticates wins; if none authenticates the record is corrupt, and corrupt
 * is terminal until an explicit reset deletes it.
 *
 * Recovery rules, stated plainly because they are the whole point of the class:
 *
 * * missing wrapping key **with** encrypted data → [G2dProtectionException.KEY_MISSING],
 *   never a silently generated replacement key;
 * * authentication failure → [G2dProtectionException.AUTH_FAILED], never a
 *   best-effort decode;
 * * unreadable bytes → [G2dProtectionException.CIPHERTEXT_MALFORMED];
 * * an older record than the last committed generation →
 *   [G2dProtectionException.STALE_RECORD];
 * * read errors are [G2dProtectionException.IO_UNAVAILABLE] and are **not**
 *   corruption, so nothing is deleted because a file could not be opened.
 *
 * [deleteRecord] is the explicit reset: it removes the data, the index and the
 * Keystore key, so the discarded identity can never be decrypted again. It
 * recreates nothing.
 */
internal class G2dIdentityStorage(
    baseDir: File,
    private val keyring: G2dIdentityKeyring,
) {

    private val directory = File(baseDir, DIRECTORY_NAME)
    private val metaFile = File(directory, META_FILE_NAME)
    private val metaTempFile = File(directory, META_FILE_NAME + ".tmp")

    /** Returns the decrypted payload, or null when no identity is stored. */
    @Synchronized
    fun loadRecord(): String? {
        val envelopes = ArrayList<G2dSealedEnvelope>()
        var storedFiles = 0
        for (index in 0 until SLOT_COUNT) {
            val file = slotFile(index)
            if (!file.exists()) {
                continue
            }
            storedFiles += 1
            val bytes = try {
                file.readBytes()
            } catch (error: IOException) {
                throw G2dProtectionException(
                    G2dProtectionException.IO_UNAVAILABLE,
                    "stored identity data could not be read",
                    error,
                )
            }
            try {
                envelopes.add(G2dSealedEnvelope.decode(bytes))
            } catch (error: G2dProtectionException) {
                // A damaged slot is not immediately fatal: the other slot may hold
                // the last good copy. If neither does, the record is corrupt below.
            }
        }
        if (storedFiles == 0) {
            return null
        }
        if (envelopes.isEmpty()) {
            throw G2dProtectionException(
                G2dProtectionException.CIPHERTEXT_MALFORMED,
                "stored identity data is not a G2-D identity record",
            )
        }

        val index = readIndex()
        val expectedKeyId = index?.keyId ?: envelopes[0].keyId
        val key = keyring.ensureKey(G2D_WRAPPING_KEY_ALIAS, allowCreate = false)

        var authenticationFailure: G2dProtectionException? = null
        var keyIdMismatch = false
        for (envelope in envelopes.sortedByDescending { it.generation }) {
            if (!envelope.keyId.contentEquals(expectedKeyId)) {
                keyIdMismatch = true
                continue
            }
            val plaintext = try {
                keyring.decrypt(
                    key,
                    envelope.iv,
                    envelope.ciphertext,
                    buildAssociatedData(G2D_RECORD_DOMAIN, envelope.generation, envelope.keyId),
                )
            } catch (error: G2dProtectionException) {
                authenticationFailure = error
                continue
            }
            if (index != null && envelope.generation < index.generation) {
                plaintext.fill(0)
                throw G2dProtectionException(
                    G2dProtectionException.STALE_RECORD,
                    "stored identity record is older than the last committed generation",
                )
            }
            writeIndexQuietly(G2dStorageIndex(envelope.keyId, envelope.generation))
            val payload = String(plaintext, Charsets.UTF_8)
            plaintext.fill(0)
            return payload
        }
        if (authenticationFailure != null) {
            throw authenticationFailure
        }
        if (keyIdMismatch) {
            throw G2dProtectionException(
                G2dProtectionException.KEY_ID_MISMATCH,
                "stored identity data was encrypted under a different wrapping key",
            )
        }
        throw G2dProtectionException(
            G2dProtectionException.CIPHERTEXT_MALFORMED,
            "stored identity data could not be read",
        )
    }

    /** Encrypts and commits [payload]. The previous generation stays readable. */
    @Synchronized
    fun saveRecord(payload: String) {
        ensureDirectory()
        val existingIndex = readIndex()
        val keyId = existingIndex?.keyId ?: randomKeyId()
        val key = keyring.ensureKey(G2D_WRAPPING_KEY_ALIAS, allowCreate = !anySlotExists())
        val generation = maxOf(existingIndex?.generation ?: 0L, highestStoredGeneration()) + 1L

        val plaintext = payload.toByteArray(Charsets.UTF_8)
        val sealed = try {
            keyring.encrypt(
                key,
                plaintext,
                buildAssociatedData(G2D_RECORD_DOMAIN, generation, keyId),
            )
        } finally {
            plaintext.fill(0)
        }

        val envelope = G2dSealedEnvelope(generation, keyId, sealed.iv, sealed.ciphertext)
        val slot = (generation % SLOT_COUNT).toInt()
        val temporary = slotTempFile(slot)
        writeDurably(temporary, envelope.encode())
        if (!temporary.renameTo(slotFile(slot))) {
            temporary.delete()
            throw G2dProtectionException(
                G2dProtectionException.WRITE_FAILED,
                "stored identity data could not be committed",
            )
        }
        writeIndexQuietly(G2dStorageIndex(keyId, generation))
    }

    /**
     * Explicit reset. Removes the slots, the index and the wrapping key.
     *
     * Idempotent by construction: deleting files that do not exist and a key that
     * is already absent is a no-op. Nothing is recreated here; the caller must
     * create a new identity deliberately.
     */
    @Synchronized
    fun deleteRecord() {
        var failure: IOException? = null
        for (index in 0 until SLOT_COUNT) {
            for (file in listOf(slotFile(index), slotTempFile(index))) {
                if (file.exists() && !file.delete() && file.exists()) {
                    failure = IOException("stored identity data could not be removed")
                }
            }
        }
        if (metaFile.exists() && !metaFile.delete() && metaFile.exists()) {
            failure = IOException("the identity storage index could not be removed")
        }
        metaTempFile.delete()
        try {
            keyring.deleteKeyIfPresent(G2D_WRAPPING_KEY_ALIAS)
        } catch (ignored: G2dProtectionException) {
            // No encrypted data remains, so an unremovable wrapping key protects
            // nothing. Reporting a write failure here would block the reset path.
        }
        if (failure != null) {
            throw G2dProtectionException(
                G2dProtectionException.WRITE_FAILED,
                "stored identity data could not be fully removed",
                failure,
            )
        }
    }

    private fun slotFile(index: Int): File = File(directory, RECORD_FILE_PREFIX + index + ".bin")

    private fun slotTempFile(index: Int): File = File(directory, RECORD_FILE_PREFIX + index + ".bin.tmp")

    private fun anySlotExists(): Boolean {
        for (index in 0 until SLOT_COUNT) {
            if (slotFile(index).exists()) {
                return true
            }
        }
        return false
    }

    private fun highestStoredGeneration(): Long {
        var highest = 0L
        for (index in 0 until SLOT_COUNT) {
            val file = slotFile(index)
            if (!file.exists()) {
                continue
            }
            val envelope = try {
                G2dSealedEnvelope.decode(file.readBytes())
            } catch (error: Exception) {
                null
            }
            if (envelope != null && envelope.generation > highest) {
                highest = envelope.generation
            }
        }
        return highest
    }

    private fun ensureDirectory() {
        if (directory.isDirectory) {
            return
        }
        if (!directory.mkdirs() && !directory.isDirectory) {
            throw G2dProtectionException(
                G2dProtectionException.IO_UNAVAILABLE,
                "the identity storage directory could not be created",
            )
        }
    }

    private fun writeDurably(file: File, bytes: ByteArray) {
        try {
            FileOutputStream(file).use { stream ->
                stream.write(bytes)
                stream.flush()
                stream.fd.sync()
            }
        } catch (error: IOException) {
            file.delete()
            throw G2dProtectionException(
                G2dProtectionException.WRITE_FAILED,
                "identity data could not be written durably",
                error,
            )
        }
    }

    private fun readIndex(): G2dStorageIndex? {
        if (!metaFile.exists()) {
            return null
        }
        val text = try {
            metaFile.readText()
        } catch (error: Exception) {
            return null
        }
        return try {
            val json = JSONObject(text)
            if (json.optInt("v", 0) != INDEX_VERSION) {
                return null
            }
            val keyId = decodeKeyId(json.optString("keyId", "")) ?: return null
            if (keyId.size != G2D_KEY_ID_BYTES) {
                return null
            }
            G2dStorageIndex(keyId, json.optLong("generation", 0L))
        } catch (error: Exception) {
            null
        }
    }

    private fun writeIndexQuietly(index: G2dStorageIndex) {
        try {
            ensureDirectory()
            val json = JSONObject()
            json.put("v", INDEX_VERSION)
            json.put("keyId", encodeKeyId(index.keyId))
            json.put("generation", index.generation)
            writeDurably(metaTempFile, json.toString().toByteArray(Charsets.UTF_8))
            if (!metaTempFile.renameTo(metaFile)) {
                metaTempFile.delete()
            }
        } catch (error: Exception) {
            // The index is a non-secret hint used for rollback detection. It is
            // never the authority for what the record says, so a failed index write
            // must not fail a committed record.
        }
    }

    private companion object {
        const val DIRECTORY_NAME = "identity"
        const val RECORD_FILE_PREFIX = "identity."
        const val META_FILE_NAME = "keyring.meta"
        const val INDEX_VERSION = 1
        const val SLOT_COUNT = 2
    }
}
