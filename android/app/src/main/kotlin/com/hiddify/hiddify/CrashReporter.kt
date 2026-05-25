package com.hiddify.hiddify

import android.app.Activity
import android.app.ActivityManager
import android.app.AlertDialog
import android.app.ApplicationExitInfo
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.core.content.FileProvider
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * family_vpn fork: crash collection for relatives whose phones do not report
 * to Play Vitals (degoogled / regional ROMs). Three layers, each catching
 * what the previous can't:
 *
 *  1. JVM uncaught handler — installed from Application.attachBaseContext,
 *     i.e. before Application.onCreate, before any plugin registration.
 *     Catches everything our managed code throws on any thread before the
 *     OS kills us. Chains to the system handler so the standard "App has
 *     stopped" dialog still appears.
 *
 *  2. ApplicationExitInfo scan (API 30+) — on every launch, look at the
 *     last 20 process exits. For any CRASH / CRASH_NATIVE / ANR /
 *     LOW_MEMORY / SIGNALED, pull the tombstone trace and write a report.
 *     This is the ONLY way to capture sing-box / libhiddify-core SIGSEGV;
 *     the JVM handler is dead before the signal handler runs. Deduped via
 *     a SharedPrefs watermark so each historical exit is recorded once.
 *
 *  3. Flutter / Dart errors are already caught by Logger.logFlutterError +
 *     Logger.logPlatformDispatcherError and end up in app.log, which the
 *     home-screen "Поделиться логами" button bundles. Not in scope here.
 *
 * Reports are written to <app-external>/crashes/crash_<utc>.txt — app-
 * private external storage, no permission needed. On every Activity start,
 * if there are unsent reports, an AlertDialog asks the user to send them
 * via ACTION_SEND_MULTIPLE, pre-targeting Telegram. On confirm tap we move
 * files to crashes/sent/ so we don't re-prompt. Privacy invariant honored:
 * nothing leaves the device without an explicit user gesture.
 */
object CrashReporter {
    private const val TAG = "A/CrashReporter"
    private const val PREFS = "crash_reporter"
    private const val KEY_LAST_EXIT_TS = "last_exit_ts"
    private const val DIR_CRASHES = "crashes"
    private const val DIR_SENT = "sent"
    private const val MAX_TRACE_LINES = 8000
    private const val LOGCAT_TAIL_LINES = 500

    /**
     * Install the JVM uncaught-exception handler. Idempotent: a second
     * call is a no-op (we don't want to wrap our own wrapper if attach
     * is invoked twice for some reason).
     */
    fun install(app: Context) {
        if (installed) return
        installed = true
        val appCtx = app.applicationContext
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                writeJvmCrash(appCtx, thread, throwable)
            } catch (t: Throwable) {
                Log.e(TAG, "writeJvmCrash itself threw — giving up", t)
            }
            // Chain to the OS default so the standard crash dialog still
            // shows and Android knows we died.
            try {
                previous?.uncaughtException(thread, throwable)
            } catch (_: Throwable) {}
            // If there was no previous handler, exit explicitly — the
            // alternative is the thread quietly disappearing.
            if (previous == null) kotlin.system.exitProcess(2)
        }
        Log.i(TAG, "uncaught-exception handler installed")
    }

    @Volatile
    private var installed = false

    /**
     * Look at past process exits and capture any crash the JVM handler
     * missed (native / ANR / OOM / signal). API 30+ only — older devices
     * have no public way to enumerate this.
     */
    fun checkPastCrashes(ctx: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val prefs = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val watermark = prefs.getLong(KEY_LAST_EXIT_TS, 0L)
        var newestSeen = watermark

        val am = ctx.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val exits = try {
            am.getHistoricalProcessExitReasons(ctx.packageName, 0, 20)
        } catch (t: Throwable) {
            Log.e(TAG, "getHistoricalProcessExitReasons failed", t)
            return
        }
        for (info in exits) {
            if (info.timestamp <= watermark) continue
            if (info.timestamp > newestSeen) newestSeen = info.timestamp
            if (!isCrashLike(info.reason)) continue
            try {
                writeExitInfoCrash(ctx, info)
            } catch (t: Throwable) {
                Log.e(TAG, "writeExitInfoCrash failed for ts=${info.timestamp}", t)
            }
        }
        if (newestSeen > watermark) {
            prefs.edit().putLong(KEY_LAST_EXIT_TS, newestSeen).apply()
        }
    }

    private fun isCrashLike(reason: Int): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return false
        return when (reason) {
            ApplicationExitInfo.REASON_CRASH,
            ApplicationExitInfo.REASON_CRASH_NATIVE,
            ApplicationExitInfo.REASON_ANR,
            ApplicationExitInfo.REASON_LOW_MEMORY,
            ApplicationExitInfo.REASON_SIGNALED,
            ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> true
            else -> false
        }
    }

    /**
     * Offer to send any unsent crash reports. Call from Activity.onCreate
     * AFTER super.onCreate AND AFTER checkPastCrashes (so freshly-detected
     * native crashes are included on this same launch).
     */
    fun shareCrashesIfAny(activity: Activity) {
        val crashes = listUnsent(activity)
        if (crashes.isEmpty()) return
        try {
            val theme = android.R.style.Theme_DeviceDefault_Light_Dialog_Alert
            val n = crashes.size
            AlertDialog.Builder(activity, theme)
                .setTitle("Сбой в приложении")
                .setMessage(
                    "Приложение в прошлый раз закрылось с ошибкой " +
                    "($n ${pluralRu(n, "отчёт", "отчёта", "отчётов")}). " +
                    "Отправить Володе, чтобы починить?"
                )
                .setPositiveButton("Отправить") { _, _ -> fireShare(activity, crashes) }
                .setNegativeButton("Позже", null)
                .setCancelable(true)
                .show()
        } catch (t: Throwable) {
            Log.e(TAG, "share dialog threw", t)
        }
    }

    private fun pluralRu(n: Int, one: String, few: String, many: String): String {
        val mod10 = n % 10
        val mod100 = n % 100
        return when {
            mod10 == 1 && mod100 != 11 -> one
            mod10 in 2..4 && mod100 !in 12..14 -> few
            else -> many
        }
    }

    private fun listUnsent(ctx: Context): List<File> {
        val dir = crashesDir(ctx) ?: return emptyList()
        if (!dir.isDirectory) return emptyList()
        return (dir.listFiles { f -> f.isFile && f.name.endsWith(".txt") }
            ?.sortedBy { it.lastModified() } ?: emptyList())
    }

    private fun fireShare(activity: Activity, files: List<File>) {
        val authority = "${activity.packageName}.fileprovider"
        val uris = ArrayList<Uri>()
        for (f in files) {
            try {
                uris.add(FileProvider.getUriForFile(activity, authority, f))
            } catch (t: Throwable) {
                Log.e(TAG, "FileProvider rejected ${f.absolutePath}", t)
            }
        }
        if (uris.isEmpty()) return

        val base = Intent(Intent.ACTION_SEND_MULTIPLE).apply {
            type = "text/plain"
            putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
            putExtra(Intent.EXTRA_SUBJECT, "Заметки crash report")
            putExtra(
                Intent.EXTRA_TEXT,
                "Отчёт об ошибке. Это поможет починить приложение."
            )
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }

        // Pre-target Telegram if installed; fall back to system chooser.
        val telegramPkg = listOf("org.telegram.messenger", "org.telegram.messenger.web")
            .firstOrNull { isPkgInstalled(activity, it) }

        val toLaunch = if (telegramPkg != null) {
            Intent(base).apply { setPackage(telegramPkg) }
        } else {
            Intent.createChooser(base, "Отправить отчёт об ошибке")
        }

        try {
            activity.startActivity(toLaunch)
        } catch (e: ActivityNotFoundException) {
            // Explicit Telegram target failed (e.g. Telegram doesn't accept
            // ACTION_SEND_MULTIPLE for this mime). Fall back to chooser.
            try {
                activity.startActivity(Intent.createChooser(base, "Отправить отчёт об ошибке"))
            } catch (t: Throwable) {
                Log.e(TAG, "fallback chooser also failed", t)
                return
            }
        } catch (t: Throwable) {
            Log.e(TAG, "startActivity for share threw", t)
            return
        }

        // Move sent files to crashes/sent/ so we don't re-prompt. We commit
        // on tap, not on actual delivery — if the user dismisses the chooser
        // the file stays in sent/ (still readable for manual retrieval) but
        // we won't badger them again. They can re-send via the home-screen
        // log share button if needed.
        val sentDir = sentDir(activity)
        if (sentDir != null) {
            sentDir.mkdirs()
            for (f in files) {
                try {
                    val dest = File(sentDir, f.name)
                    if (!f.renameTo(dest)) {
                        // renameTo can fail across mount points; copy + delete.
                        f.copyTo(dest, overwrite = true)
                        f.delete()
                    }
                } catch (t: Throwable) {
                    Log.e(TAG, "could not move ${f.name} to sent/", t)
                }
            }
        }
    }

    private fun isPkgInstalled(ctx: Context, pkg: String): Boolean {
        return try {
            @Suppress("DEPRECATION")
            ctx.packageManager.getPackageInfo(pkg, 0)
            true
        } catch (_: PackageManager.NameNotFoundException) {
            false
        }
    }

    // -----------------------------------------------------------------
    // Writers

    private fun writeJvmCrash(ctx: Context, thread: Thread, t: Throwable) {
        val dir = crashesDir(ctx) ?: return
        dir.mkdirs()
        val ts = iso8601(System.currentTimeMillis())
        val file = uniqueFile(dir, "crash_${ts}_jvm")
        val sw = StringWriter()
        val pw = PrintWriter(sw)
        pw.println("=== Заметки crash report (JVM uncaught) ===")
        pw.println("when: $ts")
        pw.println("thread: ${thread.name} (id=${thread.id})")
        writeHeader(ctx, pw)
        pw.println()
        pw.println("--- stack ---")
        t.printStackTrace(pw)
        pw.println()
        pw.println("--- logcat (own pid, last $LOGCAT_TAIL_LINES lines) ---")
        pw.println(tailLogcat(LOGCAT_TAIL_LINES))
        pw.flush()
        file.writeText(sw.toString())
    }

    private fun writeExitInfoCrash(ctx: Context, info: ApplicationExitInfo) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return
        val dir = crashesDir(ctx) ?: return
        dir.mkdirs()
        val ts = iso8601(info.timestamp)
        val reasonName = exitReasonName(info.reason)
        val file = uniqueFile(dir, "crash_${ts}_exit_${reasonName.lowercase(Locale.US)}")
        val sw = StringWriter()
        val pw = PrintWriter(sw)
        pw.println("=== Заметки crash report (ApplicationExitInfo) ===")
        pw.println("when: $ts")
        pw.println("reason: $reasonName (${info.reason})")
        pw.println("description: ${info.description}")
        pw.println("status: ${info.status}")
        pw.println("importance: ${info.importance}")
        pw.println("processName: ${info.processName}")
        pw.println("pid: ${info.pid}")
        pw.println("realUid: ${info.realUid}")
        pw.println("packageUid: ${info.packageUid}")
        pw.println("rss: ${info.rss}")
        pw.println("pss: ${info.pss}")
        writeHeader(ctx, pw)
        pw.println()
        pw.println("--- tombstone / trace (if any) ---")
        try {
            val trace = info.traceInputStream
            if (trace == null) {
                pw.println("(no trace available)")
            } else {
                trace.use { input ->
                    BufferedReader(InputStreamReader(input)).use { br ->
                        var count = 0
                        var line: String? = br.readLine()
                        while (line != null && count < MAX_TRACE_LINES) {
                            pw.println(line)
                            count++
                            line = br.readLine()
                        }
                        if (line != null) pw.println("[...truncated after $MAX_TRACE_LINES lines]")
                    }
                }
            }
        } catch (t: Throwable) {
            pw.println("(reading traceInputStream threw: ${t.javaClass.simpleName}: ${t.message})")
        }
        pw.flush()
        file.writeText(sw.toString())
    }

    private fun writeHeader(ctx: Context, pw: PrintWriter) {
        pw.println("package: ${ctx.packageName}")
        try {
            @Suppress("DEPRECATION")
            val pi = ctx.packageManager.getPackageInfo(ctx.packageName, 0)
            pw.println("versionName: ${pi.versionName}")
            pw.println(
                "versionCode: " +
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) pi.longVersionCode
                else pi.versionCode.toLong()
            )
        } catch (_: Throwable) {}
        pw.println("manufacturer: ${Build.MANUFACTURER}")
        pw.println("model: ${Build.MODEL}")
        pw.println("device: ${Build.DEVICE}")
        pw.println("brand: ${Build.BRAND}")
        pw.println("product: ${Build.PRODUCT}")
        pw.println("androidVersion: ${Build.VERSION.RELEASE} (sdk ${Build.VERSION.SDK_INT})")
        pw.println("supportedAbis: ${Build.SUPPORTED_ABIS.joinToString(",")}")
        try {
            val r = Runtime.getRuntime()
            pw.println("memory: free=${r.freeMemory()} total=${r.totalMemory()} max=${r.maxMemory()}")
        } catch (_: Throwable) {}
    }

    private fun tailLogcat(lines: Int): String {
        // Apps can read their own pid's logcat on modern Android without
        // any permission. If the device's ROM has further restricted
        // logcat, this returns "(empty)" — fine, we still have the stack.
        return try {
            val pid = android.os.Process.myPid()
            val cmd = arrayOf("logcat", "-d", "-t", lines.toString(), "--pid=$pid")
            val proc = ProcessBuilder(*cmd).redirectErrorStream(true).start()
            val out = proc.inputStream.bufferedReader().use { it.readText() }
            proc.waitFor()
            out.ifBlank { "(empty)" }
        } catch (t: Throwable) {
            "(logcat read failed: ${t.javaClass.simpleName}: ${t.message})"
        }
    }

    // -----------------------------------------------------------------
    // Paths

    private fun crashesDir(ctx: Context): File? {
        val base = ctx.getExternalFilesDir(null) ?: return null
        return File(base, DIR_CRASHES)
    }

    private fun sentDir(ctx: Context): File? {
        val crashes = crashesDir(ctx) ?: return null
        return File(crashes, DIR_SENT)
    }

    private fun uniqueFile(dir: File, baseName: String): File {
        // ApplicationExitInfo.timestamp has second granularity; two crashes
        // in the same second would collide. Append a counter when needed.
        val plain = File(dir, "$baseName.txt")
        if (!plain.exists()) return plain
        var i = 2
        while (true) {
            val candidate = File(dir, "${baseName}__$i.txt")
            if (!candidate.exists()) return candidate
            i++
        }
    }

    // -----------------------------------------------------------------
    // Formatting

    private val iso = SimpleDateFormat("yyyy-MM-dd'T'HH-mm-ss", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }

    private fun iso8601(ts: Long): String = iso.format(Date(ts))

    private fun exitReasonName(reason: Int): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return "REASON_$reason"
        return when (reason) {
            ApplicationExitInfo.REASON_UNKNOWN -> "UNKNOWN"
            ApplicationExitInfo.REASON_EXIT_SELF -> "EXIT_SELF"
            ApplicationExitInfo.REASON_SIGNALED -> "SIGNALED"
            ApplicationExitInfo.REASON_LOW_MEMORY -> "LOW_MEMORY"
            ApplicationExitInfo.REASON_CRASH -> "CRASH"
            ApplicationExitInfo.REASON_CRASH_NATIVE -> "CRASH_NATIVE"
            ApplicationExitInfo.REASON_ANR -> "ANR"
            ApplicationExitInfo.REASON_INITIALIZATION_FAILURE -> "INITIALIZATION_FAILURE"
            ApplicationExitInfo.REASON_PERMISSION_CHANGE -> "PERMISSION_CHANGE"
            ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE -> "EXCESSIVE_RESOURCE_USAGE"
            ApplicationExitInfo.REASON_USER_REQUESTED -> "USER_REQUESTED"
            ApplicationExitInfo.REASON_USER_STOPPED -> "USER_STOPPED"
            ApplicationExitInfo.REASON_DEPENDENCY_DIED -> "DEPENDENCY_DIED"
            ApplicationExitInfo.REASON_OTHER -> "OTHER"
            else -> "REASON_$reason"
        }
    }
}
