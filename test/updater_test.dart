// Picking the newest Windows installer from GitHub's list of releases.
import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/updater.dart';

Map<String, dynamic> rel(String tag, {bool draft = false, bool installer = true}) => {
      'tag_name': tag,
      'draft': draft,
      'prerelease': false,
      'assets': [
        if (installer) {'name': 'ModiriatMali-Setup.exe', 'browser_download_url': 'https://x/$tag/ModiriatMali-Setup.exe'},
      ],
    };

void main() {
  test('newest windows release with an installer wins', () {
    final r = newestWindowsRelease([
      rel('windows-v7'),
      rel('windows-v12'),
      rel('windows-v13', draft: true),
      rel('windows-v14', installer: false),
      rel('android-v99'),
      rel('windows-v9'),
    ]);
    expect(r?.build, 12);
    expect(r?.url, 'https://x/windows-v12/ModiriatMali-Setup.exe');
  });

  test('no release yet', () {
    expect(newestWindowsRelease([]), isNull);
  });
}
