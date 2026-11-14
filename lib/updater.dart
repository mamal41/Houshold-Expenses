// Updates for the Windows app: each Windows build publishes its installer as
// a GitHub release ("windows-v<build number>"). The app compares that number
// with its own and, when a newer one exists, offers to download it; the
// installer then runs silently over the installed app (the data and the
// Google sign-in are kept, they live outside the program folder) and starts
// the new version.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'main.dart';

/// This build's number (the build workflow's run number); 0 when built by
/// hand, which never asks to update.
const kWindowsBuild = int.fromEnvironment('WINDOWS_BUILD');

const _releasesUrl = 'https://api.github.com/repos/mamal41/Houshold-Expenses/releases?per_page=30';
const _tagPrefix = 'windows-v';
const _installerName = 'ModiriatMali-Setup.exe';

typedef WindowsRelease = ({int build, String url, String notes});

/// The newest published Windows release with an installer, from GitHub's
/// list of releases.
WindowsRelease? newestWindowsRelease(List releases) {
  WindowsRelease? newest;
  for (final r in releases) {
    final tag = '${r['tag_name']}';
    if (!tag.startsWith(_tagPrefix) || r['draft'] == true || r['prerelease'] == true) continue;
    final build = int.tryParse(tag.substring(_tagPrefix.length));
    if (build == null || (newest != null && build <= newest.build)) continue;
    final asset = (r['assets'] as List? ?? const []).cast<Map>().where((a) => a['name'] == _installerName).firstOrNull;
    if (asset == null) continue;
    newest = (build: build, url: '${asset['browser_download_url']}', notes: '${r['body'] ?? ''}'.trim());
  }
  return newest;
}

class WindowsUpdater {
  WindowsUpdater._();
  static final instance = WindowsUpdater._();

  bool get supported => Platform.isWindows && kWindowsBuild > 0;

  /// The newest release when it's newer than this build.
  final available = ValueNotifier<WindowsRelease?>(null);

  Future<WindowsRelease?> check() async {
    if (!supported) return null;
    final res = await http.get(Uri.parse(_releasesUrl), headers: {'Accept': 'application/vnd.github+json'});
    if (res.statusCode != 200) throw HttpException('GitHub ${res.statusCode}');
    final newest = newestWindowsRelease(jsonDecode(res.body) as List);
    available.value = newest != null && newest.build > kWindowsBuild ? newest : null;
    return available.value;
  }

  /// Checked once at start: asks whether to update when there's a new version.
  Future<void> checkAtStart() async {
    if (!supported) return;
    try {
      final r = await check();
      // A context below the navigator, for the dialog.
      final context = rootNavigatorKey.currentState?.overlay?.context;
      if (r != null && context != null && context.mounted) await offer(context, r);
    } catch (_) {
      // offline or GitHub unreachable - try again next start
    }
  }

  Future<void> offer(BuildContext context, WindowsRelease r) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc('نسخه‌ی جدید برنامه آماده است')),
        content: SingleChildScrollView(
          child: Text(
            '${locf('نسخه‌ی {0} (نسخه‌ی فعلی: {1})', [persianDigits('${r.build}'), persianDigits('$kWindowsBuild')])}\n\n'
            '${loc('برنامه بسته می‌شود، نسخه‌ی جدید نصب می‌شود و دوباره باز می‌شود. اطلاعات و اتصال به حساب گوگل سر جایش می‌ماند.')}',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(loc('بعداً'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(loc('به‌روزرسانی'))),
        ],
      ),
    );
    if (go == true && context.mounted) await install(context, r);
  }

  /// Downloads the installer (showing progress), starts it silently and
  /// closes the app so the installer can replace it.
  Future<void> install(BuildContext context, WindowsRelease r) async {
    final progress = ValueNotifier<double?>(null);
    var cancelled = false;
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(loc('دریافت نسخه‌ی جدید...')),
        content: ValueListenableBuilder<double?>(
          valueListenable: progress,
          builder: (_, p, __) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: p),
              const SizedBox(height: 8),
              Text(p == null ? '' : persianDigits('${(p * 100).round()}%')),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              cancelled = true;
              Navigator.pop(ctx);
            },
            child: Text(tr('cancel')),
          ),
        ],
      ),
    ));
    final client = http.Client();
    try {
      final res = await client.send(http.Request('GET', Uri.parse(r.url)));
      if (res.statusCode != 200) throw HttpException('${res.statusCode}');
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}\\$_installerName');
      final sink = file.openWrite();
      final total = res.contentLength ?? 0;
      var got = 0;
      await for (final chunk in res.stream) {
        if (cancelled) break;
        sink.add(chunk);
        got += chunk.length;
        if (total > 0) progress.value = got / total;
      }
      await sink.close();
      if (cancelled) return;
      await Process.start(
        file.path,
        ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/CLOSEAPPLICATIONS'],
        mode: ProcessStartMode.detached,
      );
      exit(0);
    } catch (e) {
      if (!cancelled && context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(locf('به‌روزرسانی انجام نشد: {0}', [e]))));
      }
    } finally {
      client.close();
    }
  }
}

/// "Update" entry for the Windows settings: the current version and a
/// button to look for a newer one.
class WindowsUpdateTile extends StatefulWidget {
  const WindowsUpdateTile({super.key});
  @override
  State<WindowsUpdateTile> createState() => _WindowsUpdateTileState();
}

class _WindowsUpdateTileState extends State<WindowsUpdateTile> {
  bool checking = false;

  Future<void> _check() async {
    final updater = WindowsUpdater.instance;
    setState(() => checking = true);
    try {
      final r = await updater.check();
      if (!mounted) return;
      if (r == null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(loc('برنامه به‌روز است.'))));
      } else {
        await updater.offer(context, r);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(locf('بررسی به‌روزرسانی انجام نشد: {0}', [e]))));
      }
    } finally {
      if (mounted) setState(() => checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.system_update_alt),
      title: Text(loc('به‌روزرسانی برنامه')),
      subtitle: Text(locf('نسخه‌ی نصب‌شده: {0}', [persianDigits('$kWindowsBuild')])),
      trailing: checking
          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.chevron_left),
      onTap: checking ? null : _check,
    );
  }
}
