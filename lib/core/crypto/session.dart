import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'identity.dart';

/// End-to-end payload encryption between this node and a remote peer.
///
/// A shared secret is established with X25519 ECDH between our kex key pair and
/// the peer's kex public key, then stretched with HKDF-SHA256 into a 256-bit
/// AES-GCM key. Relay nodes carry the ciphertext blindly — only the endpoints
/// hold the key.
///
/// Wire layout of an encrypted payload: nonce(12) || cipherText || mac(16).
class SessionCrypto {
  final Identity _self;

  static final _x = X25519();
  static final _aead = AesGcm.with256bits();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  static const int nonceLength = 12;
  static const int macLength = 16;
  static const _info = 'spotlink-e2e-v1';

  // Cache derived session keys per remote kex public key.
  final Map<String, SecretKey> _keyCache = {};

  SessionCrypto(this._self);

  Future<SecretKey> _sessionKey(Uint8List remoteKexPublic) async {
    final cacheKey = _hex(remoteKexPublic);
    final cached = _keyCache[cacheKey];
    if (cached != null) return cached;

    final shared = await _x.sharedSecretKey(
      keyPair: _self.kexKeyPair,
      remotePublicKey:
          SimplePublicKey(remoteKexPublic, type: KeyPairType.x25519),
    );
    // Salt bound to both public keys (sorted) so both sides derive the same
    // key regardless of direction.
    final salt = _combinedSalt(_self.kexPublic, remoteKexPublic);
    final derived = await _hkdf.deriveKey(
      secretKey: shared,
      nonce: salt,
      info: _info.codeUnits,
    );
    _keyCache[cacheKey] = derived;
    return derived;
  }

  /// Encrypt [plaintext] for the peer identified by [remoteKexPublic].
  Future<Uint8List> encrypt(
      Uint8List plaintext, Uint8List remoteKexPublic) async {
    final key = await _sessionKey(remoteKexPublic);
    final nonce = _aead.newNonce();
    final box = await _aead.encrypt(plaintext, secretKey: key, nonce: nonce);
    final out = Uint8List(nonce.length + box.cipherText.length + box.mac.bytes.length);
    out.setRange(0, nonce.length, nonce);
    out.setRange(nonce.length, nonce.length + box.cipherText.length, box.cipherText);
    out.setRange(nonce.length + box.cipherText.length, out.length, box.mac.bytes);
    return out;
  }

  /// Decrypt a payload produced by a peer's [encrypt] to us.
  Future<Uint8List> decrypt(
      Uint8List data, Uint8List remoteKexPublic) async {
    if (data.length < nonceLength + macLength) {
      throw const FormatException('ciphertext too short');
    }
    final key = await _sessionKey(remoteKexPublic);
    final nonce = data.sublist(0, nonceLength);
    final cipherText = data.sublist(nonceLength, data.length - macLength);
    final mac = data.sublist(data.length - macLength);
    final box = SecretBox(cipherText, nonce: nonce, mac: Mac(mac));
    final clear = await _aead.decrypt(box, secretKey: key);
    return Uint8List.fromList(clear);
  }

  void forget(Uint8List remoteKexPublic) =>
      _keyCache.remove(_hex(remoteKexPublic));

  static Uint8List _combinedSalt(Uint8List a, Uint8List b) {
    // Order-independent salt so both endpoints agree.
    final first = _compare(a, b) <= 0 ? a : b;
    final second = identical(first, a) ? b : a;
    return Uint8List(first.length + second.length)
      ..setRange(0, first.length, first)
      ..setRange(first.length, first.length + second.length, second);
  }

  static int _compare(Uint8List a, Uint8List b) {
    final n = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < n; i++) {
      final d = a[i] - b[i];
      if (d != 0) return d;
    }
    return a.length - b.length;
  }

  static String _hex(Uint8List b) {
    final sb = StringBuffer();
    for (final x in b) {
      sb.write(x.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}
