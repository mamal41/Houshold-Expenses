// The About screen lists the features and renders in every language.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/main.dart';

void main() {
  for (final lang in AppLanguage.values) {
    testWidgets('about screen in ${lang.name}', (tester) async {
      currentLanguage.value = lang;
      tester.view.physicalSize = const Size(400, 5000);
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(MaterialApp(
        home: Directionality(textDirection: lang.direction, child: const AboutScreen()),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      // Every feature title and text is translated (no Persian left in
      // English or German).
      if (lang != AppLanguage.fa) {
        final persian = RegExp(r'[؀-ۿ]');
        final texts = tester.widgetList<Text>(find.byType(Text)).map((t) => t.data ?? '').where(persian.hasMatch).toList();
        expect(texts, isEmpty);
      }
      // No phone/computer sync in the Bazaar build.
      expect(find.byIcon(Icons.sync), kBazaar ? findsNothing : findsOneWidget);
    });
  }
}
