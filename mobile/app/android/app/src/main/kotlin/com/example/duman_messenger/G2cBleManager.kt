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
                result.success(statusMap())
                sink?.success(statusMap())
            }
            "sendTestFrame" -> {
                val type = call.argument<Int>("type")
                val payload = call.argument<ByteArray>("payload")
                if (type == null || payload == null || payload.size > G2cGattProtocol.MAX_PAYLOAD_BYTES) {
                    result.success(errorStatus("invalid_test_frame")); return
                }
                val accepted = link?.sendFrame(type, payload) ?: server?.sendFrame(type, payload) ?: false
                if (!accepted) {
                    result.success(statusMap() + ("operationError" to "transport_not_ready_or_busy"))
                } else result.success(statusMap())
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
        val g2cServer = G2cGattServer(appContext, { next ->
            status = next
            sink?.success(statusMap())
        }, onFrame = { /* TEST-ONLY transport validation; never forwarded to production messaging. */ })
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
            val newLink = G2cGattLink(
                appContext,
                onState = { next ->
                    status = next
                    sink?.success(statusMap())
                },
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
        "discoveryState" to (discovery?.state ?: "idle"),
        "discoveryErrorCode" to discovery?.errorCode,
        "discoveredPeerIds" to (discovery?.results() ?: emptyList<String>()),
    )
}
