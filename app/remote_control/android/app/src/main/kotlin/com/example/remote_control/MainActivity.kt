package com.example.remote_control

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // WifiManager.MulticastLock — OEM broadcast-filter insurance for UDP
    // beacon discovery (RESEARCH Pattern 4). Dart pairs acquire/release
    // with the beacon socket lifecycle (Pitfall 8: never held idle).
    private var lock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "remote_control/multicast")
            .setMethodCallHandler { call, result ->
                val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                when (call.method) {
                    "acquire" -> {
                        lock = lock ?: wifi.createMulticastLock("rc-discovery")
                            .also { it.setReferenceCounted(false) }
                        lock?.acquire()
                        result.success(null)
                    }
                    "release" -> {
                        lock?.takeIf { it.isHeld }?.release()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
