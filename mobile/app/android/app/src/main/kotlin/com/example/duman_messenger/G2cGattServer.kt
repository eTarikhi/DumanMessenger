package com.example.duman_messenger

import android.Manifest
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.BluetoothLeAdvertiser
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper

/** G2-C TEST-ONLY peripheral role. It never authenticates or auto-trusts a connected device. */
internal class G2cGattServer(
    context: Context,
    private val onState: (G2cLinkSnapshot) -> Unit,
    private val onFrame: (G2cGattProtocol.Frame) -> Unit,
    /** Bounded, privacy-safe transport diagnostics: no addresses, keys, or payloads. */
    private val onEvent: (String, String?) -> Unit = { _, _ -> },
) {
    companion object {
        private const val CONNECT_TIMEOUT_MS = 30_000L
        private const val SERVICE_TIMEOUT_MS = 10_000L
        private const val TRANSPORT_TIMEOUT_MS = 15_000L
    }

    private val appContext = context.applicationContext
    private val manager = appContext.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val handler = Handler(Looper.getMainLooper())
    private var server: BluetoothGattServer? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var advertiseCallback: AdvertiseCallback? = null
    private var peer: BluetoothDevice? = null
    private var mtu = 23
    private var subscribed = false
    private var serviceReady = false
    private var timeout: Runnable? = null
    private var outbound: List<ByteArray>? = null
    private var outboundIndex = 0
    private var pendingNotificationIndex: Int? = null
    private var serviceAdded = false
    private var nextMessageId = 1
    private var destroyed = false
    val isRunning: Boolean get() = server != null
    /** True only while an accepted GATT client is connected to this test peripheral. */
    val hasConnectedPeer: Boolean get() = peer != null
    /** True only after the service is registered and the client subscribed to notifications. */
    val isSubscriptionReady: Boolean get() = serviceAdded && serviceReady && subscribed
    val isTransportBusy: Boolean get() = outbound != null
    private val reassembler = G2cFragmentReassembler(
        onComplete = { bytes ->
            try { onFrame(G2cGattProtocol.decode(bytes)) }
            catch (_: IllegalArgumentException) { fail("protocol_error") }
        },
        onError = { code -> fail(code) },
    )

    @Synchronized
    fun start(): Boolean {
        if (destroyed || server != null) return false
        if (!hasConnectPermission() || !hasAdvertisePermission()) {
            publish("permission_required", G2cLinkState.PERMISSION_DENIED); return false
        }
        if (!appContext.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE) || manager == null) {
            publish("ble_unavailable", G2cLinkState.UNSUPPORTED); return false
        }
        val adapter = try { manager.adapter } catch (_: SecurityException) { null }
        if (adapter == null || !adapter.isEnabled) { publish("bluetooth_unavailable", G2cLinkState.CONNECTION_FAILED); return false }
        val bleAdvertiser = try { adapter.bluetoothLeAdvertiser } catch (_: SecurityException) { null }
        if (bleAdvertiser == null) { publish("advertiser_unavailable", G2cLinkState.UNSUPPORTED); return false }
        advertiser = bleAdvertiser
        return try {
            val opened = manager.openGattServer(appContext, callback)
            if (opened == null) { publish("gatt_server_unavailable", G2cLinkState.UNSUPPORTED); false }
            else {
                server = opened
                serviceAdded = false
                pendingNotificationIndex = null
                armTimeout(SERVICE_TIMEOUT_MS, "service_registration_timeout")
                if (!opened.addService(createG2cGattService())) {
                    fail("service_registration_failed"); false
                } else true
            }
        } catch (_: SecurityException) {
            publish("permission_required", G2cLinkState.PERMISSION_DENIED); stop(); false
        } catch (_: RuntimeException) {
            publish("gatt_server_unavailable", G2cLinkState.UNSUPPORTED); stop(); false
        }
    }

    @Synchronized
    fun stop() {
        cancelTimeout()
        reassembler.clear()
        outbound = null
        outboundIndex = 0
        pendingNotificationIndex = null
        serviceAdded = false
        val active = server
        val connectedPeer = peer
        val activeAdvertiser = advertiser
        val callback = advertiseCallback
        server = null
        peer = null
        advertiser = null
        advertiseCallback = null
        serviceReady = false
        subscribed = false
        if (active != null && connectedPeer != null && hasConnectPermission()) {
            try { active.cancelConnection(connectedPeer) } catch (_: RuntimeException) { /* continue cleanup */ }
        }
        if (activeAdvertiser != null && callback != null) {
            try { activeAdvertiser.stopAdvertising(callback) } catch (_: SecurityException) { /* continue cleanup */ }
        }
        try { active?.clearServices() } catch (_: RuntimeException) { /* continue cleanup */ }
        try { active?.close() } catch (_: RuntimeException) { /* continue cleanup */ }
        publish(null, G2cLinkState.DISCONNECTED)
    }

    fun onDestroy() { destroyed = true; stop() }

    @Synchronized
    fun sendFrame(type: Int, payload: ByteArray): Boolean {
        val active = server ?: return false
        val target = peer ?: return false
        if (!serviceReady || !subscribed || outbound != null) return false
        val frame = try { G2cGattProtocol.encode(type, payload) }
        catch (_: IllegalArgumentException) { return false }
        return try {
            outbound = G2cFragmentation.split(frame, mtu, nextMessageId)
            nextMessageId = (nextMessageId + 1) and 0xffff
            outboundIndex = 0
            armTransportTimeout()
            notifyNext(active, target)
        } catch (_: IllegalArgumentException) { outbound = null; false }
    }

    private val callback = object : BluetoothGattServerCallback() {
        override fun onServiceAdded(status: Int, service: BluetoothGattService) {
            if (server == null || serviceAdded) return
            if (status != BluetoothGatt.GATT_SUCCESS || service.uuid != G2cGattProtocol.SERVICE_UUID) {
                fail("service_registration_failed"); return
            }
            serviceAdded = true
            onEvent("server_service_added", null)
            startAdvertising()
        }

        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (server == null) return
            onEvent("server_connection_callback", "status=$status,state=$newState")
            if (status != BluetoothGatt.GATT_SUCCESS || newState == BluetoothProfile.STATE_DISCONNECTED) {
                if (peer == device) {
                    onEvent("server_client_disconnected", "status=$status")
                    resetPeer()
                }
                return
            }
            if (newState != BluetoothProfile.STATE_CONNECTED) return
            // Ignore duplicate connected callbacks for the accepted peer; don't reset
            // service readiness or extend its connection deadline.
            if (peer == device) return
            val existing = peer
            if (existing != null) {
                // Only reject the new device while the previous peer is really still connected.
                // A stale reference left by a missed disconnect must not block new connections.
                if (peerConnected(existing) != false) {
                    onEvent("server_peer_rejected", "connected_peer_present")
                    try { server?.cancelConnection(device) } catch (_: SecurityException) { /* reject extra peer */ }
                    return
                }
                onEvent("server_stale_peer_cleared", null)
                resetPeer()
            }
            peer = device
            serviceReady = false
            subscribed = false
            mtu = 23
            armTimeout(CONNECT_TIMEOUT_MS, "connection_timeout")
            onEvent("server_client_connected", null)
            publish(null, G2cLinkState.CONNECTED_UNAUTHENTICATED)
        }

        override fun onMtuChanged(device: BluetoothDevice, mtuValue: Int) {
            if (peer == device && mtuValue >= 23) mtu = mtuValue.coerceAtMost(517)
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            if (peer != device || outbound == null ||
                pendingNotificationIndex == null || pendingNotificationIndex != outboundIndex - 1
            ) return
            pendingNotificationIndex = null
            if (status != BluetoothGatt.GATT_SUCCESS) { abortOutbound("notification_failed"); return }
            val active = server ?: return
            armTransportTimeout()
            notifyNext(active, device)
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice, requestId: Int, descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray,
        ) {
            val expected = descriptor.uuid == G2cGattProtocol.CLIENT_CONFIGURATION_UUID &&
                descriptor.characteristic.uuid == G2cGattProtocol.DATA_CHARACTERISTIC_UUID
            val validValue = value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) ||
                value.contentEquals(BluetoothGattDescriptor.DISABLE_NOTIFICATION_VALUE)
            val ok = peer == device && expected && !preparedWrite && offset == 0 && validValue
            onEvent("server_cccd_write_request", "accepted=$ok")
            if (responseNeeded) respond(device, requestId, if (ok) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_FAILURE, offset)
            if (!ok) { fail("protocol_error"); return }
            descriptor.value = value.copyOf()
            subscribed = value.contentEquals(BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
            if (subscribed) {
                serviceReady = true
                cancelTimeout()
                onEvent("server_subscription_ready", null)
                publish(null, G2cLinkState.SERVICE_READY)
            } else {
                serviceReady = false
                onEvent("server_subscription_disabled", null)
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice, requestId: Int, characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray,
        ) {
            val valid = peer == device && serviceReady &&
                characteristic.uuid == G2cGattProtocol.DATA_CHARACTERISTIC_UUID &&
                !preparedWrite && offset == 0 && value.size <= mtu - 3 &&
                value.size <= G2cFragmentation.HEADER_BYTES + 514
            if (responseNeeded) respond(device, requestId, if (valid) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_FAILURE, offset)
            if (!valid) { fail("protocol_error"); return }
            reassembler.accept(value.copyOf(), mtu)
        }
    }

    private val advertiserCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
            cancelTimeout()
            onEvent("server_advertising_started", null)
            // Re-advertising after a disconnect must not clobber a peer that already
            // connected while the advertiser was starting.
            if (peer == null) publish(null, G2cLinkState.DISCONNECTED)
        }
        override fun onStartFailure(errorCode: Int) {
            if (errorCode == AdvertiseCallback.ADVERTISE_FAILED_ALREADY_STARTED && server != null) {
                // The stack already advertises this callback; keep the server running.
                cancelTimeout()
                onEvent("server_advertising_already_active", null)
                return
            }
            fail("advertising_failed_$errorCode")
        }
    }

    private fun startAdvertising() {
        val active = advertiser ?: run { fail("advertiser_unavailable"); return }
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(true)
            .setTimeout(0)
            .build()
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .addServiceUuid(android.os.ParcelUuid(G2cGattProtocol.SERVICE_UUID))
            .build()
        advertiseCallback = advertiserCallback
        armTimeout(SERVICE_TIMEOUT_MS, "advertising_start_timeout")
        try { active.startAdvertising(settings, data, advertiserCallback) }
        catch (_: SecurityException) { fail("permission_required") }
        catch (_: RuntimeException) { fail("advertising_failed") }
    }

    private fun notifyNext(active: BluetoothGattServer, target: BluetoothDevice): Boolean {
        val fragments = outbound ?: return true
        if (outboundIndex >= fragments.size) {
            outbound = null
            outboundIndex = 0
            pendingNotificationIndex = null
            cancelTimeout()
            return true
        }
        val characteristic = active.getService(G2cGattProtocol.SERVICE_UUID)
            ?.getCharacteristic(G2cGattProtocol.DATA_CHARACTERISTIC_UUID) ?: return false
        characteristic.value = fragments[outboundIndex]
        pendingNotificationIndex = outboundIndex
        return try {
            @Suppress("DEPRECATION")
            val accepted = active.notifyCharacteristicChanged(target, characteristic, false)
            if (accepted) outboundIndex++ else {
                abortOutbound("notification_failed")
            }
            accepted
        } catch (_: SecurityException) {
            pendingNotificationIndex = null
            outbound = null
            fail("permission_required")
            false
        }
    }

    private fun respond(device: BluetoothDevice, requestId: Int, status: Int, offset: Int) {
        try { server?.sendResponse(device, requestId, status, offset, null) }
        catch (_: SecurityException) { fail("permission_required") }
    }

    private fun resetPeer() {
        cancelTimeout()
        reassembler.clear()
        peer = null
        serviceReady = false
        subscribed = false
        outbound = null
        outboundIndex = 0
        pendingNotificationIndex = null
        mtu = 23
        publish(null, G2cLinkState.DISCONNECTED)
        // Connectable advertising stops when a client connects and is not resumed by the
        // stack after a disconnect; restart it so the peer can actually reconnect.
        if (server != null && serviceAdded && advertiser != null) startAdvertising()
    }

    /** null means Android withheld the profile state (for example, without CONNECT permission). */
    private fun peerConnected(device: BluetoothDevice): Boolean? = try {
        when (manager?.getConnectionState(device, BluetoothProfile.GATT)) {
            BluetoothProfile.STATE_CONNECTED -> true
            null -> null
            else -> false
        }
    } catch (_: SecurityException) {
        null
    } catch (_: RuntimeException) {
        null
    }

    /**
     * Clears the peer record when Android reports it is no longer connected to the
     * GATT profile. Unknown profile state is left untouched rather than guessed.
     */
    @Synchronized
    fun revalidate() {
        val activePeer = peer ?: return
        if (server == null || destroyed) return
        val state = try {
            manager?.getConnectionState(activePeer, BluetoothProfile.GATT)
        } catch (_: SecurityException) {
            null
        } catch (_: RuntimeException) {
            null
        }
        if (state == null || state == BluetoothProfile.STATE_CONNECTED ||
            state == BluetoothProfile.STATE_CONNECTING
        ) return
        onEvent("server_peer_lost", "profile_state=$state")
        resetPeer()
    }

    private fun fail(code: String) {
        val state = when {
            code.contains("permission") -> G2cLinkState.PERMISSION_DENIED
            code.contains("timeout") -> G2cLinkState.TIMED_OUT
            code.contains("protocol") || code.contains("fragment") ||
                code.contains("truncated") || code.startsWith("invalid_") ->
                G2cLinkState.PROTOCOL_ERROR
            else -> G2cLinkState.CONNECTION_FAILED
        }
        stop()
        publish(code, state)
    }

    private fun publish(error: String?, state: G2cLinkState) = onState(G2cLinkSnapshot(state, error))
    private fun armTimeout(delay: Long, code: String) {
        cancelTimeout()
        timeout = Runnable { fail(code) }.also { handler.postDelayed(it, delay) }
    }

    /**
     * Stops a pending outbound queue without tearing down a still-subscribed peer.
     * A notification callback that never arrives must not be reported as delivery.
     */
    private fun armTransportTimeout() {
        cancelTimeout()
        timeout = Runnable { abortOutbound("notification_not_confirmed") }
            .also { handler.postDelayed(it, TRANSPORT_TIMEOUT_MS) }
    }

    private fun abortOutbound(code: String) {
        if (server == null) return
        outbound = null
        outboundIndex = 0
        pendingNotificationIndex = null
        cancelTimeout()
        publish(
            code,
            if (isSubscriptionReady) G2cLinkState.SERVICE_READY
            else G2cLinkState.CONNECTED_UNAUTHENTICATED,
        )
    }

    private fun cancelTimeout() { timeout?.let(handler::removeCallbacks); timeout = null }
    private fun hasConnectPermission(): Boolean = Build.VERSION.SDK_INT < 31 ||
        appContext.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
    private fun hasAdvertisePermission(): Boolean = Build.VERSION.SDK_INT < 31 ||
        appContext.checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) == PackageManager.PERMISSION_GRANTED
}
