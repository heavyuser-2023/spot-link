import 'dart:convert';
import 'dart:typed_data';

/// Versioned envelope for TEXT payloads (inside the e2e encryption).
///
/// v1.5.15+ wraps the utf8 text with an 11-byte prefix carrying the sender's
/// wall-clock send time, so a receiver can show "sent HH:mm · arrived HH:mm" —
/// which matters most for store-and-forward texts that land hours later.
///
/// ```
/// 0  magic0   0x01
/// 1  magic1   0xA7
/// 2  version  u8 (1)
/// 3  sentAtMs u64 big-endian (unix millis, sender's clock)
/// 11 text     utf8 bytes
/// ```
///
/// Wire compatibility, both directions:
/// - OLD sender → NEW receiver: a legacy payload is plain utf8. 0x01 followed
///   by 0xA7 (a bare continuation byte) is malformed utf8, so no valid legacy
///   payload can ever start with the magic — [decode] falls back cleanly.
/// - NEW sender → OLD receiver: the old app utf8-decodes the whole payload
///   (allowMalformed) and shows a short garbage prefix. Acceptable for this
///   self-distributed fleet where every device updates together; do NOT reuse
///   the magic for anything else.
class TextEnvelope {
  static const int _magic0 = 0x01;
  static const int _magic1 = 0xA7;
  static const int _version = 1;
  static const int _headerLength = 11;

  final String text;

  /// Sender's send time (their clock), or null for a legacy payload.
  final DateTime? sentAt;

  TextEnvelope(this.text, {this.sentAt});

  /// Encode with the given send time (defaults to now).
  static Uint8List encode(String text, {DateTime? sentAt}) {
    final at = sentAt ?? DateTime.now();
    final body = utf8.encode(text);
    final out = Uint8List(_headerLength + body.length);
    final bd = ByteData.view(out.buffer);
    out[0] = _magic0;
    out[1] = _magic1;
    out[2] = _version;
    bd.setUint64(3, at.millisecondsSinceEpoch, Endian.big);
    out.setRange(_headerLength, out.length, body);
    return out;
  }

  /// Decode either format; never throws on garbage (falls back to lossy utf8,
  /// mirroring the previous behaviour).
  static TextEnvelope decode(Uint8List payload) {
    if (payload.length >= _headerLength &&
        payload[0] == _magic0 &&
        payload[1] == _magic1 &&
        payload[2] == _version) {
      final bd = ByteData.view(payload.buffer, payload.offsetInBytes);
      final ms = bd.getUint64(3, Endian.big);
      // Reject absurd values (corrupt frame that happened to match the magic
      // is practically impossible, but a zero/othewise-broken clock isn't).
      final sentAt = (ms > 0 && ms < 4102444800000) // < year 2100
          ? DateTime.fromMillisecondsSinceEpoch(ms)
          : null;
      return TextEnvelope(
        utf8.decode(payload.sublist(_headerLength), allowMalformed: true),
        sentAt: sentAt,
      );
    }
    return TextEnvelope(utf8.decode(payload, allowMalformed: true));
  }
}
