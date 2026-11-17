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
 * | `loadKeyMaterial` | — | decrypted key-material JSON, or null |
 * | `saveKeyMaterial` | `{payload: String}` | null |
 * | `deleteKeyMaterial` | — | null |
 * | `loadConversations` | — | decrypted conversation JSON, or null |
 * | `saveConversations` | `{payload: String}` | null |
 * | `deleteConversations` | — | null |
 * | `loadMessages` | — | decrypted message JSON, or null |
 * | `saveMessages` | `{payload: String}` | null |
 * | `deleteMessages` | — | null |
 *
 * The three key-material methods use a **second** storage slot: its own directory
 * and its own non-exportable Keystore alias. Private identity keys live there, so
 * deleting them cannot delete the wrapping key that protects the record, and the
 * record payload stays public metadata. The Kotlin side still never parses the
 * key material and never exports a Keystore key: it encrypts and returns a string.
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
    private val keyMaterialStorage: G2dIdentityStorage? = null,
    private val conversationStorage: G2dIdentityStorage? = null,
    private val messageStorage: G2dIdentityStorage? = null,
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
            "loadKeyMaterial" -> handleKeyMaterialLoad(result)
            "saveKeyMaterial" -> handleKeyMaterialSave(call, result)
            "deleteKeyMaterial" -> handleKeyMaterialDelete(result)
            "loadConversations" -> handleConversationLoad(result)
            "saveConversations" -> handleConversationSave(call, result)
            "deleteConversations" -> handleConversationDelete(result)
            "loadMessages" -> handleMessageLoad(result)
            "saveMessages" -> handleMessageSave(call, result)
            "deleteMessages" -> handleMessageDelete(result)
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

    /**
     * The optional slot is deliberately nullable: the instrumented tests and any
     * build that has not wired key material keep working unchanged, and a missing
     * slot is reported as an explicit failure rather than silently succeeding.
     */
    private fun handleKeyMaterialLoad(result: MethodChannel.Result) {
        val slot = keyMaterialStorage
        if (slot == null) {
            slotNotConfigured(result)
            return
        }
        try {
            result.success(slot.loadRecord())
        } catch (error: Exception) {
            fail(result, error)
        }
    }

    private fun handleKeyMaterialSave(call: MethodCall, result: MethodChannel.Result) {
        val slot = keyMaterialStorage
        if (slot == null) {
            slotNotConfigured(result)
            return
        }
        val payload = call.argument<String>("payload")
        if (payload == null) {
            result.error(
                G2dProtectionException.WRITE_FAILED,
                "the identity key material payload is missing",
                null,
            )
            return
        }
        try {
            slot.saveRecord(payload)
            result.success(null)
        } catch (error: Exception) {
            fail(result, error)
        }
    }

    private fun handleKeyMaterialDelete(result: MethodChannel.Result) {
        val slot = keyMaterialStorage
        if (slot == null) {
            slotNotConfigured(result)
            return
        }
        try {
            slot.deleteRecord()
            result.success(null)
        } catch (error: Exception) {
            fail(result, error)
        }
    }

    /**
     * Conversations live in a third slot with its own directory and its own
     * Keystore alias, so deleting them cannot affect the identity record or its
     * key material. The payload is conversation metadata authored by the user;
     * it is encrypted at rest by the same non-exportable envelope and is never
     * parsed on this side.
     */
    private fun handleConversationLoad(result: MethodChannel.Result) {
        val slot = conversationStorage
        if (slot == null) {
            slotNotConfigured(result)
            return
        }
        try {
            result.success(slot.loadRecord())
        } catch (error: Exception) {
            fail(result, error)
        }
    }

    private fun handleConversationSave(call: MethodCall, result: MethodChannel.Result) {
        val slot = conversationStorage
        if (slot == null) {
            slotNotConfigured(result)
            return
        }
        val payload = call.argument<String>("payload")
        if (payload == null) {
            result.error(
                G2dProtectionException.WRITE_FAILED,
                "the conversation payload is missing",
                null,
            )
            return
        }
        try {
            slot.saveRecord(payload)
            result.success(null)
        } catch (error: Exception) {
            fail(result, error)
        }
    }

    private fun handleConversationDelete(result: MethodChannel.Result) {
        val slot = conversationStorage
        if (slot == null) {
            slotNotConfigured(result)
            return
        }
        try {
            slot.deleteRecord()
            result.success(null)
        } catch (error: Exception) {
            fail(result, error)
        }
    }

    /**
     * Messages live in a fourth slot with their own directory and Keystore alias.
     * The envelope is the same proven one: AES-256-GCM, a fresh iv per write,
     * generation binding in the associated data, two alternating slots, and the
     * highest authenticating generation wins on load. Nothing here parses or logs
     * a message body.
     */
    private fun handleMessageLoad(result: MethodChannel.Result) {
        val slot = messageStorage
        if (slot == null) {
            slotNotConfigured(result)
            return
        }
        try {
            result.success(slot.loadRecord())
        } catch (error: Exception) {
            fail(result, error)
        }
    }

    private fun handleMessageSave(call: MethodCall, result: MethodChannel.Result) {
        val slot = messageStorage
        if (slot == null) {
            slotNotConfigured(result)
            return
        }
        val payload = call.argument<String>("payload")
        if (payload == null) {
            result.error(
                G2dProtectionException.WRITE_FAILED,
                "the message payload is missing",
                null,
            )
            return
        }
        try {
            slot.saveRecord(payload)
            result.success(null)
        } catch (error: Exception) {
            fail(result, error)
        }
    }

    private fun handleMessageDelete(result: MethodChannel.Result) {
        val slot = messageStorage
        if (slot == null) {
            slotNotConfigured(result)
            return
        }
        try {
            slot.deleteRecord()
            result.success(null)
        } catch (error: Exception) {
            fail(result, error)
        }
    }

    private fun slotNotConfigured(result: MethodChannel.Result) {
        result.error(
            G2dProtectionException.INTERNAL_ERROR,
            "identity key material storage is not configured in this build",
            null,
        )
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
