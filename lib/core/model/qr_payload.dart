import 'dart:convert';
import 'dart:typed_data';

import 'peer_id.dart';

/// 친구 QR 페이로드 형식:
/// `SPOTLINK1:<base64url 공개 번들>:<base64url 표시 이름>`.
///
/// 생성(나 탭)과 파싱(스캔 화면 / 공유 링크) 양쪽을 위한 단일 코덱이므로,
/// 와이어 형식은 오직 한 곳에서만 바뀔 수 있다.
abstract final class QrPayload {
  static const prefix = 'SPOTLINK1:';

  static String encode(Uint8List publicBundle, String displayName) =>
      '$prefix${b64(publicBundle)}:${b64(utf8.encode(displayName))}';

  /// (publicBundle, displayName)를 반환하거나, [payload]가 유효한 SpotLink
  /// QR이 아니면 null을 반환한다. 이름 부분은 선택 사항이다(구형 페이로드).
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
