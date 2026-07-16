import 'dart:convert';
import 'dart:typed_data';

/// TEXT 페이로드를 위한 버전이 있는 엔벨로프 (e2e 암호화 내부).
///
/// v1.5.15+는 utf8 텍스트를 발신자의 벽시계 발신 시각을 담은 11바이트
/// 프리픽스로 감싸서, 수신자가 "보냄 HH:mm · 도착 HH:mm"을 표시할 수 있게 한다 —
/// 이는 몇 시간 뒤에 도착하는 store-and-forward 텍스트에서 가장 중요하다.
///
/// ```
/// 0  magic0   0x01
/// 1  magic1   0xA7
/// 2  version  u8 (1)
/// 3  sentAtMs u64 big-endian (unix 밀리초, 발신자 시계)
/// 11 text     utf8 bytes
/// ```
///
/// 와이어 호환성, 양방향:
/// - 구형 발신자 → 신형 수신자: 레거시 페이로드는 순수 utf8이다. 0x01 뒤에
///   0xA7(단독 연속 바이트)이 오는 것은 잘못된 utf8이므로, 유효한 레거시
///   페이로드는 결코 이 매직으로 시작할 수 없다 — [decode]가 깔끔하게 폴백한다.
/// - 신형 발신자 → 구형 수신자: 구형 앱은 페이로드 전체를 utf8 디코드하고
///   (allowMalformed) 짧은 쓰레기 프리픽스를 보여준다. 모든 기기가 함께
///   업데이트되는 이 자체 배포 플릿에서는 허용된다; 이 매직을 다른 용도로는
///   절대 재사용하지 말 것.
class TextEnvelope {
  static const int _magic0 = 0x01;
  static const int _magic1 = 0xA7;
  static const int _version = 1;
  static const int _headerLength = 11;

  final String text;

  /// 발신자의 발신 시각(발신자 시계), 레거시 페이로드면 null.
  final DateTime? sentAt;

  TextEnvelope(this.text, {this.sentAt});

  /// 주어진 발신 시각으로 인코딩한다(기본값은 현재 시각).
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

  /// 두 형식 모두 디코딩한다; 쓰레기 입력에도 절대 예외를 던지지 않는다(손실
  /// 허용 utf8로 폴백하여 이전 동작을 그대로 따른다).
  static TextEnvelope decode(Uint8List payload) {
    if (payload.length >= _headerLength &&
        payload[0] == _magic0 &&
        payload[1] == _magic1 &&
        payload[2] == _version) {
      final bd = ByteData.view(payload.buffer, payload.offsetInBytes);
      final ms = bd.getUint64(3, Endian.big);
      // 말이 안 되는 값은 거부한다(우연히 매직과 일치하는 손상 프레임은 사실상
      // 불가능하지만, 0이거나 그 밖에 망가진 시계는 그렇지 않다).
      final sentAt = (ms > 0 && ms < 4102444800000) // < 2100년
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
