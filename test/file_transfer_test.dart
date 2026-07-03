import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:spot_link/core/transfer/file_transfer.dart';

Uint8List randomBytes(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

void main() {
  group('FileMeta codec', () {
    test('round-trips', () {
      final meta = FileMeta(
        transferId: Uint8List.fromList(List.generate(16, (i) => i)),
        fileSize: 123456,
        chunkSize: 4096,
        totalChunks: 31,
        sha256: Uint8List.fromList(List.generate(32, (i) => 255 - i)),
        name: 'photo 사진.jpg',
        mime: 'image/jpeg',
      );
      final decoded = FileMeta.decode(meta.encode());
      expect(decoded.transferIdHex, meta.transferIdHex);
      expect(decoded.fileSize, meta.fileSize);
      expect(decoded.chunkSize, meta.chunkSize);
      expect(decoded.totalChunks, meta.totalChunks);
      expect(decoded.sha256, meta.sha256);
      expect(decoded.name, meta.name);
      expect(decoded.mime, meta.mime);
    });
  });

  group('FileChunk / FileAck codec', () {
    test('chunk round-trips', () {
      final c = FileChunk(Uint8List.fromList(List.generate(16, (i) => i)), 42,
          Uint8List.fromList([9, 8, 7, 6]));
      final d = FileChunk.decode(c.encode());
      expect(d.seq, 42);
      expect(d.data, c.data);
      expect(d.transferId, c.transferId);
    });

    test('ack round-trips', () {
      final a = FileAck(Uint8List.fromList(List.generate(16, (i) => i)), false,
          [1, 5, 900000]);
      final d = FileAck.decode(a.encode());
      expect(d.complete, isFalse);
      expect(d.missing, [1, 5, 900000]);
    });
  });

  group('End-to-end file transfer (in-memory)', () {
    test('perfect channel: send all, assemble matches', () {
      final data = randomBytes(50000, 1);
      final sender = FileSender.forFile(
          bytes: data, name: 'a.bin', mime: 'application/octet-stream',
          chunkSize: 4096);
      final receiver = FileReceiver(sender.meta);

      for (final c in sender.allChunks()) {
        receiver.offer(c);
      }
      expect(receiver.isComplete, isTrue);
      expect(receiver.assemble(), data);
    });

    test('lossy channel: drop some chunks then retransmit via ACK', () {
      final data = randomBytes(30000, 7);
      final sender = FileSender.forFile(
          bytes: data, name: 'b.bin', mime: 'x', chunkSize: 1000);
      final receiver = FileReceiver(sender.meta);

      // First pass: drop every 3rd chunk.
      var i = 0;
      for (final c in sender.allChunks()) {
        if (i % 3 != 0) receiver.offer(c);
        i++;
      }
      expect(receiver.isComplete, isFalse);

      // Receiver ACKs missing; sender retransmits.
      var ack = receiver.buildAck();
      expect(ack.complete, isFalse);
      expect(ack.missing, isNotEmpty);

      for (final c in sender.chunksToResend(ack)) {
        receiver.offer(c);
      }

      expect(receiver.isComplete, isTrue);
      ack = receiver.buildAck();
      expect(ack.complete, isTrue);
      expect(receiver.assemble(), data);
    });

    test('duplicate chunks are ignored', () {
      final data = randomBytes(5000, 3);
      final sender =
          FileSender.forFile(bytes: data, name: 'c', mime: 'x', chunkSize: 1000);
      final receiver = FileReceiver(sender.meta);

      final first = sender.chunk(0);
      expect(receiver.offer(first), isTrue);
      expect(receiver.offer(first), isFalse); // duplicate
      expect(receiver.receivedCount, 1);
    });

    test('assemble throws on hash mismatch', () {
      final data = randomBytes(4000, 9);
      final sender =
          FileSender.forFile(bytes: data, name: 'd', mime: 'x', chunkSize: 1000);
      // Build a receiver with tampered meta hash.
      final badMeta = FileMeta(
        transferId: sender.meta.transferId,
        fileSize: sender.meta.fileSize,
        chunkSize: sender.meta.chunkSize,
        totalChunks: sender.meta.totalChunks,
        sha256: Uint8List(32), // wrong
        name: sender.meta.name,
        mime: sender.meta.mime,
      );
      final receiver = FileReceiver(badMeta);
      for (final c in sender.allChunks()) {
        receiver.offer(c);
      }
      expect(receiver.isComplete, isTrue);
      expect(() => receiver.assemble(), throwsStateError);
    });

    test('single byte file (one chunk)', () {
      final data = Uint8List.fromList([42]);
      final sender =
          FileSender.forFile(bytes: data, name: 'e', mime: 'x', chunkSize: 4096);
      expect(sender.meta.totalChunks, 1);
      final receiver = FileReceiver(sender.meta);
      receiver.offer(sender.chunk(0));
      expect(receiver.assemble(), data);
    });
  });
}
