import CoreBluetooth
import CoreLocation
import Flutter
import Foundation

/// iBeacon 웨이크 경로 — 사용자가 스와이프로 강제 종료했거나(또는 재부팅 이후
/// 한 번도 실행된 적 없는) SpotLink 앱을 되살릴 수 있는 유일한 정식 방법:
/// CoreLocation의 region 모니터링은 사용자 강제 종료 이후에도 beacon region
/// 진입 시 앱을 다시 실행해 주는데, 이는 CoreBluetooth 복원으로는 불가능하다.
///
/// - RX (모니터링): 모든 SpotLink 노드는 고정된 하나의 beacon region을 모니터링한다.
///   근처에 SpotLink beacon이 나타나면 iOS가 백그라운드에서 우리를 실행시키고,
///   Flutter 엔진이 부팅되면서 메시가 시작된다 — 그러면 대기 중이던
///   메시지들이 BLE를 통해 흘러 들어온다.
/// - TX (송신): iOS는 오직 FOREGROUND에서만 iBeacon을 송신할 수 있으므로,
///   열려 있는 SpotLink 앱이 주변의 꺼진 폰들을 위한 "웨이크 횃불" 역할을 한다.
///   (Android SpotLink은 백그라운드에서 송신한다 — BeaconPlugin.kt 참고.)
///
/// 채널 `spotlink/beacon`: requestAlways / enableMonitoring /
/// disableMonitoring / status / startTx / stopTx.
class BeaconPlugin: NSObject {
  /// 고정된 SpotLink 웨이크 beacon 식별자들. 인덱스 0이 ORIGINAL region이다 —
  /// 이걸 맨 앞에 두어야, 이 region 하나만 모니터링하는 이전 빌드의 피어도
  /// TX 로테이션이 다시 이 region으로 돌아올 때마다 계속 깨어날 수 있다.
  ///
  /// 하나의 region이 아니라 집합을 쓰는 이유: CoreLocation은 실제 EXIT가
  /// 발생한 뒤에야(beacon이 ~30초간 사라진 뒤에야) didEnterRegion을 다시
  /// 발생시킨다. 피어가 우리의 단일 region "안에" 있는 상태로 종료됐다면,
  /// 우리가 같은 UUID를 계속 송신하는 한 그 피어는 결코 재진입하지 못하고
  /// → 계속 잠들어 있게 된다. 송신 region을 [txRotateInterval]마다 집합에 걸쳐
  /// 로테이션하면, 피어가 현재 OUTSIDE 상태인 region이 곧 켜지는 것이 보장되어
  /// 어떤 exit도 기다릴 필요 없이 새로운 ENTER가 발생한다. 또한 각 region은
  /// 자기 차례 사이에 충분히 오래 침묵하므로
  /// (rotateInterval × (count-1) ≈ 36초 > ~30초의 exit 디바운스), 그 사이클은
  /// 이 region들 중 하나 안에 갇힌 피어조차도 계속 재진입시킨다.
  static let beaconUUIDs: [UUID] = [
    UUID(uuidString: "7A3B5C4D-1E2F-4A5B-8C9D-0E1F2A3B4C5D")!,
    UUID(uuidString: "7A3B5C4D-1E2F-4A5B-8C9D-0E1F2A3B4C5E")!,
    UUID(uuidString: "7A3B5C4D-1E2F-4A5B-8C9D-0E1F2A3B4C5F")!,
  ]
  /// 레거시 단일 UUID 접근자 (인덱스 0).
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
    // 기본값 ON: 앱이 닫힌 뒤 깨어나는 것은 오프라인 메신저의 핵심 기능이므로,
    // 사용자를 기본적으로 참여시키고 Me 탭 토글로 해제할 수 있게 한다. (위치
    // 권한 자체는 여전히 첫 실행 시 Dart에서 요청한다.)
    let defaults = UserDefaults.standard
    if defaults.object(forKey: monitorFlagKey) == nil {
      defaults.set(true, forKey: monitorFlagKey)
    }
    // 매 실행마다 모니터링을 다시 활성화한다 — 사용자가 앱을 종료한 뒤의
    // CoreLocation 재실행도 포함해서.
    if defaults.bool(forKey: monitorFlagKey) {
      instance.startMonitoring()
    }
  }

  /// 진단용: 앱이 되살아난 이유를 기록해, 어떤 부팅이 iBeacon 경로 때문인지
  /// BLE 상태 복원 때문인지 구분할 수 있게 한다. 두 네이티브 모듈 모두 동일한
  /// 공유 UserDefaults 키에 append하며, Dart가 부팅 시 이를 ble.log로 비운다.
  /// 재실행이 반복돼도 무한히 커지지 않도록 개수를 제한한다.
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
    // 모든 로테이션 region을 모니터링한다 (iOS의 20개 region 상한에 한참 못 미친다).
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
      // 공유된 웨이크 원인 로그를 읽는다(지우지는 않는다); 남겨 두면 THIS 실행에
      // 대한 뒤늦은 didEnterRegion도 다음 부팅의 비우기 때 여전히 나타날 수 있다.
      result(UserDefaults.standard.stringArray(forKey: "spotlink.wake.events") ?? [])
    case "startTx":
      txWanted = true
      // 여기서 txIndex를 리셋하면 안 된다. startTx는 매 포그라운드 복귀 시마다
      // 발생하므로, 리셋하면 잠깐(18초짜리 로테이션 한 턴 미만) 열렸던 폰은
      // 언제나 region 0만 송신하게 된다 — 그러면 region 0 "안에" 갇힌 피어
      // (notifyOnExit=false)는 결코 다시 깨어날 수 없다. 대신 인덱스를 전진시키면
      // 짧은 포그라운드 세션조차도 region들을 순환하게 된다.
      if tx != nil {
        txIndex = (txIndex + 1) % Self.beaconUUIDs.count
        tx?.stopAdvertising()
        startTxIfReady()
      } else {
        tx = CBPeripheralManager(delegate: self, queue: nil)
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
      // 다음 region을 다시 광고한다: 중지한 뒤, 새 UUID로 시작한다.
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
    // 바로 이것 때문에 재실행된 경우라면 Flutter 엔진은 이미 부팅 중이고
    // 메시는 알아서 시작된다; 이 알림은 살아 있는 앱을 위한 best-effort
    // 진단용이다.
    Self.recordWake("beacon-enter[\(region.identifier)]")
    channel?.invokeMethod("regionEntered", arguments: region.identifier)
  }
}

extension BeaconPlugin: CBPeripheralManagerDelegate {
  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    startTxIfReady()
  }
}
