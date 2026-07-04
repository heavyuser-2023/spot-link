# Wi-Fi 고속 파일 전송 하이브리드 — 설계 & 구현 현황

> 상태: **코어 + LAN 소켓 경로 구현·테스트 완료**, 네이티브 AP-less 경로는
> 실기기 대기. 기존 BLE 메시는 그대로 두고, **파일 전송에 한해** 조건이 맞을
> 때만 Wi-Fi 고속 경로로 "업그레이드"하는 보완적(opt-in, 실패 시 자동 폴백) 접근.
>
> ## 구현 현황
> - ✅ **코어 추상화**: `FastLaneInterface`/`Kind`/`Offer`/`Session`
>   (`lib/core/transfer/fast_lane.dart`)
> - ✅ **BLE 협상**: `fileFastOffer`/`fileFastAccept` 프레임, offer→accept→
>   connect→stream→완료ACK, 전 구간 폴백 (`lib/core/mesh_node.dart`)
> - ✅ **LAN 소켓 경로**(순수 Dart, 크로스플랫폼): 같은 Wi-Fi 위 TCP 전송
>   (`lib/core/transfer/lan_socket_fast_lane.dart`) — 실제 소켓으로 검증
> - ✅ **컴포지트/채널 계층**: 여러 경로를 능력 순으로 라우팅
>   (`composite_fast_lane.dart`), 네이티브 채널 브리지(`platform_fast_lane.dart`)
> - ✅ **네이티브 AP-less 경로 구현**(컴파일·통합 완료, 런타임 미검증):
>   - Android **Wi-Fi Direct**: 수신자가 자율 그룹(GO 192.168.49.1) 생성→
>     SSID/passphrase를 BLE로 회신, 송신자가 `WifiNetworkSpecifier`로 그 Wi-Fi에
>     접속 후 TCP 소켓 — 바이트는 네이티브 소켓이 나름
>     (`android/.../FastLanePlugin.kt`)
>   - iOS **MultipeerConnectivity**: MCSession advertiser/browser + `sendData`
>     (`ios/Runner/FastLanePlugin.swift`)
> - ✅ **테스트**: 페이크 3종 + 실제 loopback TCP 2종 = 총 113개 통과.
>   iOS/Android 릴리즈 빌드 성공(네이티브 컴파일 검증)
> - ⏳ **런타임 검증**: 동일 플랫폼 실기기 2대(Android 2대 / iOS 2대) 필요.
>   이 환경에서 미수행 — 사용자 요청으로 "테스트 불가 감수, 최선 구현"으로 진행
>
> 즉 **LAN(같은 Wi-Fi)은 실동작·검증 완료**, **네이티브 AP-less P2P는 API대로
> 구현·컴파일 완료했으나 실기기 런타임은 미검증**이다. 어느 경로든 실패하면
> 항상 BLE로 폴백하므로, 네이티브가 특정 기기에서 안 붙어도 전송은 된다.

## 1. 목표와 원칙

- **BLE는 그대로 유지**: 발견·프레즌스·라우팅·텍스트·신원(QR)·store-and-forward·
  서명 영수증 등 모든 기존 기능은 BLE 위에서 지금처럼 동작한다. Wi-Fi는
  **대체가 아니라 추가 차선(fast lane)**이다.
- **파일 전송만 대상**: BLE의 약점은 대역폭(~5KB/s)뿐이다. 10MB 파일이 30분
  걸리는 문제만 해결하면 되고, 나머지는 BLE가 이미 잘 한다.
- **항상 폴백**: Wi-Fi 경로 협상이 실패하거나 중간에 끊기면 **즉시 기존 BLE
  청크 전송으로 되돌아간다.** 사용자는 "느리지만 됨"을 절대 잃지 않는다.
- **E2E 암호화 유지**: Wi-Fi로 나가는 바이트도 기존과 동일하게 수신자 공개키로
  암호화된 **암호문**이다. 전송 매체가 바뀌어도 보안 모델은 그대로.

## 2. 실현 가능성 (플랫폼별) — 정직한 한계

폰끼리 기지국/AP 없이 Wi-Fi로 직접 붙는 방법은 플랫폼마다 다르고,
**크로스플랫폼(iOS↔Android)이 가장 어렵다.**

| 페어 | 사용 가능한 고속 경로 | 실현성 |
|---|---|---|
| **Android ↔ Android** | Wi-Fi Direct(WifiP2p) 또는 Wi-Fi Aware(NAN, API 26+) | ✅ 높음 |
| **iOS ↔ iOS** | MultipeerConnectivity(AWDL, Wi-Fi+P2P 자동) | ✅ 높음 |
| **iOS ↔ Android** | 표준 P2P Wi-Fi 상호운용 **없음**. 한쪽 SoftAP(핫스팟)+소켓만 가능하나 iOS는 프로그래밍 방식 핫스팟 불가 | ⚠️ 매우 제한적 → **BLE 폴백** |
| 같은 Wi-Fi(AP) 아래 둘 다 | 로컬 소켓(mDNS 발견) | ✅ 가능하나 "기지국 없이"라는 전제와 다름 |

**핵심 결론**: Wi-Fi 고속 경로는 **동일 플랫폼 페어에서 확실한 이득**이 있고,
**iOS↔Android는 사실상 불가**라 BLE로 폴백한다. 즉 "모든 조합이 빨라진다"가
아니라 "될 수 있는 조합만 빨라지고 나머지는 지금과 같다"는 **순수 상향(무해)**
개선이다.

### 플러그인 관점
- Android: `wifi_p2p` / Wi-Fi Aware(직접 채널) 또는 Google **Nearby Connections**
  (Android 전용, BLE+Wi-Fi 자동 조합).
- iOS: **MultipeerConnectivity**(네이티브, iOS↔iOS/Mac 전용).
- 크로스플랫폼 단일 플러그인은 사실상 없음 → **플랫폼별 네이티브 채널** 필요.
  (여기서도 크로스플랫폼은 BLE 폴백으로 귀결)

## 3. 아키텍처 — 제어면(BLE) + 데이터면(Wi-Fi)

기존 계층은 그대로 두고 옆에 **선택적 데이터면**을 붙인다.

```
        ┌──────────────── MeshNode (오케스트레이터) ────────────────┐
        │  라우팅 · 크립토 · store-forward · 영수증 · 파일 청크/ACK  │
        └───────────────┬───────────────────────────┬──────────────┘
                        │                           │
              제어/폴백 데이터면              (신규) 고속 데이터면
         MeshTransportInterface            FastLaneInterface (opt)
          (BLE, 항상 존재)                  (Wi-Fi, 조건부 존재)
          발견·프레즌스·텍스트               대용량 파일 벌크 전송
          ·라우팅·작은 프레임                (암호문 스트림)
```

- **제어면(BLE)**: 지금 그대로. 발견·협상·프레즌스·텍스트·파일 META까지 BLE로.
- **데이터면(Wi-Fi)**: 새로 추가하는 `FastLaneInterface`. 오직 **파일 바이트 벌크
  전송**만 담당. 존재하지 않을 수도 있음(그러면 BLE 청크 전송).

### 신규 추상화 (기존과 대칭)
```dart
// 기존 MeshTransportInterface 옆에 추가되는 선택적 인터페이스(설계안)
abstract class FastLaneInterface {
  /// 이 기기가 지금 제공 가능한 고속 경로 종류 (없으면 empty).
  Set<FastLaneKind> get capabilities; // wifiDirect, wifiAware, multipeer

  /// 상대와 고속 채널을 연다. BLE로 교환한 [offer]를 사용.
  /// 성공 시 암호문 바이트를 밀어넣을 수 있는 세션을 반환, 실패 시 null(→BLE 폴백).
  Future<FastLaneSession?> connect(FastLaneOffer offer);

  /// 상대가 우리에게 붙을 수 있도록 리스닝 시작 + BLE로 보낼 offer 생성.
  Future<FastLaneOffer?> advertiseAndOffer();
}
```
`FastLaneSession`은 단순 양방향 바이트 스트림(TCP 소켓/Multipeer 스트림).
**신뢰성(재전송/순서)은 TCP/OS가 처리**하므로, Wi-Fi 경로에서는 기존의
청크/윈도우/ACK 로직이 필요 없다 — 암호문 전체를 스트림으로 흘리고 끝.

## 4. 기존 코드 통합 지점 (최소 침습)

- **`MeshNode.sendFile()`** ([mesh_node.dart:373](../lib/core/mesh_node.dart)):
  현재 `fileMeta` 전송 후 `_streamChunks()`로 BLE 청크를 뿌린다.
  → 여기서 **"고속 경로 협상"을 먼저 시도**하고, 성공하면 청크 대신 Wi-Fi
  스트림으로 보낸다. 실패하면 **지금 코드 그대로** 실행(무변경 폴백).
- **`fileMeta` 프레임 확장**: 송신자가 META에 "고속 경로 가능 + offer 토큰"을
  실어 보낸다. 수신자가 같은 능력을 가지면 BLE로 수락 신호를 보내고 Wi-Fi
  채널을 연다. (META/협상은 전부 기존 BLE 링크 위에서)
- **수신측** ([mesh_node.dart:691](../lib/core/mesh_node.dart) `fileMeta` 핸들러):
  고속 경로로 받기로 하면 `FastLaneSession`에서 암호문을 읽어 기존
  `FileReceiver`가 아니라 **한 번에 복호화·저장**. 완료 후 기존과 동일하게
  `FileReceived` 이벤트 + 서명 영수증 발행 → **UI/보관함/영수증 로직 재사용**.
- **UI**: 변화 없음. 진행률·"전달됨"·재시도 등 기존 파일 UI가 그대로 동작
  (진행률 소스만 청크 카운트 → 바이트 카운트로 바뀜).

정리: **핵심 신규 코드는 `FastLaneInterface` 플랫폼 구현 + sendFile의 분기 하나**.
라우팅/크립토/영수증/UI는 손대지 않는다.

## 5. 협상 & 폴백 시퀀스

```
A가 파일 전송 시작
 │
 ├─(BLE) fileMeta 전송 [capabilities: wifiAware, offer 토큰 포함]
 │
 ├─ 수신자 B: 공통 고속 경로 있음?
 │     ├─ 없음(예: iOS↔Android) ──────────► 기존 BLE 청크 전송 (지금과 동일)
 │     └─ 있음 ──► (BLE) 수락 + 자신의 접속 정보 회신
 │
 ├─ A/B: Wi-Fi 채널 연결 시도 (타임아웃 ~5s)
 │     ├─ 실패 ───────────────────────────► BLE 청크 전송으로 폴백
 │     └─ 성공 ──► 암호문 스트림 전송 (수십 Mbps)
 │
 └─ 완료 → (BLE) 서명 영수증 플러딩 (기존 로직 재사용)
```

- **폴백 지점이 3곳**(공통 능력 없음 / 연결 실패 / 전송 중 끊김) 모두 기존 BLE
  경로로 안전하게 회귀. Wi-Fi는 "되면 빠르고, 안 되면 지금과 같음".
- 협상·제어는 항상 BLE라, **발견/프레즌스/라우팅은 전혀 영향 없음.**

## 6. 보안

- 전송 바이트는 기존과 동일하게 **수신자 X25519 공개키로 암호화된 암호문**.
  Wi-Fi 채널이 도청·MITM 되어도 내용은 안전 (BLE와 동일 보증).
- Wi-Fi 채널 자체 인증: BLE로 교환하는 offer에 **일회용 세션 토큰/핑거프린트**를
  포함해, 엉뚱한 기기가 붙는 것을 방지. (BLE 링크는 이미 QR/ANNOUNCE로 신원 확인)
- 완료 후 서명 영수증(전파 삭제)도 그대로 → 중계 보관함 정리 로직 재사용.

## 7. 장점 / 단점

### 장점
- **파일 전송 속도 수백 배** (5KB/s → 수 MB/s): 10MB가 30분 → 수 초.
- **순수 상향, 무해**: 안 되는 조합은 지금과 100% 동일. 기존 기능/테스트 불변.
- **재사용**: 암호화·영수증·보관함·UI·라우팅 전부 그대로. 신규 표면적 최소.
- **BLE 대역폭 여유 확보**: 파일이 Wi-Fi로 빠지면, 그 시간 BLE는 프레즌스·텍스트·
  릴레이에 집중 → 메시 전체 반응성 향상.

### 단점 / 비용
- **크로스플랫폼(iOS↔Android) 이득 없음**: 표준 부재로 BLE 폴백. "모두 빨라짐"
  아님.
- **네이티브 코드 2벌**: Android(Wi-Fi Aware/Direct)·iOS(MultipeerConnectivity)를
  각각 플랫폼 채널로 구현 → 유지보수 증가. 단일 Flutter 플러그인 부재.
- **배터리·발열**: Wi-Fi P2P는 전송 중 전력 소모 큼 (전송 시에만 켜고 끄면 완화).
- **백그라운드 제약**: iOS 백그라운드에서 MultipeerConnectivity/AWDL 제약, Android도
  Wi-Fi Aware 백그라운드 제한 → **양쪽 포그라운드(전송 중 화면 켜짐) 권장**.
- **권한 추가**: Android `NEARBY_WIFI_DEVICES`(API 33+), 위치 권한 등.
- **연결 셋업 지연**: Wi-Fi 채널 수립에 1~5초. **작은 파일은 오히려 BLE가 빠름**
  → 임계값(예: 256KB) 이상만 고속 경로 시도하는 게 합리적.

## 8. 단계별 로드맵 (구현 시)

1. **M1 — Android↔Android만** (가장 이득/난이도 비율 좋음)
   - `FastLaneInterface`(Android: Wi-Fi Aware 또는 Nearby Connections) 구현
   - `sendFile` 협상 분기 + 폴백, fileMeta capability 필드 추가
   - 임계값(≥256KB)·타임아웃·폴백 통합 테스트(페이크)
2. **M2 — iOS↔iOS** (MultipeerConnectivity 플랫폼 채널)
3. **M3 — 다듬기**: 진행률 바이트 기반, 전송 후 Wi-Fi 해제(배터리), 실기기 검증
   (동일 플랫폼 2대 필요)

> iOS↔Android 고속 경로는 로드맵에서 제외 (표준 부재). 해당 조합은 계속 BLE.

## 9. 리스크 & 권장

- **가장 큰 리스크**: 네이티브 P2P Wi-Fi는 실기기·OS버전·제조사별 편차가 커서
  "테스트는 통과했는데 특정 폰에서 안 붙는" 문제가 흔하다 → **실기기 매트릭스
  검증 필수** (동일 플랫폼 2대씩).
- **권장**: 먼저 **M1(Android↔Android)만** 얇게 구현해 실기기에서 속도·안정성을
  증명한 뒤 iOS로 확장. 폴백이 견고하므로 부분 구현 상태로 배포해도 안전
  (안 되면 BLE로 조용히 회귀).
- **대안 고려**: 극단적 장거리(수 km)가 목표라면 Wi-Fi가 아니라 LoRa 외장
  모듈 브리지가 별개 축. (본 설계 범위 밖)

---
_요약: BLE 제어면은 불변, 파일 벌크만 조건부 Wi-Fi로 업그레이드하고 실패 시
BLE로 폴백하는 순수 상향 하이브리드. 동일 플랫폼에서 큰 이득, 크로스플랫폼은
BLE 유지. 먼저 Android↔Android로 얇게 검증 권장._
