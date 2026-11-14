// Going back from a screen opened from the menu returns to the open menu.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:personal_finance/main.dart';

void main() {
  testWidgets('back from a menu screen shows the menu again', (tester) async {
    SharedPreferences.setMockInitialValues({});
    currentLanguage.value = AppLanguage.en;
    tester.view.physicalSize = const Size(600, 2400); // the whole menu on screen
    tester.view.devicePixelRatio = 1;
    final key = GlobalKey<ScaffoldState>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(key: key, drawer: const AppDrawer(currentIndex: 0), body: const SizedBox()),
    ));
    key.currentState!.openDrawer();
    await tester.pumpAndSettle();
    await tester.tap(find.text(tr('settings')));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    await tester.binding.handlePopRoute(); // the phone's back button
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsNothing);
    expect(key.currentState!.isDrawerOpen, isTrue);
  });
}
