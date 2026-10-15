import 'dart:io' show Platform;

/// 플랫폼별 무선 정책 — **새 플랫폼을 추가할 때 채워야 할 단 하나의 파일**.
///
/// 왜 존재하는가: 발견·연결 로직에는 실기기에서만 드러나는 OS별 결함 대응이
/// 겹겹이 쌓인다(iOS 27의 128비트 UUID 필터 미매칭, 백그라운드 iPhone의
/// overflow 광고, Android의 status 133, 주소 회전, CoreBluetooth 세션 노화…).
/// 예전에는 이 결정들이 `Platform.isIOS` / `Platform.isAndroid` 분기로 전송·앱
/// 계층 25곳에 흩어져 있었다. 그 결과:
///
///  * **macOS가 우연히 2등 시민이 됐다** — 모든 분기의 else로 떨어져 필터
///    스캔만 돌았고(→ iOS 27 포그라운드 iPhone을 발견 못 함), 식별자 기반
///    대기 연결과 스택 하드리셋도 받지 못했다. 같은 CoreBluetooth인데도.
///  * 새 플랫폼(Windows/Linux/웨어러블)을 붙이면 25곳을 전부 감사해야 했다.
///
/// 이제 각 결정은 **이름을 가진 정책 값**이고, 메커니즘(타이머·상태기계·
/// 복구 경로)은 전부 플랫폼 중립이다. 새 플랫폼은 여기에 프로파일 하나를
/// 추가하면 되고, 빠뜨린 값은 [RadioProfile.generic]의 보수적 기본값으로
/// 안전하게 동작한다(최적은 아니지만 절대 침묵하지 않는다).
///
/// 테스트 이점: 프로파일을 주입할 수 있으므로 iOS/Android 정책의 동작을
/// 맥에서 단위 테스트로 고정할 수 있다(test/radio_profile_test.dart).
/// 스쳐간 친구 기록에 **위치를 언제 붙일 수 있는가** — 플랫폼 권한 모델이
/// 결정한다(좌표는 이 기기에만 저장된다).
enum EncounterLocationPolicy {
  /// 위치를 붙이지 않는다(권한·문구가 준비되지 않은 플랫폼).
  never,

  /// 앱 화면이 떠 있을 때만. Android는 백그라운드 위치(ACCESS_BACKGROUND_
  /// LOCATION)를 쓰려면 Play 별도 심사가 필요해 "사용 중에만" 권한으로 한정한다.
  foregroundOnly,

  /// 백그라운드에서도. iOS는 비콘 웨이크용 "항상 허용" 권한이 이미 있어,
  /// 비콘에 깨어난 짧은 창에도 위치를 받을 수 있다.
  always,
}

class RadioProfile {
  /// 로그·진단용 이름.
  final String name;

  /// 데스크톱 계열인가. 무선 정책이 아니라 **안내 문구·UX 결정**에 쓴다
  /// (예: 권한 안내가 iOS의 "설정 > 앱"이 아니라 "시스템 설정 > 개인정보
  /// 보호 및 보안"을 가리켜야 한다). UI가 Platform 분기를 다시 뿌리지 않게
  /// 여기 둔다.
  final bool isDesktop;

  // ---------------------------------------------------------------------------
  // 스캔 정책
  // ---------------------------------------------------------------------------

  /// 언제나 무필터로 스캔하고 SpotLink 여부는 소프트웨어로 판정한다.
  /// Android가 이 쪽: 하드웨어 service-UUID 필터가 iPhone의 overflow 영역
  /// 광고를 아예 매칭하지 못한다(Results=0).
  final bool scanAlwaysUnfiltered;

  /// 무필터 창과 필터 창을 번갈아 쓴다. **어느 한 모드도 두 부류를 함께
  /// 커버하지 못하기 때문**이다:
  ///  * 포그라운드 iPhone(iOS 27): 128비트 service UUID가 필터에 매칭되지도,
  ///    파싱된 광고에 드러나지도 않는다 → 무필터 + 이름 매칭만이 찾아낸다.
  ///  * 백그라운드 iPhone: 광고가 overflow 영역으로 옮겨가 **필터 스캔에만**
  ///    전달된다(이름도 숨는다).
  /// CoreBluetooth 계열(iOS·macOS)이 이 쪽이다.
  final bool alternatesScanWindows;

  /// 앱 포그라운드/백그라운드 전환 시 스캔 모드를 다시 세워야 한다
  /// (백그라운드에서는 OS가 UUID 필터를 강제하는 계열).
  final bool switchesScanModeOnForeground;

  /// 스캔 전력 등급(저전력/균형/저지연)을 런타임에 조절하는 채널이 있다.
  /// Android 전용 — 배터리 최대 소모원이라 적응형으로 낮춘다.
  final bool supportsScanPowerTuning;

  // ---------------------------------------------------------------------------
  // 연결 정책
  // ---------------------------------------------------------------------------

  /// 식별자 기반 연결이 **타임아웃 없이 OS가 계속 붙들고 있다가** 피어가
  /// 범위에 돌아오면 완료된다(CoreBluetooth의 pending connect). 백그라운드
  /// 피어는 스캔에 안 보이므로 이것이 유일한 재연결 경로다.
  /// Android의 connect()는 반대로 재시도 동안 무선 슬롯을 막으므로 쓰지 않는다.
  final bool usesPendingConnect;

  /// connect 핸드셰이크 동안 스캔을 멈춘다. Android에서 스캔과 connect가
  /// 하나의 무선을 다투면 삼성 등에서 `status 133`으로 모든 dial이 실패한다.
  final bool pausesScanWhileConnecting;

  /// 일반(non-probe) connect의 상한. null이면 무제한 — [usesPendingConnect]
  /// 설계에서는 몇 분 뒤 완료되는 것이 정상이라 상한을 두면 안 된다.
  /// 그 외 스택에서는 반드시 상한을 둬야 막힌 dial이 스캔을 영원히
  /// 일시정지된 채로 붙들지 않는다.
  final Duration? connectTimeout;

  /// 근처 Apple 기기(manufacturer id 0x004C)를 프로브 다이얼해 GATT로
  /// SpotLink 여부를 판정한다. **백그라운드 iPhone은 광고에 아무 표식도
  /// 남기지 않으므로** 이것이 Android가 그들을 찾는 유일한 방법이다.
  final bool probesAppleDevices;

  /// 광고의 이름('SL') 단계가 실패하면 **서비스 UUID만으로 광고**한다.
  ///
  /// Android 플러그인은 이름을 광고하려고 블루투스 어댑터 이름을 바꾸고 그
  /// 완료 방송(ACTION_LOCAL_NAME_CHANGED)을 기다린다. 이 단계가 거부되거나
  /// 방송이 오지 않으면 광고 전체가 실패하거나 영영 매달려, 그 폰은 어떤
  /// 스캔에도 보이지 않는다 — 네이티브 웨이크 토치는 이름을 안 쓰므로 혼자
  /// 살아 iPhone을 깨운다("알림은 오는데 레이더엔 없음"의 또 다른 경로).
  /// Android 광고자는 서비스 UUID만으로 iOS(백그라운드 필터 스캔 포함)와
  /// Android 모두에게 발견되므로 이름은 없어도 된다. iOS는 iPhone끼리의
  /// 포그라운드 발견이 이름에 의존하므로 끄지 않는다.
  final bool advertiseNameOptional;

  /// 알 수 없는/회전된 식별자로 connect할 때 스택이 던지는 오류를 식별한다.
  /// CoreBluetooth는 `illegalArgument`를 던진다 — 그러면 저장된 식별자를
  /// 버리고 스캔으로 새 주소를 찾는다.
  final bool Function(Object error) isUnknownIdentifierError;

  // ---------------------------------------------------------------------------
  // 복구 정책
  // ---------------------------------------------------------------------------

  /// 장시간 세션에서 네이티브 스택이 조용히 죽는 계열이라, 발견·링크 진전이
  /// 오래 없으면 네이티브 central을 제자리에서 재초기화한다.
  /// (2026-07-25 관찰: iOS 19.5시간 세션에서 스캔 전달과 pending connect 완료가
  /// 동시에 정지 — 앱 재시작만 치료됐다. 같은 CoreBluetooth인 macOS도 대상.)
  final bool needsStackHardReset;

  // ---------------------------------------------------------------------------
  // 앱 계층 정책(웨이크·전력)
  // ---------------------------------------------------------------------------

  /// iBeacon 리전 모니터링으로 **종료된 앱을 OS가 되살릴 수 있다**. 이것이
  /// 스와이프 킬된 상대를 깨우는 유일한 경로다(위치 권한 '항상' 필수).
  /// macOS는 CBPeripheralManager가 manufacturer data를 막아 iBeacon TX가
  /// 불가능하다 → 토치 역할을 못 한다.
  final bool supportsBeaconWake;

  /// 링크 수·충전 상태에 따라 스캔 전력을 적응적으로 조절한다(Android).
  final bool usesAdaptivePower;

  /// 앱 수명주기가 스캔 정책을 좌우하므로, 부팅 직후 포그라운드 상태를
  /// 재확인해 오판을 교정한다(iOS는 실행 직후 잠깐 `inactive`를 보고한다).
  final bool reconcilesForegroundMode;

  /// 표시 이름이 없을 때 **기기 이름으로 자동 채우고 메시를 바로 시작**한다.
  ///
  /// 왜: 메시는 이름이 정해진 뒤에야 시작된다. 폰에서는 첫 실행에 사람이
  /// 이름을 넣는 것이 자연스럽지만, 데스크톱 노드는 그대로 두면 **"설치되어
  /// 실행 중인데 아무에게도 보이지 않는"** 최악의 상태로 조용히 방치된다
  /// (2026-07-09~25 실제: 맥이 온보딩 화면에 멈춘 채 16일간 메시에 참여하지
  /// 못했고, DB조차 만들어지지 않았다 — 배포·실행은 매번 성공했으므로 아무도
  /// 눈치채지 못했다). 데스크톱은 호스트명으로 시작하고, 이름은 '내 정보'에서
  /// 언제든 바꾼다.
  ///
  /// 미지의 플랫폼(generic)은 false로 둔다: 온보딩 화면이 보이는 것은 눈에
  /// 띄는 상태이고, 조용한 실명보다 낫다.
  final bool autoAdoptsDeviceName;

  /// 스쳐간 친구 기록에 위치를 붙이는 정책. 미지의 플랫폼은 [never] — 권한
  /// 문구·요청 흐름이 갖춰진 플랫폼만 켠다.
  final EncounterLocationPolicy encounterLocation;

  const RadioProfile({
    required this.name,
    this.scanAlwaysUnfiltered = true,
    this.alternatesScanWindows = false,
    this.switchesScanModeOnForeground = false,
    this.supportsScanPowerTuning = false,
    this.usesPendingConnect = false,
    this.pausesScanWhileConnecting = false,
    this.connectTimeout = const Duration(seconds: 20),
    this.probesAppleDevices = false,
    this.advertiseNameOptional = false,
    this.isUnknownIdentifierError = _never,
    this.needsStackHardReset = false,
    this.supportsBeaconWake = false,
    this.usesAdaptivePower = false,
    this.reconcilesForegroundMode = false,
    this.autoAdoptsDeviceName = false,
    this.isDesktop = false,
    this.encounterLocation = EncounterLocationPolicy.never,
  });

  static bool _never(Object _) => false;

  /// 이번 스캔 창을 **무필터**로 열 것인가. 발견 로직에서 가장 위험한 결정이라
  /// (여기서 틀리면 특정 플랫폼이 조용히 눈먼다 — 실제로 맥이 그랬다) 순수
  /// 함수로 분리해 모든 플랫폼 정책을 단위 테스트로 고정한다.
  ///
  /// - [foreground]: 앱이 포그라운드인가. 백그라운드에서는 CoreBluetooth 계열
  ///   OS가 service-UUID 필터를 강제한다(무필터는 아무것도 전달하지 않는다).
  /// - [overflowPhase]: 교대 주기에서 지금이 '필터 창'인가. 백그라운드 피어의
  ///   overflow 영역 광고는 필터 스캔에만 전달되므로 주기적으로 필요하다.
  /// - [diagOverride]: 진단 빌드(DIAG_UNFILTERED) — 스캐너 생사 판별용.
  bool useUnfilteredScan({
    required bool foreground,
    required bool overflowPhase,
    bool diagOverride = false,
  }) {
    if (diagOverride) return true;
    if (scanAlwaysUnfiltered) return true;
    return alternatesScanWindows && foreground && !overflowPhase;
  }

  /// CoreBluetooth의 회전된/알 수 없는 식별자 오류.
  static bool _isCoreBluetoothIllegalArgument(Object error) =>
      error.toString().contains('illegalArgument');

  /// iOS: 백그라운드 제약이 가장 심하고 복구 장치가 가장 많이 필요한 플랫폼.
  static const ios = RadioProfile(
    name: 'ios',
    scanAlwaysUnfiltered: false, // 백그라운드에서는 OS가 필터를 강제한다
    alternatesScanWindows: true,
    switchesScanModeOnForeground: true,
    usesPendingConnect: true,
    connectTimeout: null, // 대기 연결은 몇 분 뒤 완료되는 것이 정상
    isUnknownIdentifierError: _isCoreBluetoothIllegalArgument,
    needsStackHardReset: true,
    supportsBeaconWake: true,
    reconcilesForegroundMode: true,
    encounterLocation: EncounterLocationPolicy.always,
  );

  /// macOS(그리고 향후 다른 Darwin 데스크톱): iOS와 같은 CoreBluetooth를
  /// 쓰므로 스캔 교대·대기 연결·하드리셋을 **모두 받아야 한다**. 예전에는
  /// 모든 플랫폼 분기의 else로 떨어져 필터 스캔만 돌았고, 그래서 iOS 27
  /// 포그라운드 iPhone을 발견하지 못한 채 상대가 dial해 주기만 기다렸다.
  /// 데스크톱은 앱이 OS에 의해 suspend되지 않으므로 비콘 웨이크는 불필요하고,
  /// iBeacon TX 자체가 불가능하다.
  static const darwinDesktop = RadioProfile(
    name: 'darwin-desktop',
    scanAlwaysUnfiltered: false,
    alternatesScanWindows: true,
    switchesScanModeOnForeground: true,
    usesPendingConnect: true,
    connectTimeout: null,
    isUnknownIdentifierError: _isCoreBluetoothIllegalArgument,
    needsStackHardReset: true,
    autoAdoptsDeviceName: true, // 데스크톱이 모달에서 조용히 멈추지 않게
    isDesktop: true,
  );

  /// Android: 무선을 직접 다루는 대신 스캔·연결 경합과 전력을 관리해야 한다.
  static const android = RadioProfile(
    name: 'android',
    scanAlwaysUnfiltered: true, // 하드웨어 필터가 overflow 광고를 놓친다
    supportsScanPowerTuning: true,
    pausesScanWhileConnecting: true, // status 133 회피
    connectTimeout: Duration(seconds: 20),
    probesAppleDevices: true, // 백그라운드 iPhone을 찾는 유일한 길
    advertiseNameOptional: true, // 어댑터 이름 변경이 막히는 기기 대비
    usesAdaptivePower: true,
    encounterLocation: EncounterLocationPolicy.foregroundOnly,
  );

  /// 알 수 없는 플랫폼의 보수적 기본값: 최적은 아니지만 **절대 침묵하지
  /// 않는다**. 무필터 스캔(가능한 곳에서 가장 넓은 발견) + 상한 있는 connect
  /// (막힌 dial이 스캔을 붙들지 않게) + OS 보장을 전제하는 기능은 모두 끔.
  /// 새 플랫폼은 실기기 관찰로 하나씩 켜 나가면 된다.
  static const generic = RadioProfile(name: 'generic');

  /// 현재 실행 중인 플랫폼의 프로파일.
  static RadioProfile forCurrentPlatform() {
    if (Platform.isIOS) return ios;
    if (Platform.isAndroid) return android;
    if (Platform.isMacOS) return darwinDesktop;
    return generic;
  }

  @override
  String toString() => 'RadioProfile($name)';
}
