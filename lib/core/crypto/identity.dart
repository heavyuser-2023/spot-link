import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as classic;

import '../model/peer_id.dart';

/// A node's cryptographic identity.
///
/// Composed of two key pairs:
///  * Ed25519 for signing (authenticity of ANNOUNCE and future signed data)
///  * X25519 for key agreement (deriving E2E session keys)
///
/// The [PeerId] is derived deterministically from the public bundle, so a
/// node's identity *is* its keys — there is no account server.
class Identity {
  final SimpleKeyPair signingKeyPair; // Ed25519
  final SimpleKeyPair kexKeyPair; // X25519

  final Uint8List signingPublic; // 32 bytes
  final Uint8List kexPublic; // 32 bytes

  final PeerId peerId;

  Identity._({
    required this.signingKeyPair,
    required this.kexKeyPair,
    required this.signingPublic,
    required this.kexPublic,
    required this.peerId,
  });

  static final _ed = Ed25519();
  static final _x = X25519();

  /// The 64-byte public bundle: signingPublic(32) || kexPublic(32).
  /// This is what is shared (e.g. via QR) so peers can address & encrypt to us.
  Uint8List get publicBundle {
    final out = Uint8List(64);
    out.setRange(0, 32, signingPublic);
    out.setRange(32, 64, kexPublic);
    return out;
  }

  /// Derive the PeerId from a public bundle: SHA-256(bundle)[0:8].
  static PeerId peerIdFromBundle(Uint8List bundle) {
    final digest = classic.sha256.convert(bundle).bytes;
    return PeerId(Uint8List.fromList(digest));
  }

  /// Generate a brand new identity.
  static Future<Identity> generate() async {
    final signing = await _ed.newKeyPair();
    final kex = await _x.newKeyPair();
    return _fromKeyPairs(signing, kex);
  }

  static Future<Identity> _fromKeyPairs(
      SimpleKeyPair signing, SimpleKeyPair kex) async {
    final signPub = await signing.extractPublicKey();
    final kexPub = await kex.extractPublicKey();
    final signPubBytes = Uint8List.fromList(signPub.bytes);
    final kexPubBytes = Uint8List.fromList(kexPub.bytes);
    final bundle = Uint8List(64)
      ..setRange(0, 32, signPubBytes)
      ..setRange(32, 64, kexPubBytes);
    return Identity._(
      signingKeyPair: signing,
      kexKeyPair: kex,
      signingPublic: signPubBytes,
      kexPublic: kexPubBytes,
      peerId: peerIdFromBundle(bundle),
    );
  }

  /// Serialize the private seeds so the identity can be persisted in secure
  /// storage. Format: base64(signingSeed(32) || kexSeed(32)).
  Future<String> exportPrivate() async {
    final signSeed = await signingKeyPair.extractPrivateKeyBytes();
    final kexSeed = await kexKeyPair.extractPrivateKeyBytes();
    final out = Uint8List(signSeed.length + kexSeed.length)
      ..setRange(0, signSeed.length, signSeed)
      ..setRange(signSeed.length, signSeed.length + kexSeed.length, kexSeed);
    return base64.encode(out);
  }

  /// Restore an identity previously produced by [exportPrivate].
  static Future<Identity> importPrivate(String encoded) async {
    final raw = base64.decode(encoded);
    final signSeed = raw.sublist(0, 32);
    final kexSeed = raw.sublist(32, 64);
    final signing = await _ed.newKeyPairFromSeed(signSeed);
    final kex = await _x.newKeyPairFromSeed(kexSeed);
    return _fromKeyPairs(signing, kex);
  }

  /// Sign a message with the Ed25519 signing key.
  Future<Uint8List> sign(List<int> message) async {
    final sig = await _ed.sign(message, keyPair: signingKeyPair);
    return Uint8List.fromList(sig.bytes);
  }

  /// Verify a signature made by [signingPublicKey] over [message].
  static Future<bool> verify(
      List<int> message, Uint8List signature, Uint8List signingPublicKey) {
    return _ed.verify(
      message,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(signingPublicKey, type: KeyPairType.ed25519),
      ),
    );
  }

  @override
  String toString() => 'Identity(${peerId.short})';
}

/// A contact: a known remote identity we can address and encrypt to.
class ContactIdentity {
  final PeerId peerId;
  final Uint8List signingPublic;
  final Uint8List kexPublic;
  final String? displayName;

  /// True once the user has confirmed this key out-of-band (e.g. scanned QR).
  final bool verified;

  ContactIdentity({
    required this.peerId,
    required this.signingPublic,
    required this.kexPublic,
    this.displayName,
    this.verified = false,
  });

  factory ContactIdentity.fromBundle(Uint8List bundle,
      {String? displayName, bool verified = false}) {
    if (bundle.length != 64) {
      throw const FormatException('public bundle must be 64 bytes');
    }
    return ContactIdentity(
      peerId: Identity.peerIdFromBundle(bundle),
      signingPublic: Uint8List.fromList(bundle.sublist(0, 32)),
      kexPublic: Uint8List.fromList(bundle.sublist(32, 64)),
      displayName: displayName,
      verified: verified,
    );
  }

  Uint8List get publicBundle => Uint8List(64)
    ..setRange(0, 32, signingPublic)
    ..setRange(32, 64, kexPublic);

  ContactIdentity copyWith({String? displayName, bool? verified}) =>
      ContactIdentity(
        peerId: peerId,
        signingPublic: signingPublic,
        kexPublic: kexPublic,
        displayName: displayName ?? this.displayName,
        verified: verified ?? this.verified,
      );
}
