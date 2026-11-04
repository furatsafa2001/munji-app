package co.munji.munji_app

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Hosts the Flutter app and the small bridge Dart uses to keep monitoring
 *  alive with the screen off (see MonitorService). */
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "munji/monitor")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start" -> {
                        val intent = Intent(this, MonitorService::class.java)
                            .putExtra(MonitorService.EXTRA_TITLE, call.argument<String>("title"))
                            .putExtra(MonitorService.EXTRA_TEXT, call.argument<String>("text"))
                            .putExtra(MonitorService.EXTRA_CHANNEL, call.argument<String>("channel"))
                        try {
                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                                startForegroundService(intent)
                            } else {
                                startService(intent)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            // e.g. not allowed from the background on Android 12+
                            result.success(false)
                        }
                    }
                    "stop" -> {
                        stopService(Intent(this, MonitorService::class.java))
                        result.success(true)
                    }
                    "sdkInt" -> result.success(Build.VERSION.SDK_INT)
                    else -> result.notImplemented()
                }
            }
    }
}
