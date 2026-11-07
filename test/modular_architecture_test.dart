import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show WidgetsBindingObserver;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:spot_link/app/mesh_controller.dart' as ctrl_entry;
import 'package:spot_link/app/mesh_frontend.dart' as frontend_entry;
import 'package:spot_link/core/ble/mesh_transport.dart' as transport_entry;
import 'package:spot_link/core/ble/mesh_transport_models.dart'
    as transport_models;
import 'package:spot_link/core/crypto/identity.dart';
import 'package:spot_link/core/mesh_node.dart' as node_entry;
import 'package:spot_link/core/model/peer_id.dart';
import 'package:spot_link/core/node_events.dart' as node_events;
import 'package:spot_link/core/transfer/file_transfer.dart';
import 'package:spot_link/data/app_database.dart';
import 'package:spot_link/data/identity_store.dart';
import 'package:spot_link/features/chat_screen.dart';
import 'package:spot_link/features/people_tab.dart';

import 'fake_transport.dart';

class _TestPathProvider extends PathProviderPlatform {
  final String root;
  _TestPathProvider(this.root);
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tmp = Directory.systemTemp.createTempSync('spotlink_mod_arch');
    PathProviderPlatform.instance = _TestPathProvider(tmp.path);
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('re-exported types across modularized files are identical', () {
    // mesh_node.dart <-> node_events.dart
    expect(identical(node_entry.NodeEvent, node_events.NodeEvent), isTrue);
    expect(identical(node_entry.PeerAnnounced, node_events.PeerAnnounced),
        isTrue);
    expect(identical(node_entry.VerifyReceived, node_events.VerifyReceived),
        isTrue);
    expect(
        identical(node_entry.ReactionReceived, node_events.ReactionReceived),
        isTrue);
    expect(
        identical(node_entry.TextReceived, node_events.TextReceived), isTrue);
    expect(
        identical(
            node_entry.DeliveryConfirmed, node_events.DeliveryConfirmed),
        isTrue);
    expect(
        identical(
            node_entry.TextDeliveryFailed, node_events.TextDeliveryFailed),
        isTrue);
    expect(identical(node_entry.FileOffered, node_events.FileOffered), isTrue);
    expect(
        identical(node_entry.FileProgress, node_events.FileProgress), isTrue);
    expect(
        identical(node_entry.TransferLane, node_events.TransferLane), isTrue);
    expect(
        identical(node_entry.FileReceived, node_events.FileReceived), isTrue);
    expect(identical(node_entry.FileFailed, node_events.FileFailed), isTrue);
    expect(
        identical(node_entry.FileDeferred, node_events.FileDeferred), isTrue);
    expect(identical(node_entry.FileSuperseded, node_events.FileSuperseded),
        isTrue);
    expect(
        identical(node_entry.LinksChanged, node_events.LinksChanged), isTrue);
    expect(identical(node_entry.NodeError, node_events.NodeError), isTrue);

    // mesh_transport.dart <-> mesh_transport_models.dart
    expect(identical(transport_entry.LinkRole, transport_models.LinkRole),
        isTrue);
    expect(identical(transport_entry.MeshLink, transport_models.MeshLink),
        isTrue);
    expect(
        identical(
            transport_entry.InboundPacket, transport_models.InboundPacket),
        isTrue);
    expect(identical(transport_entry.LinkEvent, transport_models.LinkEvent),
        isTrue);
    expect(identical(transport_entry.RssiSample, transport_models.RssiSample),
        isTrue);
    expect(
        identical(transport_entry.RadioStatus, transport_models.RadioStatus),
        isTrue);
    expect(
        identical(transport_entry.MeshTransportInterface,
            transport_models.MeshTransportInterface),
        isTrue);
    expect(identical(transport_entry.PowerMode, transport_models.PowerMode),
        isTrue);

    // mesh_controller.dart <-> mesh_frontend.dart
    expect(
        identical(ctrl_entry.MeshFrontend, frontend_entry.MeshFrontend), isTrue);
    expect(
        identical(ctrl_entry.ConversationSummary,
            frontend_entry.ConversationSummary),
        isTrue);

    // feature widgets remain accessible from their canonical imports
    expect(ChatScreen, isNotNull);
    expect(PeopleTab, isNotNull);
  });

  test('NodeEvent sealed hierarchy supports exhaustive pattern matching', () {
    final peer = PeerId(Uint8List(8));
    final contact = ContactIdentity(
      peerId: peer,
      signingPublic: Uint8List(32),
      kexPublic: Uint8List(32),
    );
    final meta = FileMeta(
      transferId: Uint8List(8),
      name: 'a.txt',
      mime: 'text/plain',
      fileSize: 1,
      chunkSize: 1,
      totalChunks: 1,
      sha256: Uint8List(32),
    );

    final events = <node_entry.NodeEvent>[
      node_entry.PeerAnnounced(contact),
      node_entry.VerifyReceived(peer, Uint8List(16)),
      node_entry.ReactionReceived(peer, '00', '👍', false),
      node_entry.TextReceived(peer, 'hi', '01'),
      node_entry.DeliveryConfirmed('01'),
      node_entry.TextDeliveryFailed('01'),
      node_entry.FileOffered(peer, meta),
      node_entry.FileProgress('02', 0.5, true),
      node_entry.TransferLane('02', 'wifi'),
      node_entry.FileReceived(peer, meta, '/tmp/a'),
      node_entry.FileFailed('02', 'a.txt', incoming: true),
      node_entry.FileDeferred('02', peer, 'a.txt', 2),
      node_entry.FileSuperseded('02'),
      node_entry.LinksChanged(1),
      node_entry.NodeError('err'),
    ];

    for (final e in events) {
      final tag = switch (e) {
        node_entry.PeerAnnounced() => 'announced',
        node_entry.VerifyReceived() => 'verify',
        node_entry.ReactionReceived() => 'reaction',
        node_entry.TextReceived() => 'text',
        node_entry.DeliveryConfirmed() => 'delivered',
        node_entry.TextDeliveryFailed() => 'text_failed',
        node_entry.FileOffered() => 'offered',
        node_entry.FileProgress() => 'progress',
        node_entry.TransferLane() => 'lane',
        node_entry.FileReceived() => 'received',
        node_entry.FileFailed() => 'failed',
        node_entry.FileDeferred() => 'deferred',
        node_entry.FileSuperseded() => 'superseded',
        node_entry.LinksChanged() => 'links',
        node_entry.NodeError() => 'error',
      };
      expect(tag, isNotEmpty);
    }
  });

  test(
      'MeshController mixin composition preserves MeshFrontend polymorphism and remote snapshot contract',
      () async {
    final id = await Identity.generate();
    final peer = await Identity.generate();
    final radio = FakeRadio();
    final node = node_entry.MeshNode(
      identity: id,
      displayName: 'Alice',
      transport: radio.create(id.peerId),
    );
    final controller = ctrl_entry.MeshController(
      identity: id,
      displayName: 'Alice',
      db: AppDatabase(overridePath: p.join(tmp.path, 'mod_test.db')),
      identityStore: IdentityStore(),
      node: node,
    );
    await controller.init();

    // Verify polymorphic assignment to MeshFrontend and WidgetsBindingObserver.
    final ctrl_entry.MeshFrontend frontend = controller;
    final WidgetsBindingObserver observer = controller;
    expect(frontend.myId, equals(id.peerId));
    expect(observer, isNotNull);

    // Contact operations via MeshFrontend interface
    final added =
        await frontend.addContactFromBundle(peer.publicBundle, name: 'Bob');
    expect(added.displayName, 'Bob');
    await frontend.renameContact(peer.peerId.hex, 'Bobby');
    expect(frontend.contactByHex(peer.peerId.hex)?.displayName, 'Bobby');

    // QR payload round-trip through MeshController.parseQr
    final qr = frontend.myQrPayload;
    final parsed = ctrl_entry.MeshController.parseQr(qr);
    expect(parsed, isNotNull);
    expect(parsed!.$2, 'Alice');
    expect(parsed.$3, isNotNull);

    // Remote snapshot keys contract used by headless bridge
    final snap = controller.snapshotForRemote();
    expect(
      snap.keys,
      containsAll(<String>[
        'started',
        'links',
        'peers',
        'err',
        'radio',
        'saver',
        'relayN',
        'relayB',
        'name',
        'rev',
        'encRev',
        'contacts',
        'meAvatar',
        'meAvCustom',
        'seen',
        'hops',
        'via',
        'lanes',
        'rssi',
        'unread',
        'last',
        'prog',
      ]),
    );

    await frontend.deleteContact(peer.peerId.hex);
    expect(frontend.contactByHex(peer.peerId.hex), isNull);

    await controller.node.dispose();
    controller.dispose();
  });
}
