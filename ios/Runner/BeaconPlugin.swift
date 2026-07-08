import CoreBluetooth
import CoreLocation
import Flutter
import Foundation

/// iBeacon wake path — the one legitimate way to revive a SpotLink app the
/// user swipe-killed (or that never ran since reboot): CoreLocation region
/// monitoring relaunches an app for beacon-region entry even after a user
/// termination, which CoreBluetooth restoration cannot do.
///
/// - RX (monitoring): every SpotLink node monitors one fixed beacon region.
///   When any SpotLink beacon appears nearby, iOS launches us in the
///   background; the Flutter engine boots and the mesh starts — queued
///   messages then flow in over BLE.
/// - TX (transmitting): iOS can only transmit iBeacon in the FOREGROUND, so
///   an open SpotLink app acts as the "wake torch" for dead phones around it.
///   (Android SpotLink transmits in the background — see BeaconPlugin.kt.)
///
/// Channel `spotlink/beacon`: requestAlways / enableMonitoring /
/// disableMonitoring / status / startTx / stopTx.
class BeaconPlugin: NSObject {
  /// Fixed SpotLink wake-beacon identities. Index 0 is the ORIGINAL region —
  /// keep it first so a peer on an older build (which monitors only that one)
  /// is still woken whenever the TX rotation lands back on it.
  ///
  /// Why a set instead of one region: CoreLocation only re-fires didEnterRegion
  /// after a real EXIT (the beacon absent ~30s). If a peer was killed while
  /// "inside" our single region, it never re-enters as long as we keep
  /// transmitting the same UUID → it stays asleep. Rotating the transmitted
  /// region across a set every [txRotateInterval] guarantees a region the peer
  /// is currently OUTSIDE lights up soon, firing a fresh ENTER without waiting
  /// on any exit. Each region also stays silent long enough between turns
  /// (rotateInterval × (count-1) ≈ 36s > the ~30s exit debounce) that the
  /// cycle keeps re-entering even a peer stuck inside one of them.
  static let beaconUUIDs: [UUID] = [
    UUID(uuidString: "7A3B5C4D-1E2F-4A5B-8C9D-0E1F2A3B4C5D")!,
    UUID(uuidString: "7A3B5C4D-1E2F-4A5B-8C9D-0E1F2A3B4C5E")!,
    UUID(uuidString: "7A3B5C4D-1E2F-4A5B-8C9D-0E1F2A3B4C5F")!,
  ]
  /// Legacy single-UUID accessor (index 0).
  static var beaconUUID: UUID { beaconUUIDs[0] }
  private static let monitorFlagKey = "spotlink.beacon.monitor"
  private static let txRotateInterval: TimeInterval = 18

  private let location = CLLocationManager()
  private var tx: CBPeripheralManager?
  private var txWanted = false
  private var txIndex = 0
  private var txTimer: Timer?
  private var channel: FlutterMethodChannel?

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = BeaconPlugin()
    let channel = FlutterMethodChannel(
      name: "spotlink/beacon", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler(instance.handle)
    instance.channel = channel
    instance.location.delegate = instance
    // Default ON: waking after the app was closed is core to an offline
    // messenger, so opt users in and let the Me-tab toggle opt out. (The
    // location permission itself is still requested from Dart on first run.)
    let defaults = UserDefaults.standard
    if defaults.object(forKey: monitorFlagKey) == nil {
      defaults.set(true, forKey: monitorFlagKey)
    }
    // Re-assert monitoring on every launch — including a CoreLocation
    // relaunch after the user killed the app.
    if defaults.bool(forKey: monitorFlagKey) {
      instance.startMonitoring()
    }
  }

  /// Diagnostics: record why the app came alive so a boot can be attributed
  /// to the iBeacon path vs BLE state-restoration. Both native modules append
  /// to the same shared UserDefaults key; Dart drains it into ble.log at boot.
  /// Bounded so it can never grow unbounded across relaunches.
  static func recordWake(_ reason: String) {
    let key = "spotlink.wake.events"
    let defaults = UserDefaults.standard
    var events = defaults.stringArray(forKey: key) ?? []
    events.append("\(reason) \(ISO8601DateFormatter().string(from: Date()))")
    if events.count > 12 { events.removeFirst(events.count - 12) }
    defaults.set(events, forKey: key)
  }

  private func makeRegion(_ index: Int) -> CLBeaconRegion {
    let region = CLBeaconRegion(
      uuid: Self.beaconUUIDs[index], identifier: "spotlink.wake.\(index)")
    region.notifyOnEntry = true
    region.notifyOnExit = false
    return region
  }

  private func startMonitoring() {
    // Monitor every rotation region (well under iOS's 20-region cap).
    for i in Self.beaconUUIDs.indices {
      location.startMonitoring(for: makeRegion(i))
    }
  }

  private func stopMonitoring() {
    for i in Self.beaconUUIDs.indices {
      location.stopMonitoring(for: makeRegion(i))
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "requestAlways":
      location.requestAlwaysAuthorization()
      result(nil)
    case "enableMonitoring":
      UserDefaults.standard.set(true, forKey: Self.monitorFlagKey)
      startMonitoring()
      result(true)
    case "disableMonitoring":
      UserDefaults.standard.set(false, forKey: Self.monitorFlagKey)
      stopMonitoring()
      result(nil)
    case "status":
      let auth: String
      switch location.authorizationStatus {
      case .authorizedAlways: auth = "always"
      case .authorizedWhenInUse: auth = "whenInUse"
      case .denied, .restricted: auth = "denied"
      default: auth = "notDetermined"
      }
      result([
        "auth": auth,
        "monitoring": UserDefaults.standard.bool(forKey: Self.monitorFlagKey),
      ])
    case "wakeEvents":
      // Read (do not clear) the shared wake-cause log; keeping it lets a late
      // didEnterRegion for THIS launch still show up on the next boot's drain.
      result(UserDefaults.standard.stringArray(forKey: "spotlink.wake.events") ?? [])
    case "startTx":
      txWanted = true
      txIndex = 0
      if tx == nil {
        tx = CBPeripheralManager(delegate: self, queue: nil)
      } else {
        startTxIfReady()
      }
      startRotation()
      result(nil)
    case "stopTx":
      txWanted = false
      txTimer?.invalidate()
      txTimer = nil
      tx?.stopAdvertising()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func startRotation() {
    txTimer?.invalidate()
    guard Self.beaconUUIDs.count > 1 else { return }
    txTimer = Timer.scheduledTimer(
      withTimeInterval: Self.txRotateInterval, repeats: true
    ) { [weak self] _ in
      guard let self = self, self.txWanted else { return }
      self.txIndex = (self.txIndex + 1) % Self.beaconUUIDs.count
      // Re-advertise the next region: stop, then start on the new UUID.
      self.tx?.stopAdvertising()
      self.startTxIfReady()
    }
  }

  private func startTxIfReady() {
    guard txWanted, let tx = tx, tx.state == .poweredOn else { return }
    guard !tx.isAdvertising else { return }
    let data = makeRegion(txIndex).peripheralData(withMeasuredPower: nil)
    tx.startAdvertising(((data as NSDictionary) as! [String: Any]))
  }
}

extension BeaconPlugin: CLLocationManagerDelegate {
  func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
    // If we were relaunched just for this, the Flutter engine is already
    // booting and the mesh will start on its own; this nudge is best-effort
    // diagnostics for a live app.
    Self.recordWake("beacon-enter[\(region.identifier)]")
    channel?.invokeMethod("regionEntered", arguments: region.identifier)
  }
}

extension BeaconPlugin: CBPeripheralManagerDelegate {
  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    startTxIfReady()
  }
}
