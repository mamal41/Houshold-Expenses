// Several photos of one receipt are joined top to bottom into one image.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:personal_finance/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('photos are joined at the narrowest width', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => Directory.systemTemp.path,
    );
    final dir = await Directory.systemTemp.createTemp('stitch');
    Future<String> photo(String name, int w, int h, int r) async {
      final i = img.Image(width: w, height: h);
      img.fill(i, color: img.ColorRgb8(r, 0, 0));
      final f = File('${dir.path}/$name.png');
      await f.writeAsBytes(img.encodePng(i));
      return f.path;
    }

    final out = await stitchImagesVertically([await photo('a', 400, 300, 200), await photo('b', 800, 400, 100)]);
    final joined = img.decodeJpg(await File(out).readAsBytes())!;
    expect(joined.width, 400);
    expect(joined.height, 300 + 200); // the second one scaled to 400 wide
    expect(joined.getPixel(200, 100).r, greaterThan(180)); // first photo on top
    expect(joined.getPixel(200, 450).r, lessThan(130)); // second below it
    await dir.delete(recursive: true);
  });
}
