package com.example.duman_messenger

import android.Manifest
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import java.util.UUID

/** Foreground-requested, UUID-filtered G2-C scan. Random tokens are not peer identities. */
internal class G2cBleDiscovery(
    private val context: Context,
    private val onChanged: () -> Unit,
) {
    companion object {
        private const val SCAN_TIMEOUT_MS = 20_000L
        private const val MAX_CANDIDATES = 32
    }
    private val manager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val handler = Handler(Looper.getMainLooper())
    private val candidates = LinkedHashMap<String, BluetoothDevice>()
    private var activeScanner: android.bluetooth.le.BluetoothLeScanner? = null
    private var timeout: Runnable? = null
    var state: String = "idle"
        private set
    var errorCode: String? = null
        private set

    fun start(): Boolean {
        if (activeScanner != null) return false
        val required = if (Build.VERSION.SDK_INT >= 31) Manifest.permission.BLUETOOTH_SCAN else Manifest.permission.ACCESS_FINE_LOCATION
        if (Build.VERSION.SDK_INT >= 23 && context.checkSelfPermission(required) != PackageManager.PERMISSION_GRANTED) {
            state = "permission_denied"; errorCode = "permission_required"; onChanged(); return false
        }
        val adapter = try { manager?.adapter } catch (_: SecurityException) { null }
        if (adapter == null) {
            state = "unsupported"; errorCode = "adapter_unavailable"; onChanged(); return false
        }
        // Avoid reading adapter.isEnabled here: Android 12 gates that getter on CONNECT permission.
        val target = try { adapter.bluetoothLeScanner } catch (_: SecurityException) { null }
        if (target == null) {
            // Android may expose no scanner when the radio is disabled. Avoid claiming
            // unsupported hardware when BLE capability was already established.
            state = "failed"; errorCode = "bluetooth_unavailable"; onChanged(); return false
        }
        candidates.clear()
        errorCode = null
        activeScanner = target
        state = "scanning"
        onChanged()
        return try {
            target.startScan(
                listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(G2cGattProtocol.SERVICE_UUID)).build()),
                ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(),
                callback,
            )
            timeout = Runnable { stop("scan_timeout") }.also { handler.postDelayed(it, SCAN_TIMEOUT_MS) }
            true
        } catch (_: SecurityException) {
            state = "permission_denied"; errorCode = "permission_required"; activeScanner = null; onChanged(); false
        } catch (_: RuntimeException) {
            state = "failed"; errorCode = "scan_failed"; activeScanner = null; onChanged(); false
        }
    }

    fun stop(error: String? = null) {
        timeout?.let(handler::removeCallbacks); timeout = null
        val active = activeScanner
        activeScanner = null
        if (active != null) try { active.stopScan(callback) } catch (_: SecurityException) { /* clear local state */ }
        state = when {
            error == "scan_timeout" -> "timed_out"
            error == null -> "idle"
            else -> "failed"
        }
        errorCode = error
        onChanged()
    }

    fun contains(token: String): Boolean = candidates.containsKey(token)

    fun take(token: String): BluetoothDevice? {
        val selected = candidates[token] ?: return null
        stop()
        candidates.clear()
        onChanged()
        return selected
    }
    fun clear() { stop(); candidates.clear(); onChanged() }
    fun results(): List<String> = candidates.keys.toList()

    private val callback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) = accept(result)
        override fun onBatchScanResults(results: MutableList<ScanResult>) { results.forEach(::accept) }
        override fun onScanFailed(errorCode: Int) {
            if (activeScanner == null) return
            stop("scan_failed_$errorCode")
            state = "failed"
            onChanged()
        }
        private fun accept(result: ScanResult) {
            if (activeScanner == null || candidates.size >= MAX_CANDIDATES) return
            // BluetoothDevice equality deduplicates transient objects without emitting identifiers.
            if (candidates.values.contains(result.device)) return
            candidates[UUID.randomUUID().toString()] = result.device
            state = "results"
            onChanged()
        }
    }
}
