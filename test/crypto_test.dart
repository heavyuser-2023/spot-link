import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:spot_link/core/crypto/identity.dart';
import 'package:spot_link/core/crypto/session.dart';

void main() {
  group('Identity', () {
    test('generate produces stable peerId from bundle', () async {
      final id = await Identity.generate();
      expect(id.publicBundle.length, 64);
      expect(Identity.peerIdFromBundle(id.publicBundle), id.peerId);
    });

    test('export/import round-trips keys and peerId', () async {
      final id = await Identity.generate();
      final exported = await id.exportPrivate();
      final restored = await Identity.importPrivate(exported);
      expect(restored.peerId, id.peerId);
      expect(restored.signingPublic, id.signingPublic);
      expect(restored.kexPublic, id.kexPublic);
    });

    test('sign and verify', () async {
      final id = await Identity.generate();
      final msg = Uint8List.fromList([1, 2, 3, 4, 5]);
      final sig = await id.sign(msg);
      expect(await Identity.verify(msg, sig, id.signingPublic), isTrue);

      final tampered = Uint8List.fromList([1, 2, 3, 4, 6]);
      expect(await Identity.verify(tampered, sig, id.signingPublic), isFalse);
    });

    test('ContactIdentity from bundle recovers peerId', () async {
      final id = await Identity.generate();
      final contact = ContactIdentity.fromBundle(id.publicBundle);
      expect(contact.peerId, id.peerId);
      expect(contact.kexPublic, id.kexPublic);
    });
  });

  group('SessionCrypto E2E', () {
    test('two parties derive the same key and can talk', () async {
      final alice = await Identity.generate();
      final bob = await Identity.generate();

      final aCrypto = SessionCrypto(alice);
      final bCrypto = SessionCrypto(bob);

      final message =
          Uint8List.fromList(List.generate(500, (i) => (i * 3) % 256));

      final cipher = await aCrypto.encrypt(message, bob.kexPublic);
      // Ciphertext must not equal plaintext.
      expect(cipher, isNot(equals(message)));

      final recovered = await bCrypto.decrypt(cipher, alice.kexPublic);
      expect(recovered, message);
    });

    test('round trip both directions', () async {
      final alice = await Identity.generate();
      final bob = await Identity.generate();
      final aCrypto = SessionCrypto(alice);
      final bCrypto = SessionCrypto(bob);

      final m1 = Uint8List.fromList([10, 20, 30]);
      final c1 = await aCrypto.encrypt(m1, bob.kexPublic);
      expect(await bCrypto.decrypt(c1, alice.kexPublic), m1);

      final m2 = Uint8List.fromList([40, 50, 60, 70]);
      final c2 = await bCrypto.encrypt(m2, alice.kexPublic);
      expect(await aCrypto.decrypt(c2, bob.kexPublic), m2);
    });

    test('a third party cannot decrypt', () async {
      final alice = await Identity.generate();
      final bob = await Identity.generate();
      final eve = await Identity.generate();

      final aCrypto = SessionCrypto(alice);
      final eCrypto = SessionCrypto(eve);

      final cipher =
          await aCrypto.encrypt(Uint8List.fromList([1, 2, 3]), bob.kexPublic);

      // Eve tries to decrypt a message meant for Bob.
      expect(
        () => eCrypto.decrypt(cipher, alice.kexPublic),
        throwsA(anything),
      );
    });

    test('nonce randomised: same plaintext yields different ciphertext',
        () async {
      final alice = await Identity.generate();
      final bob = await Identity.generate();
      final aCrypto = SessionCrypto(alice);
      final msg = Uint8List.fromList([9, 9, 9, 9]);
      final c1 = await aCrypto.encrypt(msg, bob.kexPublic);
      final c2 = await aCrypto.encrypt(msg, bob.kexPublic);
      expect(c1, isNot(equals(c2)));
    });
  });
}
