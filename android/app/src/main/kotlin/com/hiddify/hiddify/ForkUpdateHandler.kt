package com.hiddify.hiddify

import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.content.pm.Signature
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest

/**
 * Platform channel for the family_vpn fork's in-app APK update.
 *
 * Dart side (ForkUpdateService) downloads the staged APK into the app-private
 * cache and persists the path; this handler turns that path into a content://
 * URI via FileProvider and fires Intent.ACTION_VIEW with the
 * application/vnd.android.package-archive mime type. The system installer
 * picks up the intent and shows the standard "Install update?" dialog.
 *
 * REQUEST_INSTALL_PACKAGES is declared in AndroidManifest. On API 26+ the
 * user may still need to grant "install unknown apps" per source app — on a
 * sideloaded build that's already been granted, this is a no-op. If the
 * permission isn't granted, the installer activity launches the settings
 * screen for the user to flip the toggle.
 *
 * FileProvider authority is "<applicationId>.fileprovider" (configured in
 * AndroidManifest), and the only declared shared path is the app cache —
 * matches getApplicationCacheDirectory() on the Dart side.
 */
class ForkUpdateHandler : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var channel: MethodChannel? = null
    private var binding: FlutterPlugin.FlutterPluginBinding? = null

    companion object {
        const val TAG = "A/ForkUpdate"
        const val channelName = "com.hiddify.app/fork_update"
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        this.binding = binding
        channel = MethodChannel(binding.binaryMessenger, channelName)
        channel?.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        this.binding = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "install" -> handleInstall(call, result)
            else -> result.notImplemented()
        }
    }

    private fun handleInstall(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path.isNullOrEmpty()) {
            result.error("INVALID_PATH", "path argument missing or empty", null)
            return
        }
        val ctx = binding?.applicationContext
        if (ctx == null) {
            result.error("NO_CONTEXT", "FlutterPluginBinding has no applicationContext", null)
            return
        }
        val file = File(path)
        if (!file.exists()) {
            result.error("APK_MISSING", "no file at $path", null)
            return
        }

        // Defense in depth: refuse to launch the system installer for an APK
        // signed by a different key than the running app. The platform
        // installer would reject it anyway with "App not installed", but
        // catching it here gives a precise error to surface back through Dart
        // and prevents the user from seeing the cryptic system dialog.
        val installedSha = installedSignerSha256(ctx)
        val stagedSha = apkSignerSha256(ctx, path)
        if (installedSha == null || stagedSha == null) {
            Log.e(TAG, "signer check: could not read certs (installed=$installedSha staged=$stagedSha)")
            result.error("SIGNER_UNKNOWN", "could not read signing certificates", null)
            return
        }
        if (installedSha != stagedSha) {
            Log.e(TAG, "signer mismatch: installed=$installedSha staged=$stagedSha path=$path")
            result.error(
                "SIGNER_MISMATCH",
                "staged APK signer ($stagedSha) ≠ installed signer ($installedSha)",
                null
            )
            return
        }

        val authority = "${ctx.packageName}.fileprovider"
        val uri: Uri = try {
            FileProvider.getUriForFile(ctx, authority, file)
        } catch (e: IllegalArgumentException) {
            // FileProvider throws if the path isn't under any of the
            // <paths> in fork_update_file_paths.xml. Surface the message —
            // most often this is "the file is outside the app cache dir".
            Log.e(TAG, "FileProvider rejected path: $path", e)
            result.error("FILEPROVIDER", e.message ?: "FileProvider rejected the path", null)
            return
        }

        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, "application/vnd.android.package-archive")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

        try {
            ctx.startActivity(intent)
        } catch (e: Throwable) {
            Log.e(TAG, "startActivity failed", e)
            result.error("INSTALL_LAUNCH", e.message ?: "unable to start installer", null)
            return
        }
        result.success(true)
    }

    private fun installedSignerSha256(ctx: Context): String? {
        val pm = ctx.packageManager
        val info = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                pm.getPackageInfo(ctx.packageName, PackageManager.GET_SIGNING_CERTIFICATES)
            } else {
                @Suppress("DEPRECATION")
                pm.getPackageInfo(ctx.packageName, PackageManager.GET_SIGNATURES)
            }
        } catch (e: PackageManager.NameNotFoundException) {
            Log.e(TAG, "getPackageInfo for self failed", e)
            return null
        }
        return firstSignerSha256(info)
    }

    private fun apkSignerSha256(ctx: Context, apkPath: String): String? {
        val pm = ctx.packageManager
        val info = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            pm.getPackageArchiveInfo(apkPath, PackageManager.GET_SIGNING_CERTIFICATES)
        } else {
            @Suppress("DEPRECATION")
            pm.getPackageArchiveInfo(apkPath, PackageManager.GET_SIGNATURES)
        }
        if (info == null) {
            Log.e(TAG, "getPackageArchiveInfo returned null for $apkPath (malformed APK?)")
            return null
        }
        return firstSignerSha256(info)
    }

    private fun firstSignerSha256(info: PackageInfo): String? {
        val signature: Signature? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val si = info.signingInfo ?: return null
            // Prefer the current signer set; fall back to the cert history
            // (covers rotated keys — system installer treats both as valid).
            val sigs: Array<Signature>? = if (si.hasMultipleSigners()) {
                si.apkContentsSigners
            } else {
                si.signingCertificateHistory
            }
            sigs?.firstOrNull()
        } else {
            @Suppress("DEPRECATION")
            info.signatures?.firstOrNull()
        }
        if (signature == null) return null
        val digest = MessageDigest.getInstance("SHA-256").digest(signature.toByteArray())
        return digest.joinToString("") { "%02x".format(it) }
    }
}
