import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spot_link/features/onboarding_screen.dart';

void main() {
  testWidgets('onboarding submits the entered name', (tester) async {
    String? submitted;
    await tester.pumpWidget(MaterialApp(
      home: OnboardingScreen(onSubmit: (name) async {
        submitted = name;
      }),
    ));

    expect(find.text('SpotLink에 오신 걸 환영합니다'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '김정훈');
    await tester.tap(find.text('시작하기'));
    await tester.pump();

    expect(submitted, '김정훈');
  });

  testWidgets('onboarding ignores empty name', (tester) async {
    var called = false;
    await tester.pumpWidget(MaterialApp(
      home: OnboardingScreen(onSubmit: (name) async {
        called = true;
      }),
    ));

    await tester.tap(find.text('시작하기'));
    await tester.pump();

    expect(called, isFalse);
  });
}
