package com.hiddify.hiddify

import android.app.Application
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.wifi.WifiManager
import android.os.PowerManager
import androidx.core.content.getSystemService
import com.hiddify.hiddify.bg.AppChangeReceiver
import com.hiddify.hiddify.Application as BoxApplication

class Application : Application() {

    override fun attachBaseContext(base: Context?) {
        super.attachBaseContext(base)
        application = this
        // Install JVM uncaught handler at the earliest possible hook —
        // before Application.onCreate, before any Flutter plugin or
        // libbox init can fail. See CrashReporter.kt.
        CrashReporter.install(this)
    }

    override fun onCreate() {
        super.onCreate()

        // Capture any native / ANR / OOM crashes from the previous process
        // (JVM handler can't see those — process is already dead by signal
        // handler time). Idempotent across launches.
        CrashReporter.checkPastCrashes(this)

        // family_vpn fork: Seq.setContext deliberately NOT called here.
        // Moved to MainActivity.onCreate so Application survives even when
        // libhiddify-core fails to dlopen (e.g. ABI mismatch on entry-level
        // Unisoc/Android Go ROMs). When Application crashes here the OS
        // never reaches any Activity → DiagnoseActivity (no-gomobile) can
        // still launch, read filesDir/crashes/*.txt, and ship the dump.

        registerReceiver(AppChangeReceiver(), IntentFilter().apply {
            addAction(Intent.ACTION_PACKAGE_ADDED)
            addDataScheme("package")
        })
    }

    companion object {
        lateinit var application: BoxApplication
        val notification by lazy { application.getSystemService<NotificationManager>()!! }
        val connectivity by lazy { application.getSystemService<ConnectivityManager>()!! }
        val packageManager by lazy { application.packageManager }
        val powerManager by lazy { application.getSystemService<PowerManager>()!! }
        val notificationManager by lazy { application.getSystemService<NotificationManager>()!! }

        val wifiManager by lazy { application.getSystemService<WifiManager>()!! }

    }

}