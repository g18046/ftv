package com.example.ftv

import android.app.PictureInPictureParams
import android.os.Build
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.example.ftv/pip"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val w = call.argument<Int>("numerator") ?: 16
                val h = call.argument<Int>("denominator") ?: 9
                val params = PictureInPictureParams.Builder().setAspectRatio(Rational(w, h))

                if (call.method == "enterPip") {
                    result.success(enterPictureInPictureMode(params.build()))
                } else if (call.method == "enableAutoPip") {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        val enabled = call.argument<Boolean>("enabled") ?: true
                        params.setAutoEnterEnabled(enabled)
                        setPictureInPictureParams(params.build())
                    }
                    result.success(true)
                } else {
                    result.notImplemented()
                }
            } else {
                result.success(false)
            }
        }
    }
}