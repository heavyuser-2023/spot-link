# iOS 27 정식 릴리스 시 재검증 체크리스트

> **작성**: 2026-07-20 (iOS 27 beta 24A5380h 기준, v1.9.4)
> **트리거**: iOS 27 **정식 릴리스**가 나와 heavy/gold 중 한 대라도 업데이트되는 시점.
> **성격**: 기능 수정 아님 — 우회 코드는 정식 OS에서도 안전하게 동작한다(무필터는
> 필터의 상위집합, 광고 교체는 무해한 위생). 여기 항목들은 **선택적 최적화**와
> **신규 회귀 조기 발견**을 위한 것이다.

## 배경: 베타에서 확정한 OS 결함 2건과 우회

| # | iOS 27 베타 결함 | 우회 (코드 위치) |
|---|---|---|
| 1 | 128비트 서비스 UUID 광고가 상대 iPhone에서 **필터 매칭·파싱 모두 실패** (bluetoothd "0 advertisements delivered") | 포그라운드는 **무필터 스캔 + 이름('SL') 매칭**, 백그라운드 iPhone 발견용 필터 스캔과 12s/6s 교대 — [mesh_transport.dart](../lib/core/ble/mesh_transport.dart) `_startScanning`/`_beginScanModeCycle` |
| 2 | 앱 종료 시 bluetoothd가 "isAdvertising:True + 서비스 빈" **오염 복원 레코드**를 저장, 재기동 시 광고 상태기계 중독 | darwin 포크에서 **페리페럴 복원 식별자 제거** — packages/bluetooth_low_energy_darwin `PeripheralManagerImpl`; 부트/포그라운드 복귀 시 광고 stop→start 교체 |

관련 진단 이력은 [IOS_RELIABILITY.md](IOS_RELIABILITY.md)와 메모리
`spotlink-ios-device-workflow` 참고.

## 재검증 절차

1. **필터 매칭 확인** (결함 1이 고쳐졌는가):
   ```
   flutter build ios --release --dart-define=DIAG_UNFILTERED=true
   ```
   진단 빌드를 한 대에 설치, 상대는 일반 빌드 포그라운드. `ble.log`의
   `BLE saw ... svc=1[...]`에 우리 서비스 UUID가 파싱되어 보이면 → 파싱 회복.
   이어서 일반 빌드(필터 스캔 구간)에서 백그라운드 상대가 발견되는지 확인.
   `pymobiledevice3 syslog live`로 bluetoothd의 "N advertisements delivered"
   카운터가 0이 아닌지 교차 확인.

2. **복원 레코드 확인** (결함 2가 고쳐졌는가): 앱 스와이프킬 → 재실행 부트
   로그에 `advertising started` 정상 + 상대 발견 확인(유령 광고 시그니처:
   "advertising started" 부재 + 상대 발견 0건).

## 고쳐졌을 때의 선택적 튜닝 (필수 아님)

- **스캔 교대 비율 조정**: `_wideScanWindow`(12s) / `_overflowScanWindow`(6s)를
  필터 쪽으로 늘리거나, 필터 매칭이 완전하면 필터 상시 스캔으로 단순화
  → 무필터 스캔의 배터리 비용 절감 + 백그라운드 iPhone 발견 지연(최악 ~12s) 제거.
- **주의**: 사용자층에 iOS 26·27 베타 기기가 남아 있는 동안 우회 경로 자체는
  제거하지 말 것. 튜닝은 창 비율까지만.

## 고쳐지지 않았거나 새 회귀가 있을 때

- 우회가 그대로 동작하므로 즉각 조치 불필요. 새 증상은 위 진단 도구
  (DIAG_UNFILTERED, bluetoothd syslog, ble.log 시그니처)로 귀속부터 할 것.
