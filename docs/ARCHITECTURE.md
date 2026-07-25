# SpotLink — BLE Mesh Messenger 아키텍처 문서

> 목표: 인터넷/인프라 없이 BLE만으로 텍스트·파일을 주고받고, 직접 연결이 안 되는 상대에게는
> 중간 노드가 **중계(relay)** 및 **저장 후 전달(store-and-forward)** 하는 오프라인 메신저.
>
> 타겟: **Android + iOS** (Flutter) / 파일 전송 **초기 버전부터 포함**

---

## 1. 설계 목표와 비목표

### 목표
- 각 기기가 인프라 없이 서로 발견하고 연결 (P2P)
- **멀티홉 릴레이**: 나 → A → B 형태로 직접 안 보이는 상대에게 전달
- **오프라인 전달**: 수신자가 지금 없어도 중간 노드가 보관 후 나중에 전달
- **엔드투엔드 암호화**: 중계 노드는 내용을 볼 수 없음
- 텍스트 + 파일(청크 전송) 지원
- Android/iOS 동시 지원

### 비목표 (초기 버전)
- 대규모(수백 노드) 라우팅 최적화 — 초기엔 flooding으로 충분
- 인터넷 브리지/서버 동기화
- 그룹/채널 (1차는 1:1, 브로드캐스트만)
- 음성/영상 실시간 스트리밍 (BLE 대역폭 부적합)

---

## 2. 용어

| 용어 | 의미 |
|---|---|
| Node | 앱이 실행 중인 하나의 기기 |
| Peripheral | BLE 광고 + GATT 서버 역할 (남이 나를 발견/연결) |
| Central | BLE 스캔 + GATT 클라이언트 역할 (내가 남에게 연결) |
| Link | 두 노드 간 물리적 BLE 연결 1개 |
| Relay | 자신이 목적지가 아닌 패킷을 이웃에게 재전파 |
| Store-and-forward | 목적지가 현재 도달 불가일 때 큐에 보관 후 전달 |
| Peer ID | 노드 신원 = Ed25519/X25519 공개키의 해시 |

---

## 3. 노드 구조 (Dual-role)

모든 노드는 **Peripheral과 Central을 동시에** 실행하는 대칭 구조.

```
┌───────────────────────────────────────────────┐
│                   SpotLink Node                │
│                                                │
│   ┌────────────┐          ┌────────────────┐   │
│   │  Peripheral│          │    Central     │   │
│   │ (advertise │          │ (scan +        │   │
│   │  + GATT    │◄────────►│  connect to    │   │
│   │  server)   │          │  peers)        │   │
│   └─────┬──────┘          └───────┬────────┘   │
│         │                         │            │
│   ┌─────▼─────────────────────────▼────────┐   │
│   │           Link Manager                  │   │
│   │  (연결 목록, MTU, 재연결, 혼잡제어)      │   │
│   └─────┬───────────────────────────────────┘   │
│   ┌─────▼───────────────────────────────────┐   │
│   │           Router                        │   │
│   │  (flooding, TTL, dedup, relay 결정)      │   │
│   └─────┬───────────────────────────────────┘   │
│   ┌─────▼──────────┐  ┌───────────────────────┐ │
│   │ Message Store  │  │  Crypto (E2E, Noise)  │ │
│   │ (queue, outbox)│  │  X25519 + AES-GCM     │ │
│   └────────────────┘  └───────────────────────┘ │
└────────────────────────────────────────────────┘
```

동시에 두 역할을 하므로, 두 노드가 만나면 **누가 Central이고 누가 Peripheral인가**를 정해야 함
(둘 다 서로에게 연결하면 이중 링크 발생 → 낭비/충돌). → **Peer ID 사전순 비교로 tie-break**
(작은 ID가 Central 역할로 connect, 큰 ID는 광고만 유지).

---

## 4. GATT 프로파일 설계

Peripheral이 노출하는 커스텀 서비스 1개:

```
Service UUID: 0xSPOT (128-bit custom UUID, 앱 고정값)
├─ Characteristic: TX   (Write / Write No Response)  ← 상대가 나에게 보냄
├─ Characteristic: RX   (Notify)                     ← 내가 상대에게 보냄
└─ Characteristic: INFO (Read)                        ← Peer ID, 프로토콜 버전, MTU 힌트
```

- 연결 후 양쪽 모두 MTU 협상 (Android 최대 517, iOS 자동). 실효 payload = MTU − 3
- 큰 데이터는 TX/RX로 **프레이밍된 청크 스트림** 전송 (아래 8절)
- 광고 패킷: Service UUID + 짧은 식별자(회전형, 프라이버시). 이름 노출 최소화

---

## 5. 패킷 포맷

모든 통신은 링크 위에서 프레임 단위로 흐른다. 프레임 = 헤더 + 페이로드.

### 5.1 Frame 헤더 (고정 12+ bytes)

```
Offset  Size  Field
0       1     version         (프로토콜 버전, 현재 1)
1       1     type            (아래 6절 메시지 타입)
2       1     ttl             (남은 홉 수, 시작값 예: 7)
3       1     flags           (bit0: encrypted, bit1: compressed, bit2: ack_req)
4       16    msgId           (랜덤 128-bit, dedup 키)
20      8     srcId           (송신자 Peer ID 앞 8B)
28      8     dstId           (목적지 Peer ID 앞 8B, 브로드캐스트=0x00..)
36      4     payloadLen      (uint32, 전체 논리 메시지 길이)
40      ...   payload         (암호화된 본문 or 청크)
```

> srcId/dstId를 8바이트 축약으로 쓰되, 충돌 방지를 위해 핸드셰이크 시 전체 공개키 교환.

### 5.2 링크 레벨 청킹

BLE는 한 번에 MTU만큼만 보낼 수 있으므로, 위 Frame을 **L2 청크**로 쪼갬:

```
[chunkHeader: msgId(16B) | seq(2B) | total(2B) | len(1B)] [chunk bytes...]
```
수신 측은 msgId별 버퍼에 seq 순서대로 재조립 → Frame 완성 → Router로 전달.

---

## 6. 메시지 타입

| type | 이름 | 방향 | 설명 |
|---|---|---|---|
| 0x01 | ANNOUNCE | 링크 | 연결 직후 신원(공개키)·버전 교환, Noise 핸드셰이크 |
| 0x02 | TEXT | E2E | 텍스트 메시지 (암호화 payload) |
| 0x03 | FILE_META | E2E | 파일 전송 시작: 이름, 크기, mime, 총 청크 수, 해시 |
| 0x04 | FILE_CHUNK | E2E | 파일 청크 (seq 포함) |
| 0x05 | ACK | E2E | 특정 msgId 수신 확인 (신뢰성) |
| 0x06 | HAVE | 링크 | 내가 보유한 store-and-forward msgId 목록 (동기화) |
| 0x07 | WANT | 링크 | 상대에게 특정 msgId 요청 |
| 0x08 | RECEIPT | E2E | 최종 수신자의 종단 전달 영수증 (발신자에게 역전파) |

- ANNOUNCE / HAVE / WANT는 **홉 단위**(암호화 불필요, 이웃끼리)
- TEXT / FILE_* / ACK / RECEIPT는 **종단 간**(암호화됨, 중계 노드는 못 읽음)

---

## 7. 라우팅 — Flooding + TTL + Dedup + Store-and-forward

인터넷식 경로 계산 대신, 검증된 메시 방식(Bitchat/Briar 계열):

### 7.1 전파 규칙
```
onFrameReceived(frame):
    if frame.msgId in seenCache:        # 이미 본 것
        return                          # 드롭 (루프 방지)
    seenCache.add(frame.msgId, ttl=10min)

    if frame.dstId == myId or frame.dstId == BROADCAST:
        deliverLocally(frame)           # 나에게 온 것 → 복호화·표시
        if frame.dstId == myId:
            sendAck(frame)              # 종단 ACK 역전파

    if frame.dstId != myId:             # 나 아니면 중계 대상
        frame.ttl -= 1
        if frame.ttl > 0:
            storeAndForward(frame)      # 큐에 저장
            relayToAllNeighbors(frame, except=sender)
```

### 7.2 Dedup 캐시
- `seenCache`: msgId → 만료시간 (LRU + TTL). 링 버퍼로 메모리 상한.
- 같은 메시지를 여러 이웃에게서 받아도 1번만 처리·전파.

### 7.3 Store-and-forward (핵심)
- 목적지가 현재 이웃에 없어도, 노드는 msgId를 **outbox 큐**에 보관.
- 새 이웃과 연결되면 **HAVE/WANT 동기화**:
  1. 연결 직후 서로 `HAVE`(보유 msgId 목록) 교환
  2. 상대가 없는 것을 `WANT`으로 요청
  3. 해당 Frame 전송
- 이 방식으로 B가 나중에 A 근처에 오면 밀린 메시지를 받음 (지연 전달).
- 보관 정책: 최대 보관 기간(예 24h), 최대 용량, 종단 RECEIPT 수신 시 삭제.

### 7.4 브로드캐스트
- `dstId = 0x00...`: 근처 모두에게. TTL로 확산 범위 제한. (공지/디스커버리용)

---

## 8. 파일 전송

BLE 실효 처리량은 낮고(수 KB~수십 KB/s), 멀티홉이면 더 느림. 아래로 대응:

### 8.1 흐름
```
발신자                                    수신자
  │  FILE_META (name,size,mime,chunks,sha256) │
  │──────────────────────────────────────────►│
  │  FILE_CHUNK seq=0                          │
  │──────────────────────────────────────────►│
  │  FILE_CHUNK seq=1 ...                       │
  │──────────────────────────────────────────►│
  │              ACK (window/seq)              │
  │◄──────────────────────────────────────────│
  │  ... 누락분 재전송 ...                       │
  │  RECEIPT (전체 완료 + sha256 검증)          │
  │◄──────────────────────────────────────────│
```

### 8.2 규칙
- **청크 크기**: 논리 청크 = 부하 조절용(예 4KB). 이를 다시 L2 MTU 청크로 분할.
- **윈도우 기반 흐름제어**: N개 보내고 ACK 대기 (BLE 버퍼 오버런 방지).
- **재전송**: 수신자가 누락 seq를 ACK에 담아 요청 → 해당 청크만 재전송.
- **무결성**: FILE_META의 sha256으로 최종 검증. 실패 시 해당 청크 재요청.
- **크기 제한(초기)**: 예 5MB. 초과 시 경고. 이미지 자동 리사이즈/압축 옵션.
- **멀티홉 파일**: 각 청크도 일반 Frame이므로 flooding으로 중계됨. 다만 대용량은
  홉이 늘수록 지연 급증 → UX 상 "전송 중/예상 시간" 표시 필수.
- **재개(resume)**: FILE_META의 msgId 기준으로 이미 받은 seq는 스킵.

---

## 9. 신원 & 보안 (E2E)

### 9.1 신원
- 최초 실행 시 키쌍 생성: **Ed25519(서명) + X25519(키교환)**.
- Peer ID = 공개키 SHA-256의 앞부분. 신원 = 키 (계정 서버 없음).
- 최초 신뢰 구축: **QR 코드로 상대 공개키 교환·검증** (중간자 공격 방지).

### 9.2 암호화
- 종단 간 세션: **Noise Protocol (XX 핸드셰이크)** 권장. 대안: X25519 ECDH → HKDF → AES-256-GCM.
- 중계 노드는 헤더(dstId, ttl)만 읽고 payload는 복호화 불가.
- 각 메시지 nonce 유니크. 순방향 비밀성 위해 세션키 주기적 재협상.
- 메타데이터 최소화: 광고 식별자 회전, srcId/dstId는 축약 해시.

### 9.3 신뢰 모델
- 중계 노드는 신뢰하지 않음(무내용). 다만 메시지 존재/타이밍은 노출됨(BLE 특성).
- 스팸/DoS 방지: 서명 검증 실패 Frame 드롭, rate-limit, TTL 상한.

---

## 10. 로컬 저장 (Persistence)

| 저장소 | 내용 | 기술 |
|---|---|---|
| Identity | 내 키쌍 | 보안 저장소 (Keychain / Keystore) |
| Contacts | 알고 있는 Peer 공개키·별칭·검증여부 | 암호화 DB |
| Messages | 대화 내역, 상태(sending/sent/delivered/read) | SQLite (drift/sqflite) |
| Outbox | store-and-forward 대기 Frame | SQLite + 파일 |
| Files | 수신 파일 blob | 앱 문서 디렉토리 |
| SeenCache | dedup (휘발성 + 일부 영속) | 메모리 + LRU |

---

## 11. 플랫폼 제약 & 대응 (가장 큰 리스크)

### 11.1 Android
- 백그라운드 BLE 스캔/광고 가능하나 **Foreground Service + 알림** 필수 (지속 동작).
- Android 12+ 권한: `BLUETOOTH_SCAN`, `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT`,
  스캔 시 위치권한 or `neverForLocation` 플래그.
- Doze 모드에서 스캔 주기 제한 → Foreground Service로 완화.

### 11.2 iOS (최난관)
- 백그라운드 광고 시 **로컬 네임 미포함**, "overflow area"로만 광고 → iOS끼리 백그라운드 발견 어려움.
- 백그라운드 스캔은 **Service UUID 명시 필수**, 주기 느림, 화면 꺼지면 성능 급감.
- `bluetooth-central` + `bluetooth-peripheral` 백그라운드 모드 Info.plist 선언 필요.
- State Preservation/Restoration으로 앱 종료 후 BLE 이벤트 복원.
- **iOS ↔ iOS 백그라운드 릴레이는 실질적으로 불안정** → 앱 포그라운드 권장, 또는
  Android 노드를 "슈퍼 릴레이"로 활용하는 하이브리드 토폴로지 고려.

### 11.3 크로스플랫폼 상호운용
- Android/iOS가 같은 커스텀 GATT 서비스·프레이밍을 쓰면 상호 연결 가능.
- MTU/쓰기 방식 차이 흡수 위해 Link Manager에서 플랫폼별 정규화.

### 11.4 RadioProfile — 플랫폼 정책의 단일 지점 (구현됨)

위 11.1~11.3의 대응책은 실기기 사건마다 하나씩 추가되면서 한때 전송·앱 계층
**25곳의 `Platform.isX` 분기**로 흩어져 있었다. 그 결과 두 가지 구조적 문제가
있었다:

1. **macOS가 우연히 2등 시민이 됐다.** 모든 분기의 else로 떨어져 ① 필터 스캔만
   돌았고(→ iOS 27 포그라운드 iPhone을 발견 못 함 — 상대가 dial해 주기만 기다림),
   ② 식별자 기반 대기 연결과 ③ 스택 하드리셋도 받지 못했다. 같은 CoreBluetooth인데도.
2. 새 플랫폼을 붙이려면 25곳을 전부 감사해야 했다.

이제 모든 OS별 결정은 [`lib/core/ble/radio_profile.dart`](../lib/core/ble/radio_profile.dart)의
**이름을 가진 정책 값**이고, 메커니즘(타이머·상태기계·복구 경로)은 전부 플랫폼
중립이다. 전송·앱 계층의 `Platform.isX` 분기는 **0개**다.

| 정책 | ios | android | darwin-desktop | generic(미지의 플랫폼) |
|---|---|---|---|---|
| `scanAlwaysUnfiltered` | – | ✓ | – | ✓ |
| `alternatesScanWindows` | ✓ | – | ✓ | – |
| `switchesScanModeOnForeground` | ✓ | – | ✓ | – |
| `usesPendingConnect` | ✓ | – | ✓ | – |
| `connectTimeout` | 무제한 | 20s | 무제한 | 20s |
| `pausesScanWhileConnecting` | – | ✓ | – | – |
| `probesAppleDevices` | – | ✓ | – | – |
| `supportsScanPowerTuning` | – | ✓ | – | – |
| `needsStackHardReset` | ✓ | – | ✓ | – |
| `supportsBeaconWake` | ✓ | – | – | – |
| `usesAdaptivePower` | – | ✓ | – | – |

각 값의 **근거(어떤 실기기 사건에서 나왔는지)** 는 프로파일 파일의 doc 주석에
붙어 있다 — 값과 이유가 분리되지 않게 하는 것이 이 설계의 핵심이다.

#### 새 플랫폼 추가 체크리스트

1. `RadioProfile`에 프로파일 상수를 추가하고 `forCurrentPlatform()`에 분기 한 줄
   추가. **다른 파일은 건드리지 않는다.**
2. 아무 값도 모르겠으면 그냥 `generic`을 쓴다 — 최적은 아니지만 **절대 침묵하지
   않는다**(무필터 스캔 + 상한 있는 connect + OS 보장 전제 기능 전부 끔).
3. 실기기에서 관찰하며 하나씩 켠다. 판정용 로그 시그니처:
   - `BLE start: ... profile=<name>` — 어떤 정책으로 돌았는지
   - `BLE scanning started (unfiltered|filtered)` — 스캔 모드 교대 확인
   - `BLE discovered <id>` — 발견 경로가 살아 있는지
   - `BLE hard reset: ...` — 세션 노화 자동복구가 돌았는지
4. `test/radio_profile_test.dart`에 새 프로파일을 불변식 목록에 넣는다. 불변식이
   모순 설정(예: 대기 연결도 없고 connect 상한도 없음 → dial 영구 정지)을 잡아준다.

### 11.5 RadioHealth — "왜 못 찾았는가"의 단일 분류

"연결 안 됨"은 증상이지 원인이 아니고, 원인별 조치가 정반대다. 그 구분을 사람이
매번 `ble.log`로 하지 않도록 [`lib/core/ble/radio_health.dart`](../lib/core/ble/radio_health.dart)가
관측 신호에서 자동 분류한다. 이 분류는 **로그·자동복구·알림 결정의 공통 근거**다.

| 상태 | 의미 | 옳은 조치 |
|---|---|---|
| `linked` | 링크 있음 | 없음 |
| `searching` | 최근 발견·링크 진전 있음 | 기다린다 |
| `quiet` | 스캔 정상인데 아무 광고도 안 보임 | **주변에 아무도 없다** — 알림 금지 |
| `linkFlapping` | 발견되나 링크가 반복 절단 | 상대 스택 문제 → 재연결 **억제**(플랩 차단기) |
| `stackAged` | 진전 장기 전무 | 우리 스택 사망 → 하드리셋 |
| `radioOff` / `unauthorized` | 블루투스 꺼짐 / 권한 없음 | 사용자만 해결 가능 → 배너 |

세 개의 파생 속성이 결정 지점을 대신한다: `needsUserAction`(배너),
`needsSelfRepair`(하드리셋 게이트), `hasPeerEvidence`(웨이크 넛지 알림 게이트 —
`quiet`에서 알림을 보내면 오탐이다). 상태 전이는 `BLE health: <state> (...)`로
로그에 남아, 다음 사건에서 로그 첫 줄만 봐도 분류가 끝난다.

### 11.6 복구 에스컬레이션 사다리 (타이머 상호 잠금 주의)

복구 장치는 **가벼운 것부터 무거운 것 순**으로 겹쳐 있다. 각 층은 아래 층이
실패했을 때만 의미가 있고, 일부는 서로 물려 있어 상수를 혼자 바꾸면 깨진다.

| 층 | 트리거 | 동작 | 근거 사건 |
|---|---|---|---|
| 1 | 링크 up 후 12s(central)/30s(peripheral) 무수신 | 좀비 링크 절단+재다이얼 | 07-18·19 반쯤 죽은 ACL |
| 2 | central 링크 성립 직후 | INFO 읽기로 능동 생존 확인(8s) | 위와 동일(감지 12s→8s) |
| 3 | GATT write 실패/타임아웃(10s) | 링크 절단 | 07-17 다중 파일 동결 |
| 4 | 같은 키 90s 내 3회 절단 | **플랩 차단기**: 재연결 60s 휴식 | 07-24 삼성 루프 |
| 5 | 링크 0, 15s 주기 | 광고·스캔 재확립(멱등) | 상시 |
| 6 | 링크 0 약 2분(8틱) | deep heal: GATT 재발행 + 대기 연결 재장전 | 재발견 교착 |
| 7 | 링크 있음, 2분 주기 | 유지보수 재확립(3번째 기기 발견 구멍 방지) | 구조 검토 |
| 8 | 진전 4분 전무(`stackAged`) | **네이티브 스택 하드리셋** | 07-25 세션 노화 |
| 9 | 링크 0, 부팅 후 30s / 운영 중 60s | 비콘 TX 펄스(상대를 깨움) | 스와이프킬 재실행 |

**깨지기 쉬운 상호 잠금 3가지**

1. 9층의 펄스 간격(40s 블랙아웃)은 **비콘 리전 EXIT 임계(~30s)보다 커야** 한다.
   더 이른 전면 펄스는 로테이션 웨이크를 침묵시켜 역효과다.
2. 8층 하드리셋은 `health.needsSelfRepair`만 통과시킨다 — 4층(플랩)이나
   `quiet`에서 스택을 재초기화하면 **오진**이다.
3. 1층의 peripheral 창(30s)은 central(12s)보다 길어야 한다. 상대가 우리 서비스를
   discover하고 write 핸들을 얻는 데 삼성 등에서 12s를 넘기며, 짧으면 상대가
   준비를 끝내려는 찰나마다 끊는 무한 재연결 루프가 된다.

---

## 12. 전력 관리
- 스캔: 저전력 주기 스캔(듀티 사이클) + 이벤트 시 버스트.
- 연결 유지 개수 상한(예 4~8개 링크). 오래된/약한 링크 정리.
- 파일 전송 중에만 고속 연결 파라미터 요청.
- 사용자 토글: "배터리 절약 모드" ↔ "적극 릴레이 모드".

---

## 13. Flutter 모듈 구조 (제안)

```
lib/
├── main.dart
├── core/
│   ├── ble/
│   │   ├── peripheral_service.dart   # 광고 + GATT 서버
│   │   ├── central_service.dart      # 스캔 + 연결
│   │   ├── link_manager.dart         # 링크/ MTU / 재연결
│   │   └── framing.dart              # L2 청크 분할·재조립
│   ├── router/
│   │   ├── router.dart               # flooding/TTL/dedup
│   │   ├── seen_cache.dart
│   │   └── store_forward.dart        # HAVE/WANT 동기화
│   ├── crypto/
│   │   ├── identity.dart             # 키쌍/Peer ID
│   │   └── session.dart              # Noise / ECDH+AES-GCM
│   ├── transfer/
│   │   ├── text_transfer.dart
│   │   └── file_transfer.dart        # 청크/윈도우/재전송
│   └── model/                        # Frame, Message, Peer, FileMeta
├── data/
│   ├── db.dart                       # drift/sqflite
│   └── repositories/
├── features/
│   ├── chat/                         # UI: 대화
│   ├── contacts/                     # QR 신원교환
│   └── nearby/                       # 주변 노드 지도/목록
└── app/ (라우팅, DI, 테마)
```

**후보 패키지**
- `bluetooth_low_energy` (central + peripheral 둘 다) — 1순위
- 대안: `flutter_blue_plus`(central) + `ble_peripheral`(peripheral) 조합
- `cryptography` / `libsodium` 바인딩 (X25519, AES-GCM, Ed25519)
- `drift` 또는 `sqflite` (DB), `flutter_secure_storage` (키)

---

## 14. 핵심 상태 머신

### 14.1 Link 상태
```
DISCOVERED → CONNECTING → CONNECTED → ANNOUNCED(핸드셰이크 완료)
           ↘ FAILED        ↘ DISCONNECTED → (재연결 백오프)
```

### 14.2 메시지 상태 (발신자 관점)
```
QUEUED → SENT(첫 홉 전달) → DELIVERED(종단 ACK) → READ
       ↘ FAILED(TTL 소진/만료)
```

---

## 15. 개발 로드맵 (파일 포함 크로스플랫폼)

| 단계 | 내용 | 검증 기준 |
|---|---|---|
| M0 | 프로젝트 셋업, 권한, 패키지 PoC | 2대에서 광고/스캔 상호 발견 |
| M1 | 1:1 링크 + ANNOUNCE + 텍스트 송수신 | Android↔iOS 텍스트 왕복 |
| M2 | Router: flooding+TTL+dedup, 3대 멀티홉 | 나→A→B 텍스트 전달 |
| M3 | Store-and-forward + HAVE/WANT | B 나중 접속 시 밀린 메시지 수신 |
| M4 | Crypto: 신원, QR 교환, E2E 암호화 | 중계 노드가 내용 못 봄 확인 |
| M5 | 파일 전송: META/CHUNK/ACK/재전송/해시 | 이미지 멀티홉 전송·무결성 |
| M6 | 백그라운드/전력 최적화, iOS 제약 대응 | 화면 꺼짐 상태 릴레이(가능 범위) |
| M7 | UI 완성도, 대화/연락처/주변 지도 | 사용성 테스트 |

---

## 16. 주요 리스크 & 오픈 이슈

| 리스크 | 영향 | 대응 |
|---|---|---|
| iOS 백그라운드 BLE 제약 | 릴레이 신뢰성 저하 | 포그라운드 권장, Android 슈퍼릴레이, 기대치 관리 |
| BLE 대역폭 낮음 | 파일 전송 느림 | 압축·크기제한·진행률 UI |
| 배터리 소모 | 상시 스캔/광고 | 듀티사이클, 링크 상한, 절약 모드 |
| 플러딩 확산/스팸 | 네트워크 혼잡 | TTL 상한, dedup, rate-limit, 서명검증 |
| 신원 위조 | 사칭 | QR 검증, 서명, TOFU |
| iOS↔iOS 백그라운드 발견 | 메시 단절 | State Restoration, 하이브리드 토폴로지 |

### 결정 대기 항목
- 그룹 채팅 필요 시점? (초기 비목표)
- 파일 최대 크기 정책 확정
- 슈퍼릴레이(전용 릴레이 노드) 도입 여부
- 메시지 보관 기간/용량 상한 수치
