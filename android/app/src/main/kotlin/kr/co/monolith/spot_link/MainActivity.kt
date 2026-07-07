package kr.co.monolith.spot_link

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // FastLane/Beacon live in the spotlink_native plugin package now, so
        // they auto-register in every engine (this one AND the mesh-owning
        // foreground-service engine, which never runs this method).
        //
        // Offline self-distribution: hand Dart the path of our own installed
        // APK so it can be shared/sent without any app store. UI-only.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "spotlink/app")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "apkPath" -> result.success(applicationInfo.publicSourceDir)
                    else -> result.notImplemented()
                }
            }
    }
}
