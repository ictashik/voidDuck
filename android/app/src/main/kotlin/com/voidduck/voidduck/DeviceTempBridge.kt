package com.voidduck.voidduck

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Device thermal readout for the top-left corner display. Reads the
 * battery's reported temperature off the sticky ACTION_BATTERY_CHANGED
 * broadcast — the standard, permission-free way to get a device thermal
 * proxy on Android. No root, no extra permission, no persistent
 * registration needed: the intent is sticky, so a null receiver just
 * returns the last one immediately.
 */
class DeviceTempBridge(private val context: Context) : MethodChannel.MethodCallHandler {
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "getBatteryTemperatureC") {
            result.notImplemented()
            return
        }
        val intent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val tenthsC = intent?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE)
            ?: Int.MIN_VALUE
        if (tenthsC == Int.MIN_VALUE) {
            result.success(null)
        } else {
            result.success(tenthsC / 10.0)
        }
    }
}
