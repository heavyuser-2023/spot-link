# SpotLink 개인정보처리방침 (Privacy Policy)

최종 수정일: 2026년 7월 6일

SpotLink(이하 "앱")는 인터넷 인프라 없이 근거리 BLE 메시 네트워크로 메시지와 파일을
주고받는 오프라인 메신저입니다. 본 방침은 앱이 다루는 정보와 그 처리 방식을 설명합니다.

## 1. 수집하는 정보: 없음

**SpotLink는 운영 서버가 없으며, 개발자나 제3자에게 어떠한 개인정보도 수집·전송하지
않습니다.** 회원가입, 전화번호, 이메일, 광고 식별자, 분석(analytics), 위치 추적을
일절 사용하지 않습니다.

## 2. 기기에만 저장되는 정보

아래 정보는 오직 사용자의 기기 내부 저장소(SQLite)에만 보관되며, 앱 삭제 시 함께
삭제됩니다.

- **신원 키**: 기기에서 생성되는 Ed25519/X25519 키 쌍. 개인키는 기기를 떠나지 않습니다.
- **대화 내용·파일**: 주고받은 메시지와 첨부 파일.
- **중계 보관함**: 메시 네트워크의 다른 사용자 간 메시지를 대신 전달하기 위한
  암호화된 데이터. 종단간 암호화되어 있어 중계 기기에서는 내용을 볼 수 없습니다.
- **프로필**: 사용자가 직접 입력한 표시 이름.

## 3. 기기 간 전송되는 정보

메시지·파일은 X25519 ECDH + AES-256-GCM으로 **종단간 암호화**되어 근처 기기와의
BLE(및 같은 네트워크의 로컬 TCP/Wi-Fi Direct) 연결로만 전송됩니다. 인터넷을 경유하지
않으며, 수신자만 복호화할 수 있습니다.

## 4. 권한 사용 목적

- **근처 기기(블루투스) 권한** (BLUETOOTH_SCAN/ADVERTISE/CONNECT): BLE 메시의 탐색·연결·중계.
  스캔 권한은 `neverForLocation` 플래그로 선언되어 위치 파악에 사용되지 않습니다.
- **위치 권한** (Android 11 이하만): 구버전 Android에서 BLE 스캔에 시스템상 필요. 위치
  정보를 저장하거나 전송하지 않습니다.
- **알림 권한**: 백그라운드 수신 메시지의 로컬 알림 표시.
- **포그라운드 서비스·배터리 최적화 예외**: 화면이 꺼져도 메시 노드(수신·중계)를 유지.
- **카메라**: 친구의 QR 코드 스캔(신원 공개키 확인) 용도로만 사용.
- **사진/파일 접근**: 사용자가 직접 선택한 파일의 첨부 전송 및 수신 파일 저장.

## 5. 제3자 제공·광고·추적

없습니다. 앱에는 광고 SDK, 분석 SDK, 크래시 리포팅 SDK가 포함되어 있지 않습니다.

## 6. 아동

앱은 연령과 무관하게 개인정보를 수집하지 않습니다.

## 7. 데이터 삭제

모든 데이터는 기기에만 존재합니다. 앱 내에서 대화·중계 보관함을 삭제하거나, 앱을
제거하면 모든 데이터가 삭제됩니다.

## 8. 문의

- 개발자: 김정훈 (Monolith Co., Ltd.)
- 이메일: jeonghun.kim@monolith.co.kr

---

# Privacy Policy (English Summary)

SpotLink is an offline BLE mesh messenger. **It has no servers and collects no personal
data whatsoever.** No sign-up, no phone number, no ads, no analytics, no tracking.
Messages and files are end-to-end encrypted (X25519 + AES-256-GCM) and travel only over
nearby Bluetooth LE / local Wi-Fi links. All data (identity keys, chats, relay store)
lives solely on your device and is deleted when you uninstall the app. Bluetooth
permissions are declared `neverForLocation`; location permission is used only on
Android ≤ 11 where the OS requires it for BLE scanning, and location is never stored or
transmitted. Contact: jeonghun.kim@monolith.co.kr
