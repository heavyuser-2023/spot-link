import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as classic;

import '../model/peer_id.dart';

/// 노드의 암호학적 신원.
///
/// 두 개의 키 쌍으로 구성된다:
///  * 서명용 Ed25519 (ANNOUNCE 및 향후 서명 데이터의 진위 보장)
///  * 키 합의용 X25519 (E2E 세션 키 파생)
///
/// [PeerId]는 공개 번들로부터 결정론적으로 파생되므로, 노드의 신원은 곧 그
/// 노드의 키 그 자체이다 — 계정 서버가 없다.
class Identity {
  final SimpleKeyPair signingKeyPair; // Ed25519
  final SimpleKeyPair kexKeyPair; // X25519

  final Uint8List signingPublic; // 32바이트
  final Uint8List kexPublic; // 32바이트

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

  /// 64바이트 공개 번들: signingPublic(32) || kexPublic(32).
  /// 피어가 우리를 지정하고 우리에게 암호화할 수 있도록 (예: QR로) 공유되는 값.
  Uint8List get publicBundle {
    final out = Uint8List(64);
    out.setRange(0, 32, signingPublic);
    out.setRange(32, 64, kexPublic);
    return out;
  }

  /// 공개 번들로부터 PeerId를 파생: SHA-256(bundle)[0:8].
  static PeerId peerIdFromBundle(Uint8List bundle) {
    final digest = classic.sha256.convert(bundle).bytes;
    return PeerId(Uint8List.fromList(digest));
  }

  /// 완전히 새로운 신원을 생성한다.
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

  /// 신원을 보안 저장소에 영속할 수 있도록 비공개 시드를 직렬화한다.
  /// 형식: base64(signingSeed(32) || kexSeed(32)).
  Future<String> exportPrivate() async {
    final signSeed = await signingKeyPair.extractPrivateKeyBytes();
    final kexSeed = await kexKeyPair.extractPrivateKeyBytes();
    final out = Uint8List(signSeed.length + kexSeed.length)
      ..setRange(0, signSeed.length, signSeed)
      ..setRange(signSeed.length, signSeed.length + kexSeed.length, kexSeed);
    return base64.encode(out);
  }

  /// [exportPrivate]로 이전에 생성한 신원을 복원한다.
  static Future<Identity> importPrivate(String encoded) async {
    final raw = base64.decode(encoded);
    final signSeed = raw.sublist(0, 32);
    final kexSeed = raw.sublist(32, 64);
    final signing = await _ed.newKeyPairFromSeed(signSeed);
    final kex = await _x.newKeyPairFromSeed(kexSeed);
    return _fromKeyPairs(signing, kex);
  }

  /// Ed25519 서명 키로 메시지에 서명한다.
  Future<Uint8List> sign(List<int> message) async {
    final sig = await _ed.sign(message, keyPair: signingKeyPair);
    return Uint8List.fromList(sig.bytes);
  }

  /// [message]에 대해 [signingPublicKey]로 만든 서명을 검증한다.
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

/// 연락처: 우리가 지정하고 암호화할 수 있는, 알려진 원격 신원.
class ContactIdentity {
  final PeerId peerId;
  final Uint8List signingPublic;
  final Uint8List kexPublic;
  final String? displayName;

  /// 사용자가 이 키를 대역 외로(예: QR 스캔) 확인하면 true가 된다.
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
