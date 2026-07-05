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
    // Wi-Fi fast lane (MultipeerConnectivity).
    FastLanePlugin.register(
      with: engineBridge.pluginRegistry.registrar(forPlugin: "FastLanePlugin")!)
    // iBeacon wake: re-arms region monitoring on every launch, including a
    // CoreLocation relaunch after the user swipe-killed the app.
    BeaconPlugin.register(
      with: engineBridge.pluginRegistry.registrar(forPlugin: "BeaconPlugin")!)
  }
}
