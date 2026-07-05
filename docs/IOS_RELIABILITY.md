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

## 남은 개선 — 플러그인(bluetooth_low_energy) 개조 필요 ⏳

둘 다 Darwin 구현부에 없는 API라 플러그인 포크/벤더링이 선행돼야 한다.

### A. 시작 시 기지 피어 재획득 — `retrievePeripherals(withIdentifiers:)`
앱을 다시 열었을 때, 과거 연결했던 피어의 UUID로 CBPeripheral을 **스캔 없이**
재획득해 pending connect를 걸 수 있다. 상대가 백그라운드(overflow 광고)라
스캔으로는 영영 못 찾는 경우에도 재연결된다. 필요 작업: Darwin 플러그인에
API 1개 추가 + Dart에서 피어 UUID 영속화. **효과 크고 난이도 중.**

### B. State Restoration — jetsam 생존
`CBCentralManagerOptionRestoreIdentifierKey` + `willRestoreState`로, iOS가
앱을 종료했어도 BLE 이벤트(pending connect 완성, 알림 수신)에 앱을 백그라운드
재기동시킨다. 플러그인의 매니저 생성부·델리게이트 개조 + Flutter 엔진 헤드리스
기동 처리 필요. **효과 가장 크고 난이도 높음.**

## 검증 방법
- `Documents/ble.log`를 `devicectl device copy from`으로 추출
- 재연결: `link down → pending reconnect armed → link up` (discovered 없이)
- 좀비 절단: `BLE link stale (3 failed RSSI reads) — cutting C:…`
- 전달: 송신 `MSG delivered <id>`, 수신 `MSG recv <id>`
