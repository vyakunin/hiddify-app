package com.hiddify.hiddify

import android.util.Log
import com.hiddify.hiddify.bg.BoxService
//import com.hiddify.hiddify.bg.BoxService.Companion.workingDir
import com.hiddify.hiddify.constant.Status
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

import com.hiddify.core.libbox.Libbox
import com.hiddify.core.mobile.Mobile
import com.hiddify.core.mobile.SetupOptions
import com.hiddify.hiddify.bg.Bugs
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.GlobalScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.File

class MethodHandler(private val scope: CoroutineScope) : FlutterPlugin,
    MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null

    companion object {
        const val TAG = "A/MethodHandler"
        const val channelName = "com.hiddify.app/method"

        enum class Trigger(val method: String) {
            Setup("setup"),
            Start("start"),
            Stop("stop"),
            Restart("restart"),
            AddGrpcClientPublicKey("add_grpc_client_public_key"),
            GetGrpcServerPublicKey("get_grpc_server_public_key"),
            // family_vpn fork: perm-only paths for first-launch pre-request
            // and post-denied auto-retry. Does NOT start the VPN service.
            PrepareVpnPermission("prepare_vpn_permission"),

            // family_vpn fork: Kotlin-authoritative session-timer source of
            // truth. BoxService writes Settings.connectedSinceMs on
            // Status.Started, clears on Status.Stopped. Dart calls this on
            // Connected emissions to refresh its cache (Flutter
            // shared_preferences doesn't notice native-side writes on its
            // own).
            GetConnectedSinceMs("get_connected_since_ms"),

            // family_vpn fork: dump this process's own logcat to
            // workingDir/logcat.log so LogBundle can ship it. Captures the
            // Kotlin BoxService logs ("starting service", caught Mobile.setup/
            // start exceptions) and any system kill/ANR lines for our UID that
            // never reach the Dart app.log — the missing half of a remote
            // tunnel-start failure (Roza realme C30, 2026-06-23).
            DumpLogcat("dump_logcat"),

        }
    }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(
            flutterPluginBinding.binaryMessenger,
            channelName,
        )
        channel!!.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            Trigger.AddGrpcClientPublicKey.method -> {
                GlobalScope.launch {
                    result.runCatching {
                        val args = call.arguments as Map<*, *>
                        val clientPub = args["clientPublicKey"] as ByteArray
//                        Mobile.addGrpcClientPublicKey(clientPub)
                        Settings.grpcFlutterPublicKey = clientPub
                        success("")

                    }
                }
            }

            Trigger.GetGrpcServerPublicKey.method -> {
                GlobalScope.launch {
                    result.runCatching {
                        result.success(Mobile.getServerPublicKey())
                    }
                }
            }

            Trigger.Setup.method -> {
                GlobalScope.launch {
                    result.runCatching {
                        val args = call.arguments as Map<*, *>
                        Settings.baseDir = args["baseDir"] as String
                        Settings.workingDir = args["workingDir"] as String
                        Settings.tempDir = args["tempDir"] as String
                        Settings.debugMode = args["debug"] as Boolean? ?: false
                        val mode = args["mode"] as Int
                        val grpcPort = args["grpcPort"] as Int
                        Log.d("debugmode","${Settings.debugMode}")
                        runCatching {
                            Mobile.setup(
                                SetupOptions().also {
                                    it.basePath = Settings.baseDir
                                    it.workingDir = Settings.workingDir
                                    it.tempDir = Settings.tempDir
                                    it.fixAndroidStack = Bugs.fixAndroidStack
                                    it.mode=mode.toLong()
                                    it.listen= "127.0.0.1:" + grpcPort
                                    it.secret=""
                                    it.debug = Settings.debugMode
                                },null)

//                            Libbox.setup(Settings.baseDir, Settings.workingDir, Settings.tempDir, false)
                            Libbox.redirectStderr(File(Settings.workingDir, "stderr2.log").path)

                            success("")
                        }.onFailure {
                            error(it)
                        }

                    }
                }
            }


            Trigger.Start.method -> {
                scope.launch {
                    result.runCatching {
                        val args = call.arguments as Map<*, *>
                        Settings.activeConfigPath = args["path"] as String? ?: ""
                        Settings.activeProfileName = args["name"] as String? ?: ""
                        Settings.debugMode = args["debug"] as Boolean? ?: false
                        Settings.grpcServiceModePort = args["grpcPort"] as Int

                        val mainActivity = MainActivity.instance
//                        val started = mainActivity.serviceStatus.value == Status.Started
//                        if (started) {
//                            Log.w(TAG, "service is already running")
//                            return@launch success(true)
//                        }
                        Settings.startCoreAfterStartingService = false

                        mainActivity.startService()
                        success(true)
                    }
                }
            }

            Trigger.PrepareVpnPermission.method -> {
                // Synchronously launch the Android system VPN-permission dialog
                // and return granted=true|false to Dart. Does NOT start service.
                val mainActivity = MainActivity.instance
                mainActivity.requestVpnPermissionOnly { granted ->
                    result.success(granted)
                }
            }

            Trigger.GetConnectedSinceMs.method -> {
                result.success(Settings.connectedSinceMs)
            }

            Trigger.DumpLogcat.method -> {
                GlobalScope.launch(Dispatchers.IO) {
                    result.runCatching {
                        try {
                            val out = File(Settings.workingDir, "logcat.log")
                            // -d: dump and exit; -t 4000: last 4000 lines (bounds
                            // size); -v threadtime: timestamps + pid/tid. On modern
                            // Android an unprivileged app only sees its own UID's
                            // logs, which is exactly what we want.
                            val proc = ProcessBuilder(
                                "logcat", "-d", "-t", "4000", "-v", "threadtime"
                            ).redirectErrorStream(true).start()
                            proc.inputStream.use { ins ->
                                out.outputStream().use { os -> ins.copyTo(os) }
                            }
                            proc.waitFor()
                            success(out.path)
                        } catch (e: Exception) {
                            // Best-effort: never let a logcat-dump failure break
                            // the share-logs flow.
                            Log.w(TAG, "dump_logcat failed: ${e.message}")
                            success("")
                        }
                    }
                }
            }

            Trigger.Stop.method -> {
                scope.launch {
                    result.runCatching {
                        val mainActivity = MainActivity.instance
                        val started = mainActivity.serviceStatus.value == Status.Started
                        if (!started) {
                            Log.w(TAG, "service is not running")
                            //    return@launch success(true)
                        }
                        BoxService.stop()
                        success(true)
                    }
                }
            }

//            Trigger.Restart.method -> {
//                scope.launch(Dispatchers.IO) {
//                    result.runCatching {
//                        val args = call.arguments as Map<*, *>
//                        Settings.activeConfigPath = args["path"] as String? ?: ""
//                        Settings.activeProfileName = args["name"] as String? ?: ""
//                        val mainActivity = MainActivity.instance
//                        val started = mainActivity.serviceStatus.value == Status.Started
//                        if (!started) return@launch success(true)
//                        val restart = Settings.rebuildServiceMode()
//                        if (restart) {
//                            mainActivity.reconnect()
//                            BoxService.stop()
//                            delay(1000L)
//                            mainActivity.startService()
//                            return@launch success(true)
//                        }
//                        runCatching {
//                            Libbox.newStandaloneCommandClient().serviceReload()
//                            success(true)
//                        }.onFailure {
//                            error(it)
//                        }
//                    }
//                }
//            }

            else -> result.notImplemented()
        }
    }
}