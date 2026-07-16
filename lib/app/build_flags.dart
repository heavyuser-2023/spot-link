/// 컴파일 타임 빌드 플래그.
///
/// `kStoreBuild`는 Google Play 빌드에서 true이며, 이 빌드에는 오프라인 APK
/// 자가 배포 기능이 포함되어서는 안 된다(REQUEST_INSTALL_PACKAGES는 Play에서
/// 제한된 권한이며, 이 기능은 스토어 배포 앱에 대한 기기 및 네트워크 악용
/// 정책을 위반한다).
///
/// Play 빌드:
///   flutter build appbundle --flavor store --dart-define=STORE_BUILD=true
/// 사이드로드(GitHub releases) 빌드:
///   flutter build apk --flavor sideload
const bool kStoreBuild = bool.fromEnvironment('STORE_BUILD');
