package com.example.duman_messenger

import android.os.Handler
import android.os.Looper

/** Bounded transport segmentation; successful reassembly is NOT authentication. */
internal object G2cFragmentation {
    const val HEADER_BYTES = 9
    const val MAX_MESSAGE_BYTES = 2048
    const val MAX_FRAGMENTS = 192
    private const val VERSION = 1

    fun split(message: ByteArray, mtu: Int, messageId: Int): List<ByteArray> {
        require(message.isNotEmpty() && message.size <= MAX_MESSAGE_BYTES) { "Invalid G2-C message size" }
        require(messageId in 0..0xffff) { "Invalid G2-C message id" }
        val attValueCapacity = (mtu - 3).coerceIn(20, 514)
        val pieceCapacity = attValueCapacity - HEADER_BYTES
        require(pieceCapacity > 0) { "MTU too small for G2-C fragment header" }
        val count = (message.size + pieceCapacity - 1) / pieceCapacity
        require(count in 1..MAX_FRAGMENTS) { "G2-C fragment count exceeded" }
        return (0 until count).map { index ->
            val start = index * pieceCapacity
            val size = minOf(pieceCapacity, message.size - start)
            val out = java.nio.ByteBuffer.allocate(HEADER_BYTES + size)
                .order(java.nio.ByteOrder.BIG_ENDIAN)
            out.put(VERSION.toByte())
                .putShort(messageId.toShort())
                .putShort(index.toShort())
                .putShort(count.toShort())
                .putShort(message.size.toShort())
                .put(message, start, size)
            out.array()
        }
    }
}

/** One in-flight message only; strict in-order assembly, byte/count caps, timeout and reset. */
internal class G2cFragmentReassembler(
    private val onComplete: (ByteArray) -> Unit,
    private val onError: (String) -> Unit,
) {
    companion object { private const val ASSEMBLY_TIMEOUT_MS = 15_000L }
    private val handler = Handler(Looper.getMainLooper())
    private var messageId = -1
    private var expectedIndex = 0
    private var count = 0
    private var declaredLength = 0
    private var used = 0
    private var buffer: ByteArray? = null
    private var timeout: Runnable? = null

    @Synchronized
    fun accept(fragment: ByteArray, mtu: Int) {
        val capacity = (mtu - 3).coerceIn(20, 514)
        if (fragment.size !in (G2cFragmentation.HEADER_BYTES + 1)..capacity) {
            reject("invalid_fragment_size"); return
        }
        val input = java.nio.ByteBuffer.wrap(fragment).order(java.nio.ByteOrder.BIG_ENDIAN)
        val version = input.get().toInt() and 0xff
        val id = input.short.toInt() and 0xffff
        val index = input.short.toInt() and 0xffff
        val fragments = input.short.toInt() and 0xffff
        val total = input.short.toInt() and 0xffff
        val payloadLength = input.remaining()
        if (version != 1 || fragments !in 1..G2cFragmentation.MAX_FRAGMENTS ||
            total !in 1..G2cFragmentation.MAX_MESSAGE_BYTES || index >= fragments ||
            payloadLength > total
        ) { reject("invalid_fragment_header"); return }

        if (buffer == null) {
            if (index != 0) { reject("fragment_sequence_error"); return }
            messageId = id
            count = fragments
            declaredLength = total
            expectedIndex = 0
            used = 0
            buffer = ByteArray(total)
            armTimeout()
        }
        if (id != messageId || fragments != count || total != declaredLength || index != expectedIndex) {
            reject("fragment_sequence_error"); return
        }
        if (used + payloadLength > declaredLength) {
            reject("fragment_length_error"); return
        }
        input.get(buffer!!, used, payloadLength)
        used += payloadLength
        expectedIndex++
        if (expectedIndex == count) {
            if (used != declaredLength) { reject("truncated_message"); return }
            val result = buffer!!.copyOf()
            reset()
            onComplete(result)
        }
    }

    @Synchronized
    fun clear() = reset()

    private fun armTimeout() {
        cancelTimeout()
        timeout = Runnable { synchronized(this) { reject("reassembly_timeout") } }
            .also { handler.postDelayed(it, ASSEMBLY_TIMEOUT_MS) }
    }

    private fun reject(code: String) {
        reset()
        onError(code)
    }

    private fun reset() {
        cancelTimeout()
        buffer?.fill(0)
        buffer = null
        messageId = -1
        expectedIndex = 0
        count = 0
        declaredLength = 0
        used = 0
    }

    private fun cancelTimeout() {
        timeout?.let(handler::removeCallbacks)
        timeout = null
    }
}
