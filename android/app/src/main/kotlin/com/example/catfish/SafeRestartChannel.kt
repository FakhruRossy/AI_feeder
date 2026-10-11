// 🟢 REVISI (P1 / Room 9): relaunch app untuk SafeRestartScheduler.
// PendingIntent + AlarmManager menyalakan app lagi, lalu proses ini dimatikan.
package com.example.catfish // TODO verifikasi: samakan dengan applicationId / package MainActivity

import android.app.Activity
import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.Process
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

object SafeRestartChannel {
    const val CHANNEL = "catfish/safe_restart"
    private const val REQUEST_CODE = 9001
    private const val KILL_AFTER_MS = 300L

    fun register(activity: Activity, messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "relaunch" -> {
                    // Alarm HARUS menyala setelah proses lama mati (KILL_AFTER_MS).
                    val delayMs = (call.argument<Number>("delayMs")?.toLong() ?: 1500L)
                        .coerceIn(1000L, 10000L)
                    try {
                        relaunch(activity, delayMs)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("relaunch_failed", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun relaunch(activity: Activity, delayMs: Long) {
        val ctx = activity.applicationContext
        val intent = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
            ?: throw IllegalStateException("launch intent null")
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        val pi = PendingIntent.getActivity(
            ctx,
            REQUEST_CODE,
            intent,
            PendingIntent.FLAG_CANCEL_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val am = ctx.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        am.setExact(AlarmManager.RTC_WAKEUP, System.currentTimeMillis() + delayMs, pi)
        Handler(Looper.getMainLooper()).postDelayed({
            activity.finishAffinity()
            Process.killProcess(Process.myPid())
        }, KILL_AFTER_MS)
    }
}
