package dev.omkar.remotecontrol

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

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

        // APK self-update (D-19). A SECOND channel alongside the multicast one:
        // the OS owns package installation, so the app only stages bytes and
        // commits a PackageInstaller session. The file handed to `install` was
        // already sha256-verified in Dart (apk_installer.dart's contract) — this
        // side never verifies and never fetches.
        val installerChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "remote_control/installer")
        // InstallResultReceiver pushes outcomes back through this reference.
        // Cleared in onDestroy so a torn-down engine is never invoked.
        outcomeChannel = installerChannel
        installerChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "canInstall" -> {
                    // API 26 introduced the per-app "install unknown apps"
                    // grant; below it the global setting governs and this call
                    // does not exist at all (NoSuchMethodError on API 24/25,
                    // which is the project's effective minSdk — Pitfall 5).
                    val ok = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        packageManager.canRequestPackageInstalls()
                    } else {
                        true
                    }
                    result.success(ok)
                }
                "openInstallPermission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        startActivity(
                            Intent(
                                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName")
                            )
                        )
                    }
                    // Success either way: on API < 26 there is no screen to
                    // open, and the Dart side never opens the sheet there.
                    result.success(null)
                }
                // Exists so the Dart download path can stream ~70 MB without a
                // path_provider dependency.
                "cacheDir" -> result.success(applicationContext.cacheDir.absolutePath)
                "install" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrEmpty()) {
                        result.error("no-path", "install requires a non-empty path", null)
                    } else {
                        installApk(File(path), result)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        outcomeChannel = null
        super.onDestroy()
    }

    /**
     * Stage [apk] into a PackageInstaller session and commit it.
     *
     * commit() does NOT show a dialog itself: it first calls back with
     * STATUS_PENDING_USER_ACTION, whose Intent.EXTRA_INTENT is the confirmation
     * activity InstallResultReceiver must launch (Pitfall 6). So `result` here
     * only reports that the session was staged and committed — the user's
     * answer arrives later, on the outcome channel.
     */
    private fun installApk(apk: File, result: MethodChannel.Result) {
        val installer = packageManager.packageInstaller
        var sessionId = -1
        try {
            val params = PackageInstaller.SessionParams(
                PackageInstaller.SessionParams.MODE_FULL_INSTALL
            )
            sessionId = installer.createSession(params)
            installer.openSession(sessionId).use { session ->
                session.openWrite("rc", 0, apk.length()).use { out ->
                    apk.inputStream().use { it.copyTo(out) }
                    session.fsync(out) // required BEFORE the stream is closed
                }
                val intent = Intent(this, InstallResultReceiver::class.java)
                // API 31+ demands explicit mutability, and the SYSTEM fills in
                // the status extras — so this one must be MUTABLE. It names an
                // explicit, non-exported component in this package, so
                // mutability grants no cross-app capability (T-12-22). The
                // session id is the request code, so concurrent sessions cannot
                // collide under FLAG_UPDATE_CURRENT.
                val mutability = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    PendingIntent.FLAG_MUTABLE
                } else {
                    0
                }
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or mutability
                val pending = PendingIntent.getBroadcast(this, sessionId, intent, flags)
                session.commit(pending.intentSender)
            }
            result.success(null)
        } catch (e: Exception) {
            // Never crash the activity over a failed staging: abandon the
            // half-written session and report a code the Dart row can render.
            if (sessionId != -1) {
                try {
                    installer.abandonSession(sessionId)
                } catch (_: Exception) {
                    // Already gone; nothing to release.
                }
            }
            result.error("install-failed", e.message ?: e.javaClass.simpleName, null)
        }
    }

    companion object {
        private var outcomeChannel: MethodChannel? = null

        /**
         * Forward one install outcome to Dart. Called from
         * InstallResultReceiver.onReceive, which runs on the main thread — the
         * only thread a MethodChannel may be invoked from.
         *
         * If the engine is already gone the outcome is dropped silently: the
         * app is being replaced and there is nothing left to tell.
         */
        fun reportInstallOutcome(outcome: String, status: Int?) {
            outcomeChannel?.invokeMethod(
                "outcome",
                mapOf("outcome" to outcome, "status" to status)
            )
        }
    }
}
