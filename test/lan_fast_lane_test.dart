import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:spot_link/core/crypto/identity.dart';
import 'package:spot_link/core/mesh_node.dart';
import 'package:spot_link/core/transfer/composite_fast_lane.dart';
import 'package:spot_link/core/transfer/fast_lane.dart';
import 'package:spot_link/core/transfer/lan_socket_fast_lane.dart';

import 'fake_transport.dart';

/// End-to-end over a REAL loopback TCP socket (not a fake): proves the LAN
/// fast lane negotiates over BLE and moves the bytes over an actual socket.
class TestNode {
  final MeshNode node;
  final List<NodeEvent> events = [];
  TestNode(this.node) {
    node.events.listen(events.add);
  }
}

Future<T> waitFor<T extends NodeEvent>(TestNode n, bool Function(T) t,
    {Duration timeout = const Duration(seconds: 8)}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final m = n.events.whereType<T>().where(t);
    if (m.isNotEmpty) return m.last;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  throw StateError('event ${T.toString()} not observed');
}

void main() {
  test('LAN fast lane transfers a large file over a real loopback socket',
      () async {
    // Bind + advertise loopback so both nodes talk over real 127.0.0.1 TCP.
    LanSocketFastLane lan() => LanSocketFastLane(
          bindHost: InternetAddress.loopbackIPv4,
          localAddresses: () async => [InternetAddress.loopbackIPv4],
        );

    final radio = FakeRadio();
    final idA = await Identity.generate();
    final idB = await Identity.generate();
    final a = TestNode(MeshNode(
        identity: idA,
        displayName: 'A',
        transport: radio.create(idA.peerId),
        fastLane: lan()));
    final b = TestNode(MeshNode(
        identity: idB,
        displayName: 'B',
        transport: radio.create(idB.peerId),
        fastLane: lan()));
    await a.node.start();
    await b.node.start();
    a.node.addContact(ContactIdentity.fromBundle(idB.publicBundle));
    b.node.addContact(ContactIdentity.fromBundle(idA.publicBundle));
    radio.connect(idA.peerId, idB.peerId);
    await Future<void>.delayed(const Duration(milliseconds: 60));

    final rnd = Random(123);
    final fileBytes = Uint8List.fromList(
        List.generate(500 * 1024, (_) => rnd.nextInt(256)));

    final tid = await a.node.sendFile(idB.peerId,
        bytes: fileBytes, name: 'photo.jpg', mime: 'image/jpeg');
    expect(tid, isNotNull);

    final got = await waitFor<FileReceived>(b, (e) => true);
    expect(got.meta.name, 'photo.jpg');
    expect(File(got.path).readAsBytesSync(), fileBytes); // exact bytes over real TCP
    expect(got.from, idA.peerId);

    // Sender flips to delivered via the reused BLE completion ACK.
    final done = await waitFor<DeliveryConfirmed>(a, (e) => e.msgId == tid);
    expect(done.msgId, tid);

    await a.node.dispose();
    await b.node.dispose();
  });

  test('fast lane streams multi-segment files without whole-file RAM',
      () async {
    // 세그먼트 크기를 줄여 500KB 파일이 4+개 세그먼트로 쪼개지게 한다 —
    // 매직/길이/종료 마커 파싱과 세그먼트 오프셋 기록을 실 TCP로 검증.
    final savedSeg = MeshNode.fastLaneSegmentBytes;
    MeshNode.fastLaneSegmentBytes = 96 * 1024;
    addTearDown(() => MeshNode.fastLaneSegmentBytes = savedSeg);

    LanSocketFastLane lan() => LanSocketFastLane(
          bindHost: InternetAddress.loopbackIPv4,
          localAddresses: () async => [InternetAddress.loopbackIPv4],
        );
    final radio = FakeRadio();
    final idA = await Identity.generate();
    final idB = await Identity.generate();
    final a = TestNode(MeshNode(
        identity: idA,
        displayName: 'A',
        transport: radio.create(idA.peerId),
        fastLane: lan()));
    final b = TestNode(MeshNode(
        identity: idB,
        displayName: 'B',
        transport: radio.create(idB.peerId),
        fastLane: lan()));
    await a.node.start();
    await b.node.start();
    a.node.addContact(ContactIdentity.fromBundle(idB.publicBundle));
    b.node.addContact(ContactIdentity.fromBundle(idA.publicBundle));
    radio.connect(idA.peerId, idB.peerId);
    await Future<void>.delayed(const Duration(milliseconds: 60));

    final rnd = Random(77);
    final fileBytes = Uint8List.fromList(
        List.generate(500 * 1024 + 123, (_) => rnd.nextInt(256)));
    await a.node.sendFile(idB.peerId,
        bytes: fileBytes, name: 'video.mp4', mime: 'video/mp4');

    final got = await waitFor<FileReceived>(b, (e) => true);
    expect(File(got.path).readAsBytesSync(), fileBytes);
    // 실제로 fast lane(wifi)으로 갔는지 확인 — BLE 폴백이면 회귀다.
    expect(
        b.events.whereType<TransferLane>().any((e) => e.lane == 'wifi'), isTrue);

    await a.node.dispose();
    await b.node.dispose();
  });

  test('legacy single-blob fast lane format still delivers (구버전 호환)',
      () async {
    // 구버전 송신자 시뮬레이션: 수신자가 세그먼트를 지원해도 레거시 형식 사용.
    MeshNode.debugForceLegacyFastLane = true;
    addTearDown(() => MeshNode.debugForceLegacyFastLane = false);

    LanSocketFastLane lan() => LanSocketFastLane(
          bindHost: InternetAddress.loopbackIPv4,
          localAddresses: () async => [InternetAddress.loopbackIPv4],
        );
    final radio = FakeRadio();
    final idA = await Identity.generate();
    final idB = await Identity.generate();
    final a = TestNode(MeshNode(
        identity: idA,
        displayName: 'A',
        transport: radio.create(idA.peerId),
        fastLane: lan()));
    final b = TestNode(MeshNode(
        identity: idB,
        displayName: 'B',
        transport: radio.create(idB.peerId),
        fastLane: lan()));
    await a.node.start();
    await b.node.start();
    a.node.addContact(ContactIdentity.fromBundle(idB.publicBundle));
    b.node.addContact(ContactIdentity.fromBundle(idA.publicBundle));
    radio.connect(idA.peerId, idB.peerId);
    await Future<void>.delayed(const Duration(milliseconds: 60));

    final rnd = Random(9);
    final fileBytes = Uint8List.fromList(
        List.generate(400 * 1024, (_) => rnd.nextInt(256)));
    await a.node.sendFile(idB.peerId,
        bytes: fileBytes, name: 'old.jpg', mime: 'image/jpeg');

    final got = await waitFor<FileReceived>(b, (e) => true);
    expect(File(got.path).readAsBytesSync(), fileBytes);
    expect(
        b.events.whereType<TransferLane>().any((e) => e.lane == 'wifi'), isTrue);

    await a.node.dispose();
    await b.node.dispose();
  });

  test('LAN fast lane with no network address stays on BLE', () async {
    // localAddresses empty ⇒ capabilities empty ⇒ never attempts fast lane.
    final noNet = LanSocketFastLane(localAddresses: () async => []);
    // capabilities is a fixed set, but prepareInbound returns null with no
    // address, so the sender times out and BLE carries it.
    final radio = FakeRadio();
    final idA = await Identity.generate();
    final idB = await Identity.generate();
    final a = TestNode(MeshNode(
        identity: idA,
        displayName: 'A',
        transport: radio.create(idA.peerId),
        fastLane: noNet));
    final b = TestNode(MeshNode(
        identity: idB,
        displayName: 'B',
        transport: radio.create(idB.peerId),
        fastLane: LanSocketFastLane(localAddresses: () async => [])));
    await a.node.start();
    await b.node.start();
    a.node.addContact(ContactIdentity.fromBundle(idB.publicBundle));
    b.node.addContact(ContactIdentity.fromBundle(idA.publicBundle));
    radio.connect(idA.peerId, idB.peerId);
    await Future<void>.delayed(const Duration(milliseconds: 60));

    final rnd = Random(5);
    final fileBytes = Uint8List.fromList(
        List.generate(300 * 1024, (_) => rnd.nextInt(256)));
    await a.node.sendFile(idB.peerId,
        bytes: fileBytes, name: 'x.bin', mime: 'application/octet-stream');

    final got = await waitFor<FileReceived>(b, (e) => true,
        timeout: const Duration(seconds: 30));
    expect(File(got.path).readAsBytesSync(), fileBytes); // delivered over BLE fallback

    await a.node.dispose();
    await b.node.dispose();
  });

  test('pickAdvertisable: 셀룰러·터널 제외, Wi-Fi 우선', () {
    final wifi = InternetAddress('192.168.0.10');
    final cell = InternetAddress('10.123.45.6');
    final vpn = InternetAddress('10.8.0.2');
    final mystery = InternetAddress('172.16.0.9');
    final picked = LanSocketFastLane.pickAdvertisable([
      ('pdp_ip0', [cell]), // iOS 셀룰러 — 제외
      ('utun3', [vpn]), // VPN 터널 — 제외
      ('weird0', [mystery]), // 알 수 없는 인터페이스 — 후순위로 유지
      ('en0', [wifi]), // Wi-Fi — 최우선
    ]);
    expect(picked.first, wifi);
    expect(picked, isNot(contains(cell)));
    expect(picked, isNot(contains(vpn)));
    expect(picked, contains(mystery));

    // 셀룰러뿐이면 빈 목록 → prepareInbound가 null을 돌려 BLE로 남는다.
    expect(
        LanSocketFastLane.pickAdvertisable([
          ('rmnet_data1', [cell])
        ]),
        isEmpty);
  });

  test('tid 프리앰블: 낯선 접속은 거절하고 진짜 송신자를 기다린다', () async {
    final lane = LanSocketFastLane(
      bindHost: InternetAddress.loopbackIPv4,
      localAddresses: () async => [InternetAddress.loopbackIPv4],
    );
    const tidHex = '00112233445566778899aabbccddeeff';
    final tidBytes = Uint8List.fromList([
      0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, //
      0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
    ]);
    final inbound = await lane.prepareInbound(tidHex, FastLaneKind.lanSocket,
        tidPreamble: true);
    expect(inbound, isNotNull);
    final port = (inbound!.offer.blob[4] << 8) | inbound.offer.blob[5];

    // ① 낯선 접속(포트 스캔 흉내): 엉뚱한 16바이트 → 세션이 되면 안 된다.
    final intruder = await Socket.connect(InternetAddress.loopbackIPv4, port);
    intruder.add(Uint8List(16)); // 전부 0 — tid와 불일치
    await intruder.flush();

    // ② 진짜 송신자: 올바른 프리앰블 + 본문 — 세션으로 채택돼야 한다.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final sender = await Socket.connect(InternetAddress.loopbackIPv4, port);
    sender.add(tidBytes);
    sender.add(Uint8List.fromList([1, 2, 3, 4]));
    await sender.flush();

    final session = await inbound.session;
    expect(session, isNotNull, reason: '낯선 접속이 진짜 송신자를 밀어냈다');
    final firstData = await session!.incoming.first
        .timeout(const Duration(seconds: 3));
    expect(firstData, [1, 2, 3, 4]); // 프리앰블은 벗겨지고 본문만 흐른다

    await session.close();
    intruder.destroy();
    sender.destroy();
  });

  test('선호 수단 연결 실패 시 남은 수단으로 재오퍼해 완주한다', () async {
    // 네이티브 P2P(wifiAware) 흉내: 수신 대기는 되지만 송신 연결은 항상
    // 실패한다. 선호도상 lanSocket보다 먼저 선택되므로, 재오퍼 없이는 이
    // 조합이 lanSocket을 영원히 가린다(개선 전 동작 = BLE 폴백).
    LanSocketFastLane lan() => LanSocketFastLane(
          bindHost: InternetAddress.loopbackIPv4,
          localAddresses: () async => [InternetAddress.loopbackIPv4],
        );
    final radio = FakeRadio();
    final idA = await Identity.generate();
    final idB = await Identity.generate();
    final a = TestNode(MeshNode(
        identity: idA,
        displayName: 'A',
        transport: radio.create(idA.peerId),
        fastLane: CompositeFastLane([_BrokenNativeLane(), lan()])));
    final b = TestNode(MeshNode(
        identity: idB,
        displayName: 'B',
        transport: radio.create(idB.peerId),
        fastLane: CompositeFastLane([_BrokenNativeLane(), lan()])));
    await a.node.start();
    await b.node.start();
    a.node.addContact(ContactIdentity.fromBundle(idB.publicBundle));
    b.node.addContact(ContactIdentity.fromBundle(idA.publicBundle));
    radio.connect(idA.peerId, idB.peerId);
    await Future<void>.delayed(const Duration(milliseconds: 60));

    final rnd = Random(42);
    final fileBytes = Uint8List.fromList(
        List.generate(300 * 1024, (_) => rnd.nextInt(256)));
    await a.node.sendFile(idB.peerId,
        bytes: fileBytes, name: 'retry.bin', mime: 'application/octet-stream');

    final got = await waitFor<FileReceived>(b, (e) => true,
        timeout: const Duration(seconds: 15));
    expect(File(got.path).readAsBytesSync(), fileBytes);
    // 2차 오퍼의 lanSocket으로 fast lane 완주 — BLE 폴백이면 회귀다.
    expect(
        b.events.whereType<TransferLane>().any((e) => e.lane == 'wifi'), isTrue);

    await a.node.dispose();
    await b.node.dispose();
  });
}

/// 수신 대기(prepareInbound)는 성공하지만 송신 연결(connect)은 항상 실패하는
/// 네이티브 P2P 레인 — 라디오 혼잡으로 죽는 multipeer/wifiDirect의 축소판.
class _BrokenNativeLane implements FastLaneInterface {
  @override
  Set<FastLaneKind> get capabilities => {FastLaneKind.wifiAware};

  @override
  Set<FastLaneKind> get inboundCapabilities => {FastLaneKind.wifiAware};

  @override
  Future<FastLaneInbound?> prepareInbound(
      String transferIdHex, FastLaneKind kind,
      {bool tidPreamble = false}) async {
    if (kind != FastLaneKind.wifiAware) return null;
    // 송신자가 끝내 연결하지 않는 리스너: future는 영영 완료되지 않는다
    // (재협상이 이 유령을 대체하는 경로를 검증한다).
    return FastLaneInbound(
        FastLaneOffer(FastLaneKind.wifiAware, Uint8List.fromList([1])),
        Completer<FastLaneSession?>().future);
  }

  @override
  Future<FastLaneSession?> connect(
          String transferIdHex, FastLaneOffer offer) async =>
      null;
}
