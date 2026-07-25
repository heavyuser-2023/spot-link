import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 앱 데이터(DB·신원 부속 파일·진단 로그·릴레이 메일박스)를 둘 **단 하나의
/// 경로 정책**.
///
/// 왜 별도 정책이 필요한가 — 플랫폼마다 "항상 쓸 수 있는 곳"이 다르다:
///
///  * **iOS / Android**: `getApplicationDocumentsDirectory()`가 앱 전용
///    컨테이너다. 사용자에게 보이지 않고 권한도 필요 없다. 그대로 쓴다
///    (기존 설치의 데이터가 여기 있으므로 절대 바꾸면 안 된다).
///  * **macOS(비샌드박스)**: 같은 호출이 **사용자의 실제 `~/Documents`** 를
///    돌려준다. 이 폴더는 macOS TCC로 보호되어, 사용자가 "파일 및 폴더" 권한을
///    허용하지 않으면 모든 읽기/쓰기가 `PathAccessException`으로 실패한다.
///    그 결과 2026-07-09~25 실제 사건이 발생했다: 맥이 **16일간** DB도 로그도
///    만들지 못해 메시에 전혀 참여하지 못했다 — 그런데 배포·실행은 매번
///    성공했으므로 아무도 눈치채지 못했다(진단 로그조차 못 써서 원인 추적도
///    불가능했다). Keychain+BLE를 쓰려고 샌드박스를 끈 것의 부작용이었다.
///    → 데스크톱은 `getApplicationSupportDirectory()`(`~/Library/Application Support/<bundle-id>`)를 쓴다. TCC 대상이 아니고 항상 쓸 수 있다.
///
/// 새 플랫폼을 붙일 때: 그 OS에서 **권한 프롬프트 없이 항상 쓸 수 있는** 앱
/// 전용 경로가 무엇인지 먼저 확인하고 여기에 반영한다. 잘못 고르면 앱은
/// "실행되지만 아무 데이터도 남기지 못하는" 상태로 조용히 죽는다.
class AppPaths {
  static Directory? _cached;

  /// 앱 데이터 루트. 없으면 만든다.
  static Future<Directory> dataDir() async {
    final cached = _cached;
    if (cached != null) return cached;
    Directory dir;
    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      // 데스크톱: TCC 보호 밖의 앱 전용 지원 디렉터리.
      dir = await getApplicationSupportDirectory();
    } else {
      // 모바일: 앱 컨테이너의 Documents(기존 설치 데이터가 있는 곳).
      dir = await getApplicationDocumentsDirectory();
    }
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    _cached = dir;
    return dir;
  }

  /// 테스트 훅.
  static void resetForTest() => _cached = null;
}
