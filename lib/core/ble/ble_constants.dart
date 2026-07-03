import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

/// Fixed identifiers for the SpotLink GATT profile. See docs/ARCHITECTURE.md §4.
class BleConstants {
  BleConstants._();

  /// Primary custom service. All SpotLink nodes advertise & expose this.
  static final UUID serviceUuid =
      UUID.fromString('7370746c-696e-6b00-0000-000000000001');

  /// TX: central -> peripheral. The central writes frames here.
  static final UUID txCharacteristicUuid =
      UUID.fromString('7370746c-696e-6b00-0000-000000000002');

  /// RX: peripheral -> central (notify). The peripheral notifies frames here.
  static final UUID rxCharacteristicUuid =
      UUID.fromString('7370746c-696e-6b00-0000-000000000003');

  /// INFO: readable characteristic exposing the peripheral's public bundle.
  static final UUID infoCharacteristicUuid =
      UUID.fromString('7370746c-696e-6b00-0000-000000000004');

  /// Manufacturer id used to carry the short PeerId in advertisements.
  /// 0xFFFF is the "no company" test id — fine for a P2P app.
  static const int manufacturerId = 0xFFFF;

  /// Conservative default packet size before MTU negotiation completes.
  /// BLE 4.0 guarantees a 23-byte ATT MTU (20 usable payload bytes). Our L2
  /// header is 8 bytes, so 20 leaves 12 data bytes — always splittable.
  static const int defaultMaxPacketSize = 20;

  /// Absolute floor used defensively when a reported write/notify length is
  /// implausibly small or zero (must exceed the 8-byte L2 header).
  static const int minUsablePacketSize = 20;

  /// Fallback packet size we aim for after negotiation (MTU 247 -> 244 usable).
  static const int targetMaxPacketSize = 244;
}
