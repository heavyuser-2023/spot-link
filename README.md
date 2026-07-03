# SpotLink

인프라 없이 **BLE 메시**로 텍스트·파일을 주고받는 오프라인 메신저 (Flutter, Android + iOS).

직접 연결이 안 되는 상대에게도 중간 노드가 **중계(relay)** 하거나 **저장 후 전달
(store-and-forward)** 합니다. 모든 메시지는 **엔드투엔드 암호화**되어 중계 노드는 내용을
볼 수 없습니다.

설계 상세는 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) 참고.

## 기능 (M0–M7 완료)

- **BLE 메시**: 모든 기기가 Peripheral + Central을 동시에 수행하는 대칭 노드
- **멀티홉 릴레이**: flooding + TTL + 중복제거(dedup)로 나 → A → B 전달
- **Store-and-forward**: 수신자가 없을 때 보관 후, 나중에 만나면 HAVE/WANT 동기화로 전달
- **DTN식 "언젠가 전달"**: 텍스트(+ACK)는 SQLite에 **무기한 영구 보관**되어 앱을
  재시작해도 다른 기기를 만날 때마다 계속 전파됨 (TTL 32홉). 파일은 24시간/512개로
  제한(남의 폰을 대용량으로 채우지 않음). 내 정보 탭 **"중계 보관함"**에서 보관량
  확인·비우기 가능. 수신 확인(RECEIPT/ACK)이 돌아오면 자동 삭제
- **E2E 암호화**: X25519 ECDH → HKDF → AES-256-GCM. 신원 = Ed25519/X25519 키
- **QR 신원교환**: 상대 공개키를 QR로 스캔해 검증(중간자 공격 방지)
- **파일 전송**: 청크 분할 + 누락 재전송(ACK) + SHA-256 무결성 검증. **진행 중이면
  타임아웃 없음**(무진행 60초일 때만 실패), 청크는 store-and-forward 제외 + 4KiB 청크로 오버헤드↓
- **텍스트 신뢰성**: 종단 ACK 미수신 시 자동 재전송, 최종 실패 시 재시도 UI
- **백그라운드 알림**: 화면이 꺼진(백그라운드) 상태에서 메시지·파일 도착 시 로컬 알림
- **백그라운드**: Android Foreground Service, iOS BLE 백그라운드 모드
- **전력 관리**: 링크 수 상한, 배터리 절약(듀티 사이클) 모드
- **자동 복구**: 블루투스 껐다 켜면 광고·스캔 자동 재개
- **런타임 권한**: Android 12+ BLE 권한을 시작 시 실제 요청
- **실시간 프레즌스**: 주기적 ANNOUNCE로 "주변에 있음"이 정확히 만료됨
- **멀티홉 프레즌스**: ANNOUNCE가 TTL 3으로 릴레이되어, 직접 전파거리 밖의
  피어도 "주변 · n홉 경유"로 표시 (초록 점 = 직접, 노란 점 = 릴레이 경유).
  키도 함께 전파되어 QR 없이 2~3홉 상대에게 바로 암호화 메시지 전송 가능

### UI
- **스플래시/온보딩**: 첫 실행 시 이름 설정, 로딩 화면(검은 화면 없음)
- **대화 목록**: 최근 메시지 미리보기·시간·안읽음 배지
- **채팅**: 날짜 구분선, 자동 스크롤, 전송 상태(전송/전달/실패) + 실패 시 탭 재시도
- **파일**: 받은 파일 탭하여 열기, 전송 진행률
- **연락처**: 아바타 색상, 이름 변경, 인증 표시, 주변 표시
- **내 정보**: 이름 편집, ID 복사, QR 공유, 배터리 절약 토글
- **에러 처리**: 블루투스 꺼짐 배너 + 스낵바
- **한국어 UI**, 접근성 시맨틱, 다크 모드

## 구조

```
lib/
├── core/                     # 플랫폼 독립 (전부 단위 테스트됨)
│   ├── model/                # Frame, PeerId, Announce
│   ├── ble/                  # framing(L2 청킹) + mesh_transport(실제 BLE)
│   ├── router/               # flooding/TTL/dedup + store-and-forward
│   ├── crypto/               # identity + E2E session
│   ├── transfer/             # 파일 청크/재조립/ACK
│   └── mesh_node.dart        # 오케스트레이터 (전부 결합)
├── data/                     # SQLite, 보안 저장소, 모델
├── app/                      # MeshController(ChangeNotifier), 백그라운드 서비스
├── features/                 # UI 화면
└── main.dart
```

## 실행

```bash
flutter pub get
flutter run                 # 실제 기기 2대 이상 권장 (BLE는 시뮬레이터 미지원)
```

- **Android**: 최초 실행 시 Bluetooth/알림 권한 허용 필요 (API 24+).
- **iOS**: `cd ios && pod install` 후 Xcode에서 서명 설정 필요 (iOS 14.0+).

## 빌드 & 설치 (릴리즈)

기기 ID는 `flutter devices`로 확인.

### Android

```bash
flutter build apk --release   # → build/app/outputs/flutter-apk/app-release.apk
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

현재 릴리즈 빌드는 **디버그 키로 서명**됩니다(템플릿 기본값). 스토어 배포 전에는
`android/app/build.gradle.kts`의 TODO대로 릴리즈 키스토어를 설정해야 합니다.

### iOS

```bash
flutter build ios --release   # Xcode 프로젝트의 팀 키로 자동 서명
xcrun devicectl device install app \
  --device <기기ID> build/ios/iphoneos/Runner.app
```

- `flutter run --release -d <기기ID>` 한 줄로 빌드+설치+실행도 가능 (`q`로 세션을
  끝내도 앱은 남음).
- 자동 실행까지 하려면(잠금 해제 상태 필요):
  `xcrun devicectl device process launch --device <기기ID> kr.co.monolith.spotLink`
- 개발용 인증서 서명은 유효기간(유료 계정 1년, 무료 7일)이 지나면 재설치 필요.
  기간 제한 없는 배포는 `flutter build ipa` → TestFlight/App Store.

## 테스트

```bash
flutter test        # 93개 테스트 (아래) — 전부 통과
flutter analyze     # 무결점
```

검증 범위:

- **단위**: frame/framing/router/seen-cache/crypto/file-transfer/store-forward/QR/DB
- **통합**(`mesh_integration_test.dart`, 인메모리 가짜 라디오): 1:1 E2E 텍스트+ACK,
  ANNOUNCE 키 학습, 멀티홉 릴레이(릴레이는 평문 못 봄), store-and-forward 지연 전달,
  멀티홉 파일 전송+무결성, 다이아몬드 토폴로지 중복 방지
- **실전/적대적**(`robustness_test.dart`):
  - **실제 L2 프레이밍 경로**로 다중 패킷 텍스트 재조립(작은 MTU, 직접+멀티홉)
  - **패킷 손실 10~12% 하에서 파일 전송 복구**(재전송 + 수신측 복구 타이머로 tail 손실도 완료)
  - **손상/악의적 입력**(랜덤 프레임, 잘린 비암호화 ACK, 미상 발신자 암호문, 잘린 파일 청크)에도
    노드가 죽지 않고 이후 정상 메시지 처리
  - TTL 소진(4홉·TTL 2는 미도달, TTL 7은 도달)
  - `Frame.decode` 퍼징 5000회(항상 FormatException 이내)
- **신뢰성**(`reliability_test.dart`): 텍스트 재전송/확인, **수신측 첫 ACK 유실 시 재전송으로 복구**,
  이름 변경 재-ANNOUNCE
- **컨트롤러/UI**(`controller_test.dart`, `home_widget_test.dart`, `onboarding_widget_test.dart`):
  재시도 시 대화목록 동기화, 연락처 이름변경 영속, **최초 권한 승인 시 자동 시작**(재시작
  불필요), HomeScreen 렌더링·탭 전환·빈 상태

Android APK + iOS(no-codesign) 빌드 모두 성공.

### 코드 재검토에서 발견·수정한 실제 버그

전체 코드 재검토(에이전트 + 수동) 후 실기기 동작을 깨뜨릴 수 있던 문제를 수정했습니다:

1. **L2 헤더 20B → 최소 MTU에서 송신 불가**: 최소 ATT MTU(23, usable 20)에서 헤더 20B면
   데이터 0B라 `split`이 예외 → peripheral 역할 송신이 전부 실패. 헤더를 8B로 축소.
2. **transferId 충돌 → 무음 손상**: 4B 랜덤 id가 동시 전송에서 충돌 가능. 프로세스 단조 카운터로 변경.
3. **손상 ACK로 수신 파이프라인 크래시(원격 DoS)**: 비암호화 ACK(payload `[0]`)에 길이검증 없어
   `sublist` 예외 → `_onPacket`(async void) 미보호. 전면 try/catch + 길이검증 추가.
4. **파일 tail 손실 시 영구 정지**: 16청크마다만 ACK → 마지막 청크 손실 시 ACK 미발생 정지.
   수신측 복구 타이머 추가.
5. **해시 불일치 시 잘못된 완료 ACK / 상태 누수**, 최종 ACK 유실 시 송신자 고착 → 정리.
6. **iOS 크로스플랫폼 발견**: iOS는 광고 시 manufacturer data를 무시 → tie-break 불가.
   미상 id는 connect-anyway로 폴백(중복 링크는 msgId dedup으로 안전).

이후 4-way 병렬 적대적 리뷰(각 findings를 다시 검증)로 리팩터링 회귀 11건을 추가로 확인·수정:

7. **텍스트 재전송이 첫 ACK 유실을 복구 못함**: 재전송은 같은 msgId → 수신측 seen-cache가
   `_deliverLocal` 전에 드롭 → 재-ACK 불가. 이제 중복 프레임(내 앞 + ackRequested)에 대해 재-ACK.
8. **뒤늦은 ACK가 실패와 동시 발생**: give-up 시 `TextDeliveryFailed`, 직후 late ACK가
   `DeliveryConfirmed` → 모순. confirmed-set으로 전달이 우선하고 실패 재발화 방지.
9. **openConversation 경합**: DB 로드 중 도착한 메시지 유실. placeholder 리스트 + 병합으로 해결.
10. **retryText가 대화목록(_lastMessage) 미동기화** → 인박스 행이 실패 상태로 고착. 동기화 추가.
11. **maxLinks가 connecting 미포함** → 발견 폭주 시 한도 초과. `links+connecting`로 카운트.
12. **블루투스 OFF 시 duty 타이머 미취소** → 꺼진 어댑터에 무한 스캔 시도. poweredOff에서 취소.
13. **stop/dispose 중 진행 중이던 연결이 닫힌 컨트롤러에 이벤트 추가 / _links 부활**: `_started`
    가드 + `_disposed` 가드 추가.
14. **부트스트랩 언마운트 시 컨트롤러 누수** → 조기 반환 전 dispose.
15. **다이얼로그 TextEditingController 누수**(이름 편집/변경) → try/finally dispose.
16. **채팅 제목이 연락처 없을 때 내 ID로 폴백** → 상대 ID로 수정.

### 파일 전송 속도/타임아웃 + 백그라운드 알림 (사용자 요청)

17. **파일 전송이 자꾸 타임아웃**: 고정 45초 절대 데드라인 → **무진행 기준(60초)** 으로 변경.
    수신측은 청크가 올 때마다 데드라인 리셋 + 5초 하트비트 ACK로 송신측 워치독을 살려둠 →
    진행 중인 전송은 절대 타임아웃되지 않음(링크가 60초 완전 침묵할 때만 실패).
18. **파일 전송이 느림**: 청크마다 `store.add`로 512칸 store가 thrash되던 것을 제거(청크·파일ACK는
    store-and-forward 제외) + 기본 청크 4KiB로 프레임/암호화 오버헤드 절반.
19. **화면 꺼짐 시 알림 없음**: `flutter_local_notifications` + 앱 라이프사이클 관측 →
    백그라운드(화면 off)에서 텍스트/파일 수신 시 발신자 이름·미리보기로 로컬 알림.

## 검증 상태 / 한계

- ✅ 순수 로직(라우팅·암호화·파일전송·store-forward): 단위 + 통합 + 신뢰성 테스트로 검증 (92개)
- ✅ UI 렌더링/탭 전환/온보딩: 위젯 테스트로 검증
- ✅ Android APK + iOS(no-codesign) 빌드 성공
- ⚠️ **실제 2대 이상 기기 간 물리 BLE 통신은 실기기 테스트가 필요** — 이 저장소의 자동화
  테스트는 BLE 스택을 가짜 전송으로 대체해 상위 프로토콜만 검증합니다. `mesh_transport.dart`
  의 실제 BLE 연동은 실기기에서 확인해야 합니다.
- ⚠️ iOS ↔ iOS 백그라운드 발견은 OS 제약으로 불안정할 수 있음 (ARCHITECTURE §11 참고).
- ℹ️ 알려진 개선 여지(정확성엔 영향 없음): 릴레이의 파일 프레임 24h 보관(RECEIVE 미구현),
  두 기기 간 중복 링크(대역폭만 낭비, dedup으로 안전).
