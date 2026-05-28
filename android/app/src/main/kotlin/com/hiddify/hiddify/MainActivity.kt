package com.hiddify.hiddify

import android.annotation.SuppressLint
import android.content.Intent
import android.Manifest
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.util.Log
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.lifecycleScope
import com.hiddify.hiddify.bg.ServiceConnection
import com.hiddify.hiddify.bg.ServiceNotification
import com.hiddify.hiddify.constant.Alert
import com.hiddify.hiddify.constant.ServiceMode
import com.hiddify.hiddify.constant.Status
import go.Seq
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.LinkedList


class MainActivity : FlutterFragmentActivity(), ServiceConnection.Callback {
    companion object {
        private const val TAG = "ANDROID/MyActivity"
        lateinit var instance: MainActivity

        const val VPN_PERMISSION_REQUEST_CODE = 1001
        const val NOTIFICATION_PERMISSION_REQUEST_CODE = 1010
    }

    private val connection = ServiceConnection(this, this)

    val logList = LinkedList<String>()
    var logCallback: ((Boolean) -> Unit)? = null
    val serviceStatus = MutableLiveData(Status.Stopped)
    val serviceAlerts = MutableLiveData<ServiceEvent?>(null)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // If anything crashed on the previous launch, surface the share
        // dialog before Flutter has a chance to fail again. Runs even if
        // configureFlutterEngine never gets called.
        CrashReporter.shareCrashesIfAny(this)

        // family_vpn fork: load gomobile (libhiddify-core.so) here, not in
        // Application.onCreate. If System.loadLibrary fails (ABI mismatch
        // on Unisoc/Android Go, missing libc++_shared, page-size, etc.) the
        // JVM uncaught handler writes a crash dump to filesDir/crashes/,
        // Application stays alive, and DiagnoseActivity can ship the dump
        // on the user's next tap of the "Логи" launcher icon. If we kept
        // Seq.setContext in Application, the dump never reaches the user
        // because no Activity ever launches.
        try {
            Seq.setContext(this.applicationContext)
        } catch (t: Throwable) {
            Log.e(TAG, "Seq.setContext failed — surfacing crash dialog", t)
            // Re-throw so the JVM uncaught handler writes a proper dump
            // (this Activity is going to die either way; better to die
            // with a recorded reason than silently).
            throw t
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        instance = this
        reconnect()
        flutterEngine.plugins.add(MethodHandler(lifecycleScope))
        flutterEngine.plugins.add(PlatformSettingsHandler())
        flutterEngine.plugins.add(EventHandler())
        flutterEngine.plugins.add(LogHandler())
        // family_vpn fork: in-app APK install channel; takes a path to the
        // APK that ForkUpdateService staged in app cache and fires the
        // system installer activity.
        flutterEngine.plugins.add(ForkUpdateHandler())
//        flutterEngine.plugins.add(GroupsChannel(lifecycleScope))
//        flutterEngine.plugins.add(ActiveGroupsChannel(lifecycleScope))
//        flutterEngine.plugins.add(StatsChannel(lifecycleScope))
    }

    fun reconnect() {
        connection.reconnect()
    }

    @SuppressLint("NewApi")
    fun startService() {
        // family_vpn fork: skip POST_NOTIFICATIONS dialog entirely.
        // Why: it was the first of TWO sequential system dialogs (notif then
        // VPN-permission) on first launch, each blocking startService0() until
        // tapped. Dart's setupBackground polling loop times out after ~22s and
        // surfaces "Непредвиденный сбой / starting background core..." — the
        // user has to tap connect again. Foreground VPN services run fine
        // without POST_NOTIFICATIONS — the status-bar notif just isn't visible,
        // which is fine for relatives. Removing this halves the dialog chain.
        startService0()
    }

    private fun startService0() {
        lifecycleScope.launch(Dispatchers.IO) {
            if (Settings.rebuildServiceMode()) {
                connection.reconnect()
            }
            if (Settings.serviceMode == ServiceMode.VPN) {
                if (prepare()) {
                    return@launch
                }
            }
            val intent = Intent(Application.application, Settings.serviceClass())
            withContext(Dispatchers.Main) {
                ContextCompat.startForegroundService(this@MainActivity, intent)
            }
            Settings.startedByUser = true
        }
    }

    private suspend fun prepare() = withContext(Dispatchers.Main) {
        try {
            val intent = VpnService.prepare(this@MainActivity)
            if (intent != null) {
                prepareLauncher.launch(intent)
                true
            } else {
                false
            }
        } catch (e: Exception) {
            onServiceAlert(Alert.RequestVPNPermission, e.message)
            true
        }
    }

    // family_vpn fork: perm-only path used by (a) first-launch pre-request and
    // (b) auto-retry when the core surfaces 'permission denied' on connect.
    // Unlike prepare()/prepareLauncher, the result here does NOT start the
    // VPN service — Dart decides what to do next based on the boolean result.
    private var prepareOnlyResult: ((Boolean) -> Unit)? = null

    fun requestVpnPermissionOnly(callback: (Boolean) -> Unit) {
        lifecycleScope.launch(Dispatchers.Main) {
            try {
                val intent = VpnService.prepare(this@MainActivity)
                if (intent == null) {
                    // already granted
                    callback(true)
                    return@launch
                }
                prepareOnlyResult = callback
                prepareOnlyLauncher.launch(intent)
            } catch (e: Exception) {
                Log.w(TAG, "requestVpnPermissionOnly failed: ${e.message}")
                callback(false)
            }
        }
    }

    private val prepareOnlyLauncher =
        registerForActivityResult(
            ActivityResultContracts.StartActivityForResult(),
        ) { result ->
            val cb = prepareOnlyResult
            prepareOnlyResult = null
            cb?.invoke(result.resultCode == RESULT_OK)
        }

    private val notificationPermissionLauncher =
        registerForActivityResult(
            ActivityResultContracts.RequestPermission(),
        ) { isGranted ->
            if (Settings.dynamicNotification && !isGranted) {
                onServiceAlert(Alert.RequestNotificationPermission, null)
            } else {
                startService0()
            }
        }

    private val prepareLauncher =
        registerForActivityResult(
            ActivityResultContracts.StartActivityForResult(),
        ) { result ->
            if (result.resultCode == RESULT_OK) {
                startService0()
            } else {
                onServiceAlert(Alert.RequestVPNPermission, null)
            }
        }

    override fun onServiceStatusChanged(status: Status) {
        serviceStatus.postValue(status)
    }

    override fun onServiceAlert(type: Alert, message: String?) {
        serviceAlerts.postValue(ServiceEvent(Status.Stopped, type, message))
    }




    override fun onDestroy() {
        connection.disconnect()
        super.onDestroy()
    }

    @SuppressLint("NewApi")
    private fun grantNotificationPermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                NOTIFICATION_PERMISSION_REQUEST_CODE
            )
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        if (requestCode == NOTIFICATION_PERMISSION_REQUEST_CODE) {
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                startService()
            } else onServiceAlert(Alert.RequestNotificationPermission, null)
        }
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == VPN_PERMISSION_REQUEST_CODE) {
            if (resultCode == RESULT_OK) startService()
            else onServiceAlert(Alert.RequestVPNPermission, null)
        } else if (requestCode == NOTIFICATION_PERMISSION_REQUEST_CODE) {
            if (resultCode == RESULT_OK) startService()
            else onServiceAlert(Alert.RequestNotificationPermission, null)
        }
    }
}
