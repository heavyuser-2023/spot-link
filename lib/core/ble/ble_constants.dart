import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

/// SpotLink GATT 프로파일의 고정 식별자들. docs/ARCHITECTURE.md §4 참고.
class BleConstants {
  BleConstants._();

  /// 기본 커스텀 서비스. 모든 SpotLink 노드가 이를 광고하고 노출한다.
  static final UUID serviceUuid =
      UUID.fromString('7370746c-696e-6b00-0000-000000000001');

  /// TX: 센트럴 -> 페리페럴. 센트럴이 이곳에 프레임을 쓴다.
  static final UUID txCharacteristicUuid =
      UUID.fromString('7370746c-696e-6b00-0000-000000000002');

  /// RX: 페리페럴 -> 센트럴 (notify). 페리페럴이 이곳으로 프레임을 알린다(notify).
  static final UUID rxCharacteristicUuid =
      UUID.fromString('7370746c-696e-6b00-0000-000000000003');

  /// INFO: 페리페럴의 공개 번들을 노출하는 읽기 가능한 characteristic.
  static final UUID infoCharacteristicUuid =
      UUID.fromString('7370746c-696e-6b00-0000-000000000004');

  /// 광고에 짧은 PeerId를 실어 나르는 데 사용하는 제조사 id.
  /// 0xFFFF는 "회사 없음" 테스트 id로 — P2P 앱에는 적합하다.
  static const int manufacturerId = 0xFFFF;

  /// 모든 노드가 광고하는 로컬 이름. 발견용 폴백 역할도 겸한다: iOS 피어의
  /// 128비트 서비스 UUID가 BLE 오버플로 영역에 숨겨져 있을 때, 필터링되지 않은
  /// 안드로이드 스캔이 이 이름으로 iOS 피어를 매칭한다.
  static const String advertisedName = 'SL';

  /// MTU 협상이 완료되기 전에 쓰는 보수적인 기본 패킷 크기.
  /// BLE 4.0은 23바이트 ATT MTU(사용 가능한 페이로드 20바이트)를 보장한다. 우리 L2
  /// 헤더는 8바이트이므로, 20이면 데이터 12바이트가 남아 — 항상 분할 가능하다.
  static const int defaultMaxPacketSize = 20;

  /// 보고된 write/notify 길이가 비현실적으로 작거나 0일 때 방어적으로 사용하는
  /// 절대 하한선 (8바이트 L2 헤더보다는 커야 한다).
  static const int minUsablePacketSize = 20;

  /// 협상 이후 우리가 목표로 하는 폴백 패킷 크기 (MTU 247 -> 사용 가능 244).
  static const int targetMaxPacketSize = 244;
}
