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

  test('the phone picks the newest android release', () {
    final r = newestWindowsRelease(
      [
        {'tag_name': 'windows-v30', 'assets': [{'name': 'ModiriatMali-Setup.exe', 'browser_download_url': 'w'}]},
        {'tag_name': 'android-v185', 'assets': [{'name': 'ModiriatMali.apk', 'browser_download_url': 'a185'}]},
        {'tag_name': 'android-v186', 'assets': [{'name': 'ModiriatMali.apk', 'browser_download_url': 'a186'}]},
      ],
      tagPrefix: 'android-v',
      installerName: 'ModiriatMali.apk',
    );
    expect(r?.build, 186);
    expect(r?.url, 'a186');
  });

  test('no release yet', () {
    expect(newestWindowsRelease([]), isNull);
  });
}
