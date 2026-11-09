package com.example.duman_messenger

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.Settings
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** G2-C TEST-ONLY bridge. Peer addresses stay native and are never returned or logged. */
internal class G2cBleManager(private val activity: Activity) : EventChannel.StreamHandler {
    companion object {
        const val METHOD_CHANNEL = "com.dumanmessenger/g2c/methods"
        const val EVENT_CHANNEL = "com.dumanmessenger/g2c/events"
        private const val PERMISSION_REQUEST_CODE = 7253

        /** Bounded hex preview only; a received test payload is never forwarded anywhere. */
        private const val RECEIVED_PREVIEW_BYTES = 32
    }

    private val appContext = activity.applicationContext
    private val permissionHistory = activity.getSharedPreferences("g2c_permission_history", Context.MODE_PRIVATE)
    private data class PendingPermission(
        val names: List<String>,
        val result: MethodChannel.Result,
        val continueOperation: () -> Unit,
    )
    private var pendingPermission: PendingPermission? = null
    private var deferredPermission: PendingPermission? = null
    private var permissionState = "not_required"
    private var permissionError: String? = null
    private var permanentlyDenied = false
    private var permissionShouldShowRationale = false
    private var lastPermissionNames: List<String> = emptyList()
    private var activityResumed = false
    private var sink: EventChannel.EventSink? = null
    private var link: G2cGattLink? = null
    private var server: G2cGattServer? = null
    private var discovery: G2cBleDiscovery? = null
    private var status = G2cLinkSnapshot()

    // TEST-ONLY transport diagnostics. Send acceptance is queued, never "delivered";
    // only an actually decoded inbound frame counts as reception evidence.
    private var transportOutcome: String? = null
    private var transportOutcomeDetail: String? = null
    private var receivedFrameCount = 0
    private var lastReceivedRole: String? = null
    private var lastReceivedType: Int? = null
    private var lastReceivedBytes: Int? = null
    private var lastReceivedPreview: String? = null

    fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getStatus" -> {
                refreshPermissionSnapshot()
                result.success(statusMap())
            }
            "openPermissionSettings" -> openPermissionSettings(result)
            "startDiscovery" -> withPermissions(scanPermissions(), result) {
                startDiscoveryNow(result)
            }
            "stopDiscovery" -> {
                discovery?.stop()
                result.success(statusMap())
            }
            "startServer" -> {
                discovery?.stop()
                withPermissions(serverPermissions(), result) { startServerNow(result) }
            }
            "stopServer" -> {
                server?.stop()
                server = null
                status = G2cLinkSnapshot(G2cLinkState.DISCONNECTED)
                recordOutcome("disconnected", "server_stopped")
                result.success(statusMap())
                sink?.success(statusMap())
            }
            "sendTestFrame" -> {
                val type = call.argument<Int>("type")
                val payload = call.argument<ByteArray>("payload")
                if (type == null || payload == null || type !in 1..255 ||
                    payload.size > G2cGattProtocol.MAX_PAYLOAD_BYTES
                ) {
                    recordOutcome("malformed_frame", "invalid_test_frame")
                    result.success(statusMap() + ("operationError" to "invalid_test_frame"))
                    sink?.success(statusMap())
                    return
                }
                val activeLink = link
                val activeServer = server
                val busy = activeLink?.isTransportBusy == true || activeServer?.isTransportBusy == true
                val linkState = activeLink?.snapshot()?.state
                val linkSendReady = linkState == G2cLinkState.SERVICE_READY
                val linkDisconnected = linkState == G2cLinkState.DISCONNECTED ||
                    linkState == G2cLinkState.DISCONNECTING ||
                    linkState == G2cLinkState.CONNECTION_FAILED
                val blocked = when {
                    activeLink == null && activeServer == null -> "transport_unavailable"
                    busy -> "busy"
                    activeLink != null && !linkSendReady ->
                        if (linkDisconnected) "disconnected" else "transport_unavailable"
                    activeServer != null && !activeServer.isSubscriptionReady ->
                        if (activeServer.hasConnectedPeer) "transport_unavailable" else "disconnected"
                    else -> null
                }
                if (blocked != null) {
                    recordOutcome(blocked, "send_rejected")
                    result.success(statusMap() + ("operationError" to blocked))
                    sink?.success(statusMap())
                    return
                }
                val accepted = activeLink?.sendFrame(type, payload) ?: activeServer?.sendFrame(type, payload) ?: false
                // Clear a stale queue-level error for this new attempt; acceptance is still only queued.
                if (accepted) status = G2cLinkSnapshot(status.state)
                // A local GATT write or notification acceptance is queued transport only.
                // Remote reception is reported separately from an actually decoded inbound frame.
                recordOutcome(
                    if (accepted) "queued" else "transport_failure",
                    if (accepted) "queued_for_transmission" else "write_rejected",
                )
                val response: Map<String, Any?> = if (accepted) {
                    statusMap()
                } else {
                    statusMap() + ("operationError" to "transport_failure")
                }
                result.success(response)
                sink?.success(statusMap())
            }
            "connect" -> {
                val peerId = call.argument<String>("peerId")
                if (link != null || server != null) {
                    result.success(errorStatus("operation_in_progress")); return
                }
                if (peerId == null || discovery?.contains(peerId) != true) {
                    result.success(errorStatus("unknown_peer")); return
                }
                discovery?.stop()
                withPermissions(connectPermissions(), result) { connectNow(peerId, result) }
            }
            "disconnect" -> {
                link?.close()
                link = null
                server?.stop()
                server = null
                status = G2cLinkSnapshot(G2cLinkState.DISCONNECTED)
                recordOutcome("disconnected", "explicit_disconnect")
                result.success(statusMap())
                sink?.success(statusMap())
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        events.success(statusMap())
    }

    override fun onCancel(arguments: Any?) {
        (pendingPermission ?: deferredPermission)?.result?.error(
            "operation_cancelled",
            "The G2-C screen closed during a permission request.",
            null,
        )
        pendingPermission = null
        deferredPermission = null
        sink = null
        // Activity/UI disposal must not leave a foreground GATT connection behind.
        link?.close()
        link = null
        server?.stop()
        server = null
        discovery?.clear()
        discovery = null
        status = G2cLinkSnapshot(G2cLinkState.DISCONNECTED)
    }

    fun onActivityResumed() {
        activityResumed = true
        val deferred = deferredPermission
        if (deferred != null) {
            deferredPermission = null
            deferred.continueOperation()
        }
    }

    fun onActivityPaused() {
        activityResumed = false
        if (pendingPermission != null) return
        discovery?.stop("foreground_required")
        link?.close()
        link = null
        server?.stop()
        server = null
        status = G2cLinkSnapshot(G2cLinkState.DISCONNECTED, "foreground_required")
        recordOutcome("disconnected", "foreground_required")
        sink?.success(statusMap())
    }

    fun onDestroy() {
        (pendingPermission ?: deferredPermission)?.result?.error(
            "activity_unavailable",
            "The Android activity ended during a G2-C permission request.",
            null,
        )
        pendingPermission = null
        deferredPermission = null
        link?.close()
        link = null
        server?.onDestroy()
        server = null
        discovery?.clear()
        discovery = null
        sink = null
        status = G2cLinkSnapshot()
    }

    private fun requireForeground(result: MethodChannel.Result): Boolean {
        if (activityResumed && !activity.isFinishing && !activity.isDestroyed) return true
        result.success(errorStatus("foreground_required"))
        return false
    }

    private fun startDiscoveryNow(result: MethodChannel.Result) {
        if (!requireForeground(result)) return
        if (link != null || server != null) {
            result.success(errorStatus("operation_in_progress")); return
        }
        status = G2cLinkSnapshot(G2cLinkState.DISCONNECTED)
        val scanner = discovery ?: G2cBleDiscovery(appContext) {
            sink?.success(statusMap())
        }.also { discovery = it }
        scanner.start()
        if (scanner.errorCode != null) {
            status = G2cLinkSnapshot(
                when (scanner.state) {
                    "permission_denied" -> G2cLinkState.PERMISSION_DENIED
                    "unsupported" -> G2cLinkState.UNSUPPORTED
                    "timed_out" -> G2cLinkState.TIMED_OUT
                    else -> G2cLinkState.CONNECTION_FAILED
                }, scanner.errorCode,
            )
        }
        result.success(statusMap())
    }

    private fun startServerNow(result: MethodChannel.Result) {
        if (!requireForeground(result)) return
        if (link != null || server != null) {
            result.success(errorStatus("operation_in_progress")); return
        }
        discovery?.stop()
        status = G2cLinkSnapshot(G2cLinkState.DISCONNECTED)
        resetReceiveDiagnostics()
        val g2cServer = G2cGattServer(
            appContext,
            onState = { next -> publishSnapshot(next) },
            // TEST-ONLY transport validation; never forwarded to production messaging.
            onFrame = { frame -> recordReceivedFrame("server", frame) },
        )
        server = g2cServer
        val started = g2cServer.start()
        if (!started && status.state == G2cLinkState.DISCONNECTED) {
            status = G2cLinkSnapshot(G2cLinkState.CONNECTION_FAILED, "server_start_failed")
        }
        result.success(statusMap())
    }

    private fun connectNow(peerId: String, result: MethodChannel.Result) {
        if (!requireForeground(result)) return
        if (link != null || server != null) {
            result.success(errorStatus("operation_in_progress")); return
        }
        if (!capabilityReady()) { result.success(errorStatus("ble_unavailable")); return }
        val device = discovery?.take(peerId)
        if (device == null) { result.success(errorStatus("unknown_peer")); return }
        try {
            val adapter = (appContext.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
            if (adapter == null || !adapter.isEnabled) {
                result.success(errorStatus("bluetooth_unavailable")); return
            }
            resetReceiveDiagnostics()
            val newLink = G2cGattLink(
                appContext,
                onState = { next -> publishSnapshot(next) },
                // TEST-ONLY inbound diagnostics; never forwarded to production messaging.
                onMessage = { frame -> recordReceivedFrame("client", frame) },
            )
            link = newLink
            newLink.connect(device)
            status = newLink.snapshot()
            result.success(statusMap())
        } catch (_: SecurityException) {
            result.success(errorStatus("permission_required"))
        } catch (_: IllegalArgumentException) {
            result.success(errorStatus("invalid_peer_reference"))
        } catch (_: RuntimeException) {
            result.success(errorStatus("connection_failed"))
        }
    }

    private fun publishSnapshot(next: G2cLinkSnapshot) {
        status = next
        outcomeForError(next.errorCode)?.let { recordOutcome(it, next.errorCode) }
        sink?.success(statusMap())
    }

    private fun recordOutcome(outcome: String, detail: String?) {
        transportOutcome = outcome
        transportOutcomeDetail = detail
    }

    /**
     * Records an inbound TEST-ONLY frame. Only the metadata and a bounded hex preview are
     * retained; the payload is zeroed immediately and never forwarded to production messaging.
     */
    private fun recordReceivedFrame(role: String, frame: G2cGattProtocol.Frame) {
        val valid = frame.type in 1..255 &&
            frame.payload.size <= G2cGattProtocol.MAX_PAYLOAD_BYTES
        if (!valid) {
            frame.payload.fill(0)
            recordOutcome("malformed_frame", "invalid_test_frame")
            sink?.success(statusMap())
            return
        }
        lastReceivedRole = role
        lastReceivedType = frame.type
        lastReceivedBytes = frame.payload.size
        lastReceivedPreview =
            frame.payload.take(RECEIVED_PREVIEW_BYTES).joinToString("") { "%02x".format(it) } +
            if (frame.payload.size > RECEIVED_PREVIEW_BYTES) "…" else ""
        frame.payload.fill(0)
        receivedFrameCount = (receivedFrameCount + 1).coerceAtMost(Int.MAX_VALUE - 1)
        recordOutcome("received", null)
        sink?.success(statusMap())
    }

    private fun resetReceiveDiagnostics() {
        transportOutcome = null
        transportOutcomeDetail = null
        receivedFrameCount = 0
        lastReceivedRole = null
        lastReceivedType = null
        lastReceivedBytes = null
        lastReceivedPreview = null
    }

    private fun outcomeForError(code: String?): String? = when {
        code == null -> null
        code.contains("permission") -> "permission_denied"
        code.contains("fragment") || code.contains("truncated") ||
            code.contains("protocol") || code.startsWith("invalid_") -> "malformed_frame"
        code.contains("timeout") -> "timed_out"
        else -> "transport_failure"
    }

    private fun refreshPermissionSnapshot() {
        if (lastPermissionNames.isEmpty()) return
        val missing = lastPermissionNames.filterNot(::isGranted)
        if (missing.isEmpty()) {
            permissionState = "granted"
            permissionError = null
            permanentlyDenied = false
            permissionShouldShowRationale = false
            return
        }
        // Re-read grants on resume/getStatus so revocation in system settings is not
        // represented by a stale "granted" permission state.
        permissionShouldShowRationale = missing.any(activity::shouldShowRequestPermissionRationale)
        permanentlyDenied = missing.any { permission ->
            permissionHistory.getBoolean("requested:$permission", false) &&
                !activity.shouldShowRequestPermissionRationale(permission)
        }
        permissionState = if (permanentlyDenied) "permanently_denied" else "requestable"
        permissionError = if (permanentlyDenied) "permission_settings_required" else "permission_denied"
    }

    private fun scanPermissions(): List<String> = when {
        Build.VERSION.SDK_INT >= 31 -> listOf(Manifest.permission.BLUETOOTH_SCAN)
        Build.VERSION.SDK_INT >= 23 -> listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        else -> emptyList()
    }

    private fun connectPermissions(): List<String> = if (Build.VERSION.SDK_INT >= 31)
        listOf(Manifest.permission.BLUETOOTH_CONNECT) else emptyList()

    private fun serverPermissions(): List<String> = if (Build.VERSION.SDK_INT >= 31)
        listOf(Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_ADVERTISE)
        else emptyList()

    private fun isGranted(permission: String): Boolean = Build.VERSION.SDK_INT < 23 ||
        activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun withPermissions(
        requested: List<String>,
        result: MethodChannel.Result,
        continueOperation: () -> Unit,
    ) {
        if (pendingPermission != null) {
            result.success(errorStatus("permission_request_in_progress")); return
        }
        lastPermissionNames = requested.distinct()
        val missing = requested.distinct().filterNot(::isGranted)
        if (missing.isEmpty()) {
            permissionState = if (requested.isEmpty()) "not_required" else "granted"
            permissionError = null
            permanentlyDenied = false
            permissionShouldShowRationale = false
            continueOperation()
            return
        }
        permissionShouldShowRationale = missing.any(activity::shouldShowRequestPermissionRationale)
        permanentlyDenied = missing.any { permission ->
            permissionHistory.getBoolean("requested:$permission", false) &&
                !activity.shouldShowRequestPermissionRationale(permission)
        }
        if (permanentlyDenied) {
            permissionState = "permanently_denied"
            permissionError = "permission_settings_required"
            status = G2cLinkSnapshot(G2cLinkState.PERMISSION_DENIED, permissionError)
            result.success(statusMap())
            sink?.success(statusMap())
            return
        }
        pendingPermission = PendingPermission(missing, result, continueOperation)
        permissionState = "requesting"
        permissionError = null
        sink?.success(statusMap())
        try {
            activity.requestPermissions(missing.toTypedArray(), PERMISSION_REQUEST_CODE)
        } catch (_: RuntimeException) {
            pendingPermission = null
            permissionState = "requestable"
            permissionError = "permission_request_failed"
            result.success(errorStatus(permissionError!!))
        }
    }

    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false
        val pending = pendingPermission ?: return true
        pendingPermission = null
        pending.names.forEach { permissionHistory.edit().putBoolean("requested:$it", true).apply() }
        val denied = pending.names.filterNot(::isGranted)
        if (denied.isNotEmpty()) {
            permissionShouldShowRationale = denied.any(activity::shouldShowRequestPermissionRationale)
            permanentlyDenied = denied.any { !activity.shouldShowRequestPermissionRationale(it) }
            permissionState = if (permanentlyDenied) "permanently_denied" else "requestable"
            permissionError = if (permanentlyDenied) "permission_settings_required" else "permission_denied"
            status = G2cLinkSnapshot(G2cLinkState.PERMISSION_DENIED, permissionError)
            pending.result.success(statusMap())
            sink?.success(statusMap())
            return true
        }
        permissionState = "granted"
        permissionError = null
        permanentlyDenied = false
        permissionShouldShowRationale = false
        if (activityResumed) pending.continueOperation() else deferredPermission = pending
        return true
    }

    private fun openPermissionSettings(result: MethodChannel.Result) {
        try {
            val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.fromParts("package", activity.packageName, null)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            activity.startActivity(intent)
            result.success(statusMap())
        } catch (_: RuntimeException) {
            result.success(errorStatus("settings_unavailable"))
        }
    }

    /** null means the platform withheld role capability (for example, a missing permission). */
    private fun roleAvailable(probe: (android.bluetooth.BluetoothAdapter) -> Boolean): Boolean? {
        if (!capabilityReady()) return false
        return try {
            val adapter =
                (appContext.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
            if (adapter == null) false else probe(adapter)
        } catch (_: SecurityException) {
            null
        } catch (_: RuntimeException) {
            null
        }
    }

    private fun capabilityReady(): Boolean =
        appContext.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE) &&
            (appContext.getSystemService(Context.BLUETOOTH_SERVICE) is BluetoothManager)

    /** null means Android withholds adapter state until CONNECT is granted. */
    private fun bluetoothEnabledSnapshot(): Boolean? {
        if (!capabilityReady()) return false
        if (Build.VERSION.SDK_INT >= 31 && !hasConnectPermission()) return null
        return try {
            (appContext.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)
                ?.adapter?.isEnabled
        } catch (_: SecurityException) {
            null
        } catch (_: RuntimeException) {
            null
        }
    }

    private fun hasConnectPermission(): Boolean = Build.VERSION.SDK_INT < 31 ||
        appContext.checkSelfPermission(android.Manifest.permission.BLUETOOTH_CONNECT) ==
        PackageManager.PERMISSION_GRANTED

    private fun hasScanPermission(): Boolean = Build.VERSION.SDK_INT < 23 ||
        appContext.checkSelfPermission(
            if (Build.VERSION.SDK_INT >= 31) android.Manifest.permission.BLUETOOTH_SCAN
            else android.Manifest.permission.ACCESS_FINE_LOCATION,
        ) == PackageManager.PERMISSION_GRANTED

    private fun hasAdvertisePermission(): Boolean = Build.VERSION.SDK_INT < 31 ||
        appContext.checkSelfPermission(android.Manifest.permission.BLUETOOTH_ADVERTISE) ==
        PackageManager.PERMISSION_GRANTED

    private fun errorStatus(code: String): Map<String, Any?> {
        val state = when {
            code.contains("permission") -> G2cLinkState.PERMISSION_DENIED
            code.contains("unsupported") || code == "ble_unavailable" ||
                code == "scanner_unavailable" || code == "advertiser_unavailable" ||
                code == "gatt_server_unavailable" -> G2cLinkState.UNSUPPORTED
            code.contains("timeout") -> G2cLinkState.TIMED_OUT
            code.contains("protocol") -> G2cLinkState.PROTOCOL_ERROR
            else -> G2cLinkState.CONNECTION_FAILED
        }
        status = G2cLinkSnapshot(state, code)
        sink?.success(statusMap())
        return statusMap()
    }

    private fun statusMap(): Map<String, Any?> = mapOf(
        "testOnly" to true,
        "state" to status.state.name.lowercase(),
        "authenticated" to status.isAuthenticated,
        "errorCode" to status.errorCode,
        "apiLevel" to Build.VERSION.SDK_INT,
        "bleHardwareSupported" to appContext.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE),
        "bluetoothEnabled" to bluetoothEnabledSnapshot(),
        "connectPermissionGranted" to hasConnectPermission(),
        "scanPermissionGranted" to hasScanPermission(),
        "advertisePermissionGranted" to hasAdvertisePermission(),
        "permissionState" to permissionState,
        "permissionErrorCode" to permissionError,
        "permissionNames" to lastPermissionNames,
        "permissionPermanentlyDenied" to permanentlyDenied,
        "permissionShouldShowRationale" to permissionShouldShowRationale,
        "serverRunning" to (server?.isRunning == true),
        "advertiserAvailable" to roleAvailable { it.bluetoothLeAdvertiser != null },
        "scannerAvailable" to roleAvailable { it.bluetoothLeScanner != null },
        "activeRole" to when {
            link != null -> "client"
            server?.isRunning == true -> "server"
            else -> null
        },
        "serverClientConnected" to (server?.hasConnectedPeer == true),
        "serverSubscriptionReady" to (server?.isSubscriptionReady == true),
        "transportOutcome" to transportOutcome,
        "transportOutcomeDetail" to transportOutcomeDetail,
        "receivedFrameCount" to receivedFrameCount,
        "lastReceivedFrameRole" to lastReceivedRole,
        "lastReceivedFrameType" to lastReceivedType,
        "lastReceivedFrameBytes" to lastReceivedBytes,
        "lastReceivedFramePreview" to lastReceivedPreview,
        "discoveryState" to (discovery?.state ?: "idle"),
        "discoveryErrorCode" to discovery?.errorCode,
        "discoveredPeerIds" to (discovery?.results() ?: emptyList<String>()),
    )
}
