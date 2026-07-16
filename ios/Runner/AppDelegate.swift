import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Wi-Fi 패스트 레인 (MultipeerConnectivity).
    FastLanePlugin.register(
      with: engineBridge.pluginRegistry.registrar(forPlugin: "FastLanePlugin")!)
    // iBeacon 웨이크: 매 실행마다 region 모니터링을 다시 활성화한다 — 사용자가
    // 앱을 스와이프로 강제 종료한 뒤의 CoreLocation 재실행도 포함해서.
    BeaconPlugin.register(
      with: engineBridge.pluginRegistry.registrar(forPlugin: "BeaconPlugin")!)
  }
}
