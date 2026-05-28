package com.hiddify.hiddify

import android.app.Activity
import android.os.Bundle

/**
 * family_vpn fork: standalone "Логи" launcher icon that lets the user
 * ship crash dumps even when MainActivity is in a crash-loop (libhiddify-core
 * fails to dlopen, gomobile init throws, Flutter engine refuses to start).
 *
 * Hard invariant: this Activity MUST NOT touch any gomobile / libhiddify-core
 * code, must NOT call Seq.setContext, must NOT load any class that triggers
 * a JNI dependency. The only Application path it shares with MainActivity is
 * Application.onCreate, which (in this fork) is also kept gomobile-free.
 *
 * Behaviour:
 *  - On launch, scan filesDir/crashes for unsent reports (the same path
 *    CrashReporter writes to).
 *  - If any exist, show the standard "Отправить Володе?" dialog.
 *  - If none, show "Нет отчётов об ошибках" so the user knows the tap
 *    landed (vs the activity silently flickering closed).
 *  - In both cases, finish() once the dialog is dismissed — no UI to leave
 *    behind.
 *
 * Theme is the transparent NoDisplay-style theme so no chrome flashes
 * behind the dialog.
 */
class DiagnoseActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Trigger an ApplicationExitInfo sweep in case the user is opening
        // Diagnose immediately after a crash — we want the latest tombstone
        // pulled into filesDir/crashes before listUnsent runs.
        try {
            CrashReporter.checkPastCrashes(this.applicationContext)
        } catch (_: Throwable) {
            // checkPastCrashes is best-effort and never throws under normal
            // conditions; swallow here so a broken ExitInfo path can't
            // prevent the user from sharing earlier dumps.
        }

        if (hasAnyCrash()) {
            CrashReporter.shareCrashesIfAny(this) { finish() }
        } else {
            CrashReporter.showNoCrashesDialog(this) { finish() }
        }
    }

    private fun hasAnyCrash(): Boolean {
        val base = getExternalFilesDir(null) ?: return false
        val dir = java.io.File(base, "crashes")
        if (!dir.isDirectory) return false
        val files = dir.listFiles { f -> f.isFile && f.name.endsWith(".txt") }
        return files != null && files.isNotEmpty()
    }
}
