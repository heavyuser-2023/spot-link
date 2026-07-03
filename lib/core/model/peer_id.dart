import 'dart:convert';
import 'dart:typed_data';

/// A node identity, derived from its public key.
///
/// On the wire we only carry the first [wireLength] bytes of the full
/// SHA-256(publicKey) digest to keep frame headers small. The full public key
/// is exchanged during the ANNOUNCE handshake, so the short id is only ever
/// used as a routing/dedup hint — never as a security boundary.
class PeerId {
  static const int wireLength = 8;

  /// The short id bytes carried on the wire (exactly [wireLength] bytes).
  final Uint8List bytes;

  PeerId(Uint8List raw)
      : bytes = Uint8List.fromList(
          raw.length >= wireLength
              ? raw.sublist(0, wireLength)
              : (Uint8List(wireLength)..setRange(0, raw.length, raw)),
        );

  /// The broadcast destination: all-zero id.
  static final PeerId broadcast = PeerId(Uint8List(wireLength));

  bool get isBroadcast {
    for (final b in bytes) {
      if (b != 0) return false;
    }
    return true;
  }

  /// Hex representation, used as a stable map key / db key.
  String get hex {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// A short human-friendly form for the UI.
  String get short => hex.substring(0, 6);

  factory PeerId.fromHex(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return PeerId(out);
  }

  /// Compare two ids lexicographically. Used for connection-role tie-break:
  /// the node with the smaller id takes the Central (connecting) role.
  int compareTo(PeerId other) {
    for (var i = 0; i < wireLength; i++) {
      final d = bytes[i] - other.bytes[i];
      if (d != 0) return d;
    }
    return 0;
  }

  @override
  bool operator ==(Object other) =>
      other is PeerId && _listEquals(bytes, other.bytes);

  @override
  int get hashCode => Object.hashAll(bytes);

  @override
  String toString() => 'PeerId($short)';
}

bool _listEquals(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Utility: base64url helpers used for QR payloads and db storage of keys.
String b64(List<int> bytes) => base64Url.encode(bytes);
Uint8List unb64(String s) => base64Url.decode(s);
