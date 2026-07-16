import 'dart:convert';
import 'dart:typed_data';

/// 링크가 올라온 직후 링크-로컬로 교환되는 ANNOUNCE 페이로드.
/// 피어가 상대를 지정하고, 암호화하고, 라벨을 붙일 수 있도록 발신자의
/// 64바이트 공개 번들과 표시 이름을 실어 나른다.
///
/// 레이아웃: version(u8) | bundle(64) | nameLen(u16) | name(utf8).
class Announce {
  static const int version1 = 1;

  final Uint8List publicBundle; // 64바이트
  final String displayName;

  Announce({required this.publicBundle, required this.displayName});

  Uint8List encode() {
    final name = utf8.encode(displayName);
    final out = Uint8List(1 + 64 + 2 + name.length);
    out[0] = version1;
    out.setRange(1, 65, publicBundle);
    ByteData.view(out.buffer).setUint16(65, name.length, Endian.big);
    out.setRange(67, out.length, name);
    return out;
  }

  static Announce decode(Uint8List data) {
    if (data.length < 67) {
      throw const FormatException('announce too short');
    }
    final bundle = Uint8List.fromList(data.sublist(1, 65));
    final nameLen = ByteData.view(data.buffer, data.offsetInBytes)
        .getUint16(65, Endian.big);
    final name = utf8.decode(data.sublist(67, 67 + nameLen));
    return Announce(publicBundle: bundle, displayName: name);
  }
}
