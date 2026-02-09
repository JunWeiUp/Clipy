package com.clipyclone.clipy_android

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        FlutterEngineCache.getInstance().put("main_engine", flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "clipy_sync_service_control")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startService" -> {
                        SyncHttpService.start(this)
                        result.success(null)
                    }
                    "stopService" -> {
                        SyncHttpService.stop(this)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
