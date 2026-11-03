// The receipt crop screen: dragging a corner and an edge, previewing and
// saving gives an image of the framed area.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:personal_finance/main.dart';

void main() {
  testWidgets('crop with dragged corner and edge, preview, save', (tester) async {
    currentLanguage.value = AppLanguage.en;
    tester.view.physicalSize = const Size(456, 856); // 400x800 photo + 28px margins
    tester.view.devicePixelRatio = 1;
    final photo = img.Image(width: 400, height: 800);
    img.fill(photo, color: img.ColorRgb8(240, 240, 240));
    final bytes = Uint8List.fromList(img.encodePng(photo));
    Uint8List? saved;
    // Opened with a suggested frame.
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: ElevatedButton(
            onPressed: () async {
              saved = await Navigator.push<Uint8List>(
                context,
                MaterialPageRoute(
                  builder: (_) => ReceiptCropScreen(
                    bytes: bytes,
                    width: 400,
                    height: 800,
                    png: true,
                    suggestion: const [Offset(100, 100), Offset(300, 100), Offset(300, 700), Offset(100, 700)],
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Crop receipt photo'), findsOneWidget);

    // The editor area sits between the hint and the buttons; find the
    // top-left handle by its on-screen position relative to the photo.
    final photoRect = tester.getRect(find.byType(Image));
    final scale = photoRect.width / 400;
    Offset onScreen(Offset p) => photoRect.topLeft + p * scale;
    // Top-left corner from (100,100) to (60,60) in photo pixels.
    await tester.dragFrom(onScreen(const Offset(100, 100)), const Offset(-40, -40) * scale);
    await tester.pump();
    // Bottom edge (midpoint 200,700) down to 740.
    await tester.dragFrom(onScreen(const Offset(200, 700)), const Offset(0, 40) * scale);
    await tester.pump();

    await tester.tap(find.text('Crop and preview'));
    await tester.runAsync(() => Future.delayed(const Duration(seconds: 2)));
    await tester.pumpAndSettle();
    expect(find.text('Preview of the cropped photo'), findsOneWidget);
    await tester.tap(find.text('Confirm and save'));
    await tester.pumpAndSettle();

    expect(saved, isNotNull);
    final out = img.decodePng(saved!)!;
    // Not a rectangle any more (only the top-left corner moved), so it's
    // straightened: width = longest of top/bottom edge, height = longest
    // of left/right edge.
    const dragSlop = 20 * 2; // touch slop eaten before a pan starts
    expect(out.width, inInclusiveRange(200, 240 + dragSlop));
    expect(out.height, inInclusiveRange(640, 680 + dragSlop));
  });
}
