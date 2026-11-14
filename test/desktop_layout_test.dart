// On a wide Windows window the menu is a permanent side menu: picking an
// entry shows that screen next to it, and Home's slide-out menu is gone.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:personal_finance/main.dart';

void main() {
  testWidgets('side menu on a wide Windows window', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    SharedPreferences.setMockInitialValues({});
    currentLanguage.value = AppLanguage.en;
    tester.view.physicalSize = const Size(1400, 1700); // the whole side menu on screen
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(MaterialApp(
      navigatorKey: rootNavigatorKey,
      builder: (context, child) => DesktopFrame(child: child!),
      home: Builder(builder: (context) => Scaffold(appBar: AppBar(title: const Text('home')), drawer: AppDrawer.of(context, 0))),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(DesktopSideMenu), findsOneWidget);
    expect(find.byTooltip('Open navigation menu'), findsNothing); // no hamburger
    // The page keeps a readable width next to the menu.
    expect(tester.getSize(find.byType(Scaffold).first).width, lessThanOrEqualTo(1100));

    await tester.tap(find.text(tr('settings')));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(desktopMenuIndex.value, 3);
    // Esc / back returns to Home, which is current in the menu again.
    rootNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('narrow window keeps the slide-out menu', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(700, 900);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => DesktopFrame(child: child!),
      home: Builder(builder: (context) => Scaffold(appBar: AppBar(), drawer: AppDrawer.of(context, 0))),
    ));
    expect(find.byType(DesktopSideMenu), findsNothing);
    expect(find.byType(DrawerButton), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
