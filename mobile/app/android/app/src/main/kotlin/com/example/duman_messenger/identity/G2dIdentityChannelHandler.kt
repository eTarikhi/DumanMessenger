package com.example.duman_messenger.identity

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Platform channel for G2-D identity services.
 *
 * Channel: `duman/identity`.
 *
 * | Method | Arguments | Response |
 * |---|---|---|
 * | `capabilities` | `{refresh: bool}` | measured capability evidence |
 * | `load` | — | decrypted record JSON, or null when absent |
 * | `save` | `{payload: String}` | null |
 * | `delete` | — | null |
 *
 * The contract is deliberately narrow. Dart owns the identity state machine
 * (creation, rotation, revocation); this side owns the Keystore and the files.
 * Requests and responses carry the record payload and non-secret probe facts
 * only — never key material, never an iv, never ciphertext.
 *
 * Errors are returned as `result.error(code, message, null)` with the codes in
 * [G2dProtectionException]. A missing key and a failed authentication are
 * different codes on purpose: both are unrecoverable without a reset, but only
 * reporting them apart lets the Dart side and the owner tell a wiped Keystore
 * from a tampered file.
 */
internal class G2dIdentityChannelHandler(
    private val probe: G2dCapabilityProbe,
    private val storage: G2dIdentityStorage,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val METHOD_CHANNEL = "duman/identity"
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "capabilities" -> handleCapabilities(call, result)
            "load" -> handleLoad(result)
            "save" -> handleSave(call, result)
            "delete" -> handleDelete(result)
            else -> result.notImplemented()
        }
    }

    private fun handleCapabilities(call: MethodCall, result: MethodChannel.Result) {
        try {
            val refresh = call.argument<Boolean>("refresh") ?: false
            result.success(probe.probe(refresh))
        } catch (error: Exception) {
            fail(result, error)
        }
    }

    private fun handleLoad(result: MethodChannel.Result) {
        try {
            result.success(storage.loadRecord())
        } catch (error: Exception) {
            fail(result, error)
        }
    }

    private fun handleSave(call: MethodCall, result: MethodChannel.Result) {
        val payload = call.argument<String>("payload")
        if (payload == null) {
            result.error(
                G2dProtectionException.WRITE_FAILED,
                "the identity record payload is missing",
                null,
            )
            return
        }
        try {
            storage.saveRecord(payload)
            result.success(null)
        } catch (error: Exception) {
            fail(result, error)
        }
    }

    private fun handleDelete(result: MethodChannel.Result) {
        try {
            storage.deleteRecord()
            result.success(null)
        } catch (error: Exception) {
            fail(result, error)
        }
    }

    private fun fail(result: MethodChannel.Result, error: Exception) {
        val protectionError = error as? G2dProtectionException
        if (protectionError != null) {
            result.error(protectionError.code, protectionError.message ?: protectionError.code, null)
            return
        }
        result.error(
            G2dProtectionException.INTERNAL_ERROR,
            error.javaClass.simpleName,
            null,
        )
    }
}
