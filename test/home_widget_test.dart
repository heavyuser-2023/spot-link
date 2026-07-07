import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:spot_link/app/mesh_controller.dart';
import 'package:spot_link/core/crypto/identity.dart';
import 'package:spot_link/core/mesh_node.dart';
import 'package:spot_link/data/app_database.dart';
import 'package:spot_link/data/identity_store.dart';
import 'package:spot_link/features/home_screen.dart';

import 'fake_transport.dart';

void main() {
  late Directory tmp;
  var counter = 0;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await initializeDateFormatting('ko', null);
    tmp = Directory.systemTemp.createTempSync('spotlink_widget');
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<MeshController> buildController() async {
    final id = await Identity.generate();
    final radio = FakeRadio();
    final node = MeshNode(
        identity: id, displayName: '나', transport: radio.create(id.peerId));
    final controller = MeshController(
      identity: id,
      displayName: '나',
      db: AppDatabase(overridePath: p.join(tmp.path, 'w${counter++}.db')),
      identityStore: IdentityStore(),
      node: node,
    );
    await controller.init();
    return controller;
  }

  testWidgets('HomeScreen renders tabs and empty states', (tester) async {
    // DB + BLE node startup touch real async (isolate/IO); run them on the real
    // event loop, not inside the widget test's FakeAsync zone.
    late MeshController controller;
    await tester.runAsync(() async {
      controller = await buildController();
    });

    await tester.pumpWidget(MaterialApp(
      home: ChangeNotifierProvider<MeshFrontend>.value(
        value: controller,
        child: const HomeScreen(),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));

    // Bottom nav labels present.
    expect(find.text('채팅'), findsWidgets);
    expect(find.text('친구'), findsWidgets);
    expect(find.text('내 정보'), findsWidgets);

    // Chats tab empty state.
    expect(find.text('아직 대화가 없어요'), findsOneWidget);

    // People tab.
    await tester.tap(find.text('친구').last);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('아직 아무도 없어요'), findsOneWidget);
    expect(find.text('QR로 추가'), findsOneWidget);

    // Me tab.
    await tester.tap(find.text('내 정보').last);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('나'), findsWidgets); // our display name at the top

    // Battery-saver toggle lives below the QR in a scrollable list.
    await tester.scrollUntilVisible(
      find.text('배터리 절약'),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    expect(find.text('배터리 절약'), findsOneWidget);

    // Tear down all timers/subscriptions on the real event loop so no pending
    // timer trips the test framework.
    await tester.runAsync(() async {
      controller.dispose(); // cancels presence timer + disposes node (async)
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump();
  });

  testWidgets('pushed ChatScreen still finds the MeshController provider',
      (tester) async {
    late MeshController controller;
    await tester.runAsync(() async {
      controller = await buildController();
      final bob = await Identity.generate();
      await controller.addContactFromBundle(bob.publicBundle, name: 'Bob');
    });

    // Mirror the real app: the provider sits BELOW MaterialApp (in Bootstrap),
    // while pushed routes mount on the root navigator above it.
    await tester.pumpWidget(MaterialApp(
      home: ChangeNotifierProvider<MeshFrontend>.value(
        value: controller,
        child: const HomeScreen(),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('친구').last);
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Bob'), findsOneWidget);

    // Before the fix this died with "Provider<MeshController> not found"
    // and rendered a blank page in release mode.
    await tester.tap(find.text('Bob'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // route transition
    expect(tester.takeException(), isNull);
    expect(find.text('메시지'), findsOneWidget); // compose field is there

    // Let ChatScreen's openConversation (db IO on the real event loop) finish
    // before disposing, or it calls notifyListeners on a disposed controller.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump();

    await tester.runAsync(() async {
      controller.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump();
  });
}
