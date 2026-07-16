package kr.co.monolith.spotlink_native

import io.flutter.embedding.engine.plugins.FlutterPlugin

/**
 * 복합 진입점: Flutter 플러그인은 정확히 하나의 pluginClass만 선언하므로,
 * 이 클래스가 엔진 라이프사이클을 SpotLink의 네이티브 조각들로 분배한다.
 * (MainActivity 수동 등록이 아니라) 플러그인으로 두는 것이 바로 이들을
 * 모든 엔진에 넣어 주는 방법이다 — Activity가 없고 configureFlutterEngine을
 * 결코 실행하지 않는, 메시를 소유한 포그라운드 서비스 엔진까지 포함해서.
 */
class SpotlinkNativePlugin : FlutterPlugin {
    private val fastLane = FastLanePlugin()
    private val beacon = BeaconPlugin()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        fastLane.onAttachedToEngine(binding)
        beacon.onAttachedToEngine(binding)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        fastLane.onDetachedFromEngine(binding)
        beacon.onDetachedFromEngine(binding)
    }
}
