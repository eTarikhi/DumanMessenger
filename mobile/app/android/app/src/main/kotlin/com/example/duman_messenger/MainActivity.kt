package com.example.duman_messenger

import com.example.duman_messenger.identity.G2dCapabilityProbe
import com.example.duman_messenger.identity.G2dIdentityChannelHandler
import com.example.duman_messenger.identity.G2dIdentityKeyring
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var bleDiagnosticManager: BleDiagnosticManager? = null
    private var bleMethodChannel: MethodChannel? = null
    private var bleEventChannel: EventChannel? = null

    private var bleDiscoveryManager: BleDiscoveryManager? = null
    private var bleDiscoveryMethodChannel: MethodChannel? = null
    private var bleDiscoveryEventChannel: EventChannel? = null

    private var g2cBleManager: G2cBleManager? = null
    private var g2cMethodChannel: MethodChannel? = null
    private var g2cEventChannel: EventChannel? = null

    private var identityChannel: MethodChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val manager = BleDiagnosticManager(this)
        bleDiagnosticManager = manager
        bleMethodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BleDiagnosticManager.METHOD_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler(manager::onMethodCall)
        }
        bleEventChannel = EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BleDiagnosticManager.EVENT_CHANNEL,
        ).also { channel ->
            channel.setStreamHandler(manager)
        }

        val discoveryManager = BleDiscoveryManager(this)
        bleDiscoveryManager = discoveryManager
        bleDiscoveryMethodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BleDiscoveryManager.METHOD_CHANNEL,
        ).also { channel ->
            channel.setMethodCallHandler(discoveryManager::onMethodCall)
        }
        bleDiscoveryEventChannel = EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            BleDiscoveryManager.EVENT_CHANNEL,
        ).also { channel ->
            channel.setStreamHandler(discoveryManager)
        }

        val g2cManager = G2cBleManager(this)
        g2cBleManager = g2cManager
        g2cMethodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            G2cBleManager.METHOD_CHANNEL,
        ).also { channel -> channel.setMethodCallHandler(g2cManager::onMethodCall) }
        g2cEventChannel = EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            G2cBleManager.EVENT_CHANNEL,
        ).also { channel -> channel.setStreamHandler(g2cManager) }

        // G2-D identity: Keystore-backed protection facts, measured on this device.
        // Only non-secret facts cross this channel; see G2dIdentityChannelHandler.
        val identityKeyring = G2dIdentityKeyring()
        val handler = G2dIdentityChannelHandler(G2dCapabilityProbe(identityKeyring))
        identityChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            G2dIdentityChannelHandler.METHOD_CHANNEL,
        ).also { channel -> channel.setMethodCallHandler(handler) }
    }

    override fun onResume() {
        super.onResume()
        bleDiagnosticManager?.onActivityResumed()
        bleDiscoveryManager?.onActivityResumed()
        g2cBleManager?.onActivityResumed()
    }

    override fun onPause() {
        bleDiagnosticManager?.onActivityPaused()
        bleDiscoveryManager?.onActivityPaused()
        g2cBleManager?.onActivityPaused()
        super.onPause()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        bleDiagnosticManager?.onRequestPermissionsResult(
            requestCode,
            permissions,
            grantResults,
        )
        bleDiscoveryManager?.onRequestPermissionsResult(
            requestCode,
            permissions,
            grantResults,
        )
        g2cBleManager?.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onDestroy() {
        bleDiagnosticManager?.onActivityDestroyed()
        bleDiscoveryManager?.onActivityDestroyed()
        bleMethodChannel?.setMethodCallHandler(null)
        bleEventChannel?.setStreamHandler(null)
        bleDiscoveryMethodChannel?.setMethodCallHandler(null)
        bleDiscoveryEventChannel?.setStreamHandler(null)
        g2cBleManager?.onDestroy()
        g2cMethodChannel?.setMethodCallHandler(null)
        g2cEventChannel?.setStreamHandler(null)
        identityChannel?.setMethodCallHandler(null)

        g2cBleManager = null
        g2cMethodChannel = null
        g2cEventChannel = null
        identityChannel = null
        bleDiagnosticManager = null
        bleMethodChannel = null
        bleEventChannel = null
        bleDiscoveryManager = null
        bleDiscoveryMethodChannel = null
        bleDiscoveryEventChannel = null
        super.onDestroy()
    }
}
