package com.example.duman_messenger

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.UUID

/** G2-C TEST-ONLY GATT service identifiers. UUIDs route bytes; they do not authenticate peers. */
internal object G2cGattProtocol {
    val SERVICE_UUID: UUID = UUID.fromString("a71c0001-7d2b-4f5a-9d11-6c47c20a0001")
    val DATA_CHARACTERISTIC_UUID: UUID = UUID.fromString("a71c0002-7d2b-4f5a-9d11-6c47c20a0001")
    val CLIENT_CONFIGURATION_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    const val VERSION: Int = 1
    const val HEADER_BYTES: Int = 4
    const val MAX_PAYLOAD_BYTES: Int = 512
    const val MAX_FRAME_BYTES: Int = HEADER_BYTES + MAX_PAYLOAD_BYTES

    /** Validation framing only. No encryption, authentication, or replay defense is provided. */
    fun encode(type: Int, payload: ByteArray): ByteArray {
        require(type in 1..255) { "Invalid G2-C frame type" }
        require(payload.size <= MAX_PAYLOAD_BYTES) { "G2-C payload too large" }
        return ByteBuffer.allocate(HEADER_BYTES + payload.size)
            .order(ByteOrder.BIG_ENDIAN)
            .put(VERSION.toByte())
            .put(type.toByte())
            .putShort(payload.size.toShort())
            .put(payload)
            .array()
    }

    fun decode(frame: ByteArray): Frame {
        require(frame.size in HEADER_BYTES..MAX_FRAME_BYTES) { "Invalid G2-C frame size" }
        val buffer = ByteBuffer.wrap(frame).order(ByteOrder.BIG_ENDIAN)
        val version = buffer.get().toInt() and 0xff
        require(version == VERSION) { "Unsupported G2-C frame version" }
        val type = buffer.get().toInt() and 0xff
        require(type != 0) { "Invalid G2-C frame type" }
        val length = buffer.short.toInt() and 0xffff
        require(length <= MAX_PAYLOAD_BYTES && length == buffer.remaining()) {
            "G2-C frame length mismatch"
        }
        val payload = ByteArray(length)
        buffer.get(payload)
        return Frame(version, type, payload)
    }

    data class Frame(val version: Int, val type: Int, val payload: ByteArray)
}

/** Public-key identity helper; fingerprint is an identifier and is not proof of key possession. */
internal object G2cPeerIdentity {
    fun fingerprint(publicKey: ByteArray): String {
        require(publicKey.isNotEmpty() && publicKey.size <= 4096) { "Invalid public key size" }
        return MessageDigest.getInstance("SHA-256").digest(publicKey)
            .joinToString("") { "%02x".format(it) }
    }

    fun sameKey(first: ByteArray, second: ByteArray): Boolean =
        MessageDigest.isEqual(first, second)
}

/** Explicit, process-local trust seam. Not persistent and not an authentication mechanism. */
internal class G2cExplicitTrustStore {
    private val pinnedKeys = LinkedHashMap<String, ByteArray>()

    @Synchronized
    fun confirmTrust(publicKey: ByteArray, displayedFingerprint: String, userConfirmed: Boolean): String {
        require(userConfirmed) { "Explicit peer confirmation is required" }
        val fingerprint = G2cPeerIdentity.fingerprint(publicKey)
        require(MessageDigest.isEqual(
            fingerprint.toByteArray(Charsets.US_ASCII),
            displayedFingerprint.lowercase().toByteArray(Charsets.US_ASCII),
        )) { "Peer fingerprint confirmation mismatch" }
        val existing = pinnedKeys[fingerprint]
        require(existing == null || G2cPeerIdentity.sameKey(existing, publicKey)) {
            "Trusted identity key replacement rejected"
        }
        pinnedKeys[fingerprint] = publicKey.copyOf()
        return fingerprint
    }

    @Synchronized
    fun isExplicitlyTrusted(publicKey: ByteArray): Boolean {
        val key = pinnedKeys[G2cPeerIdentity.fingerprint(publicKey)] ?: return false
        return G2cPeerIdentity.sameKey(key, publicKey)
    }

    @Synchronized
    fun revoke(fingerprint: String): Boolean {
        val removed = pinnedKeys.remove(fingerprint) ?: return false
        removed.fill(0)
        return true
    }

    @Synchronized
    fun clear() {
        pinnedKeys.values.forEach { it.fill(0) }
        pinnedKeys.clear()
    }
}

enum class G2cLinkState {
    DISCONNECTED, DISCOVERED, CONNECTING, CONNECTED_UNAUTHENTICATED, SERVICE_READY,
    AUTHENTICATING, AUTHENTICATED, DISCONNECTING, CONNECTION_FAILED,
    PERMISSION_DENIED, UNSUPPORTED, TIMED_OUT, PROTOCOL_ERROR
}

/** Deliberately makes it impossible for transport connection alone to imply authentication. */
internal data class G2cLinkSnapshot(
    val state: G2cLinkState = G2cLinkState.DISCONNECTED,
    val errorCode: String? = null,
) {
    val isAuthenticated: Boolean get() = state == G2cLinkState.AUTHENTICATED
}
