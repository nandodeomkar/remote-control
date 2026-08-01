package dev.omkar.remotecontrol

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import android.util.Log

/**
 * Status sink for the PackageInstaller session committed in MainActivity.
 *
 * commit() does NOT show a dialog itself: it calls back HERE first with
 * STATUS_PENDING_USER_ACTION, whose Intent.EXTRA_INTENT is the confirmation
 * activity that must be launched for Android's own dialog to appear
 * (RESEARCH Pitfall 6).
 *
 * Declared android:exported="false" and reached only through an
 * explicit-component PendingIntent, so no other app can feed it a forged
 * status (T-12-21).
 */
class InstallResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, INVALID_STATUS)
        // Device-specific and can contain paths — logged, never forwarded to
        // Dart and never rendered (T-12-06).
        Log.i(TAG, "install status=$status msg=${intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)}")

        when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val confirm = confirmationIntent(intent)
                if (confirm == null) {
                    Log.w(TAG, "pending user action without EXTRA_INTENT")
                    MainActivity.reportInstallOutcome("failure", status)
                    return
                }
                // A BroadcastReceiver has no activity context.
                confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                MainActivity.reportInstallOutcome("pendingUserAction", null)
                context.startActivity(confirm)
            }

            // The user declined the system dialog. D-19: the row returns to
            // "update available" — no retry, no nagging, not an error.
            PackageInstaller.STATUS_FAILURE_ABORTED ->
                MainActivity.reportInstallOutcome("declined", null)

            // Usually NEVER arrives: replacing the APK kills this process, so
            // the success broadcast lands on a process being torn down
            // (RESEARCH Pitfall 7). Handled if it does, but nothing depends on
            // it — success is confirmed by the app relaunching at a new
            // package_info_plus version, and no "installing" flag is persisted
            // that a fresh launch could read as stuck (T-12-25).
            PackageInstaller.STATUS_SUCCESS ->
                Log.i(TAG, "install reported success (rarely observed)")

            // Every other non-success status, carrying only the numeric code.
            // STATUS_FAILURE_CONFLICT (5) is what a signature mismatch or a
            // lower versionCode produces (RESEARCH Pitfall 8).
            else -> MainActivity.reportInstallOutcome("failure", status)
        }
    }

    private fun confirmationIntent(intent: Intent): Intent? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(Intent.EXTRA_INTENT)
        }

    private companion object {
        const val TAG = "RcInstaller"
        const val INVALID_STATUS = -1000
    }
}
