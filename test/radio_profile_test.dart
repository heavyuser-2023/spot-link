import 'package:flutter_test/flutter_test.dart';
import 'package:spot_link/core/ble/radio_profile.dart';

/// 플랫폼 정책 매트릭스를 못질한다. 이 테스트의 목적은 두 가지다:
///
/// 1. **회귀 방지** — 각 값은 실기기에서 피 흘려 얻은 결정이다. 누군가 무심히
///    바꾸면 특정 플랫폼이 조용히 눈머는 회귀가 난다(예: iOS에서 스캔 교대를
///    끄면 포그라운드 iPhone끼리 서로 안 보인다).
/// 2. **새 플랫폼 안전성** — 알 수 없는 플랫폼이 들어와도 '침묵하지 않는'
///    기본값을 갖는지 검증한다.
void main() {
  group('플랫폼 정책 매트릭스', () {
    test('iOS: 백그라운드 제약 대응이 모두 켜져 있다', () {
      const p = RadioProfile.ios;
      // 포그라운드 iPhone(무필터+이름) ↔ 백그라운드 iPhone(필터+overflow)은
      // 한 모드로 함께 커버되지 않는다 → 교대가 필수.
      expect(p.alternatesScanWindows, isTrue);
      expect(p.switchesScanModeOnForeground, isTrue);
      // 백그라운드 피어는 스캔에 안 보인다 → 식별자 기반 대기 연결이 유일한 길.
      expect(p.usesPendingConnect, isTrue);
      // 대기 연결은 몇 분 뒤 완료되는 것이 정상 — 상한을 두면 안 된다.
      expect(p.connectTimeout, isNull);
      // 장시간 세션에서 CoreBluetooth가 조용히 죽는다(2026-07-25 19.5h 관찰).
      expect(p.needsStackHardReset, isTrue);
      // 종료된 앱을 되살리는 유일한 경로.
      expect(p.supportsBeaconWake, isTrue);
      // 무선 경합/전력 관리는 Android 쪽 문제다.
      expect(p.pausesScanWhileConnecting, isFalse);
      expect(p.supportsScanPowerTuning, isFalse);
      expect(p.probesAppleDevices, isFalse);
    });

    test('Android: 무선 경합·전력·프로브 대응이 켜져 있다', () {
      const p = RadioProfile.android;
      // 하드웨어 필터가 iPhone의 overflow 광고를 놓친다 → 항상 무필터.
      expect(p.scanAlwaysUnfiltered, isTrue);
      expect(p.alternatesScanWindows, isFalse);
      // status 133 회피.
      expect(p.pausesScanWhileConnecting, isTrue);
      // 막힌 dial이 스캔을 붙들지 못하게 반드시 상한.
      expect(p.connectTimeout, isNotNull);
      // 백그라운드 iPhone은 광고에 표식이 없다 → 프로브 다이얼이 유일한 길.
      expect(p.probesAppleDevices, isTrue);
      expect(p.supportsScanPowerTuning, isTrue);
      expect(p.usesAdaptivePower, isTrue);
      // Android connect()는 슬롯을 막으므로 대기 연결을 쓰지 않는다.
      expect(p.usesPendingConnect, isFalse);
    });

    test('macOS: iOS와 같은 CoreBluetooth 대응을 받는다(2등 시민 금지)', () {
      const p = RadioProfile.darwinDesktop;
      // 이것이 이 아키텍처의 핵심 수정이다: 예전에는 모든 플랫폼 분기의
      // else로 떨어져 필터 스캔만 돌았고 → iOS 27 포그라운드 iPhone을
      // 발견하지 못했다(상대가 dial해 주기만 기다림).
      expect(p.alternatesScanWindows, isTrue,
          reason: '맥이 포그라운드 iPhone을 발견하려면 무필터 창이 필요하다');
      expect(p.usesPendingConnect, isTrue,
          reason: 'macOS CoreBluetooth도 식별자 기반 재연결을 지원한다');
      expect(p.needsStackHardReset, isTrue,
          reason: '같은 CoreBluetooth이므로 세션 노화도 같이 온다');
      expect(p.connectTimeout, isNull);
      // 데스크톱은 OS가 앱을 suspend하지 않고, iBeacon TX 자체가 불가능하다.
      expect(p.supportsBeaconWake, isFalse);
      expect(p.usesAdaptivePower, isFalse);
    });

    test('CoreBluetooth 계열은 illegalArgument를 회전된 식별자로 읽는다', () {
      for (final p in [RadioProfile.ios, RadioProfile.darwinDesktop]) {
        expect(p.isUnknownIdentifierError('PlatformException(illegalArgument)'),
            isTrue,
            reason: '${p.name}: 죽은 식별자를 버리고 스캔으로 새 주소를 찾아야 한다');
        expect(p.isUnknownIdentifierError('some other error'), isFalse);
      }
      // 다른 스택은 이 문자열에 의미를 두지 않는다.
      expect(RadioProfile.android.isUnknownIdentifierError('illegalArgument'),
          isFalse);
    });
  });

  group('알 수 없는 플랫폼(generic) 안전성', () {
    const p = RadioProfile.generic;

    test('발견이 침묵하지 않는다: 무필터 스캔이 기본', () {
      // 어떤 OS가 와도 '아무것도 못 보는' 상태로 시작하지 않게 한다.
      expect(p.scanAlwaysUnfiltered, isTrue);
    });

    test('OS 보장을 전제하는 기능은 모두 꺼져 있다', () {
      // 대기 연결(무한 유지)은 CoreBluetooth의 보장이다 — 없는 곳에서 켜면
      // 연결이 영영 완료되지 않는 걸 기다리며 슬롯만 잡는다.
      expect(p.usesPendingConnect, isFalse);
      expect(p.needsStackHardReset, isFalse);
      expect(p.supportsBeaconWake, isFalse);
      expect(p.supportsScanPowerTuning, isFalse);
      expect(p.probesAppleDevices, isFalse);
    });

    test('막힌 dial이 스캔을 영구 정지시키지 않도록 connect에 상한이 있다', () {
      expect(p.connectTimeout, isNotNull);
      expect(p.connectTimeout!.inSeconds, lessThanOrEqualTo(30));
    });
  });

  group('모든 프로파일 불변식', () {
    final all = {
      'ios': RadioProfile.ios,
      'android': RadioProfile.android,
      'darwinDesktop': RadioProfile.darwinDesktop,
      'generic': RadioProfile.generic,
    };

    test('대기 연결을 쓰지 않는 플랫폼은 반드시 connect 상한이 있다', () {
      // 상한 없는 connect는 대기 연결 설계에서만 안전하다. 둘 다 없으면
      // 막힌 dial이 슬롯과 스캔을 영구 점유한다.
      for (final e in all.entries) {
        if (!e.value.usesPendingConnect) {
          expect(e.value.connectTimeout, isNotNull,
              reason: '${e.key}: 대기 연결도 상한도 없으면 dial이 영구 정지한다');
        }
      }
    });

    test('스캔 교대를 쓰는 플랫폼은 포그라운드 전환에 반응해야 한다', () {
      for (final e in all.entries) {
        if (e.value.alternatesScanWindows) {
          expect(e.value.switchesScanModeOnForeground, isTrue,
              reason: '${e.key}: 백그라운드로 가면 OS가 필터를 강제한다');
        }
      }
    });

    test('무필터 상시 스캔과 창 교대는 동시에 켜지지 않는다', () {
      for (final e in all.entries) {
        expect(e.value.scanAlwaysUnfiltered && e.value.alternatesScanWindows,
            isFalse,
            reason: '${e.key}: 상시 무필터라면 교대할 이유가 없다(모순 설정)');
      }
    });

    test('이름이 비어 있지 않다(진단 로그 추적성)', () {
      for (final e in all.entries) {
        expect(e.value.name, isNotEmpty);
      }
    });
  });

  _scanDecisionTests();
}

/// 스캔 모드 결정(useUnfilteredScan)은 발견 로직에서 가장 위험한 판단이다 —
/// 여기서 틀리면 특정 플랫폼이 아무 에러 없이 조용히 눈먼다. 플랫폼×상태
/// 조합을 전부 못질한다.
void _scanDecisionTests() {
  group('스캔 모드 결정', () {
    test('Android: 상태와 무관하게 항상 무필터', () {
      const p = RadioProfile.android;
      for (final fg in [true, false]) {
        for (final ov in [true, false]) {
          expect(p.useUnfilteredScan(foreground: fg, overflowPhase: ov), isTrue,
              reason: 'fg=$fg overflow=$ov');
        }
      }
    });

    test('iOS: 포그라운드 무필터 창 ↔ 필터 창 교대, 백그라운드는 항상 필터', () {
      const p = RadioProfile.ios;
      // 포그라운드 넓은 창: 포그라운드 iPhone(iOS 27)을 찾는 유일한 모드.
      expect(p.useUnfilteredScan(foreground: true, overflowPhase: false), isTrue);
      // 포그라운드 필터 창: 백그라운드 iPhone의 overflow 광고를 잡는 유일한 모드.
      expect(p.useUnfilteredScan(foreground: true, overflowPhase: true), isFalse);
      // 백그라운드: OS가 필터를 강제 — 무필터는 아무것도 전달하지 않는다.
      expect(p.useUnfilteredScan(foreground: false, overflowPhase: false), isFalse);
      expect(p.useUnfilteredScan(foreground: false, overflowPhase: true), isFalse);
    });

    test('macOS: iOS와 동일하게 교대한다(예전 필터 전용 → 아이폰 실명 회귀 방지)', () {
      const p = RadioProfile.darwinDesktop;
      expect(p.useUnfilteredScan(foreground: true, overflowPhase: false), isTrue,
          reason: '맥이 포그라운드 iPhone을 발견하는 유일한 모드');
      expect(p.useUnfilteredScan(foreground: true, overflowPhase: true), isFalse,
          reason: '백그라운드 iPhone의 overflow 광고를 잡는 창');
    });

    test('generic: 항상 무필터(가장 넓은 발견으로 시작)', () {
      const p = RadioProfile.generic;
      expect(p.useUnfilteredScan(foreground: true, overflowPhase: false), isTrue);
      expect(p.useUnfilteredScan(foreground: false, overflowPhase: true), isTrue);
    });

    test('진단 오버라이드는 모든 플랫폼에서 무필터를 강제한다', () {
      for (final p in [
        RadioProfile.ios,
        RadioProfile.android,
        RadioProfile.darwinDesktop,
        RadioProfile.generic,
      ]) {
        expect(
            p.useUnfilteredScan(
                foreground: false, overflowPhase: true, diagOverride: true),
            isTrue,
            reason: p.name);
      }
    });

    test('교대 플랫폼은 두 창이 서로 다른 모드를 낸다(교대가 실제로 일어남)', () {
      for (final p in [RadioProfile.ios, RadioProfile.darwinDesktop]) {
        final wide = p.useUnfilteredScan(foreground: true, overflowPhase: false);
        final narrow = p.useUnfilteredScan(foreground: true, overflowPhase: true);
        expect(wide, isNot(narrow),
            reason: '${p.name}: 교대인데 두 창이 같은 모드면 한쪽 피어를 영영 못 본다');
      }
    });
  });
}
