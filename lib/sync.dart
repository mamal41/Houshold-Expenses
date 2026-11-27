// Syncing the data between the phone and the Windows app over the internet,
// through a file in the person's own Google Drive (the hidden app-data
// folder, which only this app can see). Whenever a device is online it
// merges its changes with that file: records changed on one side only are
// taken from that side, a record deleted on one side and untouched on the
// other is deleted, and when both changed the same record the device
// syncing now wins (a record is never lost to a delete it conflicts with).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'main.dart';

// ============================== Merge ==============================

/// Records of one collection, by id.
typedef SyncRecords = Map<String, Map<String, dynamic>>;

/// Collection name -> records.
typedef SyncSnapshot = Map<String, SyncRecords>;

String _canonical(Object? v) {
  if (v is Map) {
    final keys = v.keys.map((k) => k.toString()).toList()..sort();
    return '{${keys.map((k) => '${jsonEncode(k)}:${_canonical(v[k])}').join(',')}}';
  }
  if (v is List) return '[${v.map(_canonical).join(',')}]';
  return jsonEncode(v);
}

bool _same(Object? a, Object? b) => _canonical(a) == _canonical(b);

/// Three-way merge of [local] and [remote] against [base], the snapshot both
/// had after this device's last sync (null before the first sync: then a
/// record both sides have but differently is taken from [remote], the data
/// already shared, and records only one side has are kept).
///
/// A device joining with no transactions of its own (a new install) takes
/// the shared data as it is, so its default account and categories don't
/// end up next to the real ones.
SyncSnapshot mergeSnapshots(SyncSnapshot? base, SyncSnapshot local, SyncSnapshot remote) {
  final remoteHasData = remote.values.any((records) => records.isNotEmpty);
  if (base == null && (local['transactions']?.isEmpty ?? true) && remoteHasData) {
    return {for (final e in remote.entries) e.key: Map.of(e.value)};
  }
  final out = <String, SyncRecords>{};
  final names = {...local.keys, ...remote.keys};
  for (final name in names) {
    final b = base?[name] ?? const <String, Map<String, dynamic>>{};
    final l = local[name] ?? const <String, Map<String, dynamic>>{};
    final r = remote[name] ?? const <String, Map<String, dynamic>>{};
    final merged = <String, Map<String, dynamic>>{};
    for (final id in {...l.keys, ...r.keys}) {
      final lv = l[id], rv = r[id], bv = b[id];
      Map<String, dynamic>? pick;
      if (_same(lv, rv)) {
        pick = lv;
      } else if (base == null) {
        pick = rv ?? lv;
      } else if (_same(lv, bv)) {
        pick = rv; // changed (or deleted) on the other device only
      } else if (_same(rv, bv)) {
        pick = lv; // changed (or deleted) here only
      } else {
        // Changed on both: keep this device's version; a change beats a delete.
        pick = lv ?? rv;
      }
      if (pick != null) merged[id] = pick;
    }
    out[name] = merged;
  }
  return out;
}

bool snapshotsEqual(SyncSnapshot a, SyncSnapshot b) => _same(a, b);

// ============================== Local data ==============================

/// The synced data of this device. A receipt photo's file path means
/// nothing on the other device, so it's left out of the synced records and
/// kept as it is locally; the photos themselves travel as separate files
/// (see Receipt photos below).
class LocalSyncData {
  static String _id(Map<String, dynamic> j) => '${j['id']}';

  static Future<SyncSnapshot> read() async {
    SyncRecords byId(List<Map<String, dynamic>> list, [String Function(Map<String, dynamic>)? id]) =>
        {for (final j in list) (id ?? _id)(j): j};
    final tx = (await Store.loadTransactions()).map((t) => t.toJson()..remove('imagePath')).toList();
    final rates = await Store.loadExchangeRates();
    final base = await Store.loadBaseCurrency();
    return {
      'transactions': byId(tx),
      // As stored: shown names follow each device's language (see
      // Store.loadCategories), what is synced must not.
      'categories': byId((await Store.loadCategories(raw: true)).map((c) => c.toJson()).toList()),
      'accounts': byId((await Store.loadAccounts(raw: true)).map((a) => a.toJson()).toList()),
      'budgetGoals': byId((await Store.loadBudgetGoals()).map((g) => g.toJson()).toList(), (j) => '${j['categoryId']}'),
      'savingsGoals': byId((await Store.loadSavingsGoals()).map((g) => g.toJson()).toList()),
      'savingsContributions': byId((await Store.loadSavingsContributions()).map((c) => c.toJson()).toList()),
      'shoppingLists': byId((await Store.loadShoppingLists()).map((l) => l.toJson()).toList()),
      'settings': {
        if (base != null) 'baseCurrency': {'value': base},
        if (rates.isNotEmpty) 'exchangeRates': {'value': rates},
      },
    };
  }

  /// Writes [s] as this device's data, only the collections that differ
  /// from [current].
  static Future<void> write(SyncSnapshot s, SyncSnapshot current) async {
    bool changed(String name) => !_same(s[name], current[name]);
    List<Map<String, dynamic>> list(String name) => (s[name] ?? const {}).values.toList();
    if (changed('transactions')) {
      final photos = {for (final t in await Store.loadTransactions()) if (t.imagePath != null) t.id: t.imagePath};
      await Store.saveTransactions([
        for (final j in list('transactions'))
          Transaction.fromJson({...j, if (photos[j['id']] != null) 'imagePath': photos[j['id']]}),
      ]);
    }
    if (changed('categories')) await Store.saveCategories(list('categories').map(Category.fromJson).toList());
    if (changed('accounts')) await Store.saveAccounts(list('accounts').map(Account.fromJson).toList());
    if (changed('budgetGoals')) await Store.saveBudgetGoals(list('budgetGoals').map(BudgetGoal.fromJson).toList());
    if (changed('savingsGoals')) await Store.saveSavingsGoals(list('savingsGoals').map(SavingsGoal.fromJson).toList());
    if (changed('savingsContributions')) {
      await Store.saveSavingsContributions(list('savingsContributions').map(SavingsContribution.fromJson).toList());
    }
    if (changed('shoppingLists')) await Store.saveShoppingLists(list('shoppingLists').map(ShoppingList.fromJson).toList());
    if (changed('settings')) {
      final settings = s['settings'] ?? const {};
      final base = settings['baseCurrency']?['value'];
      if (base is String) await Store.saveBaseCurrency(base);
      final rates = settings['exchangeRates']?['value'];
      await Store.saveExchangeRates(
          rates is Map ? rates.map((k, v) => MapEntry('$k', (v as num).toDouble())) : <String, double>{});
    }
  }
}

SyncSnapshot _snapshotFromJson(Object? j) {
  final out = <String, SyncRecords>{};
  if (j is! Map) return out;
  j.forEach((name, records) {
    if (records is Map) {
      out['$name'] = {for (final e in records.entries) '${e.key}': Map<String, dynamic>.from(e.value as Map)};
    }
  });
  return out;
}

// ============================== Google sign-in ==============================

const _driveScope = 'https://www.googleapis.com/auth/drive.appdata';

/// Signs in to Google and hands out access tokens for the Drive app folder:
/// with Google Play services on the phone, and in the browser on Windows
/// (OAuth with a local redirect, the way desktop apps sign in to Google).
abstract class GoogleAccess {
  static GoogleAccess forPlatform() => Platform.isWindows ? _DesktopGoogleAccess() : _PhoneGoogleAccess();

  /// Whether this build can sign in at all (Windows needs the app's
  /// Google client id built in).
  bool get configured;

  /// The OAuth client id this build signs in with (shown to compare with
  /// Google Cloud; not a secret). Null where it isn't built in.
  String? get clientId => null;
  Future<String?> email();
  Future<bool> signIn();
  Future<void> signOut();

  /// A valid access token, or null when not signed in.
  Future<String?> accessToken();
}

class _PhoneGoogleAccess extends GoogleAccess {
  final _google = GoogleSignIn(scopes: const [_driveScope]);
  GoogleSignInAccount? _account;

  @override
  bool get configured => true;

  Future<GoogleSignInAccount?> _current() async {
    _account ??= _google.currentUser ?? await _google.signInSilently(suppressErrors: true);
    return _account;
  }

  @override
  Future<String?> email() async => (await _current())?.email;

  @override
  Future<bool> signIn() async {
    _account = await _google.signIn();
    if (_account == null) return false;
    return _google.requestScopes(const [_driveScope]);
  }

  @override
  Future<void> signOut() async {
    await _google.disconnect().catchError((_) => _google.signOut());
    _account = null;
  }

  @override
  Future<String?> accessToken() async {
    final account = await _current();
    if (account == null) return null;
    final headers = await account.authHeaders;
    final auth = headers['Authorization'];
    return auth?.startsWith('Bearer ') == true ? auth!.substring(7) : null;
  }
}

class _DesktopGoogleAccess extends GoogleAccess {
  // The Windows app's OAuth client ("Desktop app" type), built in from the
  // repository secrets. Google treats a desktop client's secret as public.
  // Without any whitespace: a space or line break copied along with a secret
  // (also in the middle of it) makes Google reject the client
  // ("invalid_client"); neither value ever contains one.
  static final _clientId = const String.fromEnvironment('GOOGLE_DESKTOP_CLIENT_ID').replaceAll(RegExp(r'\s'), '');
  static final _clientSecret =
      const String.fromEnvironment('GOOGLE_DESKTOP_CLIENT_SECRET').replaceAll(RegExp(r'\s'), '');
  static const _refreshKey = 'sync_google_refresh_token';
  static const _emailKey = 'sync_google_email';

  String? _token;
  DateTime _expires = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  bool get configured => _clientId.isNotEmpty;

  @override
  String? get clientId => _clientId;

  @override
  Future<String?> email() async => (await SharedPreferences.getInstance()).getString(_emailKey);

  String _random(int bytes) {
    final r = Random.secure();
    return base64UrlEncode(List.generate(bytes, (_) => r.nextInt(256))).replaceAll('=', '');
  }

  @override
  Future<bool> signIn() async {
    if (!configured) return false;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final redirect = 'http://127.0.0.1:${server.port}';
      final verifier = _random(48);
      final challenge = base64UrlEncode(sha256.convert(utf8.encode(verifier)).bytes).replaceAll('=', '');
      final state = _random(16);
      final url = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
        'client_id': _clientId,
        'redirect_uri': redirect,
        'response_type': 'code',
        'scope': 'openid email $_driveScope',
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'access_type': 'offline',
        'prompt': 'consent',
        'state': state,
      });
      await Process.start('rundll32', ['url.dll,FileProtocolHandler', url.toString()]);
      final request = await server.first.timeout(const Duration(minutes: 5));
      final params = request.uri.queryParameters;
      request.response
        ..statusCode = 200
        ..headers.contentType = ContentType.html
        ..write('<html><body style="font-family:sans-serif;text-align:center;margin-top:80px">'
            '<h2>${params['code'] != null ? '&#10004;' : '&#10008;'}</h2>'
            '<p>You can close this window and return to the app.</p></body></html>');
      await request.response.close();
      final code = params['code'];
      if (code == null || params['state'] != state) return false;
      final res = await http.post(Uri.parse('https://oauth2.googleapis.com/token'), body: {
        'code': code,
        'client_id': _clientId,
        'client_secret': _clientSecret,
        'code_verifier': verifier,
        'redirect_uri': redirect,
        'grant_type': 'authorization_code',
      });
      if (res.statusCode != 200) return false;
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final sp = await SharedPreferences.getInstance();
      if (j['refresh_token'] is String) await sp.setString(_refreshKey, j['refresh_token'] as String);
      _token = j['access_token'] as String?;
      _expires = DateTime.now().add(Duration(seconds: ((j['expires_in'] as num?) ?? 3600).toInt() - 60));
      final info = await http.get(Uri.parse('https://openidconnect.googleapis.com/v1/userinfo'),
          headers: {'Authorization': 'Bearer $_token'});
      if (info.statusCode == 200) {
        final mail = (jsonDecode(info.body) as Map<String, dynamic>)['email'];
        if (mail is String) await sp.setString(_emailKey, mail);
      }
      return _token != null;
    } on TimeoutException {
      return false;
    } finally {
      await server.close(force: true);
    }
  }

  @override
  Future<void> signOut() async {
    final sp = await SharedPreferences.getInstance();
    final refresh = sp.getString(_refreshKey);
    if (refresh != null) {
      unawaited(http.post(Uri.parse('https://oauth2.googleapis.com/revoke'), body: {'token': refresh}).catchError((_) => http.Response('', 0)));
    }
    await sp.remove(_refreshKey);
    await sp.remove(_emailKey);
    _token = null;
  }

  @override
  Future<String?> accessToken() async {
    if (_token != null && DateTime.now().isBefore(_expires)) return _token;
    final sp = await SharedPreferences.getInstance();
    final refresh = sp.getString(_refreshKey);
    if (refresh == null || !configured) return null;
    final res = await http.post(Uri.parse('https://oauth2.googleapis.com/token'), body: {
      'client_id': _clientId,
      'client_secret': _clientSecret,
      'refresh_token': refresh,
      'grant_type': 'refresh_token',
    });
    if (res.statusCode == 400 || res.statusCode == 401) {
      // Access was withdrawn (e.g. in the Google account settings).
      await sp.remove(_refreshKey);
      return null;
    }
    if (res.statusCode != 200) throw SyncException(locf('خطای ورود به گوگل ({0})', [res.statusCode]));
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    _token = j['access_token'] as String?;
    _expires = DateTime.now().add(Duration(seconds: ((j['expires_in'] as num?) ?? 3600).toInt() - 60));
    return _token;
  }
}

// ============================== Drive file ==============================

class SyncException implements Exception {
  final String message;
  SyncException(this.message);
  @override
  String toString() => message;
}

/// The one sync file in the Drive app-data folder.
class _DriveFile {
  static const name = 'household-finance-sync.json';
  final String token;
  _DriveFile(this.token);

  Map<String, String> get _auth => {'Authorization': 'Bearer $token'};

  void _check(http.Response r) {
    if (r.statusCode >= 200 && r.statusCode < 300) return;
    if (r.statusCode == 401 || r.statusCode == 403) {
      throw SyncException(loc('دسترسی به Google Drive داده نشد. دوباره وارد حساب گوگل شوید.'));
    }
    throw SyncException(locf('خطای Google Drive ({0})', [r.statusCode]));
  }

  /// Id and version of the sync file, or null when there's none yet.
  Future<({String id, String version})?> find() async {
    final r = await http.get(
      Uri.https('www.googleapis.com', '/drive/v3/files', {
        'spaces': 'appDataFolder',
        'q': "name = '$name' and trashed = false",
        'fields': 'files(id,version)',
      }),
      headers: _auth,
    );
    _check(r);
    final files = (jsonDecode(r.body) as Map<String, dynamic>)['files'] as List? ?? const [];
    if (files.isEmpty) return null;
    final f = files.first as Map<String, dynamic>;
    return (id: '${f['id']}', version: '${f['version']}');
  }

  Future<Map<String, dynamic>> download(String id) async {
    final r = await http.get(Uri.https('www.googleapis.com', '/drive/v3/files/$id', {'alt': 'media'}), headers: _auth);
    _check(r);
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  Future<void> upload(String? id, Map<String, dynamic> content) async {
    final body = utf8.encode(jsonEncode(content));
    if (id != null) {
      final r = await http.patch(
        Uri.https('www.googleapis.com', '/upload/drive/v3/files/$id', {'uploadType': 'media'}),
        headers: {..._auth, 'Content-Type': 'application/json'},
        body: body,
      );
      _check(r);
      return;
    }
    const boundary = 'sync-boundary-7f3a';
    final meta = jsonEncode({'name': name, 'parents': ['appDataFolder']});
    final multipart = <int>[
      ...utf8.encode('--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n$meta\r\n'),
      ...utf8.encode('--$boundary\r\nContent-Type: application/json\r\n\r\n'),
      ...body,
      ...utf8.encode('\r\n--$boundary--'),
    ];
    final r = await http.post(
      Uri.https('www.googleapis.com', '/upload/drive/v3/files', {'uploadType': 'multipart'}),
      headers: {..._auth, 'Content-Type': 'multipart/related; boundary=$boundary'},
      body: multipart,
    );
    _check(r);
  }
}

// ============================== Receipt photos ==============================
//
// Each receipt photo is its own file in the same hidden Drive folder, named
// "receipt-<content hash>-<transaction id>.<ext>", so the same photo has the
// same name on every device. A photo new or changed on one device is
// uploaded (replacing that transaction's older photo files) and the other
// device downloads it. Each device remembers, per transaction, which Drive
// file its own copy matches, so nothing moves twice. A photo removed on one
// device is removed from Drive, but never deleted from the other device.

/// A receipt photo file in Drive.
typedef DriveReceipt = ({String id, String name, String txId, DateTime modified});

/// What this device's copy of a transaction's photo last matched: [key] of
/// the local file (see [receiptFileKey]) and the [drive] file name.
typedef ReceiptState = ({String key, String drive});

/// How the receipt photos stand after a sync, for the sync screen.
typedef ReceiptSyncStatus = ({int photos, int shared, int pending, String? error});

/// The transaction a Drive receipt file belongs to, or null for any other
/// file.
String? receiptTxId(String name) {
  final m = RegExp(r'^receipt-[0-9a-f]{10}-(.+)\.[A-Za-z0-9]+$').firstMatch(name);
  return m?.group(1);
}

String receiptFileName(String hash, String txId, String ext) => 'receipt-$hash-$txId.$ext';

/// A cheap check whether a photo file changed: its path, size and time.
String receiptFileKey(String path, int length, DateTime modified) =>
    sha1.convert(utf8.encode('$path|$length|${modified.millisecondsSinceEpoch}')).toString().substring(0, 10);

/// The first 10 hex digits of the SHA-1 of a file's bytes.
String receiptContentHash(List<int> bytes) => sha1.convert(bytes).toString().substring(0, 10);

/// What to do with one transaction's photo.
sealed class ReceiptAction {
  final String txId;
  const ReceiptAction(this.txId);
}

/// Share this device's photo: upload it unless Drive has the same photo
/// already, and remove the transaction's other photo files from Drive.
class ReceiptUpload extends ReceiptAction {
  const ReceiptUpload(super.txId);
}

/// Download [file] as this device's photo.
class ReceiptDownload extends ReceiptAction {
  final DriveReceipt file;
  const ReceiptDownload(super.txId, this.file);
}

/// Delete these Drive files (the photo was removed here, or its transaction
/// deleted) and forget the transaction's photo state.
class ReceiptDelete extends ReceiptAction {
  final List<DriveReceipt> files;
  const ReceiptDelete(super.txId, this.files);
}

/// Decides what to move for each transaction.
///
/// [local]: every transaction on this device -> the [receiptFileKey] of its
/// photo here, or null when it has none. [state]: per transaction, what
/// this device's copy last matched. Photo files of a transaction that
/// doesn't exist here are deleted only once they're an hour old, as the
/// other device may be in the middle of adding it.
List<ReceiptAction> planReceiptSync({
  required Map<String, String?> local,
  required List<DriveReceipt> drive,
  required Map<String, ReceiptState> state,
  required DateTime now,
}) {
  final byTx = <String, List<DriveReceipt>>{};
  for (final f in drive) {
    (byTx[f.txId] ??= []).add(f);
  }
  for (final l in byTx.values) {
    l.sort((a, b) => b.modified.compareTo(a.modified));
  }
  final actions = <ReceiptAction>[];
  for (final e in local.entries) {
    final id = e.key;
    final key = e.value;
    final files = byTx[id] ?? const <DriveReceipt>[];
    final newest = files.firstOrNull;
    final st = state[id];
    if (key != null) {
      if (st == null || st.key != key) {
        // New or changed here, or not known to be shared yet.
        actions.add(ReceiptUpload(id));
      } else if (newest != null && newest.name != st.drive) {
        // A newer photo from the other device.
        actions.add(ReceiptDownload(id, newest));
      }
      // Otherwise in step - or Drive lost it, and the other device keeps
      // its own copy anyway.
    } else if (st != null) {
      // Removed here after it was shared.
      actions.add(ReceiptDelete(id, files));
    } else if (newest != null) {
      // Only on Drive.
      actions.add(ReceiptDownload(id, newest));
    }
  }
  // Photos of deleted transactions.
  for (final e in byTx.entries) {
    if (local.containsKey(e.key)) continue;
    final old = e.value.where((f) => now.difference(f.modified) > const Duration(hours: 1)).toList();
    if (old.isNotEmpty) actions.add(ReceiptDelete(e.key, old));
  }
  return actions;
}

class _DriveReceipts {
  final String token;
  _DriveReceipts(this.token);
  Map<String, String> get _auth => {'Authorization': 'Bearer $token'};

  void _check(http.Response r) {
    if (r.statusCode < 200 || r.statusCode >= 300) throw SyncException(locf('خطای Google Drive ({0})', [r.statusCode]));
  }

  /// The receipt photo files: every file of the hidden folder is listed and
  /// the photos picked by name (no search by name, whose matching rules
  /// for names like these aren't certain).
  Future<List<DriveReceipt>> list() async {
    final out = <DriveReceipt>[];
    String? page;
    do {
      final r = await http.get(
        Uri.https('www.googleapis.com', '/drive/v3/files', {
          'spaces': 'appDataFolder',
          'q': 'trashed = false',
          'fields': 'nextPageToken,files(id,name,modifiedTime)',
          'pageSize': '1000',
          if (page != null) 'pageToken': page,
        }),
        headers: _auth,
      );
      _check(r);
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      for (final f in (j['files'] as List? ?? const []).whereType<Map<String, dynamic>>()) {
        final name = '${f['name']}';
        final tx = receiptTxId(name);
        if (tx == null) continue;
        out.add((id: '${f['id']}', name: name, txId: tx, modified: DateTime.tryParse('${f['modifiedTime']}') ?? DateTime(2000)));
      }
      page = j['nextPageToken'] as String?;
    } while (page != null && page.isNotEmpty);
    return out;
  }

  /// A resumable upload: any size (a simple upload stops at 5 MB, which a
  /// long receipt of several photos can pass).
  Future<void> upload(String name, List<int> bytes) async {
    final type = name.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';
    final start = await http.post(
      Uri.https('www.googleapis.com', '/upload/drive/v3/files', {'uploadType': 'resumable'}),
      headers: {
        ..._auth,
        'Content-Type': 'application/json; charset=UTF-8',
        'X-Upload-Content-Type': type,
        'X-Upload-Content-Length': '${bytes.length}',
      },
      body: jsonEncode({'name': name, 'parents': ['appDataFolder']}),
    );
    _check(start);
    final session = start.headers['location'];
    if (session == null || session.isEmpty) throw SyncException(locf('خطای Google Drive ({0})', ['no upload address']));
    final r = await http.put(Uri.parse(session), headers: {..._auth, 'Content-Type': type}, body: bytes);
    _check(r);
  }

  Future<List<int>> download(String id) async {
    final r = await http.get(Uri.https('www.googleapis.com', '/drive/v3/files/$id', {'alt': 'media'}), headers: _auth);
    _check(r);
    return r.bodyBytes;
  }

  Future<void> delete(String id) async {
    final r = await http.delete(Uri.https('www.googleapis.com', '/drive/v3/files/$id'), headers: _auth);
    if (r.statusCode != 404) _check(r);
  }
}

/// Moves receipt photos between this device and Drive and returns how they
/// stand, and whether another run should follow right away (more were
/// waiting than one run moves) and whether any photo here changed. A photo
/// that fails is tried again next time.
Future<({ReceiptSyncStatus status, bool more, bool changed})> syncReceiptPhotos(String token, {int maxTransfers = 30}) async {
  // The state of this version; the first version's (under another key) is
  // dropped: it could claim photos as shared that a bug had lost.
  const stateKey = 'sync_receipt_photos';
  final sp = await SharedPreferences.getInstance();
  await sp.remove('sync_receipts_state');
  final state = <String, ReceiptState>{};
  try {
    final raw = jsonDecode(sp.getString(stateKey) ?? '{}') as Map<String, dynamic>;
    raw.forEach((k, v) => state[k] = (key: '${v['k']}', drive: '${v['d']}'));
  } catch (_) {}
  Future<void> saveState() =>
      sp.setString(stateKey, jsonEncode({for (final e in state.entries) e.key: {'k': e.value.key, 'd': e.value.drive}}));

  final txs = await Store.loadTransactions();
  final paths = <String, String>{};
  final local = <String, String?>{};
  for (final t in txs) {
    final p = t.imagePath;
    final f = p == null ? null : File(p);
    if (f != null && f.existsSync()) {
      final stat = f.statSync();
      paths[t.id] = p!;
      local[t.id] = receiptFileKey(p, stat.size, stat.modified);
    } else {
      // A photo whose file is gone from this device is fetched again,
      // never deleted from Drive for that.
      if (p != null) state.remove(t.id);
      local[t.id] = null;
    }
  }

  final drive = _DriveReceipts(token);
  final remote = await drive.list();
  final actions = planReceiptSync(local: local, drive: remote, state: state, now: DateTime.now().toUtc());
  final newPaths = <String, String>{};
  var transfers = 0;
  var failed = 0;
  var done = 0;
  String? error;
  for (final a in actions) {
    if (transfers >= maxTransfers) break;
    try {
      switch (a) {
        case ReceiptUpload(:final txId):
          final path = paths[txId]!;
          final bytes = await File(path).readAsBytes();
          var ext = path.contains('.') ? path.split('.').last.toLowerCase() : 'jpg';
          if (!RegExp(r'^[a-z0-9]{1,5}$').hasMatch(ext)) ext = 'jpg';
          final name = receiptFileName(receiptContentHash(bytes), txId, ext);
          if (!remote.any((f) => f.name == name)) {
            transfers++;
            await drive.upload(name, bytes);
          }
          for (final old in remote.where((f) => f.txId == txId && f.name != name)) {
            await drive.delete(old.id);
          }
          state[txId] = (key: local[txId]!, drive: name);
        case ReceiptDownload(:final txId, :final file):
          transfers++;
          final bytes = await drive.download(file.id);
          final dir = Directory('${(await getApplicationDocumentsDirectory()).path}/draft_receipts');
          await dir.create(recursive: true);
          final path = '${dir.path}${Platform.pathSeparator}$txId.${file.name.split('.').last}';
          await File(path).writeAsBytes(bytes, flush: true);
          final old = paths[txId];
          if (old != null && old != path) {
            try {
              await File(old).delete();
            } catch (_) {}
          }
          final stat = File(path).statSync();
          newPaths[txId] = path;
          state[txId] = (key: receiptFileKey(path, stat.size, stat.modified), drive: file.name);
        case ReceiptDelete(:final txId, :final files):
          for (final f in files) {
            await drive.delete(f.id);
          }
          state.remove(txId);
      }
      done++;
      await saveState();
    } on SocketException {
      await saveState();
      rethrow;
    } catch (e) {
      // This photo only; the next run tries again.
      failed++;
      error = '$e';
    }
  }
  // Forget transactions that no longer exist.
  state.removeWhere((k, _) => !local.containsKey(k));
  await saveState();

  if (newPaths.isNotEmpty) {
    // Re-read: the person may have changed something meanwhile.
    final now = await Store.loadTransactions();
    await Store.saveTransactions([for (final t in now) newPaths[t.id] != null ? t.copyWith(imagePath: newPaths[t.id]) : t]);
  }
  final photos = local.values.whereType<String>().length + newPaths.keys.where((id) => local[id] == null).length;
  final pending = actions.length - done;
  return (
    status: (photos: photos, shared: state.length, pending: pending, error: error),
    more: pending > failed && transfers >= maxTransfers,
    changed: newPaths.isNotEmpty,
  );
}

// ============================== Sync service ==============================

enum SyncState { off, idle, syncing, error }

class SyncService {
  SyncService._();
  static final SyncService instance = SyncService._();

  final GoogleAccess google = GoogleAccess.forPlatform();

  /// Bumped whenever data from the other device was written here, so the
  /// screens can reload.
  final dataVersion = ValueNotifier<int>(0);
  final state = ValueNotifier<SyncState>(SyncState.off);
  String? lastError;
  DateTime? lastSync;

  /// The Google sign-in was lost (e.g. Google ended it): syncing needs the
  /// person to sign in again.
  bool needsSignIn = false;

  /// How the receipt photos stand after the last sync.
  final receiptStatus = ValueNotifier<ReceiptSyncStatus?>(null);

  static const _enabledKey = 'sync_enabled';
  static const _lastSyncKey = 'sync_last_at';

  bool _enabled = false;
  bool get enabled => _enabled;
  Timer? _debounce;
  Timer? _periodic;
  Future<void>? _running;
  bool _again = false;

  Future<File> _baseFile() async => File('${(await getApplicationSupportDirectory()).path}/sync_base.json');

  Future<SyncSnapshot?> _loadBase() async {
    try {
      final f = await _baseFile();
      if (!await f.exists()) return null;
      return _snapshotFromJson(jsonDecode(await f.readAsString()));
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveBase(SyncSnapshot s) async {
    final f = await _baseFile();
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode(s), flush: true);
  }

  /// Reads the saved setting and starts syncing in the background when on.
  Future<void> start() async {
    if (kBazaar) return; // no phone/computer sync in the Bazaar build
    final sp = await SharedPreferences.getInstance();
    _enabled = sp.getBool(_enabledKey) ?? false;
    final last = sp.getString(_lastSyncKey);
    lastSync = last == null ? null : DateTime.tryParse(last);
    if (!_enabled) return;
    state.value = SyncState.idle;
    _periodic?.cancel();
    // While the app is open, look for the other device's changes now and then.
    _periodic = Timer.periodic(const Duration(minutes: 2), (_) => requestSync());
    unawaited(syncNow());
  }

  /// Signs in and turns syncing on.
  Future<bool> enable() async {
    if (!await google.signIn()) return false;
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_enabledKey, true);
    // A new account: start over without the last shared state.
    try {
      final f = await _baseFile();
      if (await f.exists()) await f.delete();
    } catch (_) {}
    await start();
    return true;
  }

  /// Signs in again after the sign-in was lost, keeping the synced state.
  Future<bool> signInAgain() async {
    if (!await google.signIn()) return false;
    needsSignIn = false;
    await syncNow();
    return true;
  }

  Future<void> disable() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_enabledKey, false);
    _enabled = false;
    _periodic?.cancel();
    _debounce?.cancel();
    await google.signOut();
    state.value = SyncState.off;
  }

  /// Syncs a few seconds from now (several changes in a row sync once).
  void requestSync() {
    if (!_enabled) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 4), () => unawaited(syncNow()));
  }

  Future<void> syncNow() async {
    if (!_enabled) return;
    if (_running != null) {
      _again = true;
      return _running;
    }
    final run = _sync();
    _running = run;
    try {
      await run;
    } finally {
      _running = null;
      if (_again) {
        _again = false;
        requestSync();
      }
    }
  }

  Future<void> _sync() async {
    state.value = SyncState.syncing;
    try {
      final token = await google.accessToken();
      if (token == null) {
        needsSignIn = true;
        throw SyncException(loc('ورود به حساب گوگل منقضی شده است. دوباره وارد شوید.'));
      }
      needsSignIn = false;
      final drive = _DriveFile(token);
      // Another device may upload between our download and upload; then
      // merge again with what it uploaded.
      for (var attempt = 0; attempt < 3; attempt++) {
        final meta = await drive.find();
        final remoteJson = meta == null ? null : await drive.download(meta.id);
        final remote = _snapshotFromJson(remoteJson?['collections']);
        final local = await LocalSyncData.read();
        final base = await _loadBase();
        final merged = mergeSnapshots(base, local, remote);
        if (!snapshotsEqual(merged, remote) || meta == null) {
          final now = await drive.find();
          if (now?.version != meta?.version) continue;
          await drive.upload(meta?.id, {
            'format': 1,
            'updatedAt': DateTime.now().toUtc().toIso8601String(),
            'device': Platform.operatingSystem,
            'collections': merged,
          });
        }
        if (!snapshotsEqual(merged, local)) {
          await LocalSyncData.write(merged, local);
          dataVersion.value++;
        }
        await _saveBase(merged);
        // Then the receipt photos.
        // A photo that fails doesn't fail the sync of the data: it shows
        // in the photo line of the sync screen and is tried again.
        try {
          final photos = await syncReceiptPhotos(token);
          receiptStatus.value = photos.status;
          if (photos.changed) dataVersion.value++;
          // More photos than one run moves: carry on right after.
          if (photos.more) _again = true;
        } on SocketException {
          rethrow;
        } catch (e) {
          final last = receiptStatus.value;
          receiptStatus.value = (photos: last?.photos ?? 0, shared: last?.shared ?? 0, pending: last?.pending ?? 0, error: '$e');
        }
        lastSync = DateTime.now();
        lastError = null;
        final sp = await SharedPreferences.getInstance();
        await sp.setString(_lastSyncKey, lastSync!.toIso8601String());
        state.value = SyncState.idle;
        return;
      }
      throw SyncException(loc('دستگاه دیگر هم‌زمان در حال همگام‌سازی است؛ کمی بعد دوباره امتحان می‌شود.'));
    } on SocketException {
      // Offline: try again later, quietly.
      lastError = loc('اتصال به اینترنت برقرار نیست.');
      state.value = SyncState.error;
    } catch (e) {
      lastError = '$e';
      state.value = SyncState.error;
    }
  }
}

// ============================== Settings screen ==============================

class SyncSettingsScreen extends StatefulWidget {
  const SyncSettingsScreen({super.key});
  @override
  State<SyncSettingsScreen> createState() => _SyncSettingsScreenState();
}

class _SyncSettingsScreenState extends State<SyncSettingsScreen> {
  final sync = SyncService.instance;
  String? email;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    sync.state.addListener(_changed);
    sync.receiptStatus.addListener(_changed);
    _loadEmail();
  }

  @override
  void dispose() {
    sync.state.removeListener(_changed);
    sync.receiptStatus.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _loadEmail() async {
    if (!sync.enabled) return;
    try {
      final e = await sync.google.email();
      if (mounted) setState(() => email = e);
    } catch (_) {}
  }

  Future<void> _turnOn() async {
    setState(() => busy = true);
    String? error;
    try {
      if (!await sync.enable()) error = loc('ورود به حساب گوگل انجام نشد.');
    } catch (e) {
      error = locf('ورود به حساب گوگل انجام نشد: {0}', [e]);
    }
    if (!mounted) return;
    setState(() => busy = false);
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
    } else {
      await _loadEmail();
    }
  }

  Future<void> _signInAgain() async {
    setState(() => busy = true);
    String? error;
    try {
      if (!await sync.signInAgain()) error = loc('ورود به حساب گوگل انجام نشد.');
    } catch (e) {
      error = locf('ورود به حساب گوگل انجام نشد: {0}', [e]);
    }
    if (!mounted) return;
    setState(() => busy = false);
    if (error != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error)));
    await _loadEmail();
  }

  Future<void> _turnOff() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(loc('خاموش کردن همگام‌سازی')),
        content: Text(loc('اطلاعات روی این دستگاه می‌ماند و فقط دیگر با دستگاه دیگر یکی نمی‌شود.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(loc('خاموش شود'))),
        ],
      ),
    );
    if (ok != true) return;
    await sync.disable();
    if (mounted) setState(() => email = null);
  }

  @override
  Widget build(BuildContext context) {
    final st = sync.state.value;
    final on = sync.enabled;
    final muted = TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurfaceVariant, height: 1.6);
    return Scaffold(
      appBar: AppBar(title: Text(loc('همگام‌سازی گوشی و کامپیوتر'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            loc('برنامه‌ی گوشی و برنامه‌ی ویندوز با یک حساب گوگل به هم وصل می‌شوند. هر وقت به اینترنت وصل باشند، تراکنش‌ها، حساب‌ها، دسته‌بندی‌ها، اهداف و لیست‌های خرید خودکار یکی می‌شوند.'),
            style: muted,
          ),
          const SizedBox(height: 8),
          Text(
            loc('اطلاعات و تصویر رسیدها در پوشه‌ی مخفی همین برنامه در Google Drive خودتان نگه داشته می‌شود؛ فقط این برنامه به آن دسترسی دارد. تنظیمات هر دستگاه (قفل، زبان، کلید هوش مصنوعی) همگام نمی‌شوند.'),
            style: muted,
          ),
          const SizedBox(height: 20),
          if (!on) ...[
            if (!sync.google.configured)
              Text(loc('این نسخه‌ی برنامه برای ورود به گوگل تنظیم نشده است.'), style: TextStyle(color: Colors.red.shade400))
            else
              FilledButton.icon(
                onPressed: busy ? null : _turnOn,
                icon: busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.login),
                label: Text(loc('ورود با حساب گوگل و روشن کردن همگام‌سازی')),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              ),
            const SizedBox(height: 8),
            Text(loc('روی هر دو دستگاه با همان حساب گوگل وارد شوید.'), style: muted),
            if (sync.google.clientId != null) ...[
              const SizedBox(height: 16),
              Text(loc('شناسه‌ی کلاینت (Client ID) این نسخه؛ باید با Client ID کلاینت Desktop در Google Cloud یکی باشد:'),
                  style: muted.copyWith(fontSize: 12)),
              const SizedBox(height: 4),
              Directionality(
                textDirection: TextDirection.ltr,
                child: SelectableText(sync.google.clientId!, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
              ),
            ],
          ] else ...[
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.account_circle_outlined),
                    title: Text(email ?? loc('حساب گوگل')),
                    subtitle: Text(loc('همگام‌سازی روشن است')),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: st == SyncState.syncing
                        ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                        : Icon(st == SyncState.error ? Icons.error_outline : Icons.cloud_done_outlined,
                            color: st == SyncState.error ? Colors.red.shade400 : Colors.green.shade600),
                    title: Text(st == SyncState.syncing
                        ? loc('در حال همگام‌سازی...')
                        : st == SyncState.error
                            ? (sync.lastError ?? loc('خطا'))
                            : loc('همگام است')),
                    subtitle: sync.lastSync == null
                        ? null
                        : Text(locf('آخرین همگام‌سازی: {0}', [
                            '${formatDate(sync.lastSync!)} ${persianDigits(DateFormatHm.format(sync.lastSync!))}'
                          ])),
                  ),
                  if (sync.receiptStatus.value case final photos?) ...[
                    const Divider(height: 1),
                    ListTile(
                      leading: Icon(
                        photos.error != null ? Icons.image_not_supported_outlined : Icons.photo_library_outlined,
                        color: photos.error != null ? Colors.orange.shade700 : null,
                      ),
                      title: Text(loc('تصویر رسیدها')),
                      subtitle: Text([
                        locf('{0} تصویر روی این دستگاه • {1} همگام', [persianDigits('${photos.photos}'), persianDigits('${photos.shared}')]),
                        if (photos.pending > 0) locf('{0} تصویر در صف (در همگام‌سازی‌های بعدی)', [persianDigits('${photos.pending}')]),
                        if (photos.error != null) locf('آخرین خطا: {0}', [photos.error!]),
                      ].join('\n')),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (sync.needsSignIn) ...[
              FilledButton.icon(
                onPressed: busy ? null : _signInAgain,
                icon: busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.login),
                label: Text(loc('ورود دوباره به حساب گوگل')),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              ),
              const SizedBox(height: 8),
            ],
            FilledButton.icon(
              onPressed: st == SyncState.syncing ? null : () => sync.syncNow(),
              icon: const Icon(Icons.sync),
              label: Text(loc('همگام‌سازی الان')),
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _turnOff,
              icon: const Icon(Icons.logout),
              label: Text(loc('خاموش کردن و خروج از حساب')),
              style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            ),
          ],
        ],
      ),
    );
  }
}

/// "14:05" for the last-sync line.
class DateFormatHm {
  static String format(DateTime d) => '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}
