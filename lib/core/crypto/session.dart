import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'identity.dart';

/// 이 노드와 원격 피어 사이의 종단 간(end-to-end) 페이로드 암호화.
///
/// 우리 kex 키 쌍과 피어의 kex 공개 키 사이의 X25519 ECDH로 공유 비밀을
/// 수립한 뒤, HKDF-SHA256로 늘려 256비트 AES-GCM 키로 만든다. 릴레이 노드는
/// 암호문을 내용 모르게 실어 나른다 — 오직 양 끝점만 키를 가진다.
///
/// 암호화된 페이로드의 와이어 레이아웃: nonce(12) || cipherText || mac(16).
class SessionCrypto {
  final Identity _self;

  static final _x = X25519();
  static final _aead = AesGcm.with256bits();
  static final _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  static const int nonceLength = 12;
  static const int macLength = 16;
  static const _info = 'spotlink-e2e-v1';

  // 원격 kex 공개 키별로 파생된 세션 키를 캐시한다.
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
    // 양쪽 공개 키(정렬됨)에 묶인 salt이므로, 방향과 무관하게 양측이 동일한
    // 키를 파생한다.
    final salt = _combinedSalt(_self.kexPublic, remoteKexPublic);
    final derived = await _hkdf.deriveKey(
      secretKey: shared,
      nonce: salt,
      info: _info.codeUnits,
    );
    _keyCache[cacheKey] = derived;
    return derived;
  }

  /// [remoteKexPublic]로 식별되는 피어를 위해 [plaintext]를 암호화한다.
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

  /// 피어가 우리에게 보내려고 [encrypt]로 생성한 페이로드를 복호화한다.
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
    // 양 끝점이 합의하도록 순서에 무관한 salt.
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
