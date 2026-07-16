import 'dart:math';
import 'dart:typed_data';

/// 큰 논리 프레임을 MTU 크기의 BLE 패킷으로 쪼개고, 수신 측에서 다시
/// 조립한다.
///
/// 한 번의 BLE write/notify는 최대 (MTU - 3) 바이트만 담을 수 있다. 협상
/// 가능한 최소 ATT MTU인 23을 쓰면 사용 가능한 바이트는 20뿐이라 — L2
/// 헤더는 작게 유지해야 한다. 8바이트 헤더(4바이트 transfer id + seq +
/// total)를 써서, 최악의 링크에서도 최소 12바이트의 페이로드를 남긴다.
///
/// L2 청크 레이아웃(big-endian), 헤더 = 8바이트:
/// ```
/// 0   transferId  4 bytes  (한 링크에서 하나의 논리 프레임에 속한 청크들을 묶음)
/// 4   seq         u16
/// 6   total       u16
/// 8   data        패킷의 나머지
/// ```
class L2Framing {
  static const int chunkHeaderLength = 8;
  static const int _idLen = 4;

  static final Random _rng = Random.secure();

  /// transfer id를 위한 프로세스 전역 단조 증가 카운터. 순차적인 id를 쓰면
  /// (랜덤한 4바이트 값 대신) 한 링크에서 동시 진행 중인 여러 청크 프레임
  /// 사이에 2^32번의 전송 이내에서는 충돌이 절대 없음이 보장된다 — 랜덤
  /// id였다면 감수해야 할 조용한 재조립 손상을 없애준다. 랜덤하게 시드를
  /// 주어, 재시작 후에도 피어가 아직 재조립 중일 수 있는 id를 재사용하지
  /// 않는다.
  static int _counter = _rng.nextInt(0x100000000);

  static int nextTransferId() {
    final id = _counter & 0xFFFFFFFF;
    _counter = (_counter + 1) & 0xFFFFFFFF;
    return id;
  }

  /// [frameBytes]를 각 패킷의 전체 크기(헤더 + 데이터)가 [maxPacketSize]
  /// (보통 MTU - 3)를 넘지 않는 패킷들로 쪼갠다. 최소 하나의 패킷을 보장한다.
  ///
  /// [transferId]는 결과로 나오는 청크들을 묶는다; 호출자는 id가 절대
  /// 충돌하지 않도록 [nextTransferId]에서 얻은 값을 넘겨야 한다. 기본값은
  /// 다음 카운터 값이다.
  static List<Uint8List> split(Uint8List frameBytes, int maxPacketSize,
      {int? transferId}) {
    final maxData = maxPacketSize - chunkHeaderLength;
    if (maxData <= 0) {
      throw ArgumentError('maxPacketSize too small: $maxPacketSize '
          '(must exceed header $chunkHeaderLength)');
    }
    final id = (transferId ?? nextTransferId()) & 0xFFFFFFFF;
    final total = max(1, (frameBytes.length + maxData - 1) ~/ maxData);
    if (total > 0xFFFF) {
      throw ArgumentError('frame too large for L2 framing: '
          '${frameBytes.length} bytes at $maxData/chunk');
    }
    final packets = <Uint8List>[];
    for (var seq = 0; seq < total; seq++) {
      final start = seq * maxData;
      final end = min(start + maxData, frameBytes.length);
      final dataLen = end - start;
      final packet = Uint8List(chunkHeaderLength + dataLen);
      final bd = ByteData.view(packet.buffer);
      bd.setUint32(0, id, Endian.big);
      bd.setUint16(_idLen, seq, Endian.big);
      bd.setUint16(_idLen + 2, total, Endian.big);
      packet.setRange(chunkHeaderLength, packet.length,
          frameBytes.sublist(start, end));
      packets.add(packet);
    }
    return packets;
  }
}

/// 하나의 링크로 도착하는 L2 청크들을 완전한 프레임 바이트 버퍼로
/// 재조립한다. 연결된 피어 링크마다 인스턴스 하나씩 둔다.
class L2Reassembler {
  final _partials = <String, _Partial>{};

  /// 가장 오래된 것부터 밀어내기 시작하기 전, 링크당 동시에 진행 중일 수
  /// 있는 최대 전송 수 — 메모리 남용에 대한 방어적 상한.
  final int maxConcurrent;

  L2Reassembler({this.maxConcurrent = 64});

  /// 수신한 BLE 패킷 하나를 넣는다. 마지막으로 빠져 있던 청크가 도착하면
  /// 완성된 프레임 바이트를 반환하고, 그렇지 않으면 null을 반환한다. 형식이
  /// 잘못된 패킷은 무시한다.
  Uint8List? offer(Uint8List packet) {
    if (packet.length < L2Framing.chunkHeaderLength) return null;
    // 헤더는 패킷 자신의 offset에 고정된 view를 통해 읽어, sublist(0이 아닌
    // offsetInBytes)도 올바르게 처리되도록 한다.
    final bd = ByteData.view(packet.buffer, packet.offsetInBytes, packet.length);
    final idKey = _hex(packet, 0, L2Framing._idLen);
    final seq = bd.getUint16(L2Framing._idLen, Endian.big);
    final total = bd.getUint16(L2Framing._idLen + 2, Endian.big);
    if (total == 0 || seq >= total) return null;

    final data = Uint8List.fromList(
        packet.sublist(L2Framing.chunkHeaderLength, packet.length));

    // Fast path: 단일 청크 프레임.
    if (total == 1) {
      return data;
    }

    var partial = _partials[idKey];
    if (partial == null) {
      if (_partials.length >= maxConcurrent) {
        // 가장 오래된 부분 전송을 밀어낸다.
        final oldest = _partials.keys.first;
        _partials.remove(oldest);
      }
      partial = _Partial(total);
      _partials[idKey] = partial;
    } else if (partial.total != total) {
      // transferId가 다른 framing으로 재사용됨: 이 부분 전송을 처음부터 다시 시작한다.
      partial = _Partial(total);
      _partials[idKey] = partial;
    }
    partial.chunks[seq] = data;

    if (partial.chunks.length == total) {
      _partials.remove(idKey);
      final builder = BytesBuilder(copy: false);
      for (var i = 0; i < total; i++) {
        builder.add(partial.chunks[i]!);
      }
      return builder.toBytes();
    }
    return null;
  }

  void reset() => _partials.clear();

  static String _hex(Uint8List b, int start, int end) {
    final sb = StringBuffer();
    for (var i = start; i < end; i++) {
      sb.write(b[i].toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}

class _Partial {
  final int total;
  final Map<int, Uint8List> chunks = {};
  _Partial(this.total);
}
