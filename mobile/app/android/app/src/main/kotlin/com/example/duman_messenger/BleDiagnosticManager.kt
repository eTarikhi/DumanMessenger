package com.example.duman_messenger

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

internal class BleDiagnosticManager(private val activity: Activity) :
    EventChannel.StreamHandler {
    companion object {
        const val METHOD_CHANNEL = "com.dumanmessenger/ble_diagnostic/methods"
        const val EVENT_CHANNEL = "com.dumanmessenger/ble_diagnostic/events"

        private const val PERMISSION_REQUEST_CODE = 7241
        private const val PREFERENCES_NAME = "ble_diagnostic_permission_history"
    }

    private val permissionHistory =
        activity.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    private var eventSink: EventChannel.EventSink? = null
    private var activityResumed = false
    private var receiverRegistered = false
    private var destroyed = false
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingPermissionNames: List<String> = emptyList()

    // Bluetooth may be sent by a separate system UID; only the action is read.
    private val adapterStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == BluetoothAdapter.ACTION_STATE_CHANGED) {
                emitStatus()
            }
        }
    }

    fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getStatus" -> result.success(statusSnapshot())
            "requestRequiredPermissions" -> requestRequiredPermissions(result)
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        if (destroyed) return
        eventSink = events
        updateReceiverRegistration()
        emitStatus()
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
        updateReceiverRegistration()
    }

    fun onActivityResumed() {
        if (destroyed) return
        activityResumed = true
        updateReceiverRegistration()
        emitStatus()
    }

    fun onActivityPaused() {
        activityResumed = false
        updateReceiverRegistration()
    }

    fun onActivityDestroyed() {
        destroyed = true
        activityResumed = false
        eventSink = null
        updateReceiverRegistration()
        pendingPermissionResult?.error(
            "activity_unavailable",
            "The Android activity ended before permission handling completed.",
            null,
        )
        pendingPermissionResult = null
        pendingPermissionNames = emptyList()
    }

    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false

        if (permissions.isNotEmpty()) {
            val editor = permissionHistory.edit()
            permissions.forEachIndexed { index, permission ->
                val granted = grantResults.getOrNull(index) == PackageManager.PERMISSION_GRANTED
                editor.putBoolean(denialHistoryKey(permission), !granted)
            }
            editor.apply()
        }

        val result = pendingPermissionResult
        pendingPermissionResult = null
        pendingPermissionNames = emptyList()
        result?.success(statusSnapshot())
        emitStatus()
        return true
    }

    private fun requestRequiredPermissions(result: MethodChannel.Result) {
        if (destroyed || activity.isFinishing || activity.isDestroyed) {
            result.error(
                "activity_unavailable",
                "The Android activity is not available for a permission request.",
                null,
            )
            return
        }
        if (pendingPermissionResult != null) {
            result.error(
                "permission_request_in_progress",
                "A BLE diagnostic permission request is already in progress.",
                null,
            )
            return
        }

        if (!activity.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE) ||
            activity.getSystemService(Context.BLUETOOTH_SERVICE) !is BluetoothManager
        ) {
            result.success(statusSnapshot())
            return
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) {
            result.success(statusSnapshot())
            return
        }

        val connectPermission = Manifest.permission.BLUETOOTH_CONNECT
        if (hasPermission(connectPermission) || !canRequest(connectPermission)) {
            result.success(statusSnapshot())
            return
        }

        pendingPermissionResult = result
        pendingPermissionNames = listOf(connectPermission)
        try {
            activity.requestPermissions(
                pendingPermissionNames.toTypedArray(),
                PERMISSION_REQUEST_CODE,
            )
        } catch (_: RuntimeException) {
            pendingPermissionResult = null
            pendingPermissionNames = emptyList()
            result.error(
                "permission_request_failed",
                "Android could not start the required permission request.",
                null,
            )
        }
    }

    private fun statusSnapshot(): Map<String, Any?> {
        val hasBleHardware = activity.packageManager.hasSystemFeature(
            PackageManager.FEATURE_BLUETOOTH_LE,
        )
        val bluetoothManager =
            activity.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val permissions = permissionReports(hasBleHardware)
        val requiredPermissionDenied = permissions.any { entry ->
            entry["requiredForDiagnostics"] == true && entry["state"] != "granted"
        }
        val adapter = if (bluetoothManager == null || requiredPermissionDenied) {
            null
        } else {
            try {
                bluetoothManager.adapter
            } catch (_: SecurityException) {
                null
            }
        }
        val adapterAvailable: Boolean? = when {
            bluetoothManager == null -> false
            requiredPermissionDenied -> null
            else -> adapter != null
        }
        val bluetoothEnabled = if (adapter == null) {
            null
        } else {
            try {
                adapter.isEnabled
            } catch (_: SecurityException) {
                null
            }
        }

        val state = when {
            !hasBleHardware -> "ble_hardware_unavailable"
            bluetoothManager == null -> "native_service_unavailable"
            requiredPermissionDenied -> "permissions_denied"
            adapter == null -> "native_service_unavailable"
            bluetoothEnabled == false -> "bluetooth_disabled"
            bluetoothEnabled == true -> "ready"
            else -> "error"
        }

        val reason = when (state) {
            "ble_hardware_unavailable" ->
                "This device does not report Bluetooth LE hardware support."
            "native_service_unavailable" ->
                "The Android Bluetooth service or adapter is unavailable."
            "permissions_denied" ->
                "A Bluetooth permission required for local adapter status is not granted."
            "bluetooth_disabled" ->
                "Bluetooth is off. Enable it manually in Android system settings."
            "ready" ->
                "Diagnostic prerequisites are satisfied; no BLE radio operation was performed."
            else -> "The BLE diagnostic status could not be determined."
        }

        return mapOf(
            "state" to state,
            "apiLevel" to Build.VERSION.SDK_INT,
            "bleHardwareSupported" to hasBleHardware,
            "bluetoothManagerAvailable" to (bluetoothManager != null),
            "adapterAvailable" to adapterAvailable,
            "bluetoothEnabled" to bluetoothEnabled,
            "permissions" to permissions,
            "advertisingCapability" to advertisingCapability(
                hasBleHardware,
                bluetoothManager,
                adapter,
            ),
            "reason" to reason,
        )
    }

    private fun permissionReports(hasBleHardware: Boolean): List<Map<String, Any?>> {
        val modern = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
        val legacy = Build.VERSION.SDK_INT <= Build.VERSION_CODES.R
        return listOf(
            permissionReport(
                Manifest.permission.BLUETOOTH_SCAN,
                applicable = modern,
                requiredForDiagnostics = false,
                runtime = modern,
            ),
            permissionReport(
                Manifest.permission.BLUETOOTH_ADVERTISE,
                applicable = modern,
                requiredForDiagnostics = false,
                runtime = modern,
            ),
            permissionReport(
                Manifest.permission.BLUETOOTH_CONNECT,
                applicable = modern,
                requiredForDiagnostics = modern && hasBleHardware,
                runtime = modern,
            ),
            permissionReport(
                Manifest.permission.BLUETOOTH,
                applicable = legacy,
                requiredForDiagnostics = legacy && hasBleHardware,
                runtime = false,
            ),
            permissionReport(
                Manifest.permission.BLUETOOTH_ADMIN,
                applicable = legacy,
                requiredForDiagnostics = legacy && hasBleHardware,
                runtime = false,
            ),
            // The manifest entry is required through API 30 but does not gate G2-A's no-scan status.
            permissionReport(
                Manifest.permission.ACCESS_FINE_LOCATION,
                applicable = legacy,
                requiredForDiagnostics = false,
                runtime = legacy && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M,
            ),
        )
    }

    private fun permissionReport(
        permission: String,
        applicable: Boolean,
        requiredForDiagnostics: Boolean,
        runtime: Boolean,
    ): Map<String, Any?> {
        val granted = applicable && hasPermission(permission)
        val state = when {
            !applicable -> "not_required"
            granted -> "granted"
            else -> "denied"
        }
        val shouldShowRationale =
            applicable && runtime && !granted && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
                activity.shouldShowRequestPermissionRationale(permission)
        val canRequestAgain =
            requiredForDiagnostics && runtime && !granted && canRequest(permission)

        return mapOf(
            "name" to permission,
            "state" to state,
            "requiredForDiagnostics" to requiredForDiagnostics,
            "runtime" to runtime,
            "canRequestAgain" to canRequestAgain,
            "shouldShowRationale" to shouldShowRationale,
        )
    }

    private fun hasPermission(permission: String): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
    }

    private fun canRequest(permission: String): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return false
        val previouslyDenied =
            permissionHistory.getBoolean(denialHistoryKey(permission), false)
        return !previouslyDenied || activity.shouldShowRequestPermissionRationale(permission)
    }

    private fun denialHistoryKey(permission: String): String = "denied:$permission"

    private fun advertisingCapability(
        hasBleHardware: Boolean,
        bluetoothManager: BluetoothManager?,
        adapter: BluetoothAdapter?,
    ): String {
        if (!hasBleHardware) return "unsupported"
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) return "unsupported"
        if (bluetoothManager == null || adapter == null) return "unknown"
        return try {
            if (adapter.isMultipleAdvertisementSupported) "supported" else "unsupported"
        } catch (_: SecurityException) {
            "unknown"
        }
    }

    private fun updateReceiverRegistration() {
        val shouldRegister = !destroyed && activityResumed && eventSink != null
        if (shouldRegister && !receiverRegistered) {
            val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    activity.registerReceiver(
                        adapterStateReceiver,
                        filter,
                        Context.RECEIVER_EXPORTED,
                    )
                } else {
                    @Suppress("UnspecifiedRegisterReceiverFlag")
                    activity.registerReceiver(adapterStateReceiver, filter)
                }
                receiverRegistered = true
            } catch (_: RuntimeException) {
                receiverRegistered = false
            }
        } else if (!shouldRegister && receiverRegistered) {
            try {
                activity.unregisterReceiver(adapterStateReceiver)
            } catch (_: IllegalArgumentException) {
                // The receiver may already have been unregistered during Activity teardown.
            } finally {
                receiverRegistered = false
            }
        }
    }

    private fun emitStatus() {
        val sink = eventSink ?: return
        if (destroyed) return
        try {
            sink.success(statusSnapshot())
        } catch (_: RuntimeException) {
            eventSink = null
            updateReceiverRegistration()
        }
    }
}
