package com.example.duman_messenger

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.os.Build
import android.os.ParcelUuid
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/**
 * Foreground-only, service-UUID-filtered discovery. Device objects are retained only in memory
 * for scan-session de-duplication; no address or device name is read, emitted, logged, or persisted.
 */
internal class BleDiscoveryManager(private val activity: Activity) :
    EventChannel.StreamHandler {
    companion object {
        const val METHOD_CHANNEL = "com.dumanmessenger/ble_discovery/methods"
        const val EVENT_CHANNEL = "com.dumanmessenger/ble_discovery/events"

        const val SERVICE_UUID = "5d1796d0-d8f8-406a-8b3d-1a8684447470"

        private val SERVICE_PARCEL_UUID = ParcelUuid(UUID.fromString(SERVICE_UUID))
        private const val PERMISSION_REQUEST_CODE = 7242
        private const val PREFERENCES_NAME = "ble_discovery_permission_history"
    }

    private enum class Operation { ADVERTISING, SCANNING }

    private data class PendingPermission(
        val operation: Operation,
        val permission: String,
        val result: MethodChannel.Result,
    )

    private val permissionHistory =
        activity.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    private val discoveredDevices = LinkedHashMap<BluetoothDevice, String>()

    private var eventSink: EventChannel.EventSink? = null
    private var activityResumed = false
    private var receiverRegistered = false
    private var destroyed = false
    private var pendingPermission: PendingPermission? = null

    private var activeAdvertiser: BluetoothLeAdvertiser? = null
    private var advertiseCallback: AdvertiseCallback? = null
    private var activeScanner: BluetoothLeScanner? = null
    private var scanCallback: ScanCallback? = null

    private var advertisingState = "idle"
    private var scanningState = "idle"
    private var nextResultId = 0
    private var errorCode: String? = null
    private var message: String? = null

    // The system broadcast is used only to stop foreground operations when Bluetooth turns off.
    private val adapterStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
            val state = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, -1)
            if (state == BluetoothAdapter.STATE_TURNING_OFF ||
                state == BluetoothAdapter.STATE_OFF
            ) {
                stopActiveOperations(clearResults = true)
                setError(
                    "bluetooth_unavailable",
                    "Bluetooth is off. Turn it on manually in Android settings.",
                )
                emitStatus()
            } else {
                if (state == BluetoothAdapter.STATE_ON &&
                    errorCode == "bluetooth_unavailable"
                ) {
                    clearError()
                }
                emitStatus()
            }
        }
    }

    fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getStatus" -> result.success(statusSnapshot())
            "startAdvertising" -> startOperation(Operation.ADVERTISING, result)
            "stopAdvertising" -> stopOperation(Operation.ADVERTISING, result)
            "startScanning" -> startOperation(Operation.SCANNING, result)
            "stopScanning" -> stopOperation(Operation.SCANNING, result)
            "stopAll" -> {
                cancelPendingPermission()
                stopActiveOperations(clearResults = true)
                clearError()
                emitStatus()
                result.success(statusSnapshot())
            }
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
        cancelPendingPermission()
        stopActiveOperations(clearResults = true)
        clearError()
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
        stopActiveOperations(clearResults = true)
        if (pendingPermission == null) {
            errorCode = "foreground_required"
            message = "Discovery stopped because DumanMessenger left the foreground."
        }
        updateReceiverRegistration()
        emitStatus()
    }

    fun onActivityDestroyed() {
        destroyed = true
        activityResumed = false
        eventSink = null
        stopActiveOperations(clearResults = true)
        pendingPermission?.result?.error(
            "activity_unavailable",
            "The Android activity ended while a discovery permission was pending.",
            null,
        )
        pendingPermission = null
        updateReceiverRegistration()
    }

    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST_CODE) return false

        val pending = pendingPermission
        pendingPermission = null
        if (permissions.isNotEmpty()) {
            permissions.forEachIndexed { index, permission ->
                val granted = grantResults.getOrNull(index) == PackageManager.PERMISSION_GRANTED ||
                    hasPermission(permission)
                permissionHistory.edit()
                    .putBoolean(denialHistoryKey(permission), !granted)
                    .apply()
            }
        }
        pending?.permission?.let { permission ->
            val granted = hasPermission(permission)
            permissionHistory.edit()
                .putBoolean(denialHistoryKey(permission), !granted)
                .apply()
        }

        if (pending == null) {
            emitStatus()
            return true
        }

        if (!hasPermission(pending.permission)) {
            setOperationState(pending.operation, "permission_denied")
            val canAskAgain = canRequest(pending.permission)
            setError(
                if (canAskAgain) "permission_denied" else "permission_settings_required",
                permissionDenialMessage(pending.operation, pending.permission, canAskAgain),
            )
            pending.result.success(statusSnapshot())
            emitStatus()
            return true
        }

        if (destroyed || !activityResumed || eventSink == null) {
            setOperationState(pending.operation, "idle")
            setError(
                "foreground_required",
                "Return to the foreground and start discovery again.",
            )
            pending.result.success(statusSnapshot())
            emitStatus()
            return true
        }

        val adapter = adapterFor(pending.operation)
        if (adapter == null) {
            pending.result.success(statusSnapshot())
            emitStatus()
            return true
        }
        startOperationNow(pending.operation, adapter, pending.result)
        return true
    }

    private fun startOperation(operation: Operation, result: MethodChannel.Result) {
        if (destroyed || activity.isFinishing || activity.isDestroyed ||
            !activityResumed || eventSink == null
        ) {
            setOperationState(operation, "unavailable")
            setError(
                "foreground_required",
                "Open the discovery screen while DumanMessenger is in the foreground.",
            )
            result.success(statusSnapshot())
            emitStatus()
            return
        }

        if (pendingPermission != null) {
            setError(
                "permission_request_in_progress",
                "Finish the current Android permission prompt before starting another operation.",
            )
            result.success(statusSnapshot())
            emitStatus()
            return
        }

        if (isRunning(operation)) {
            result.success(statusSnapshot())
            return
        }

        if (operation == Operation.SCANNING) {
            discoveredDevices.clear()
            nextResultId = 0
        }

        val adapter = adapterFor(operation)
        if (adapter == null) {
            result.success(statusSnapshot())
            emitStatus()
            return
        }

        val missingPermission = requiredPermissions(operation)
            .firstOrNull { !hasPermission(it) }
        if (missingPermission != null) {
            if (isRuntimePermission(missingPermission) && canRequest(missingPermission)) {
                requestPermission(operation, missingPermission, result)
            } else {
                setOperationState(operation, "permission_denied")
                setError(
                    if (isRuntimePermission(missingPermission)) {
                        "permission_settings_required"
                    } else {
                        "manifest_permission_unavailable"
                    },
                    permissionDenialMessage(
                        operation,
                        missingPermission,
                        canRequest(missingPermission),
                    ),
                )
                result.success(statusSnapshot())
                emitStatus()
            }
            return
        }

        startOperationNow(operation, adapter, result)
    }

    private fun requestPermission(
        operation: Operation,
        permission: String,
        result: MethodChannel.Result,
    ) {
        pendingPermission = PendingPermission(operation, permission, result)
        setOperationState(operation, "requesting_permission")
        clearError()
        message = permissionRequestMessage(operation, permission)
        emitStatus()
        try {
            activity.requestPermissions(arrayOf(permission), PERMISSION_REQUEST_CODE)
        } catch (_: RuntimeException) {
            pendingPermission = null
            setOperationState(operation, "failed")
            setError(
                "permission_request_failed",
                "Android could not open the required permission prompt. Check app permissions in Settings.",
            )
            result.success(statusSnapshot())
            emitStatus()
        }
    }

    private fun startOperationNow(
        operation: Operation,
        adapter: BluetoothAdapter,
        result: MethodChannel.Result,
    ) {
        if (destroyed || !activityResumed || eventSink == null) {
            setOperationState(operation, "unavailable")
            setError(
                "foreground_required",
                "Discovery can run only while DumanMessenger is visible in the foreground.",
            )
            result.success(statusSnapshot())
            emitStatus()
            return
        }

        val missingPermission = requiredPermissions(operation)
            .firstOrNull { !hasPermission(it) }
        if (missingPermission != null) {
            setOperationState(operation, "permission_denied")
            val canAskAgain = isRuntimePermission(missingPermission) &&
                canRequest(missingPermission)
            setError(
                if (canAskAgain) "permission_denied" else "permission_settings_required",
                permissionDenialMessage(operation, missingPermission, canAskAgain),
            )
            result.success(statusSnapshot())
            emitStatus()
            return
        }

        clearError()
        when (operation) {
            Operation.ADVERTISING -> startAdvertising(adapter, result)
            Operation.SCANNING -> startScanning(adapter, result)
        }
    }

    private fun startAdvertising(adapter: BluetoothAdapter, result: MethodChannel.Result) {
        val advertiser = try {
            adapter.bluetoothLeAdvertiser
        } catch (_: SecurityException) {
            null
        }
        if (advertiser == null) {
            setOperationState(Operation.ADVERTISING, "unavailable")
            setError(
                "advertiser_unavailable",
                "BLE advertising is unavailable. Bluetooth may be off or this adapter may not support advertising.",
            )
            result.success(statusSnapshot())
            emitStatus()
            return
        }

        val callback = object : AdvertiseCallback() {
            override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
                if (advertiseCallback !== this || destroyed || !activityResumed) {
                    try {
                        advertiser.stopAdvertising(this)
                    } catch (_: RuntimeException) {
                        // A stale callback must never keep advertising active.
                    }
                    return
                }
                setOperationState(Operation.ADVERTISING, "active")
                clearError()
                emitStatus()
            }

            override fun onStartFailure(errorCode: Int) {
                if (advertiseCallback !== this) return
                advertiseCallback = null
                activeAdvertiser = null
                setOperationState(Operation.ADVERTISING, "failed")
                setError(
                    "advertising_failed",
                    "Android could not start BLE advertising. Check adapter availability and try again.",
                )
                emitStatus()
            }
        }

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_POWER)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_LOW)
            .setConnectable(false)
            .setTimeout(0)
            .build()
        val data = AdvertiseData.Builder()
            .addServiceUuid(SERVICE_PARCEL_UUID)
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .build()

        activeAdvertiser = advertiser
        advertiseCallback = callback
        setOperationState(Operation.ADVERTISING, "starting")
        try {
            advertiser.startAdvertising(settings, data, callback)
            emitStatus()
            result.success(statusSnapshot())
        } catch (_: SecurityException) {
            advertiseCallback = null
            activeAdvertiser = null
            setOperationState(Operation.ADVERTISING, "permission_denied")
            setError(
                "permission_denied",
                "Advertising permission is unavailable. Allow Nearby devices permission and try again.",
            )
            result.success(statusSnapshot())
            emitStatus()
        } catch (_: RuntimeException) {
            advertiseCallback = null
            activeAdvertiser = null
            setOperationState(Operation.ADVERTISING, "failed")
            setError(
                "advertising_failed",
                "Android could not start BLE advertising on this adapter.",
            )
            result.success(statusSnapshot())
            emitStatus()
        }
    }

    private fun startScanning(adapter: BluetoothAdapter, result: MethodChannel.Result) {
        val scanner = try {
            adapter.bluetoothLeScanner
        } catch (_: SecurityException) {
            null
        }
        if (scanner == null) {
            setOperationState(Operation.SCANNING, "unavailable")
            setError(
                "scanner_unavailable",
                "BLE scanning is unavailable. Bluetooth may be off or this adapter may not support scanning.",
            )
            result.success(statusSnapshot())
            emitStatus()
            return
        }

        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                acceptScanResult(this, result)
            }

            override fun onBatchScanResults(results: MutableList<ScanResult>) {
                results.forEach { acceptScanResult(this, it) }
            }

            override fun onScanFailed(errorCode: Int) {
                if (scanCallback !== this) return
                scanCallback = null
                activeScanner = null
                setOperationState(Operation.SCANNING, "failed")
                setError(
                    "scanning_failed",
                    "Android stopped BLE scanning unexpectedly. Check permissions and adapter availability.",
                )
                emitStatus()
            }
        }

        val filters = listOf(
            ScanFilter.Builder()
                .setServiceUuid(SERVICE_PARCEL_UUID)
                .build(),
        )
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()

        activeScanner = scanner
        scanCallback = callback
        setOperationState(Operation.SCANNING, "starting")
        try {
            scanner.startScan(filters, settings, callback)
            if (scanCallback === callback && scanningState == "starting") {
                setOperationState(Operation.SCANNING, "active")
            }
            emitStatus()
            result.success(statusSnapshot())
        } catch (_: SecurityException) {
            scanCallback = null
            activeScanner = null
            setOperationState(Operation.SCANNING, "permission_denied")
            setError(
                "permission_denied",
                "The scan permission is unavailable. Allow the requested permission and start scanning again.",
            )
            result.success(statusSnapshot())
            emitStatus()
        } catch (_: RuntimeException) {
            scanCallback = null
            activeScanner = null
            setOperationState(Operation.SCANNING, "failed")
            setError(
                "scanning_failed",
                "Android could not start BLE scanning on this adapter.",
            )
            result.success(statusSnapshot())
            emitStatus()
        }
    }

    private fun acceptScanResult(callback: ScanCallback, result: ScanResult) {
        if (scanCallback !== callback ||
            (scanningState != "active" && scanningState != "starting") ||
            destroyed || !activityResumed
        ) {
            return
        }
        val serviceUuids = result.scanRecord?.serviceUuids ?: return
        if (!serviceUuids.contains(SERVICE_PARCEL_UUID)) return
        if (scanningState == "starting") {
            setOperationState(Operation.SCANNING, "active")
        }

        val device = result.device
        if (discoveredDevices.containsKey(device)) return
        nextResultId += 1
        discoveredDevices[device] = "result-$nextResultId"
        clearError()
        emitStatus()
    }

    private fun stopOperation(operation: Operation, result: MethodChannel.Result) {
        cancelPendingPermission(operation)
        when (operation) {
            Operation.ADVERTISING -> stopAdvertisingInternal()
            Operation.SCANNING -> stopScanningInternal(clearResults = false)
        }
        setOperationState(operation, "idle")
        clearError()
        emitStatus()
        result.success(statusSnapshot())
    }

    private fun stopActiveOperations(clearResults: Boolean) {
        stopAdvertisingInternal()
        stopScanningInternal(clearResults)
        if (pendingPermission?.operation != Operation.ADVERTISING) {
            advertisingState = "idle"
        }
        if (pendingPermission?.operation != Operation.SCANNING) {
            scanningState = "idle"
        }
        if (clearResults) {
            discoveredDevices.clear()
            nextResultId = 0
        }
    }

    private fun stopAdvertisingInternal() {
        val advertiser = activeAdvertiser
        val callback = advertiseCallback
        activeAdvertiser = null
        advertiseCallback = null
        if (advertiser != null && callback != null) {
            try {
                advertiser.stopAdvertising(callback)
            } catch (_: RuntimeException) {
                // Stop remains idempotent even if Android already stopped the advertiser.
            }
        }
        if (advertisingState == "active" || advertisingState == "starting") {
            advertisingState = "idle"
        }
    }

    private fun stopScanningInternal(clearResults: Boolean) {
        val scanner = activeScanner
        val callback = scanCallback
        activeScanner = null
        scanCallback = null
        if (scanner != null && callback != null) {
            try {
                scanner.stopScan(callback)
            } catch (_: RuntimeException) {
                // Stop remains idempotent even if Android already stopped the scanner.
            }
        }
        if (scanningState == "active" || scanningState == "starting") {
            scanningState = "idle"
        }
        if (clearResults) {
            discoveredDevices.clear()
            nextResultId = 0
        }
    }

    private fun cancelPendingPermission(operation: Operation? = null) {
        val pending = pendingPermission ?: return
        if (operation != null && pending.operation != operation) return
        pendingPermission = null
        setOperationState(pending.operation, "idle")
        pending.result.success(statusSnapshot())
    }

    private fun adapterFor(operation: Operation): BluetoothAdapter? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) {
            setOperationState(operation, "unsupported")
            setError(
                "ble_api_unsupported",
                "This Android version does not provide the required foreground BLE APIs.",
            )
            return null
        }
        if (!activity.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)) {
            setOperationState(operation, "unsupported")
            setError(
                "ble_hardware_unsupported",
                "This device does not report Bluetooth LE hardware support.",
            )
            return null
        }

        val manager = activity.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        if (manager == null) {
            setOperationState(operation, "unavailable")
            setError(
                "bluetooth_service_unavailable",
                "The Android Bluetooth service is unavailable.",
            )
            return null
        }
        val adapter = try {
            manager.adapter
        } catch (_: SecurityException) {
            null
        }
        if (adapter == null) {
            setOperationState(operation, "unavailable")
            setError(
                "adapter_unavailable",
                "The Bluetooth adapter is unavailable. Check Bluetooth in Android settings.",
            )
            return null
        }
        return adapter
    }

    private fun requiredPermissions(operation: Operation): List<String> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            return listOf(
                if (operation == Operation.SCANNING) {
                    Manifest.permission.BLUETOOTH_SCAN
                } else {
                    Manifest.permission.BLUETOOTH_ADVERTISE
                },
            )
        }

        val permissions = mutableListOf(
            Manifest.permission.BLUETOOTH,
            Manifest.permission.BLUETOOTH_ADMIN,
        )
        if (operation == Operation.SCANNING) {
            permissions.add(Manifest.permission.ACCESS_FINE_LOCATION)
        }
        return permissions
    }

    private fun permissionReports(): List<Map<String, Any?>> {
        val modern = Build.VERSION.SDK_INT >= Build.VERSION_CODES.S
        val legacy = Build.VERSION.SDK_INT <= Build.VERSION_CODES.R
        return listOf(
            permissionReport(
                Manifest.permission.BLUETOOTH_SCAN,
                applicable = modern,
                requiredForScanning = modern,
                requiredForAdvertising = false,
                runtime = modern,
            ),
            permissionReport(
                Manifest.permission.BLUETOOTH_ADVERTISE,
                applicable = modern,
                requiredForScanning = false,
                requiredForAdvertising = modern,
                runtime = modern,
            ),
            permissionReport(
                Manifest.permission.BLUETOOTH_CONNECT,
                applicable = modern,
                requiredForScanning = false,
                requiredForAdvertising = false,
                runtime = modern,
            ),
            permissionReport(
                Manifest.permission.BLUETOOTH,
                applicable = legacy,
                requiredForScanning = legacy,
                requiredForAdvertising = legacy,
                runtime = false,
            ),
            permissionReport(
                Manifest.permission.BLUETOOTH_ADMIN,
                applicable = legacy,
                requiredForScanning = legacy,
                requiredForAdvertising = legacy,
                runtime = false,
            ),
            permissionReport(
                Manifest.permission.ACCESS_FINE_LOCATION,
                applicable = legacy,
                requiredForScanning = legacy,
                requiredForAdvertising = false,
                runtime = legacy && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M,
            ),
        )
    }

    private fun permissionReport(
        permission: String,
        applicable: Boolean,
        requiredForScanning: Boolean,
        requiredForAdvertising: Boolean,
        runtime: Boolean,
    ): Map<String, Any?> {
        val granted = applicable && hasPermission(permission)
        val state = when {
            !applicable -> "not_required"
            granted -> "granted"
            else -> "denied"
        }
        val shouldShowRationale = applicable && runtime && !granted &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
            try {
                activity.shouldShowRequestPermissionRationale(permission)
            } catch (_: RuntimeException) {
                false
            }
        val canAskAgain = (requiredForScanning || requiredForAdvertising) &&
            runtime && !granted && canRequest(permission)

        return mapOf(
            "name" to permission,
            "state" to state,
            "requiredForScanning" to requiredForScanning,
            "requiredForAdvertising" to requiredForAdvertising,
            "runtime" to runtime,
            "canRequestAgain" to canAskAgain,
            "shouldShowRationale" to shouldShowRationale,
        )
    }

    private fun statusSnapshot(): Map<String, Any?> {
        val hasBleHardware = activity.packageManager.hasSystemFeature(
            PackageManager.FEATURE_BLUETOOTH_LE,
        )
        val manager = activity.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        var adapterReadDenied = false
        val adapter = try {
            manager?.adapter
        } catch (_: SecurityException) {
            adapterReadDenied = true
            null
        }
        val permissions = permissionReports()
        val adapterAvailable: Boolean? = when {
            !hasBleHardware || manager == null -> false
            adapterReadDenied -> null
            else -> adapter != null
        }
        val connectGranted = Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            hasPermission(Manifest.permission.BLUETOOTH_CONNECT)
        val adapterEnabled = if (adapter == null || !connectGranted) {
            null
        } else {
            try {
                adapter.isEnabled
            } catch (_: SecurityException) {
                null
            }
        }

        val scannerPermission = runtimePermissionFor(Operation.SCANNING)
        val scanPermissionGranted = scannerPermission == null || hasPermission(scannerPermission)
        val advertiserPermission = runtimePermissionFor(Operation.ADVERTISING)
        val advertisePermissionGranted =
            advertiserPermission == null || hasPermission(advertiserPermission)

        val scannerAvailable: Boolean? = when {
            Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP -> false
            !hasBleHardware || manager == null -> false
            adapterReadDenied -> null
            adapter == null -> false
            !scanPermissionGranted -> null
            else -> try {
                adapter.bluetoothLeScanner != null
            } catch (_: SecurityException) {
                null
            }
        }
        val advertiserAvailable: Boolean? = when {
            Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP -> false
            !hasBleHardware || manager == null -> false
            adapterReadDenied -> null
            adapter == null -> false
            !advertisePermissionGranted -> null
            else -> try {
                adapter.bluetoothLeAdvertiser != null
            } catch (_: SecurityException) {
                null
            }
        }

        return mapOf(
            "apiLevel" to Build.VERSION.SDK_INT,
            "bleHardwareSupported" to hasBleHardware,
            "adapterAvailable" to adapterAvailable,
            "adapterEnabled" to adapterEnabled,
            "advertiserAvailable" to advertiserAvailable,
            "scannerAvailable" to scannerAvailable,
            "advertisingState" to advertisingState,
            "scanningState" to scanningState,
            "permissions" to permissions,
            "results" to discoveredDevices.values.map { sessionId ->
                mapOf("sessionId" to sessionId)
            },
            "errorCode" to errorCode,
            "message" to message,
        )
    }

    private fun runtimePermissionFor(operation: Operation): String? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            return if (operation == Operation.SCANNING) {
                Manifest.permission.BLUETOOTH_SCAN
            } else {
                Manifest.permission.BLUETOOTH_ADVERTISE
            }
        }
        return if (operation == Operation.SCANNING &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.M
        ) {
            Manifest.permission.ACCESS_FINE_LOCATION
        } else {
            null
        }
    }

    private fun isRuntimePermission(permission: String): Boolean =
        (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            (permission == Manifest.permission.BLUETOOTH_SCAN ||
                permission == Manifest.permission.BLUETOOTH_ADVERTISE ||
                permission == Manifest.permission.BLUETOOTH_CONNECT)) ||
            (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M &&
                permission == Manifest.permission.ACCESS_FINE_LOCATION)

    private fun hasPermission(permission: String): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        return try {
            activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
        } catch (_: RuntimeException) {
            false
        }
    }

    private fun canRequest(permission: String): Boolean {
        if (!isRuntimePermission(permission)) return false
        val previouslyDenied = permissionHistory.getBoolean(denialHistoryKey(permission), false)
        val showRationale = try {
            activity.shouldShowRequestPermissionRationale(permission)
        } catch (_: RuntimeException) {
            false
        }
        return !previouslyDenied || showRationale
    }

    private fun permissionRequestMessage(operation: Operation, permission: String): String =
        when (permission) {
            Manifest.permission.ACCESS_FINE_LOCATION ->
                "Android 6–11 requires foreground location permission to scan for BLE. " +
                    "DumanMessenger does not read or store location data."
            Manifest.permission.BLUETOOTH_SCAN ->
                "Allow Nearby devices scan permission to find the DumanMessenger service UUID."
            Manifest.permission.BLUETOOTH_ADVERTISE ->
                "Allow Nearby devices advertising permission to advertise the DumanMessenger service UUID."
            else -> "Allow the Android permission required to start BLE ${operationLabel(operation)}."
        }

    private fun permissionDenialMessage(
        operation: Operation,
        permission: String,
        canAskAgain: Boolean,
    ): String {
        val purpose = when (permission) {
            Manifest.permission.ACCESS_FINE_LOCATION ->
                "Foreground location permission is required by Android 6–11 for BLE scanning; no location data is accessed."
            Manifest.permission.BLUETOOTH_SCAN ->
                "Nearby devices scan permission is required to scan for the DumanMessenger service UUID."
            Manifest.permission.BLUETOOTH_ADVERTISE ->
                "Nearby devices advertising permission is required to advertise the service UUID."
            else -> "An Android Bluetooth permission is required for ${operationLabel(operation)}."
        }
        return if (canAskAgain) {
            "$purpose Allow it and start ${operationLabel(operation)} again."
        } else {
            "$purpose Allow it in Android app settings, then return and start again. " +
                "DumanMessenger will not open Settings automatically."
        }
    }

    private fun operationLabel(operation: Operation): String = when (operation) {
        Operation.ADVERTISING -> "advertising"
        Operation.SCANNING -> "scanning"
    }

    private fun setOperationState(operation: Operation, state: String) {
        when (operation) {
            Operation.ADVERTISING -> advertisingState = state
            Operation.SCANNING -> scanningState = state
        }
    }

    private fun isRunning(operation: Operation): Boolean = when (operation) {
        Operation.ADVERTISING -> advertisingState == "starting" || advertisingState == "active"
        Operation.SCANNING -> scanningState == "starting" || scanningState == "active"
    }

    private fun setError(code: String, detail: String) {
        errorCode = code
        message = detail
    }

    private fun clearError() {
        errorCode = null
        message = null
    }

    private fun denialHistoryKey(permission: String): String = "denied:$permission"

    private fun emitStatus() {
        if (destroyed) return
        try {
            eventSink?.success(statusSnapshot())
        } catch (_: RuntimeException) {
            eventSink = null
            stopActiveOperations(clearResults = true)
            updateReceiverRegistration()
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
}
