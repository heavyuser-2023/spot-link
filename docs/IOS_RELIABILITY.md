# iOS 연결·메시지 전달 안정화

iOS에서 "앱을 죽이지 않았는데 연결이 안 된다/메시지가 안 간다"가 생기는 원인과,
실제 구현 가능한 대책의 조사·구현 기록.

## 문제 모델 — iOS가 백그라운드 BLE를 제약하는 방식

| 상황 | iOS 동작 | 결과 |
|---|---|---|
| 연결된 링크 | 백그라운드에서도 유지, 데이터 흐름 | 정상 동작 ✅ |
| 백그라운드 광고 | 서비스 UUID가 overflow 영역으로 강등 | **포그라운드 스캐너만** 발견 가능 |
| 백그라운드 스캔 | 수십 초~분 단위로 절전 | 발견이 매우 느림 |
| 양쪽 다 백그라운드 + 링크 절단 | 스캔·광고 모두 무력 | **재연결 불가** (핵심 문제) |
| 메모리 압박 | 앱 조용히 종료(jetsam) | 스와이프와 동일한 효과 |
| 반죽은(GATT stale) 링크 | didDisconnect가 안 오는 경우 있음 | 프레임이 조용히 유실 |

## 구현 완료 ✅

### 1. Pending reconnect (커밋 ea4c8da, 실기기 검증)
확립됐던 central 링크가 끊기면 같은 peripheral에 즉시 `connect()` 재장전.
iOS에서 이 요청은 **타임아웃이 없고 백그라운드에서도 상대가 범위에 돌아오면
OS가 연결을 완성**한다(Apple 권장 패턴) — 스캔이 장님이 되는 "양쪽 백그라운드"
조합의 유일한 탈출구. 실기기 검증: 절단 → 2.9초 복원, `BLE discovered` 없이
`pending reconnect armed → link up` 로그로 확인.

### 2. 좀비 링크 감지 (RSSI 기반 liveness)
5초 주기 RSSI 폴링에서 **연속 3회 읽기 실패(~15초 침묵) 시 링크를 강제 절단**.
절단은 disconnect 이벤트 → pending reconnect 재장전으로 이어져 자동 복구된다.
반죽은 링크가 몇 분씩 프레임을 삼키던 창이 최대 ~15초로 줄어든다.
(Android에도 동일 적용 — 절단 후엔 스캔이 복구.)

### 3. 링크업 즉시 재전송
미ACK 텍스트를 주기 재전송 타이머나 HAVE/WANT 왕복을 기다리지 않고
**새 링크가 붙는 순간 그 링크로 바로 밀어넣는다** (무료 재시도 — 시도 횟수
미차감, 수신 측 dedup으로 중복 무해). 재연결 직후 전달 지연 최소화.

### 4. 기존 방어선 (이전 마일스톤)
- DTN 영구 보관("언젠가 전달"): 텍스트는 무기한, 만나면 HAVE/WANT로 전달
- 텍스트 ACK + 주기 재전송, 파일 무진행 60초 타임아웃 + 청크 복구
- 포그라운드 복귀 시 wake() 즉시 재광고·재스캔
- 진단: `MSG recv/delivered`, `FT *`, `BLE *` 마커가 Documents/ble.log에 기록

## 구현 완료 (2차) — 플러그인 포크 + 비콘 웨이크 ✅

### 5. State Restoration + 기지 피어 재획득 (플러그인 포크)
`packages/bluetooth_low_energy_darwin`으로 벤더링(6.2.1)하고 세 곳 패치:
- **복원 식별자**: CBCentral/CBPeripheralManager를
  `RestoreIdentifierKey`("spotlink.central"/"spotlink.peripheral")와
  델리게이트를 생성 시점에 부착해 만들고, `willRestoreState`에서 복원된
  peripheral들을 캐시에 입양 — iOS가 죽인 앱을 pending connect 완성/알림
  수신 시 백그라운드 재기동한다.
- **시스템 retrieve 폴백**: `retrievePeripheral(uuid)`가 메모리 캐시에 없으면
  `retrievePeripherals(withIdentifiers:)`로 시스템에서 재획득 — 재시작 후에도
  UUID만으로 connect 가능.
- **getPeripheral(uuid) 구현**: Darwin에서 UnsupportedError였던 공개 API를
  구현해 Dart가 영속화된 UUID로 Peripheral 핸들을 얻는다.

앱 쪽: 링크 성공한 피어 UUID를 `known_peers.json`(최근 6개)에 영속화,
start() 시(iOS) 스캔과 병행해 전원에 pending connect 재장전
(`BLE known-peer reconnect armed xN` 로그). maxLinks-2 예산으로 스캔 슬롯 보호.

### 6. iBeacon 웨이크 — 스와이프 킬·재부팅 생존 (조건부)
CoreLocation 지역 감시는 **사용자가 죽인 앱도 재기동**한다(BLE 복원이 못 하는
유일한 영역). 고정 UUID(7A3B5C4D-…)의 SpotLink 비콘으로:
- **iOS RX**: `BeaconPlugin.swift` — 지역 감시 등록(재부팅 생존), 진입 시 앱
  재기동→메시 부팅. 위치 "항상 허용" 필요, 내 정보 탭 토글로 옵트인.
- **iOS TX**: 포그라운드에서만 송신(연 사람이 "깨우는 횃불"이 됨).
- **Android TX**: `BeaconPlugin.kt` — 백그라운드에서 상시 iBeacon 광고.
  Android 한 대가 근처에 있으면 죽은 아이폰들이 깨어난다.

### 실기기 E2E 검증 (2026-07-06)
전 체인이 실기기에서 확인됨:
1. heavy 프로세스 강제 종료(devicectl terminate) — 이후 실행 명령 없음
2. bluetoothd가 heavy의 GATT 서비스를 보존(peripheral restoration),
   gold의 pending connect가 그 서비스에 붙는 순간 **iOS가 heavy를 자율
   재기동** (`=== app start` 01:37:11, 종료 4분 후)
3. **완전 부팅**: BLE start + known-peer reconnect armed x4 — 잠금 상태
   부팅을 막던 keychain 버그(-25308)는 first_unlock 접근성으로 해결됨
4. 상호 링크 복구(01:39:42 양방향 link up) → 메시 재가동

검증 과정에서 잡은 실기기 버그 3건도 함께 수정: 잠긴 폰 keychain 부팅
크래시(first_unlock+부트 재시도), 접근성 필터로 기존 keychain 항목이 안
보이던 마이그레이션 버그(신원 무손실 복구 확인), 스테일 광고 발견 폭풍
(백오프가 발견 경로 지배).

### 남는 한계 (플랫폼 원천 제약)
주변 전부가 iPhone이고 전부 스와이프 킬/재부팅 상태(비콘 쏠 주체 없음),
그리고 iOS↔iOS 둘 다 백그라운드인 낯선 피어의 첫 발견 — 서버 푸시 없이는
어떤 앱도 불가능한 영역.

## 검증 방법
- `Documents/ble.log`를 `devicectl device copy from`으로 추출
- 재연결: `link down → pending reconnect armed → link up` (discovered 없이)
- 좀비 절단: `BLE link stale (3 failed RSSI reads) — cutting C:…`
- 전달: 송신 `MSG delivered <id>`, 수신 `MSG recv <id>`
