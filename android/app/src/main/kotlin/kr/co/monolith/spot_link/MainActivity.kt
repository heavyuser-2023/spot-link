package kr.co.monolith.spot_link

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Wi-Fi fast lane (Wi-Fi Direct).
        flutterEngine.plugins.add(FastLanePlugin())
    }
}
