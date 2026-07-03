import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:spot_link/app/mesh_controller.dart';
import 'package:spot_link/core/crypto/identity.dart';
import 'package:spot_link/core/model/peer_id.dart';

void main() {
  group('QR payload codec', () {
    test('parses a well-formed SpotLink QR payload', () async {
      final id = await Identity.generate();
      // Reproduce the exact encoding MeshController.myQrPayload uses.
      final payload =
          'SPOTLINK1:${b64(id.publicBundle)}:${b64(utf8.encode("김정훈"))}';

      final parsed = MeshController.parseQr(payload);
      expect(parsed, isNotNull);
      final (bundle, name) = parsed!;
      expect(bundle.length, 64);
      expect(bundle, id.publicBundle);
      expect(name, '김정훈');
      // The recovered bundle yields the same PeerId.
      expect(Identity.peerIdFromBundle(bundle), id.peerId);
    });

    test('rejects foreign / malformed payloads', () {
      expect(MeshController.parseQr('https://example.com'), isNull);
      expect(MeshController.parseQr('SPOTLINK1:not-base64!!'), isNull);
      expect(MeshController.parseQr('SPOTLINK1:${b64([1, 2, 3])}'), isNull);
    });

    test('parses payload without a name', () async {
      final id = await Identity.generate();
      final payload = 'SPOTLINK1:${b64(id.publicBundle)}';
      final parsed = MeshController.parseQr(payload);
      expect(parsed, isNotNull);
      expect(parsed!.$1, id.publicBundle);
      expect(parsed.$2, '');
    });
  });
}
