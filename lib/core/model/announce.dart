import 'dart:convert';
import 'dart:typed_data';

/// 링크가 올라온 직후 링크-로컬로 교환되는 ANNOUNCE 페이로드.
/// 피어가 상대를 지정하고, 암호화하고, 라벨을 붙일 수 있도록 발신자의
/// 64바이트 공개 번들과 표시 이름을 실어 나른다.
///
/// 레이아웃: version(u8) | bundle(64) | nameLen(u16) | name(utf8)
///           [| avatarLen(u16) | avatar(utf8)]  ← 선택(파츠 아바타 레시피)
///
/// 아바타 레시피는 이름 뒤에 덧붙는다: 구버전 디코더는 name까지만 읽고
/// 나머지 바이트를 무시하므로 하위 호환이고, 신버전은 남은 길이가 충분할
/// 때만 읽으므로 상위 호환이다. 아바타는 이미지가 아니라 파츠 조합
/// 레시피(~30바이트 텍스트)다 — 렌더링은 각 기기의 내장 파츠 자산이 한다.
class Announce {
  static const int version1 = 1;

  final Uint8List publicBundle; // 64바이트
  final String displayName;
  final String? avatar; // 파츠 아바타 레시피(compact), 없으면 null

  Announce({required this.publicBundle, required this.displayName, this.avatar});

  Uint8List encode() {
    final name = utf8.encode(displayName);
    final av = avatar == null ? const <int>[] : utf8.encode(avatar!);
    final out = Uint8List(
        1 + 64 + 2 + name.length + (av.isEmpty ? 0 : 2 + av.length));
    out[0] = version1;
    out.setRange(1, 65, publicBundle);
    ByteData.view(out.buffer).setUint16(65, name.length, Endian.big);
    out.setRange(67, 67 + name.length, name);
    if (av.isNotEmpty) {
      final off = 67 + name.length;
      ByteData.view(out.buffer).setUint16(off, av.length, Endian.big);
      out.setRange(off + 2, off + 2 + av.length, av);
    }
    return out;
  }

  static Announce decode(Uint8List data) {
    if (data.length < 67) {
      throw const FormatException('announce too short');
    }
    final bundle = Uint8List.fromList(data.sublist(1, 65));
    final bd = ByteData.view(data.buffer, data.offsetInBytes);
    final nameLen = bd.getUint16(65, Endian.big);
    final name = utf8.decode(data.sublist(67, 67 + nameLen));
    String? avatar;
    final off = 67 + nameLen;
    if (data.length >= off + 2) {
      final avLen = bd.getUint16(off, Endian.big);
      if (avLen > 0 && data.length >= off + 2 + avLen) {
        try {
          avatar = utf8.decode(data.sublist(off + 2, off + 2 + avLen));
        } catch (_) {} // 손상된 아바타는 무시 — 이름/키가 우선이다
      }
    }
    return Announce(
        publicBundle: bundle, displayName: name, avatar: avatar);
  }
}
