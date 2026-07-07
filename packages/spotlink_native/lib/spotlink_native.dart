/// SpotLink app-local Android native plugins.
///
/// No Dart API lives here — the app talks to the native side over the raw
/// MethodChannels it always used:
///  - `spotlink/fastlane` (+ `spotlink/fastlane/events`): Wi-Fi Direct fast
///    lane, consumed by `PlatformFastLane`.
///  - `spotlink/beacon`: iBeacon wake-torch TX, consumed by `BeaconWake`.
///
/// The point of this package is REGISTRATION, not API: as a Flutter plugin it
/// is auto-registered in every engine — the UI engine AND the foreground
/// service engine that owns the mesh. (Manual registration in MainActivity
/// only reached the UI engine, which silently degraded headless file
/// transfers to LAN-TCP/BLE.)
library;
