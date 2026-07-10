import 'dart:convert';
import 'dart:typed_data';

import 'peer_id.dart';

/// The friend-QR payload format:
/// `SPOTLINK1:<base64url public bundle>:<base64url display name>`.
///
/// The single codec for both building (me tab) and parsing (scan screen /
/// share links), so the wire format can only ever change in one place.
abstract final class QrPayload {
  static const prefix = 'SPOTLINK1:';

  static String encode(Uint8List publicBundle, String displayName) =>
      '$prefix${b64(publicBundle)}:${b64(utf8.encode(displayName))}';

  /// Returns (publicBundle, displayName), or null when [payload] is not a
  /// valid SpotLink QR. The name part is optional (older payloads).
  static (Uint8List, String)? decode(String payload) {
    if (!payload.startsWith(prefix)) return null;
    final body = payload.substring(prefix.length);
    final parts = body.split(':');
    if (parts.isEmpty) return null;
    try {
      final bundle = unb64(parts[0]);
      final name = parts.length > 1 ? utf8.decode(unb64(parts[1])) : '';
      if (bundle.length != 64) return null;
      return (bundle, name);
    } catch (_) {
      return null;
    }
  }
}
