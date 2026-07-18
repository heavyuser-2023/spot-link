import 'dart:convert';
import 'dart:typed_data';

import 'peer_id.dart';

/// 친구 QR 페이로드 형식:
/// `SPOTLINK1:<base64url 공개 번들>:<base64url 표시 이름>[:<base64url 논스>]`.
///
/// 논스(16바이트)는 상호 인증의 핵심이다: 공개 번들은 ANNOUNCE로도 방송되는
/// 공개 정보라 "번들을 안다"는 아무 증명이 못 되지만, 논스는 QR을 띄운 화면을
/// **직접 본** 사람만 알 수 있다 — 스캔한 쪽이 이를 암호화해 되돌려주면
/// "물리적으로 마주쳤다"의 증거가 되어 양쪽 모두 인증된 친구가 된다.
///
/// 생성(나 탭)과 파싱(스캔 화면 / 공유 링크) 양쪽을 위한 단일 코덱이므로,
/// 와이어 형식은 오직 한 곳에서만 바뀔 수 있다. 구버전은 세 번째 부분을
/// 무시한다(스캔한 쪽만 인증되는 기존 동작으로 자연 강등).
abstract final class QrPayload {
  static const prefix = 'SPOTLINK1:';

  static String encode(Uint8List publicBundle, String displayName,
          {Uint8List? nonce}) =>
      '$prefix${b64(publicBundle)}:${b64(utf8.encode(displayName))}'
      '${nonce != null ? ':${b64(nonce)}' : ''}';

  /// (publicBundle, displayName, 상호인증 논스?)를 반환하거나, [payload]가
  /// 유효한 SpotLink QR이 아니면 null을 반환한다. 이름·논스는 선택 사항이다
  /// (구형 페이로드).
  static (Uint8List, String, Uint8List?)? decode(String payload) {
    if (!payload.startsWith(prefix)) return null;
    final body = payload.substring(prefix.length);
    final parts = body.split(':');
    if (parts.isEmpty) return null;
    try {
      final bundle = unb64(parts[0]);
      final name = parts.length > 1 ? utf8.decode(unb64(parts[1])) : '';
      Uint8List? nonce;
      if (parts.length > 2) {
        final n = unb64(parts[2]);
        if (n.length == 16) nonce = n;
      }
      if (bundle.length != 64) return null;
      return (bundle, name, nonce);
    } catch (_) {
      return null;
    }
  }
}
