package com.example.duman_messenger

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
    }

    override fun onResume() {
        super.onResume()
        bleDiagnosticManager?.onActivityResumed()
        bleDiscoveryManager?.onActivityResumed()
    }

    override fun onPause() {
        bleDiagnosticManager?.onActivityPaused()
        bleDiscoveryManager?.onActivityPaused()
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
    }

    override fun onDestroy() {
        bleDiagnosticManager?.onActivityDestroyed()
        bleDiscoveryManager?.onActivityDestroyed()
        bleMethodChannel?.setMethodCallHandler(null)
        bleEventChannel?.setStreamHandler(null)
        bleDiscoveryMethodChannel?.setMethodCallHandler(null)
        bleDiscoveryEventChannel?.setStreamHandler(null)

        bleDiagnosticManager = null
        bleMethodChannel = null
        bleEventChannel = null
        bleDiscoveryManager = null
        bleDiscoveryMethodChannel = null
        bleDiscoveryEventChannel = null
        super.onDestroy()
    }
}
