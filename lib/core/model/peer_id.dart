import 'dart:convert';
import 'dart:typed_data';

/// 공개 키로부터 파생된 노드 신원.
///
/// 프레임 헤더를 작게 유지하기 위해, 와이어에서는 전체
/// SHA-256(publicKey) 다이제스트의 앞 [wireLength] 바이트만 실어 나른다. 전체
/// 공개 키는 ANNOUNCE 핸드셰이크 중에 교환되므로, 이 짧은 id는 언제나
/// 라우팅/중복 제거 힌트로만 쓰이며 — 보안 경계로는 절대 쓰이지 않는다.
class PeerId {
  static const int wireLength = 8;

  /// 와이어에 실리는 짧은 id 바이트 (정확히 [wireLength] 바이트).
  final Uint8List bytes;

  PeerId(Uint8List raw)
      : bytes = Uint8List.fromList(
          raw.length >= wireLength
              ? raw.sublist(0, wireLength)
              : (Uint8List(wireLength)..setRange(0, raw.length, raw)),
        );

  /// 브로드캐스트 목적지: 전부 0인 id.
  static final PeerId broadcast = PeerId(Uint8List(wireLength));

  bool get isBroadcast {
    for (final b in bytes) {
      if (b != 0) return false;
    }
    return true;
  }

  /// 안정적인 맵 키 / db 키로 사용되는 16진수 표현.
  String get hex {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// UI를 위한 짧고 사람이 읽기 쉬운 형태.
  String get short => hex.substring(0, 6);

  factory PeerId.fromHex(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return PeerId(out);
  }

  /// 두 id를 사전식으로 비교한다. 연결 역할 동점 처리에 사용된다:
  /// id가 더 작은 노드가 Central(연결을 거는) 역할을 맡는다.
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

/// 유틸: QR 페이로드와 키의 db 저장에 사용되는 base64url 헬퍼.
String b64(List<int> bytes) => base64Url.encode(bytes);
Uint8List unb64(String s) => base64Url.decode(s);
