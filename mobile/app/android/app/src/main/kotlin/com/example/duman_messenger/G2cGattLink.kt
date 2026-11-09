package com.example.duman_messenger

import android.Manifest
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.util.concurrent.atomic.AtomicBoolean

/**
 * G2-C TEST-ONLY client-side GATT lifecycle. Connected is explicitly unauthenticated.
 * This class does not send payloads and does not establish a cryptographic session.
 */
internal class G2cGattLink(
    context: Context,
    private val onState: (G2cLinkSnapshot) -> Unit,
    private val onMessage: (G2cGattProtocol.Frame) -> Unit = {},
) {
    companion object {
        private const val CONNECT_TIMEOUT_MS = 15_000L
        private const val DISCOVERY_TIMEOUT_MS = 10_000L
        private const val TRANSPORT_TIMEOUT_MS = 15_000L
    }

    private val appContext = context.applicationContext
    private val handler = Handler(Looper.getMainLooper())
    private val closed = AtomicBoolean(false)
    private var gatt: BluetoothGatt? = null
    @Volatile private var snapshot = G2cLinkSnapshot()
    private var timeout: Runnable? = null
    private var negotiatedMtu = 23
    private var outbound: List<ByteArray>? = null
    private var outboundIndex = 0
    private var nextMessageId = 1
    private var serviceDiscoveryHandled = false
    private var descriptorWritePending = false
    private var pendingWriteIndex: Int? = null
    private val reassembler = G2cFragmentReassembler(
        onComplete = { message ->
            try { onMessage(G2cGattProtocol.decode(message)) }
            catch (_: IllegalArgumentException) { fail("protocol_error") }
        },
        onError = { code -> fail(code) },
    )

    fun snapshot(): G2cLinkSnapshot = snapshot

    val isTransportBusy: Boolean get() = outbound != null

    @Synchronized
    fun connect(device: BluetoothDevice): Boolean {
        if (!hasConnectPermission()) {
            fail("permission_required")
            return false
        }
        if (gatt != null || snapshot.state !in setOf(G2cLinkState.DISCONNECTED, G2cLinkState.CONNECTION_FAILED, G2cLinkState.PERMISSION_DENIED, G2cLinkState.TIMED_OUT, G2cLinkState.PROTOCOL_ERROR)) {
            fail("operation_in_progress")
            return false
        }
        closed.set(false)
        serviceDiscoveryHandled = false
        descriptorWritePending = false
        pendingWriteIndex = null
        negotiatedMtu = 23
        reassembler.clear()
        outbound = null
        outboundIndex = 0
        publish(G2cLinkSnapshot(G2cLinkState.CONNECTING))
        armTimeout(CONNECT_TIMEOUT_MS, "connection_timeout")
        try {
            // This overload exists on API 27; autoConnect=false avoids background connection scans.
            gatt = device.connectGatt(appContext, false, callback, BluetoothDevice.TRANSPORT_LE)
            if (gatt == null) fail("gatt_unavailable")
        } catch (_: SecurityException) {
            fail("permission_required")
        } catch (_: RuntimeException) {
            fail("connection_failed")
        }
        return gatt != null
    }

    @Synchronized
    fun close() {
        if (closed.getAndSet(true)) return
        cancelTimeout()
        reassembler.clear()
        outbound = null
        outboundIndex = 0
        pendingWriteIndex = null
        descriptorWritePending = false
        val active = gatt
        gatt = null
        publish(G2cLinkSnapshot(G2cLinkState.DISCONNECTING))
        if (active != null && hasConnectPermission()) {
            try { active.disconnect() } catch (_: SecurityException) { /* cleanup continues */ }
            try { active.close() } catch (_: RuntimeException) { /* cleanup continues */ }
        } else {
            try { active?.close() } catch (_: RuntimeException) { /* cleanup continues */ }
        }
        publish(G2cLinkSnapshot(G2cLinkState.DISCONNECTED))
    }

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (closed.get() || this@G2cGattLink.gatt !== gatt) return
            if (status != BluetoothGatt.GATT_SUCCESS) {
                fail("gatt_connection_error")
                return
            }
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    if (snapshot.state != G2cLinkState.CONNECTING) return
                    publish(G2cLinkSnapshot(G2cLinkState.CONNECTED_UNAUTHENTICATED))
                    armTimeout(DISCOVERY_TIMEOUT_MS, "service_discovery_timeout")
                    try {
                        if (!gatt.discoverServices()) fail("service_discovery_failed")
                    } catch (_: SecurityException) {
                        fail("permission_required")
                    }
                }
                BluetoothProfile.STATE_DISCONNECTED -> disconnectFromRemote()
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (closed.get() || this@G2cGattLink.gatt !== gatt ||
                snapshot.state != G2cLinkState.CONNECTED_UNAUTHENTICATED || serviceDiscoveryHandled
            ) return
            serviceDiscoveryHandled = true
            cancelTimeout()
            if (status != BluetoothGatt.GATT_SUCCESS) {
                fail("service_discovery_failed")
                return
            }
            val service = gatt.getService(G2cGattProtocol.SERVICE_UUID)
            val characteristic = service?.getCharacteristic(G2cGattProtocol.DATA_CHARACTERISTIC_UUID)
            val required = BluetoothGattCharacteristic.PROPERTY_WRITE or
                BluetoothGattCharacteristic.PROPERTY_NOTIFY
            if (service == null || characteristic == null ||
                characteristic.properties and required != required
            ) {
                fail("g2c_service_mismatch")
                return
            }
            val descriptor = characteristic.getDescriptor(G2cGattProtocol.CLIENT_CONFIGURATION_UUID)
            if (descriptor == null || !gatt.setCharacteristicNotification(characteristic, true)) {
                fail("notification_setup_failed")
                return
            }
            descriptor.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
            armTimeout(DISCOVERY_TIMEOUT_MS, "notification_setup_timeout")
            descriptorWritePending = true
            try {
                if (!gatt.writeDescriptor(descriptor)) {
                    descriptorWritePending = false
                    fail("notification_setup_failed")
                }
            } catch (_: SecurityException) {
                fail("permission_required")
            }
        }
        override fun onDescriptorWrite(
            gatt: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int,
        ) {
            if (closed.get() || this@G2cGattLink.gatt !== gatt ||
                descriptor.uuid != G2cGattProtocol.CLIENT_CONFIGURATION_UUID || !descriptorWritePending
            ) return
            descriptorWritePending = false
            if (status != BluetoothGatt.GATT_SUCCESS) fail("notification_setup_failed")
            else {
                cancelTimeout()
                publish(G2cLinkSnapshot(G2cLinkState.SERVICE_READY))
                try { gatt.requestMtu(247) } catch (_: SecurityException) { fail("permission_required") }
            }
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            if (closed.get() || this@G2cGattLink.gatt !== gatt) return
            if (status == BluetoothGatt.GATT_SUCCESS && mtu >= 23) negotiatedMtu = mtu.coerceAtMost(517)
            // Negotiation failure safely retains the mandatory ATT default MTU of 23.
        }

        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            if (closed.get() || this@G2cGattLink.gatt !== gatt || snapshot.state != G2cLinkState.SERVICE_READY ||
                characteristic.uuid != G2cGattProtocol.DATA_CHARACTERISTIC_UUID) return
            val value = characteristic.value?.copyOf() ?: run { fail("protocol_error"); return }
            reassembler.accept(value, negotiatedMtu)
        }

        override fun onCharacteristicWrite(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            if (closed.get() || this@G2cGattLink.gatt !== gatt ||
                characteristic.uuid != G2cGattProtocol.DATA_CHARACTERISTIC_UUID ||
                pendingWriteIndex != outboundIndex || outbound == null
            ) return
            pendingWriteIndex = null
            if (status != BluetoothGatt.GATT_SUCCESS) { outbound = null; fail("gatt_write_failed"); return }
            outboundIndex++
            if (outboundIndex < (outbound?.size ?: 0)) armTimeout(TRANSPORT_TIMEOUT_MS, "transport_write_timeout")
            writeNextFragment()
        }
    }

    @Synchronized
    fun sendFrame(type: Int, payload: ByteArray): Boolean {
        if (closed.get() || snapshot.state != G2cLinkState.SERVICE_READY || outbound != null) return false
        val frame = try { G2cGattProtocol.encode(type, payload) }
        catch (_: IllegalArgumentException) { return false }
        return try {
            outbound = G2cFragmentation.split(frame, negotiatedMtu, nextMessageId)
            nextMessageId = (nextMessageId + 1) and 0xffff
            outboundIndex = 0
            armTimeout(TRANSPORT_TIMEOUT_MS, "transport_write_timeout")
            writeNextFragment()
        } catch (_: IllegalArgumentException) { outbound = null; false }
    }

    @Synchronized
    private fun writeNextFragment(): Boolean {
        val fragments = outbound ?: return true
        if (outboundIndex >= fragments.size) {
            outbound = null
            outboundIndex = 0
            cancelTimeout()
            return true
        }
        val active = gatt ?: return false
        val characteristic = active.getService(G2cGattProtocol.SERVICE_UUID)
            ?.getCharacteristic(G2cGattProtocol.DATA_CHARACTERISTIC_UUID) ?: return false
        characteristic.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        characteristic.value = fragments[outboundIndex]
        pendingWriteIndex = outboundIndex
        return try {
            if (!active.writeCharacteristic(characteristic)) {
                pendingWriteIndex = null
                outbound = null
                fail("gatt_write_failed")
                false
            } else true
        } catch (_: SecurityException) { pendingWriteIndex = null; outbound = null; fail("permission_required"); false }
    }

    private fun armTimeout(delay: Long, code: String) {
        cancelTimeout()
        timeout = Runnable { fail(code) }.also { handler.postDelayed(it, delay) }
    }

    private fun cancelTimeout() {
        timeout?.let(handler::removeCallbacks)
        timeout = null
    }

    private fun disconnectFromRemote() {
        if (closed.getAndSet(true)) return
        cancelTimeout()
        reassembler.clear()
        outbound = null
        outboundIndex = 0
        negotiatedMtu = 23
        val active = gatt
        gatt = null
        try { active?.close() } catch (_: RuntimeException) { /* cleanup continues */ }
        publish(G2cLinkSnapshot(G2cLinkState.DISCONNECTED))
    }

    private fun fail(code: String) {
        if (closed.getAndSet(true)) return
        cancelTimeout()
        reassembler.clear()
        outbound = null
        outboundIndex = 0
        negotiatedMtu = 23
        val active = gatt
        gatt = null
        try { active?.close() } catch (_: RuntimeException) { /* fail closed */ }
        publish(G2cLinkSnapshot(failureState(code), code))
    }

    private fun failureState(code: String): G2cLinkState = when {
        code.contains("permission") -> G2cLinkState.PERMISSION_DENIED
        code.contains("timeout") -> G2cLinkState.TIMED_OUT
        code.contains("service_mismatch") || code.contains("protocol") ||
            code.contains("fragment") || code.contains("truncated") ||
            code.startsWith("invalid_") -> G2cLinkState.PROTOCOL_ERROR
        else -> G2cLinkState.CONNECTION_FAILED
    }

    private fun publish(value: G2cLinkSnapshot) {
        snapshot = value
        handler.post { onState(value) }
    }

    private fun hasConnectPermission(): Boolean = Build.VERSION.SDK_INT < 31 ||
        appContext.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) ==
        PackageManager.PERMISSION_GRANTED
}

/** Shared G2-C GATT server schema; advertising is started only by explicit server start. */
internal fun createG2cGattService(): BluetoothGattService = BluetoothGattService(
    G2cGattProtocol.SERVICE_UUID,
    BluetoothGattService.SERVICE_TYPE_PRIMARY,
).apply {
    val data = BluetoothGattCharacteristic(
        G2cGattProtocol.DATA_CHARACTERISTIC_UUID,
        BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_NOTIFY,
        BluetoothGattCharacteristic.PERMISSION_WRITE,
    )
    data.addDescriptor(BluetoothGattDescriptor(
        G2cGattProtocol.CLIENT_CONFIGURATION_UUID,
        BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE,
    ))
    addCharacteristic(data)
}
