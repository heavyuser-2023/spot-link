import 'dart:math';
import 'dart:typed_data';

/// Splits large logical frames into MTU-sized BLE packets and reassembles
/// them on the receiving side.
///
/// A single BLE write/notify carries at most (MTU - 3) bytes. With the minimum
/// negotiable ATT MTU of 23, that is only 20 usable bytes — so the L2 header
/// must stay small. We use an 8-byte header (4-byte transfer id + seq + total),
/// leaving at least 12 payload bytes even on the worst-case link.
///
/// L2 chunk layout (big-endian), header = 8 bytes:
/// ```
/// 0   transferId  4 bytes  (groups chunks of one logical frame on a link)
/// 4   seq         u16
/// 6   total       u16
/// 8   data        rest of packet
/// ```
class L2Framing {
  static const int chunkHeaderLength = 8;
  static const int _idLen = 4;

  static final Random _rng = Random.secure();

  /// Process-global monotonic counter for transfer ids. A sequential id (rather
  /// than a random 4-byte value) guarantees no collision between concurrent
  /// multi-chunk frames on a link within 2^32 sends — eliminating the silent
  /// reassembly corruption a random id would risk. Seeded randomly so restarts
  /// don't reuse ids a peer might still be reassembling.
  static int _counter = _rng.nextInt(0x100000000);

  static int nextTransferId() {
    final id = _counter & 0xFFFFFFFF;
    _counter = (_counter + 1) & 0xFFFFFFFF;
    return id;
  }

  /// Split [frameBytes] into packets whose total size (header + data) does not
  /// exceed [maxPacketSize] (typically MTU - 3). Guarantees at least one packet.
  ///
  /// [transferId] groups the resulting chunks; callers should pass a value from
  /// [nextTransferId] so ids never collide. Defaults to the next counter value.
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

/// Reassembles L2 chunks arriving on a single link into complete frame byte
/// buffers. One instance per connected peer link.
class L2Reassembler {
  final _partials = <String, _Partial>{};

  /// Max simultaneous in-flight transfers per link before we start evicting
  /// the oldest — a defensive bound against memory abuse.
  final int maxConcurrent;

  L2Reassembler({this.maxConcurrent = 64});

  /// Feed one received BLE packet. Returns the completed frame bytes when the
  /// last missing chunk arrives, otherwise null. Malformed packets are ignored.
  Uint8List? offer(Uint8List packet) {
    if (packet.length < L2Framing.chunkHeaderLength) return null;
    // Read header via a view anchored at the packet's own offset so sublists
    // (non-zero offsetInBytes) are handled correctly.
    final bd = ByteData.view(packet.buffer, packet.offsetInBytes, packet.length);
    final idKey = _hex(packet, 0, L2Framing._idLen);
    final seq = bd.getUint16(L2Framing._idLen, Endian.big);
    final total = bd.getUint16(L2Framing._idLen + 2, Endian.big);
    if (total == 0 || seq >= total) return null;

    final data = Uint8List.fromList(
        packet.sublist(L2Framing.chunkHeaderLength, packet.length));

    // Fast path: single-chunk frame.
    if (total == 1) {
      return data;
    }

    var partial = _partials[idKey];
    if (partial == null) {
      if (_partials.length >= maxConcurrent) {
        // Evict the oldest partial transfer.
        final oldest = _partials.keys.first;
        _partials.remove(oldest);
      }
      partial = _Partial(total);
      _partials[idKey] = partial;
    } else if (partial.total != total) {
      // transferId reuse with a different framing: restart this partial.
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
