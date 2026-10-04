import CoreBluetooth
import CoreLocation
import Flutter
import Foundation
import UIKit

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
///
/// 채널 `spotlink/location`: currentLocation / reverseGeocode — "스쳐 지나간
/// 친구"(encounter) 기록의 "어디서"를 공급한다. 친구의 폰이 가까이 오면 앱이
/// 언제·누구·어디서를 남기는데, 위치는 이 기기에만 저장되고 메시 피어에게도
/// 우리 쪽 서버에도 보내지 않는다(지명 변환만 Apple 지오코더를 거친다).
/// 위치 권한과 델리게이트를 이미 가진 이 클래스의 CLLocationManager로 단발
/// fix만 요청한다 — region 이벤트는 didUpdateLocations를 부르지 않으므로
/// 웨이크 경로와 서로 간섭하지 않는다. 기대된 실패(권한 없음·위치 꺼짐·
/// 타임아웃·오프라인)는 에러가 아니라 nil로 회신한다. Android 쪽 구현은
/// LocationPlugin.kt.
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
  private var wakeTask: UIBackgroundTaskIdentifier = .invalid
  private var locationChannel: FlutterMethodChannel?
  /// currentLocation 대기자들. 동시에 들어온 호출은 진행 중인 requestLocation
  /// 하나를 함께 기다리고, fix 한 번이 모두를 해결한다(타임아웃은 호출마다 따로).
  private var pendingFixes: [OnceResult] = []
  /// fix 대기용 백그라운드 태스크 — wakeTask와 별개 식별자(beginFixTask 참고).
  private var fixTask: UIBackgroundTaskIdentifier = .invalid

  static func register(with registrar: FlutterPluginRegistrar) {
    let instance = BeaconPlugin()
    let channel = FlutterMethodChannel(
      name: "spotlink/beacon", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler(instance.handle)
    instance.channel = channel
    instance.location.delegate = instance
    // 위치 채널: 만남 기록의 "어디서". 권한 상태와 델리게이트를 이미 가진 위
    // 매니저를 그대로 쓴다 — 매니저를 하나 더 두면 권한·콜백을 두 군데서
    // 관리하게 될 뿐 얻는 것이 없다.
    let locationChannel = FlutterMethodChannel(
      name: "spotlink/location", binaryMessenger: registrar.messenger())
    locationChannel.setMethodCallHandler(instance.handleLocation)
    instance.locationChannel = locationChannel
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

  /// 리전 웨이크가 준 백그라운드 실행 시간(기본 ~10초)을 백그라운드 태스크로
  /// ~30초까지 늘린다. 상대를 발견해 링크를 맺는 데 필요한 전 과정 —
  /// 본딩된 대기 연결의 착지, GATT 셋업, ANNOUNCE 교환 — 이 이 창 안에서
  /// 끝나야 하므로 창의 길이가 곧 성공률이다. 만료 핸들러에서 정리하므로
  /// 시스템 한도를 넘어 붙잡지 않는다.
  private func extendWakeWindow() {
    guard UIApplication.shared.applicationState != .active else { return }
    guard wakeTask == .invalid else { return } // 이미 연장 중
    wakeTask = UIApplication.shared.beginBackgroundTask(withName: "spotlink.wake") {
      [weak self] in
      guard let self = self else { return }
      if self.wakeTask != .invalid {
        UIApplication.shared.endBackgroundTask(self.wakeTask)
        self.wakeTask = .invalid
      }
    }
  }

  // MARK: - 위치 채널 (spotlink/location)

  func handleLocation(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "currentLocation":
      let timeoutMs = (args?["timeoutMs"] as? NSNumber)?.intValue ?? 15_000
      currentLocation(timeoutMs: timeoutMs, result: result)
    case "reverseGeocode":
      guard let lat = (args?["lat"] as? NSNumber)?.doubleValue,
        let lng = (args?["lng"] as? NSNumber)?.doubleValue
      else {
        result(nil)
        return
      }
      reverseGeocode(lat: lat, lng: lng, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// 현재 위치 한 점. 만남의 "어디서"에는 동네 수준이면 충분하므로 100m
  /// 정확도의 단발 요청(requestLocation)만 쓴다 — 연속 업데이트도, GPS를 오래
  /// 켜 두는 일도 없다. 기대된 실패는 전부 nil이고, 호출마다 정확히 한 번 회신한다.
  private func currentLocation(timeoutMs: Int, result: @escaping FlutterResult) {
    switch location.authorizationStatus {
    case .authorizedAlways, .authorizedWhenInUse:
      break
    default:
      // 미결정·거부·제한. 설정에서 위치 서비스 전체를 끈 경우도 .denied로
      // 보고된다. 권한 요청은 Dart 몫이다 — 백그라운드 웨이크 중일 수도 있어
      // 여기서 묻지 않는다.
      result(nil)
      return
    }
    // 최근(60초 이내)이고 충분히 정확한(200m 이내) 캐시가 있으면 무선을 깨우지
    // 않는다. 음수 정확도는 좌표 자체가 무효라는 뜻이다.
    if let cached = location.location,
      cached.horizontalAccuracy >= 0, cached.horizontalAccuracy <= 200,
      -cached.timestamp.timeIntervalSinceNow <= 60
    {
      result(Self.locationPayload(cached))
      return
    }
    let waiter = OnceResult(result)
    pendingFixes.append(waiter)
    if pendingFixes.count == 1 {
      // 첫 대기자만 요청을 건다 — 이후 호출은 진행 중인 같은 fix에 합류한다.
      beginFixTask()
      location.desiredAccuracy = kCLLocationAccuracyHundredMeters
      location.requestLocation()
    }
    // 호출마다 자기 타임아웃: 늦게 합류한 호출이 먼저 온 호출의 대기 시간을
    // 줄이거나 늘리지 않는다. 요청 자체는 CoreLocation이 스스로 끝내므로 두고,
    // 늦게 도착한 fix는 그때 남아 있는 대기자에게 간다.
    let delay = Double(max(0, timeoutMs)) / 1000
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard !waiter.isDone else { return }
      waiter.reply(nil)
      guard let self = self else { return }
      self.pendingFixes.removeAll { $0 === waiter }
      if self.pendingFixes.isEmpty { self.endFixTask() }
    }
  }

  /// 대기 중인 currentLocation 호출 전부를 같은 값으로 해결하고 백그라운드
  /// 태스크를 반납한다.
  private func resolvePendingFixes(_ payload: [String: Any]?) {
    let waiting = pendingFixes
    pendingFixes.removeAll()
    for waiter in waiting { waiter.reply(payload) }
    endFixTask()
  }

  /// fix를 기다리는 동안 앱이 정지되지 않게 붙잡는다. 만남은 대개 beacon
  /// region 웨이크로 백그라운드에서 깨어난 직후에 기록되는데, 그 짧은 실행
  /// 창만으로는 fix가 오기 전에 앱이 정지될 수 있다. wakeTask(링크 수립용)와
  /// 수명이 달라 별도 식별자로 관리한다 — 한쪽이 끝나도 다른 쪽을 놓지 않게.
  /// 포그라운드에서 시작해도 비용이 없고 요청 도중 백그라운드로 내려가는
  /// 경우까지 덮으므로, 앱 상태와 무관하게 대기 중에는 항상 붙잡는다.
  private func beginFixTask() {
    guard fixTask == .invalid else { return }
    fixTask = UIApplication.shared.beginBackgroundTask(withName: "spotlink.location") {
      [weak self] in
      // 시스템이 남은 시간을 거둬 가기 직전: 대기자를 nil로 정리하고 반납한다.
      self?.resolvePendingFixes(nil)
    }
  }

  private func endFixTask() {
    guard fixTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(fixTask)
    fixTask = .invalid
  }

  /// 좌표 → 짧은 지명 한 줄(기기 로캘). 오프라인·지오코더 오류·10초 초과는 nil.
  private func reverseGeocode(lat: Double, lng: Double, result: @escaping FlutterResult) {
    guard CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: lat, longitude: lng))
    else {
      result(nil)
      return
    }
    let once = OnceResult(result)
    // 호출마다 새 지오코더: CLGeocoder 하나는 한 번에 요청 하나만 받는다(진행
    // 중에 새 요청을 걸지 말라고 문서화돼 있다) — 공유하면 동시 호출끼리 충돌한다.
    // CLGeocoder는 iOS 26부터 MapKit(MKReverseGeocodingRequest) 쪽으로 deprecated
    // 됐지만 여전히 동작하고, 배포 대상(iOS 15)을 모두 덮는 유일한 API다.
    let geocoder = CLGeocoder()
    geocoder.reverseGeocodeLocation(
      CLLocation(latitude: lat, longitude: lng), preferredLocale: Locale.current
    ) { placemarks, error in
      // 완료 핸들러는 메인 스레드에서 불린다.
      guard error == nil, let placemark = placemarks?.first else {
        once.reply(nil)
        return
      }
      once.reply(Self.placeLabel(placemark))
    }
    // 오프라인이면 지오코더가 네트워크 타임아웃까지 한참 매달릴 수 있다 —
    // 만남 기록이 지명 하나 때문에 늦어지지 않게 10초에서 끊는다. 이 클로저가
    // geocoder를 붙잡아 요청 도중 해제되지 않게 하는 역할도 겸한다.
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
      guard !once.isDone else { return }
      geocoder.cancelGeocode()
      once.reply(nil)
    }
  }

  /// 채널 계약의 위치 맵: lat/lng(도), accuracy(m — 모르면 키 생략).
  private static func locationPayload(_ fix: CLLocation) -> [String: Any] {
    var payload: [String: Any] = [
      "lat": fix.coordinate.latitude,
      "lng": fix.coordinate.longitude,
    ]
    if fix.horizontalAccuracy >= 0 { payload["accuracy"] = fix.horizontalAccuracy }
    return payload
  }

  /// 주소 조각으로 짧은 지명 한 줄을 만든다 — Android LocationPlugin.placeLabel과
  /// 같은 규칙: 광역 → 시·구 → 동 → 길 순서로, 빈 조각과 바로 앞 조각과 같은
  /// 조각(예: 광역시의 administrativeArea == locality)은 건너뛰고 공백 하나로
  /// 잇는다. 예) 한국어 기기: "서울특별시 강남구 역삼동 테헤란로".
  /// locality가 없는 주소(군·시골 지역 등)는 subAdministrativeArea가 그 자리를
  /// 메운다. 남는 조각이 없으면 nil.
  static func placeLabel(_ placemark: CLPlacemark) -> String? {
    func clean(_ raw: String?) -> String? {
      guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
        !trimmed.isEmpty
      else { return nil }
      return trimmed
    }
    let candidates = [
      clean(placemark.administrativeArea),
      clean(placemark.locality) ?? clean(placemark.subAdministrativeArea),
      clean(placemark.subLocality),
      clean(placemark.thoroughfare),
    ]
    var parts: [String] = []
    for case let part? in candidates where part != parts.last {
      parts.append(part)
    }
    return parts.isEmpty ? nil : parts.joined(separator: " ")
  }
}

extension BeaconPlugin: CLLocationManagerDelegate {
  func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
    // 바로 이것 때문에 재실행된 경우라면 Flutter 엔진은 이미 부팅 중이고
    // 메시는 알아서 시작된다; 이 알림은 살아 있는 앱을 위한 best-effort
    // 진단용이다.
    Self.recordWake("beacon-enter[\(region.identifier)]")
    extendWakeWindow()
    channel?.invokeMethod("regionEntered", arguments: region.identifier)
  }

  // requestLocation()은 아래 두 메서드가 모두 구현돼 있어야 한다(하나라도 없으면
  // 호출 즉시 예외로 죽는다). region 모니터링은 이 둘을 부르지 않는다 — 여기
  // 오는 것은 위치 채널의 단발 fix뿐이라 웨이크 경로와 섞이지 않는다.
  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    // 음수 정확도는 좌표 자체가 무효라는 뜻이다 — 유효한 것 중 가장 최근 것.
    guard let fix = locations.last(where: { $0.horizontalAccuracy >= 0 }) else {
      resolvePendingFixes(nil)
      return
    }
    resolvePendingFixes(Self.locationPayload(fix))
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    // 단발 요청의 실패는 최종이다(CoreLocation이 재시도하지 않는다) — 거부·위치
    // 미상 모두 nil.
    resolvePendingFixes(nil)
  }
}

extension BeaconPlugin: CBPeripheralManagerDelegate {
  func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
    startTxIfReady()
  }
}

/// FlutterResult를 정확히 한 번만 부르게 하는 래퍼. 타임아웃과 실제 완료가
/// 경합해도 두 번째 회신은 버린다 — Flutter 결과는 호출마다 한 번만 회신해야
/// 한다. 메인 스레드 전용(채널 핸들러·CoreLocation 델리게이트·CLGeocoder 완료
/// 핸들러·asyncAfter 타이머가 모두 메인에서 돈다).
private final class OnceResult {
  private var result: FlutterResult?

  init(_ result: @escaping FlutterResult) {
    self.result = result
  }

  var isDone: Bool { result == nil }

  func reply(_ value: Any?) {
    guard let result = result else { return }
    self.result = nil
    result(value)
  }
}
