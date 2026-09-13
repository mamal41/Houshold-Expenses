import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show SystemNavigator, SystemChrome, SystemUiMode;
import 'package:intl/intl.dart' hide TextDirection;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:pdfx/pdfx.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz_data;
import 'package:fl_chart/fl_chart.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Full-screen: hide the status bar and Android's gesture/nav bar; either
  // can be revealed temporarily by swiping from that edge, then auto-hides
  // again, so on-screen content never sits underneath the system bars.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  await NotificationService.instance.init();
  runApp(const MoneyApp());
}

// Isolates an LTR chunk (numbers, dates, currency) inside RTL Persian text
// so it always renders left-to-right in the right place, instead of the
// Unicode bidi algorithm re-ordering symbols/signs relative to the digits.
String ltr(String s) => '\u2066$s\u2069';

Future<bool> confirmExitApp(BuildContext context) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Ø®Ø±ÙˆØ¬ Ø§Ø² Ø¨Ø±Ù†Ø§Ù…Ù‡'),
      content: const Text('Ø¢ÛŒØ§ Ù…ÛŒâ€ŒØ®ÙˆØ§Ù‡ÛŒØ¯ Ø§Ø² Ø¨Ø±Ù†Ø§Ù…Ù‡ Ø®Ø§Ø±Ø¬ Ø´ÙˆÛŒØ¯ØŸ'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Ø®ÛŒØ±')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Ø¨Ù„Ù‡')),
      ],
    ),
  );
  return result ?? false;
}

/// Returns true if the screen should be allowed to close (discard or the
/// user chose "save" and it was handled by [onSave]), false to stay.
Future<bool> confirmDiscardChanges(BuildContext context, {Future<bool> Function()? onSave}) async {
  final choice = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('ØªØºÛŒÛŒØ±Ø§Øª Ø°Ø®ÛŒØ±Ù‡ Ù†Ø´Ø¯Ù‡'),
      content: const Text('Ú†ÛŒØ²ÛŒ ØªØºÛŒÛŒØ± Ú©Ø±Ø¯Ù‡ ÛŒØ§ Ø§Ø¶Ø§ÙÙ‡ Ø´Ø¯Ù‡ Ú©Ù‡ Ù‡Ù†ÙˆØ² Ø°Ø®ÛŒØ±Ù‡ Ù†Ø´Ø¯Ù‡. Ú†Ù‡ Ú©Ø§Ø± Ú©Ù†Ù…ØŸ'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'), child: const Text('Ø§Ù†ØµØ±Ø§Ù')),
        TextButton(onPressed: () => Navigator.pop(ctx, 'discard'), child: const Text('Ø®Ø±ÙˆØ¬ Ø¨Ø¯ÙˆÙ† Ø°Ø®ÛŒØ±Ù‡')),
        if (onSave != null) FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Ø°Ø®ÛŒØ±Ù‡ Ùˆ Ø®Ø±ÙˆØ¬')),
      ],
    ),
  );
  if (choice == 'save' && onSave != null) {
    // onSave() pops the screen itself when it succeeds (with the saved
    // result); returning true here would cause a second, empty pop.
    await onSave();
    return false;
  }
  return choice == 'discard';
}

// ============================== Enums ==============================

enum TxType { expense, income }

enum RecurrenceFrequency { none, weekly, monthly, quarterly, yearly, custom }

enum AccountType { cash, bank, creditCard, savings, other }

enum ScanSource { camera, gallery, pdf }

extension AccountTypeLabel on AccountType {
  String get label {
    switch (this) {
      case AccountType.cash:
        return 'Ù†Ù‚Ø¯ÛŒ';
      case AccountType.bank:
        return 'Ø¨Ø§Ù†Ú©ÛŒ';
      case AccountType.creditCard:
        return 'Ú©Ø§Ø±Øª Ø§Ø¹ØªØ¨Ø§Ø±ÛŒ';
      case AccountType.savings:
        return 'Ù¾Ø³â€ŒØ§Ù†Ø¯Ø§Ø²';
      case AccountType.other:
        return 'Ø³Ø§ÛŒØ±';
    }
  }
}

const kCurrencies = ['EUR', 'USD', 'GBP', 'IRR', 'TRY', 'AED', 'CHF'];

// ============================== Date helpers ==============================

int daysInMonth(int year, int month) {
  final beginningNextMonth = (month < 12) ? DateTime(year, month + 1, 1) : DateTime(year + 1, 1, 1);
  return beginningNextMonth.subtract(const Duration(days: 1)).day;
}

DateTime clampedMonthDate(int year, int month, int day) {
  final maxDay = daysInMonth(year, month);
  return DateTime(year, month, day > maxDay ? maxDay : day);
}

// ============================== Models ==============================

class Category {
  final String id;
  final String name;
  final String? parentId;
  final TxType type;
  final int? iconCodePoint; // custom icon for user-created categories (Material icon codePoint)
  const Category({required this.id, required this.name, this.parentId, required this.type, this.iconCodePoint});

  Category copyWith({String? name, String? parentId, int? iconCodePoint}) => Category(
        id: id,
        name: name ?? this.name,
        parentId: parentId ?? this.parentId,
        type: type,
        iconCodePoint: iconCodePoint ?? this.iconCodePoint,
      );

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'parentId': parentId, 'type': type.name, 'iconCodePoint': iconCodePoint};
  factory Category.fromJson(Map<String, dynamic> j) => Category(
        id: j['id'],
        name: j['name'],
        parentId: j['parentId'],
        type: TxType.values.byName(j['type']),
        iconCodePoint: j['iconCodePoint'],
      );
}

class Account {
  final String id;
  final String name;
  final AccountType type;
  final String currency;
  const Account({required this.id, required this.name, required this.type, required this.currency});

  Account copyWith({String? name, AccountType? type, String? currency}) => Account(
        id: id,
        name: name ?? this.name,
        type: type ?? this.type,
        currency: currency ?? this.currency,
      );

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'type': type.name, 'currency': currency};
  factory Account.fromJson(Map<String, dynamic> j) => Account(
        id: j['id'],
        name: j['name'],
        type: AccountType.values.byName(j['type'] ?? 'bank'),
        currency: j['currency'] ?? 'EUR',
      );
}

class ReceiptItemEntry {
  final String name;
  final double? quantity;
  final double? price;
  const ReceiptItemEntry({required this.name, this.quantity, this.price});

  Map<String, dynamic> toJson() => {'name': name, 'quantity': quantity, 'price': price};
  factory ReceiptItemEntry.fromJson(Map<String, dynamic> j) => ReceiptItemEntry(
        name: j['name'] ?? '',
        quantity: (j['quantity'] as num?)?.toDouble(),
        price: (j['price'] as num?)?.toDouble(),
      );
}

class PayslipDetails {
  final double? brutto;
  final double? netto;
  final double? lohnsteuer;
  final double? solidaritaetszuschlag;
  final double? kirchensteuer;
  final double? krankenversicherung;
  final double? pflegeversicherung;
  final double? rentenversicherung;
  final double? arbeitslosenversicherung;
  final String? steuerklasse;
  final String? arbeitgeber;
  final String? abrechnungsmonat;

  const PayslipDetails({
    this.brutto,
    this.netto,
    this.lohnsteuer,
    this.solidaritaetszuschlag,
    this.kirchensteuer,
    this.krankenversicherung,
    this.pflegeversicherung,
    this.rentenversicherung,
    this.arbeitslosenversicherung,
    this.steuerklasse,
    this.arbeitgeber,
    this.abrechnungsmonat,
  });

  Map<String, dynamic> toJson() => {
        'brutto': brutto,
        'netto': netto,
        'lohnsteuer': lohnsteuer,
        'solidaritaetszuschlag': solidaritaetszuschlag,
        'kirchensteuer': kirchensteuer,
        'krankenversicherung': krankenversicherung,
        'pflegeversicherung': pflegeversicherung,
        'rentenversicherung': rentenversicherung,
        'arbeitslosenversicherung': arbeitslosenversicherung,
        'steuerklasse': steuerklasse,
        'arbeitgeber': arbeitgeber,
        'abrechnungsmonat': abrechnungsmonat,
      };

  factory PayslipDetails.fromJson(Map<String, dynamic> j) => PayslipDetails(
        brutto: (j['brutto'] as num?)?.toDouble(),
        netto: (j['netto'] as num?)?.toDouble(),
        lohnsteuer: (j['lohnsteuer'] as num?)?.toDouble(),
        solidaritaetszuschlag: (j['solidaritaetszuschlag'] as num?)?.toDouble(),
        kirchensteuer: (j['kirchensteuer'] as num?)?.toDouble(),
        krankenversicherung: (j['krankenversicherung'] as num?)?.toDouble(),
        pflegeversicherung: (j['pflegeversicherung'] as num?)?.toDouble(),
        rentenversicherung: (j['rentenversicherung'] as num?)?.toDouble(),
        arbeitslosenversicherung: (j['arbeitslosenversicherung'] as num?)?.toDouble(),
        steuerklasse: j['steuerklasse'],
        arbeitgeber: j['arbeitgeber'],
        abrechnungsmonat: j['abrechnungsmonat'],
      );
}

class Transaction {
  final String id;
  final TxType type;
  final double amount;
  final String categoryId;
  final String accountId;
  final DateTime date;
  final String note;
  final RecurrenceFrequency recurrence;
  final int? recurrenceDay; // monthly: 1-31, clamped to month length when computing dates
  final int? recurrenceWeekday; // weekly: 1=Mon .. 7=Sun
  final int? recurrenceIntervalDays; // custom: every N days
  final int? installments; // total number of occurrences (optional)
  final DateTime? recurrenceEndDate; // last payment date (optional, alternative to installments)
  final bool draft; // true = saved from a scan but not yet confirmed by the user
  final List<ReceiptItemEntry> items; // structured line items from a scanned receipt (optional)
  final bool notifyEnabled; // whether the notification section is active at all
  final bool notifyLastTwoEnabled; // remind 1 day before the last 2 occurrences
  final String notifyMessage; // custom reminder text (e.g. "cancel this subscription")
  final int? notifyDaysBeforeEach; // also remind this many days before EVERY installment's due date
  final PayslipDetails? payslipDetails; // structured fields extracted from a scanned payslip

  const Transaction({
    required this.id,
    required this.type,
    required this.amount,
    required this.categoryId,
    required this.accountId,
    required this.date,
    this.note = '',
    this.recurrence = RecurrenceFrequency.none,
    this.recurrenceDay,
    this.recurrenceWeekday,
    this.recurrenceIntervalDays,
    this.installments,
    this.recurrenceEndDate,
    this.draft = false,
    this.items = const [],
    this.notifyEnabled = false,
    this.notifyLastTwoEnabled = false,
    this.notifyMessage = '',
    this.notifyDaysBeforeEach,
    this.payslipDetails,
  });

  bool get isRecurring => recurrence != RecurrenceFrequency.none;

  Transaction copyWith({
    TxType? type,
    double? amount,
    String? categoryId,
    String? accountId,
    DateTime? date,
    String? note,
    RecurrenceFrequency? recurrence,
    int? recurrenceDay,
    int? recurrenceWeekday,
    int? recurrenceIntervalDays,
    int? installments,
    DateTime? recurrenceEndDate,
    bool? draft,
    List<ReceiptItemEntry>? items,
    bool? notifyEnabled,
    bool? notifyLastTwoEnabled,
    String? notifyMessage,
    int? notifyDaysBeforeEach,
    bool clearNotifyDaysBeforeEach = false,
    PayslipDetails? payslipDetails,
    bool clearPayslipDetails = false,
    bool clearRecurrenceDay = false,
    bool clearRecurrenceWeekday = false,
    bool clearRecurrenceIntervalDays = false,
    bool clearInstallments = false,
    bool clearRecurrenceEndDate = false,
  }) =>
      Transaction(
        id: id,
        type: type ?? this.type,
        amount: amount ?? this.amount,
        categoryId: categoryId ?? this.categoryId,
        accountId: accountId ?? this.accountId,
        date: date ?? this.date,
        note: note ?? this.note,
        recurrence: recurrence ?? this.recurrence,
        recurrenceDay: clearRecurrenceDay ? null : (recurrenceDay ?? this.recurrenceDay),
        recurrenceWeekday: clearRecurrenceWeekday ? null : (recurrenceWeekday ?? this.recurrenceWeekday),
        recurrenceIntervalDays: clearRecurrenceIntervalDays ? null : (recurrenceIntervalDays ?? this.recurrenceIntervalDays),
        installments: clearInstallments ? null : (installments ?? this.installments),
        recurrenceEndDate: clearRecurrenceEndDate ? null : (recurrenceEndDate ?? this.recurrenceEndDate),
        draft: draft ?? this.draft,
        items: items ?? this.items,
        notifyEnabled: notifyEnabled ?? this.notifyEnabled,
        notifyLastTwoEnabled: notifyLastTwoEnabled ?? this.notifyLastTwoEnabled,
        notifyMessage: notifyMessage ?? this.notifyMessage,
        notifyDaysBeforeEach: clearNotifyDaysBeforeEach ? null : (notifyDaysBeforeEach ?? this.notifyDaysBeforeEach),
        payslipDetails: clearPayslipDetails ? null : (payslipDetails ?? this.payslipDetails),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'amount': amount,
        'categoryId': categoryId,
        'accountId': accountId,
        'date': date.toIso8601String(),
        'note': note,
        'recurrence': recurrence.name,
        'recurrenceDay': recurrenceDay,
        'recurrenceWeekday': recurrenceWeekday,
        'recurrenceIntervalDays': recurrenceIntervalDays,
        'installments': installments,
        'recurrenceEndDate': recurrenceEndDate?.toIso8601String(),
        'draft': draft,
        'items': items.map((e) => e.toJson()).toList(),
        'notifyEnabled': notifyEnabled,
        'notifyLastTwoEnabled': notifyLastTwoEnabled,
        'notifyMessage': notifyMessage,
        'notifyDaysBeforeEach': notifyDaysBeforeEach,
        'payslipDetails': payslipDetails?.toJson(),
      };

  factory Transaction.fromJson(Map<String, dynamic> j) {
    RecurrenceFrequency freq;
    if (j['recurrence'] != null) {
      freq = RecurrenceFrequency.values.byName(j['recurrence']);
    } else if (j['recurring'] == true) {
      // backward compatibility with the very first schema
      freq = RecurrenceFrequency.monthly;
    } else {
      freq = RecurrenceFrequency.none;
    }
    return Transaction(
      id: j['id'],
      type: TxType.values.byName(j['type']),
      amount: (j['amount'] as num).toDouble(),
      categoryId: j['categoryId'],
      accountId: j['accountId'] ?? 'default',
      date: DateTime.parse(j['date']),
      note: j['note'] ?? '',
      recurrence: freq,
      recurrenceDay: j['recurrenceDay'],
      recurrenceWeekday: j['recurrenceWeekday'],
      recurrenceIntervalDays: j['recurrenceIntervalDays'],
      installments: j['installments'],
      recurrenceEndDate: j['recurrenceEndDate'] != null ? DateTime.parse(j['recurrenceEndDate']) : null,
      draft: j['draft'] ?? false,
      items: (j['items'] as List<dynamic>?)?.map((e) => ReceiptItemEntry.fromJson(e)).toList() ?? const [],
      notifyEnabled: j['notifyEnabled'] ?? false,
      notifyLastTwoEnabled: j['notifyLastTwoEnabled'] ?? false,
      notifyMessage: j['notifyMessage'] ?? '',
      notifyDaysBeforeEach: j['notifyDaysBeforeEach'],
      payslipDetails: j['payslipDetails'] != null ? PayslipDetails.fromJson(j['payslipDetails']) : null,
    );
  }
}

DateTime? nextOccurrencePreview(Transaction t) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  switch (t.recurrence) {
    case RecurrenceFrequency.monthly:
      if (t.recurrenceDay == null) return null;
      var d = clampedMonthDate(today.year, today.month, t.recurrenceDay!);
      if (d.isBefore(today)) {
        final ny = today.month == 12 ? today.year + 1 : today.year;
        final nm = today.month == 12 ? 1 : today.month + 1;
        d = clampedMonthDate(ny, nm, t.recurrenceDay!);
      }
      return d;
    case RecurrenceFrequency.weekly:
      if (t.recurrenceWeekday == null) return null;
      var diff = (t.recurrenceWeekday! - today.weekday) % 7;
      if (diff < 0) diff += 7;
      return today.add(Duration(days: diff));
    case RecurrenceFrequency.custom:
      if (t.recurrenceIntervalDays == null || t.recurrenceIntervalDays! <= 0) return null;
      var next = t.date;
      while (!next.isAfter(today)) {
        next = next.add(Duration(days: t.recurrenceIntervalDays!));
      }
      return next;
    case RecurrenceFrequency.quarterly:
      if (t.recurrenceDay == null) return null;
      var probe = clampedMonthDate(t.date.year, t.date.month, t.recurrenceDay!);
      while (!probe.isAfter(today)) {
        var m = probe.month + 3;
        var y = probe.year;
        while (m > 12) {
          m -= 12;
          y++;
        }
        probe = clampedMonthDate(y, m, t.recurrenceDay!);
      }
      return probe;
    case RecurrenceFrequency.yearly:
      var d = clampedMonthDate(today.year, t.date.month, t.date.day);
      if (d.isBefore(today)) d = clampedMonthDate(today.year + 1, t.date.month, t.date.day);
      return d;
    case RecurrenceFrequency.none:
      return null;
  }
}

/// Generates the full sequence of occurrence dates for a recurring
/// transaction, starting from its own date, following its recurrence
/// pattern, until either the configured installment count or end date is
/// reached. Returns an empty list for non-recurring or truly unlimited
/// (no installments and no end date) transactions, since "last occurrence"
/// has no meaning for those.
List<DateTime> computeRecurrenceOccurrences(Transaction t) {
  if (!t.isRecurring) return [];
  final unlimited = t.installments == null && t.recurrenceEndDate == null;
  final result = <DateTime>[];
  var current = t.date;
  var count = 0;
  // For a truly unlimited series there is no real "last" occurrence; cap
  // generation to a reasonable window (used only for the optional
  // per-installment reminder, never for the "last 2" reminder).
  final hardCap = unlimited ? 200 : 1000;
  while (count < hardCap) {
    if (t.recurrenceEndDate != null && current.isAfter(t.recurrenceEndDate!)) break;
    result.add(current);
    count++;
    if (t.installments != null && count >= t.installments!) break;
    DateTime next;
    switch (t.recurrence) {
      case RecurrenceFrequency.monthly:
        final day = t.recurrenceDay ?? current.day;
        var y = current.year;
        var m = current.month + 1;
        if (m > 12) {
          m = 1;
          y++;
        }
        next = clampedMonthDate(y, m, day);
        break;
      case RecurrenceFrequency.weekly:
        next = current.add(const Duration(days: 7));
        break;
      case RecurrenceFrequency.custom:
        next = current.add(Duration(days: t.recurrenceIntervalDays ?? 30));
        break;
      case RecurrenceFrequency.quarterly:
        final day = t.recurrenceDay ?? current.day;
        var y = current.year;
        var m = current.month + 3;
        while (m > 12) {
          m -= 12;
          y++;
        }
        next = clampedMonthDate(y, m, day);
        break;
      case RecurrenceFrequency.yearly:
        next = clampedMonthDate(current.year + 1, current.month, current.day);
        break;
      case RecurrenceFrequency.none:
        return result;
    }
    current = next;
  }
  return result;
}

// ============================== Notifications ==============================

/// Reminds the user shortly before the last two occurrences of a recurring
/// transaction (useful e.g. to remember to cancel a subscription in time).
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    tz_data.initializeTimeZones();
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(const InitializationSettings(android: androidInit));
    _initialized = true;
  }

  Future<void> requestPermission() async {
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  int _idFor(String txId, int slot) => (txId.hashCode & 0xffff) * 1000 + slot;

  Future<void> cancelForTransaction(String txId) async {
    // slot 0/1 = second-to-last/last reminders, slots 2..201 = optional
    // per-installment reminders (capped at 200 upcoming installments).
    for (var slot = 0; slot < 202; slot++) {
      await _plugin.cancel(_idFor(txId, slot));
    }
  }

  /// Computes an absolute schedule instant for a given local wall-clock
  /// [target] time without needing the device's IANA timezone name: the
  /// remaining real-world duration until that local moment is computed via
  /// plain [DateTime] (which is always local), then applied on top of the
  /// current UTC instant.
  tz.TZDateTime _asTZDateTime(DateTime target) {
    final delay = target.difference(DateTime.now());
    return tz.TZDateTime.now(tz.UTC).add(delay);
  }

  Future<void> scheduleForTransaction(Transaction t, String categoryName) async {
    await cancelForTransaction(t.id);
    if (!t.notifyEnabled) return;
    final occurrences = computeRecurrenceOccurrences(t);
    if (occurrences.isEmpty) return;
    final now = DateTime.now();
    final body = t.notifyMessage.trim().isNotEmpty ? t.notifyMessage.trim() : 'Ø³Ø±Ø±Ø³ÛŒØ¯ Ø§ÛŒÙ† ØªØ±Ø§Ú©Ù†Ø´ ØªÚ©Ø±Ø§Ø±Ø´ÙˆÙ†Ø¯Ù‡ Ù†Ø²Ø¯ÛŒÚ© Ø§Ø³Øª.';
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'recurring_due',
        'ÛŒØ§Ø¯Ø¢ÙˆØ±ÛŒ ØªØ±Ø§Ú©Ù†Ø´â€ŒÙ‡Ø§ÛŒ ØªÚ©Ø±Ø§Ø±Ø´ÙˆÙ†Ø¯Ù‡',
        channelDescription: 'ÛŒØ§Ø¯Ø¢ÙˆØ±ÛŒ Ù‚Ø¨Ù„ Ø§Ø² Ø³Ø±Ø±Ø³ÛŒØ¯Ù‡Ø§ÛŒ ÛŒÚ© ØªØ±Ø§Ú©Ù†Ø´ ØªÚ©Ø±Ø§Ø±Ø´ÙˆÙ†Ø¯Ù‡',
        importance: Importance.high,
        priority: Priority.high,
      ),
    );
    final targets = <int, DateTime>{};
    final unlimited = t.installments == null && t.recurrenceEndDate == null;
    if (t.notifyLastTwoEnabled && !unlimited) {
      if (occurrences.length >= 2) targets[0] = occurrences[occurrences.length - 2];
      targets[1] = occurrences.last;
    }
    for (final entry in targets.entries) {
      final when = DateTime(entry.value.year, entry.value.month, entry.value.day, 9).subtract(const Duration(days: 1));
      if (!when.isAfter(now)) continue;
      await _plugin.zonedSchedule(
        _idFor(t.id, entry.key),
        categoryName,
        body,
        _asTZDateTime(when),
        details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      );
    }
    final days = t.notifyDaysBeforeEach;
    if (days != null && days > 0) {
      final capped = occurrences.take(200).toList();
      for (var i = 0; i < capped.length; i++) {
        final due = capped[i];
        final when = DateTime(due.year, due.month, due.day, 9).subtract(Duration(days: days));
        if (!when.isAfter(now)) continue;
        await _plugin.zonedSchedule(
          _idFor(t.id, 2 + i),
          categoryName,
          '$days Ø±ÙˆØ² ØªØ§ Ø³Ø±Ø±Ø³ÛŒØ¯ Ø§ÛŒÙ† Ù‚Ø³Ø· (${ltr(DateFormat('dd.MM.yyyy').format(due))})${t.notifyMessage.trim().isNotEmpty ? ' â€¢ ${t.notifyMessage.trim()}' : ''}',
          _asTZDateTime(when),
          details,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
        );
      }
    }
  }
}

// ============================== Default seed data ==============================

const defaultCategories = <Category>[
  Category(id: 'e_food', name: 'Ø®ÙˆØ±Ø§Ú© Ùˆ Ø®ÙˆØ§Ø±Ø¨Ø§Ø±', type: TxType.expense),
  Category(id: 'e_food_market', name: 'Ø³ÙˆÙ¾Ø±Ù…Ø§Ø±Ú©Øª', parentId: 'e_food', type: TxType.expense),
  Category(id: 'e_food_restaurant', name: 'Ø±Ø³ØªÙˆØ±Ø§Ù†', parentId: 'e_food', type: TxType.expense),
  Category(id: 'e_food_produce', name: 'Ù…ÛŒÙˆÙ‡ Ùˆ ØªØ±Ù‡â€ŒØ¨Ø§Ø±', parentId: 'e_food', type: TxType.expense),
  Category(id: 'e_housing', name: 'Ù…Ø³Ú©Ù†', type: TxType.expense),
  Category(id: 'e_housing_rent', name: 'Ø§Ø¬Ø§Ø±Ù‡ / Ø±Ù‡Ù†', parentId: 'e_housing', type: TxType.expense),
  Category(id: 'e_housing_fee', name: 'Ø´Ø§Ø±Ú˜ Ø³Ø§Ø®ØªÙ…Ø§Ù†', parentId: 'e_housing', type: TxType.expense),
  Category(id: 'e_housing_repair', name: 'ØªØ¹Ù…ÛŒØ±Ø§Øª', parentId: 'e_housing', type: TxType.expense),
  Category(id: 'e_transport', name: 'Ø­Ù…Ù„ Ùˆ Ù†Ù‚Ù„', type: TxType.expense),
  Category(id: 'e_transport_fuel', name: 'Ø¨Ù†Ø²ÛŒÙ†', parentId: 'e_transport', type: TxType.expense),
  Category(id: 'e_transport_repair', name: 'ØªØ¹Ù…ÛŒØ± Ø®ÙˆØ¯Ø±Ùˆ', parentId: 'e_transport', type: TxType.expense),
  Category(id: 'e_transport_public', name: 'Ø­Ù…Ù„â€ŒÙˆÙ†Ù‚Ù„ Ø¹Ù…ÙˆÙ…ÛŒ', parentId: 'e_transport', type: TxType.expense),
  Category(id: 'e_car', name: 'Ø®ÙˆØ¯Ø±Ùˆ', type: TxType.expense),
  Category(id: 'e_car_insurance', name: 'Ø¨ÛŒÙ…Ù‡ Ø®ÙˆØ¯Ø±Ùˆ', parentId: 'e_car', type: TxType.expense),
  Category(id: 'e_car_service', name: 'ØªØ¹Ù…ÛŒØ± Ùˆ Ø³Ø±ÙˆÛŒØ³', parentId: 'e_car', type: TxType.expense),
  Category(id: 'e_car_fuel', name: 'Ø¨Ù†Ø²ÛŒÙ†', parentId: 'e_car', type: TxType.expense),
  Category(id: 'e_car_fine', name: 'Ø¬Ø±ÛŒÙ…Ù‡ Ø±Ø§Ù†Ù†Ø¯Ú¯ÛŒ', parentId: 'e_car', type: TxType.expense),
  Category(id: 'e_car_parking', name: 'Ù¾Ø§Ø±Ú©ÛŒÙ†Ú¯', parentId: 'e_car', type: TxType.expense),
  Category(id: 'e_bills', name: 'Ù‚Ø¨ÙˆØ¶', type: TxType.expense),
  Category(id: 'e_bills_power', name: 'Ø¨Ø±Ù‚', parentId: 'e_bills', type: TxType.expense),
  Category(id: 'e_bills_water', name: 'Ø¢Ø¨', parentId: 'e_bills', type: TxType.expense),
  Category(id: 'e_bills_gas', name: 'Ú¯Ø§Ø²', parentId: 'e_bills', type: TxType.expense),
  Category(id: 'e_bills_internet', name: 'Ø§ÛŒÙ†ØªØ±Ù†Øª', parentId: 'e_bills', type: TxType.expense),
  Category(id: 'e_bills_phone', name: 'ØªÙ„ÙÙ†', parentId: 'e_bills', type: TxType.expense),
  Category(id: 'e_health', name: 'Ø¯Ø±Ù…Ø§Ù†', type: TxType.expense),
  Category(id: 'e_leisure', name: 'ØªÙØ±ÛŒØ­', type: TxType.expense),
  Category(id: 'e_clothing', name: 'Ù¾ÙˆØ´Ø§Ú©', type: TxType.expense),
  Category(id: 'e_loans', name: 'Ø§Ù‚Ø³Ø§Ø· Ùˆ ÙˆØ§Ù…', type: TxType.expense),
  Category(id: 'e_loans_car', name: 'Ù‚Ø³Ø· Ø®ÙˆØ¯Ø±Ùˆ', parentId: 'e_loans', type: TxType.expense),
  Category(id: 'e_loans_home', name: 'Ù‚Ø³Ø· Ù…Ø³Ú©Ù†', parentId: 'e_loans', type: TxType.expense),
  Category(id: 'e_loans_personal', name: 'ÙˆØ§Ù… Ø´Ø®ØµÛŒ', parentId: 'e_loans', type: TxType.expense),
  Category(id: 'e_loans_installment_purchase', name: 'Ø®Ø±ÛŒØ¯ Ù‚Ø³Ø·ÛŒ', parentId: 'e_loans', type: TxType.expense),
  Category(id: 'e_subscription', name: 'Ø§Ø´ØªØ±Ø§Ú©', type: TxType.expense),
  Category(id: 'e_subscription_software', name: 'Ø§Ø´ØªØ±Ø§Ú© Ù†Ø±Ù…â€ŒØ§ÙØ²Ø§Ø±', parentId: 'e_subscription', type: TxType.expense),
  Category(id: 'e_insurance', name: 'Ø¨ÛŒÙ…Ù‡', type: TxType.expense),
  Category(id: 'e_misc', name: 'Ù…ØªÙØ±Ù‚Ù‡', type: TxType.expense),
  Category(id: 'i_salary', name: 'Ø­Ù‚ÙˆÙ‚', type: TxType.income),
  Category(id: 'i_freelance', name: 'ÙØ±ÛŒÙ„Ù†Ø³Ø±ÛŒ', type: TxType.income),
  Category(id: 'i_investment', name: 'Ø³Ø±Ù…Ø§ÛŒÙ‡â€ŒÚ¯Ø°Ø§Ø±ÛŒ', type: TxType.income),
  Category(id: 'i_gift', name: 'Ù‡Ø¯ÛŒÙ‡', type: TxType.income),
  Category(id: 'i_misc', name: 'Ù…ØªÙØ±Ù‚Ù‡', type: TxType.income),
];

const defaultAccount = Account(id: 'default', name: 'Ø­Ø³Ø§Ø¨ Ø§ØµÙ„ÛŒ', type: AccountType.bank, currency: 'EUR');

const kCategoryIcons = <String, IconData>{
  'e_food': Icons.restaurant_outlined,
  'e_housing': Icons.home_outlined,
  'e_transport': Icons.directions_bus_outlined,
  'e_car': Icons.directions_car_outlined,
  'e_bills': Icons.receipt_long_outlined,
  'e_health': Icons.medical_services_outlined,
  'e_leisure': Icons.sports_esports_outlined,
  'e_clothing': Icons.checkroom_outlined,
  'e_loans': Icons.credit_card_outlined,
  'e_loans_installment_purchase': Icons.shopping_bag_outlined,
  'e_subscription': Icons.subscriptions_outlined,
  'e_subscription_software': Icons.laptop_chromebook_outlined,
  'e_insurance': Icons.health_and_safety_outlined,
  'e_car_parking': Icons.local_parking_outlined,
  'e_misc': Icons.more_horiz,
  'i_salary': Icons.payments_outlined,
  'i_freelance': Icons.laptop_mac_outlined,
  'i_investment': Icons.trending_up,
  'i_gift': Icons.card_giftcard_outlined,
  'i_misc': Icons.more_horiz,
};

IconData iconForCategory(Category? c, List<Category> all) {
  if (c?.iconCodePoint != null) {
    return IconData(c!.iconCodePoint!, fontFamily: 'MaterialIcons');
  }
  var cur = c;
  while (cur != null) {
    final icon = kCategoryIcons[cur.id];
    if (icon != null) return icon;
    if (cur.parentId == null) break;
    final matches = all.where((x) => x.id == cur!.parentId).toList();
    cur = matches.isEmpty ? null : matches.first;
  }
  return (c?.type ?? TxType.expense) == TxType.expense ? Icons.remove_circle_outline : Icons.add_circle_outline;
}

// Keyword -> icon hints used to pick an icon for a newly created category.
// Checked first (fast, offline); Gemini is used as a fallback for names
// that don't match any of these.
const _iconKeywordHints = <String, IconData>{
  'Ø®ÙˆØ±Ø§Ú©': Icons.restaurant_outlined,
  'ØºØ°Ø§': Icons.restaurant_outlined,
  'Ø±Ø³ØªÙˆØ±Ø§Ù†': Icons.restaurant_outlined,
  'Ú©Ø§ÙÙ‡': Icons.local_cafe_outlined,
  'Ù‚Ù‡ÙˆÙ‡': Icons.local_cafe_outlined,
  'Ø®Ø§Ù†Ù‡': Icons.home_outlined,
  'Ù…Ø³Ú©Ù†': Icons.home_outlined,
  'Ø§Ø¬Ø§Ø±Ù‡': Icons.home_outlined,
  'Ø®ÙˆØ¯Ø±Ùˆ': Icons.directions_car_outlined,
  'Ù…Ø§Ø´ÛŒÙ†': Icons.directions_car_outlined,
  'Ø¨Ù†Ø²ÛŒÙ†': Icons.local_gas_station_outlined,
  'Ø³ÙˆØ®Øª': Icons.local_gas_station_outlined,
  'Ù¾Ø§Ø±Ú©ÛŒÙ†Ú¯': Icons.local_parking_outlined,
  'ØªØ¹Ù…ÛŒØ±': Icons.build_outlined,
  'Ø­Ù…Ù„â€ŒÙˆÙ†Ù‚Ù„': Icons.directions_bus_outlined,
  'Ø§ØªÙˆØ¨ÙˆØ³': Icons.directions_bus_outlined,
  'Ù…ØªØ±Ùˆ': Icons.subway_outlined,
  'Ù‚Ø·Ø§Ø±': Icons.train_outlined,
  'Ù‡ÙˆØ§Ù¾ÛŒÙ…Ø§': Icons.flight_outlined,
  'Ø³ÙØ±': Icons.flight_outlined,
  'Ø¨Ø±Ù‚': Icons.bolt_outlined,
  'Ø¢Ø¨': Icons.water_drop_outlined,
  'Ú¯Ø§Ø²': Icons.local_fire_department_outlined,
  'Ø§ÛŒÙ†ØªØ±Ù†Øª': Icons.wifi_outlined,
  'ØªÙ„ÙÙ†': Icons.phone_iphone_outlined,
  'Ù…ÙˆØ¨Ø§ÛŒÙ„': Icons.phone_iphone_outlined,
  'Ø¯Ø±Ù…Ø§Ù†': Icons.medical_services_outlined,
  'Ø¯Ø§Ø±Ùˆ': Icons.medication_outlined,
  'Ù¾Ø²Ø´Ú©': Icons.medical_services_outlined,
  'Ø¯Ù†Ø¯Ø§Ù†': Icons.medical_services_outlined,
  'Ø¨ÛŒÙ…Ù‡': Icons.health_and_safety_outlined,
  'ÙˆØ±Ø²Ø´': Icons.fitness_center_outlined,
  'Ø¨Ø§Ø´Ú¯Ø§Ù‡': Icons.fitness_center_outlined,
  'ØªÙØ±ÛŒØ­': Icons.sports_esports_outlined,
  'Ø³ÛŒÙ†Ù…Ø§': Icons.movie_outlined,
  'ÙÛŒÙ„Ù…': Icons.movie_outlined,
  'Ù…ÙˆØ³ÛŒÙ‚ÛŒ': Icons.music_note_outlined,
  'Ù¾ÙˆØ´Ø§Ú©': Icons.checkroom_outlined,
  'Ù„Ø¨Ø§Ø³': Icons.checkroom_outlined,
  'Ú©ÙØ´': Icons.checkroom_outlined,
  'Ù‚Ø³Ø·': Icons.credit_card_outlined,
  'Ø§Ù‚Ø³Ø§Ø·': Icons.credit_card_outlined,
  'ÙˆØ§Ù…': Icons.credit_card_outlined,
  'Ø§Ø´ØªØ±Ø§Ú©': Icons.subscriptions_outlined,
  'Ø­Ù‚ÙˆÙ‚': Icons.payments_outlined,
  'ÙØ±ÛŒÙ„Ù†Ø³': Icons.laptop_mac_outlined,
  'Ø³Ø±Ù…Ø§ÛŒÙ‡': Icons.trending_up,
  'Ø³Ù‡Ø§Ù…': Icons.trending_up,
  'Ù‡Ø¯ÛŒÙ‡': Icons.card_giftcard_outlined,
  'Ú©ØªØ§Ø¨': Icons.menu_book_outlined,
  'Ø¢Ù…ÙˆØ²Ø´': Icons.school_outlined,
  'Ù…Ø¯Ø±Ø³Ù‡': Icons.school_outlined,
  'Ø¯Ø§Ù†Ø´Ú¯Ø§Ù‡': Icons.school_outlined,
  'Ø¨Ú†Ù‡': Icons.child_care_outlined,
  'Ú©ÙˆØ¯Ú©': Icons.child_care_outlined,
  'Ø­ÛŒÙˆØ§Ù†': Icons.pets_outlined,
  'Ø®ÛŒØ±ÛŒÙ‡': Icons.volunteer_activism_outlined,
  'Ú©Ù…Ú©': Icons.volunteer_activism_outlined,
  'Ù…Ø§Ù„ÛŒØ§Øª': Icons.receipt_long_outlined,
  'Ø¬Ø±ÛŒÙ…Ù‡': Icons.gavel_outlined,
  'Ø¢Ø±Ø§ÛŒØ´': Icons.face_retouching_natural_outlined,
  'Ø²ÛŒØ¨Ø§ÛŒÛŒ': Icons.face_retouching_natural_outlined,
};

Future<IconData?> _suggestIconViaGemini(String categoryName) async {
  final key = await Store.loadGeminiKey();
  if (key == null || key.trim().isEmpty) return null;
  try {
    final options = _iconKeywordHints.keys.join('ØŒ ');
    final uri = Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$_geminiModel:generateContent?key=$key');
    final body = jsonEncode({
      'contents': [
        {
          'parts': [
            {
              'text':
                  'ÛŒÚ© Ø¯Ø³ØªÙ‡â€ŒØ¨Ù†Ø¯ÛŒ Ù…Ø§Ù„ÛŒ Ø¨Ø§ Ù†Ø§Ù… "$categoryName" Ø¯Ø§Ø±ÛŒÙ…. Ø§Ø² Ø§ÛŒÙ† Ù„ÛŒØ³Øª Ú©Ù„Ù…Ø§ØªØŒ ÙÙ‚Ø· Ø¯Ù‚ÛŒÙ‚Ø§Ù‹ ÛŒÚ©ÛŒ Ø±Ø§ Ú©Ù‡ Ù…ÙÙ‡ÙˆÙ…Ø§Ù‹ Ù†Ø²Ø¯ÛŒÚ©â€ŒØªØ±ÛŒÙ† Ø¨Ù‡ Ø§ÛŒÙ† Ø¯Ø³ØªÙ‡â€ŒØ¨Ù†Ø¯ÛŒ Ø§Ø³Øª Ø§Ù†ØªØ®Ø§Ø¨ Ú©Ù† Ùˆ ÙÙ‚Ø· Ù‡Ù…Ø§Ù† ÛŒÚ© Ú©Ù„Ù…Ù‡ Ø±Ø§ Ø¨Ø¯ÙˆÙ† Ù‡ÛŒÚ† ØªÙˆØ¶ÛŒØ­ Ø¯ÛŒÚ¯Ø±ÛŒ Ø¨Ø±Ú¯Ø±Ø¯Ø§Ù†: $options',
            },
          ],
        },
      ],
    });
    final resp = await http.post(uri, headers: {'Content-Type': 'application/json'}, body: body).timeout(const Duration(seconds: 8));
    if (resp.statusCode != 200) return null;
    final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    final text = decoded['candidates']?[0]?['content']?['parts']?[0]?['text']?.toString().trim();
    if (text == null) return null;
    for (final k in _iconKeywordHints.keys) {
      if (text.contains(k)) return _iconKeywordHints[k];
    }
  } catch (_) {
    // best-effort only; fall back to a generic icon on any failure
  }
  return null;
}

Future<IconData> suggestIconForCategory(String name, TxType type) async {
  for (final entry in _iconKeywordHints.entries) {
    if (name.contains(entry.key)) return entry.value;
  }
  final aiIcon = await _suggestIconViaGemini(name);
  if (aiIcon != null) return aiIcon;
  return type == TxType.expense ? Icons.category_outlined : Icons.attach_money_outlined;
}

// ============================== Storage ==============================

class Store {
  static const _txKey = 'transactions';
  static const _catKey = 'categories_v2';
  static const _accKey = 'accounts_v2';
  static const _geminiKey = 'gemini_api_key';

  static Future<String?> loadGeminiKey() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_geminiKey);
  }

  static Future<void> saveGeminiKey(String key) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_geminiKey, key);
  }

  static Future<List<Transaction>> loadTransactions() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getStringList(_txKey) ?? [];
    return raw.map((s) => Transaction.fromJson(jsonDecode(s))).toList();
  }

  static Future<void> saveTransactions(List<Transaction> list) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(_txKey, list.map((t) => jsonEncode(t.toJson())).toList());
  }

  static Future<List<Category>> loadCategories() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getStringList(_catKey);
    List<Category> list;
    var changed = false;
    if (raw == null) {
      list = List.of(defaultCategories);
      changed = true;
    } else {
      list = raw.map((s) => Category.fromJson(jsonDecode(s))).toList();
    }
    if (!list.any((c) => c.id == 'e_car')) {
      list = [...list, ...defaultCategories.where((c) => c.id == 'e_car' || c.parentId == 'e_car')];
      changed = true;
    }
    if (list.any((c) => c.id == 'e_car_installment')) {
      // duplicate of e_loans_car, removed after the fact: reassign any
      // transactions that used it to the parent "Ø®ÙˆØ¯Ø±Ùˆ" category instead.
      list = list.where((c) => c.id != 'e_car_installment').toList();
      final tx = await loadTransactions();
      var txChanged = false;
      final newTx = tx.map((t) {
        if (t.categoryId == 'e_car_installment') {
          txChanged = true;
          return t.copyWith(categoryId: 'e_car');
        }
        return t;
      }).toList();
      if (txChanged) await saveTransactions(newTx);
      changed = true;
    }
    if (!list.any((c) => c.id == 'e_car_parking') &&
        !list.any((c) => c.parentId == 'e_car' && c.type == TxType.expense && c.name.trim() == 'Ù¾Ø§Ø±Ú©ÛŒÙ†Ú¯')) {
      list = [...list, ...defaultCategories.where((c) => c.id == 'e_car_parking')];
      changed = true;
    }
    for (final newId in ['e_loans_installment_purchase', 'e_subscription', 'e_insurance', 'e_subscription_software']) {
      final def = defaultCategories.firstWhere((c) => c.id == newId);
      final alreadyById = list.any((c) => c.id == newId);
      final alreadyByName =
          list.any((c) => c.parentId == def.parentId && c.type == def.type && c.name.trim() == def.name.trim());
      if (!alreadyById && !alreadyByName) {
        list = [...list, def];
        changed = true;
      }
    }
    if (changed) await saveCategories(list);
    return list;
  }

  static Future<void> saveCategories(List<Category> list) async {
    // Sort alphabetically (by name) every time; since children are always
    // filtered by parentId when rendered, a flat alphabetical sort keeps
    // each level's items alphabetical too.
    final sorted = List.of(list)..sort((a, b) => a.name.compareTo(b.name));
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(_catKey, sorted.map((c) => jsonEncode(c.toJson())).toList());
  }

  static Future<List<Account>> loadAccounts() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getStringList(_accKey);
    if (raw == null) {
      await saveAccounts(const [defaultAccount]);
      return [defaultAccount];
    }
    return raw.map((s) => Account.fromJson(jsonDecode(s))).toList();
  }

  static Future<void> saveAccounts(List<Account> list) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(_accKey, list.map((a) => jsonEncode(a.toJson())).toList());
  }
}

// ============================== App shell ==============================

class MoneyApp extends StatelessWidget {
  const MoneyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ù…Ø¯ÛŒØ±ÛŒØª Ù…Ø§Ù„ÛŒ Ø´Ø®ØµÛŒ',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      builder: (context, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
      home: const HomeScreen(),
    );
  }
}

class AppDrawer extends StatelessWidget {
  final int currentIndex;
  const AppDrawer({required this.currentIndex, super.key});

  @override
  Widget build(BuildContext context) {
    Widget item(int i, IconData icon, String label, Widget Function() builder) => ListTile(
          leading: Icon(icon),
          title: Text(label),
          selected: currentIndex == i,
          onTap: () {
            Navigator.pop(context);
            if (currentIndex == i) return;
            if (i == 0) {
              // Go back to the single root Home instance instead of stacking
              // a new one, so the back button naturally exits from Home.
              Navigator.popUntil(context, (route) => route.isFirst);
            } else {
              Navigator.push(context, MaterialPageRoute(builder: (_) => builder()));
            }
          },
        );
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            const DrawerHeader(
              child: Align(
                alignment: Alignment.centerRight,
                child: Text('Ù…Ø¯ÛŒØ±ÛŒØª Ù…Ø§Ù„ÛŒ Ø´Ø®ØµÛŒ', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              ),
            ),
            item(0, Icons.home_outlined, 'Ø®Ø§Ù†Ù‡', () => const HomeScreen()),
            item(1, Icons.category_outlined, 'Ù…Ø¯ÛŒØ±ÛŒØª Ø¯Ø³ØªÙ‡â€ŒØ¨Ù†Ø¯ÛŒâ€ŒÙ‡Ø§', () => const CategoryManagementScreen()),
            item(2, Icons.account_balance_wallet_outlined, 'Ø­Ø³Ø§Ø¨â€ŒÙ‡Ø§', () => const AccountManagementScreen()),
            item(3, Icons.settings_outlined, 'ØªÙ†Ø¸ÛŒÙ…Ø§Øª', () => const SettingsScreen()),
            item(4, Icons.repeat, 'ØªØ±Ø§Ú©Ù†Ø´â€ŒÙ‡Ø§ÛŒ ØªÚ©Ø±Ø§Ø±Ø´ÙˆÙ†Ø¯Ù‡', () => const RecurringTransactionsScreen()),
            item(5, Icons.category_outlined, 'ØªØ±Ø§Ú©Ù†Ø´â€ŒÙ‡Ø§ÛŒ ØªØ­Øªâ€ŒØªØ£Ø«ÛŒØ± Ø­Ø°Ù Ø¯Ø³ØªÙ‡â€ŒØ¨Ù†Ø¯ÛŒ', () => const AffectedTransactionsScreen()),
          ],
        ),
      ),
    );
  }
}

// ============================== Settings ==============================

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final ctrl = TextEditingController();
  bool loading = true;
  bool obscure = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    ctrl.text = await Store.loadGeminiKey() ?? '';
    setState(() => loading = false);
  }

  Future<void> _save() async {
    await Store.saveGeminiKey(ctrl.text.trim());
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ø°Ø®ÛŒØ±Ù‡ Ø´Ø¯.')));
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(title: const Text('ØªÙ†Ø¸ÛŒÙ…Ø§Øª')),
      drawer: const AppDrawer(currentIndex: 3),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Ú©Ù„ÛŒØ¯ Gemini API', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text(
            'Ø¨Ø±Ø§ÛŒ Ø¨Ù‡Ø¨ÙˆØ¯ Ø®ÙˆØ§Ù†Ø¯Ù† Ø±Ø³ÛŒØ¯ Ùˆ ÙÛŒØ´ Ø­Ù‚ÙˆÙ‚ÛŒ Ø¨Ø§ Ù‡ÙˆØ´ Ù…ØµÙ†ÙˆØ¹ÛŒ (Ø§Ø®ØªÛŒØ§Ø±ÛŒ). Ø§Ú¯Ø± Ø®Ø§Ù„ÛŒ Ø¨Ú¯Ø°Ø§Ø±ÛŒØ¯ØŒ ÙÙ‚Ø· Ø§Ø² ØªØ´Ø®ÛŒØµ Ù…ØªÙ† Ø¢ÙÙ„Ø§ÛŒÙ† Ø§Ø³ØªÙØ§Ø¯Ù‡ Ù…ÛŒâ€ŒØ´ÙˆØ¯.',
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: ctrl,
            obscureText: obscure,
            decoration: InputDecoration(
              labelText: 'Gemini API Key',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(obscure ? Icons.visibility_off : Icons.visibility),
                onPressed: () => setState(() => obscure = !obscure),
              ),
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _save, child: const Text('Ø°Ø®ÛŒØ±Ù‡')),
        ],
      ),
    );
  }
}

// ============================== OCR service ==============================

/// Renders the first page of a PDF at [path] to a temporary JPEG image and
/// returns the image file path. Only the first page is processed for now.
Future<String> rasterizeFirstPdfPage(String path) async {
  final doc = await PdfDocument.openFile(path);
  final page = await doc.getPage(1);
  // Cap the rendered size (matches the max dimension used for camera/gallery
  // photos) so large PDF pages don't produce oversized uploads to Gemini.
  const maxDim = 1800.0;
  var scale = 2.0;
  final longest = page.width > page.height ? page.width : page.height;
  if (longest * scale > maxDim) scale = maxDim / longest;
  final rendered = await page.render(
    width: page.width * scale,
    height: page.height * scale,
    format: PdfPageImageFormat.jpeg,
  );
  await page.close();
  await doc.close();
  final dir = await getTemporaryDirectory();
  final outPath = '${dir.path}/scan_${DateTime.now().microsecondsSinceEpoch}.jpg';
  final file = File(outPath);
  await file.writeAsBytes(rendered!.bytes);
  return outPath;
}

/// Runs on-device ML Kit text recognition (Latin script) on the image at [path].
Future<String> extractTextFromImage(String path) async {
  final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  try {
    final result = await recognizer.processImage(InputImage.fromFilePath(path));
    return result.text;
  } finally {
    await recognizer.close();
  }
}

final _amountRegex = RegExp(r'(\d{1,3}(?:[.,]\d{3})*[.,]\d{2})\b');
// German receipts always use dots for dates (DD.MM.YYYY); deliberately not
// matching '-' or '/' here, since '-' also appears inside ISO timestamps
// printed on the receipt (e.g. TSE transaction records), which previously
// got misread as a purchase date.
final _dateRegex = RegExp(r'(\d{1,2})\.(\d{1,2})\.(\d{2,4})');

double? _parseAmountToken(String token) {
  var t = token.replaceAll(' ', '');
  // normalize "1.234,56" or "1,234.56" style numbers to a plain double
  if (t.contains(',') && t.contains('.')) {
    if (t.lastIndexOf(',') > t.lastIndexOf('.')) {
      t = t.replaceAll('.', '').replaceAll(',', '.');
    } else {
      t = t.replaceAll(',', '');
    }
  } else if (t.contains(',')) {
    t = t.replaceAll(',', '.');
  }
  return double.tryParse(t);
}

class ReceiptDraft {
  String merchant;
  DateTime? date;
  double? total;
  List<ReceiptItemEntry> items;
  String? categoryHint;
  ReceiptDraft({this.merchant = '', this.date, this.total, this.items = const [], this.categoryHint});
}

const _totalKeywords = ['zu zahlen', 'endbetrag', 'gesamtbetrag', 'betrag', 'total', 'summe', 'gesamt', 'Ø¬Ù…Ø¹', 'Ù…Ø¨Ù„Øº Ú©Ù„'];

const _knownMerchants = <String, String>{
  'Lidl': 'e_food_market',
  'Aldi': 'e_food_market',
  'Rewe': 'e_food_market',
  'Edeka': 'e_food_market',
  'Netto': 'e_food_market',
  'Penny': 'e_food_market',
  'Kaufland': 'e_food_market',
  'Real': 'e_food_market',
  'Norma': 'e_food_market',
  'Globus': 'e_food_market',
  'dm': 'e_misc',
  'Rossmann': 'e_misc',
};

/// Best-effort local (offline) parsing of raw OCR text from a receipt.
/// This is a heuristic fallback; the Gemini step (when available) produces
/// a much more reliable structured result.
ReceiptDraft parseReceiptText(String text) {
  final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  final draft = ReceiptDraft();

  final lowerFull = text.toLowerCase();
  for (final entry in _knownMerchants.entries) {
    if (lowerFull.contains(entry.key.toLowerCase())) {
      draft.merchant = entry.key;
      draft.categoryHint = entry.value;
      break;
    }
  }
  if (draft.merchant.isEmpty && lines.isNotEmpty) draft.merchant = lines.first;

  for (final line in lines) {
    if (draft.date != null) break;
    final dm = _dateRegex.firstMatch(line);
    if (dm == null) continue;
    final d = int.tryParse(dm.group(1)!);
    final m = int.tryParse(dm.group(2)!);
    var y = int.tryParse(dm.group(3)!);
    if (d == null || m == null || y == null) continue;
    if (d < 1 || d > 31 || m < 1 || m > 12) continue;
    if (y < 100) y += 2000;
    // Reject implausible years - OCR noise elsewhere on the receipt (long
    // signature/hash strings, transaction numbers) can otherwise coincidentally
    // match the date pattern and produce a nonsense date like the year 2001.
    final nowYear = DateTime.now().year;
    if (y < nowYear - 5 || y > nowYear + 1) continue;
    draft.date = DateTime(y, m, d);
  }

  // Look for a total-amount keyword and, when found, only read the amount
  // from the SAME line (not a fixed character window), to avoid spilling
  // into unrelated table rows (e.g. the VAT breakdown table also contains
  // the word "Summe"). The first keyword in priority order that matches
  // wins, instead of letting a later, less reliable keyword overwrite it.
  outer:
  for (final line in lines) {
    final lowerLine = line.toLowerCase();
    for (final kw in _totalKeywords) {
      if (!lowerLine.contains(kw)) continue;
      final matches = _amountRegex.allMatches(line).toList();
      if (matches.isNotEmpty) {
        final v = _parseAmountToken(matches.last.group(1)!);
        if (v != null) {
          draft.total = v;
          break outer;
        }
      }
    }
  }
  // fallback: largest amount found anywhere in the text
  if (draft.total == null) {
    double? largest;
    for (final m in _amountRegex.allMatches(text)) {
      final v = _parseAmountToken(m.group(1)!);
      if (v != null && (largest == null || v > largest)) largest = v;
    }
    draft.total = largest;
  }

  // Best-effort structured item extraction: a line that ends with a price
  // is treated as a purchased item, with everything before the price used
  // as the item name. Lines without a trailing price (headers, totals
  // already consumed above, etc.) are skipped.
  final items = <ReceiptItemEntry>[];
  for (final line in lines.skip(1).take(25)) {
    final matches = _amountRegex.allMatches(line).toList();
    if (matches.isEmpty) continue;
    final priceMatch = matches.last;
    final price = _parseAmountToken(priceMatch.group(1)!);
    var name = line.substring(0, priceMatch.start).trim();
    name = name.replaceAll(RegExp(r'[\-:xX*]+$'), '').trim();
    if (name.isEmpty || price == null) continue;
    items.add(ReceiptItemEntry(name: name, price: price));
  }
  draft.items = items;
  return draft;
}

const _payslipFieldKeywords = <String, List<String>>{
  'brutto': ['brutto', 'gesamtbrutto'],
  'netto': ['netto', 'auszahlungsbetrag'],
  'lohnsteuer': ['lohnsteuer'],
  'solidaritaetszuschlag': ['solidaritÃ¤tszuschlag', 'soli'],
  'kirchensteuer': ['kirchensteuer'],
  'krankenversicherung': ['krankenversicherung', 'kv'],
  'pflegeversicherung': ['pflegeversicherung', 'pv'],
  'rentenversicherung': ['rentenversicherung', 'rv'],
  'arbeitslosenversicherung': ['arbeitslosenversicherung', 'av'],
};

/// Best-effort local (offline) parsing of raw OCR text from a German payslip.
Map<String, dynamic> parsePayslipText(String text) {
  final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
  final result = <String, dynamic>{};
  final lower = text.toLowerCase();

  for (final entry in _payslipFieldKeywords.entries) {
    for (final kw in entry.value) {
      final idx = lower.indexOf(kw);
      if (idx == -1) continue;
      final rest = text.substring(idx, (idx + 60).clamp(0, text.length));
      final am = _amountRegex.firstMatch(rest);
      if (am != null) {
        final v = _parseAmountToken(am.group(1)!);
        if (v != null) {
          result[entry.key] = v;
          break;
        }
      }
    }
  }

  final steuerklasseMatch = RegExp(r'steuerklasse\s*[:\-]?\s*(\d)', caseSensitive: false).firstMatch(text);
  if (steuerklasseMatch != null) result['steuerklasse'] = steuerklasseMatch.group(1);

  if (lines.isNotEmpty) result['arbeitgeber'] = lines.first;

  for (final line in lines) {
    final dm = _dateRegex.firstMatch(line);
    if (dm == null) continue;
    final d = int.tryParse(dm.group(1)!);
    final m = int.tryParse(dm.group(2)!);
    var y = int.tryParse(dm.group(3)!);
    if (d == null || m == null || y == null) continue;
    if (d < 1 || d > 31 || m < 1 || m > 12) continue;
    if (y < 100) y += 2000;
    final nowYear = DateTime.now().year;
    if (y < nowYear - 5 || y > nowYear + 1) continue;
    result['date'] = DateTime(y, m, d).toIso8601String();
    break;
  }

  return result;
}


// ============================== Gemini vision service ==============================

const _geminiModel = 'gemini-flash-latest';

Future<Map<String, dynamic>?> _geminiRequest(String apiKey, String imagePath, String prompt) async {
  final bytes = await File(imagePath).readAsBytes();
  final b64 = base64Encode(bytes);
  final uri = Uri.parse(
    'https://generativelanguage.googleapis.com/v1beta/models/$_geminiModel:generateContent?key=$apiKey',
  );
  final body = jsonEncode({
    'contents': [
      {
        'parts': [
          {'text': prompt},
          {
            'inline_data': {'mime_type': 'image/jpeg', 'data': b64}
          },
        ],
      },
    ],
    'generationConfig': {'response_mime_type': 'application/json'},
  });
  // Gemini occasionally returns a transient 503 "model overloaded" error;
  // retry a couple of times with a short backoff before giving up.
  http.Response? resp;
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      resp = await http
          .post(uri, headers: {'Content-Type': 'application/json'}, body: body)
          .timeout(const Duration(seconds: 45));
    } on Exception {
      if (attempt == 2) rethrow;
      await Future.delayed(Duration(seconds: 2 * (attempt + 1)));
      continue;
    }
    if (resp.statusCode == 200) break;
    if (resp.statusCode == 503 && attempt < 2) {
      await Future.delayed(Duration(seconds: 2 * (attempt + 1)));
      continue;
    }
    break;
  }
  if (resp == null || resp.statusCode != 200) {
    final code = resp?.statusCode;
    if (code == 503) {
      throw Exception('Ø³Ø±ÙˆØ±Ù‡Ø§ÛŒ Gemini Ù…ÙˆÙ‚ØªØ§Ù‹ Ø´Ù„ÙˆØº Ù‡Ø³ØªÙ†Ø¯. Ù„Ø·ÙØ§Ù‹ Ú†Ù†Ø¯ Ù„Ø­Ø¸Ù‡ Ø¯ÛŒÚ¯Ø± Ø¯ÙˆØ¨Ø§Ø±Ù‡ Ø§Ù…ØªØ­Ø§Ù† Ú©Ù†ÛŒØ¯.');
    }
    throw Exception('Ø®Ø·Ø§ÛŒ Gemini API (${code ?? 'â€”'}): ${resp?.body ?? ''}');
  }
  final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
  final candidates = decoded['candidates'];
  if (candidates == null || candidates is! List || candidates.isEmpty) {
    final blockReason = decoded['promptFeedback']?['blockReason'];
    if (blockReason != null) {
      throw Exception('Gemini Ø§ÛŒÙ† ØªØµÙˆÛŒØ± Ø±Ø§ Ù¾Ø±Ø¯Ø§Ø²Ø´ Ù†Ú©Ø±Ø¯ (Ø¯Ù„ÛŒÙ„: $blockReason).');
    }
    throw Exception('Ù¾Ø§Ø³Ø® Ù†Ø§Ù…Ø¹ØªØ¨Ø± Ø§Ø² Gemini Ø¯Ø±ÛŒØ§ÙØª Ø´Ø¯ (Ø¨Ø¯ÙˆÙ† Ù†ØªÛŒØ¬Ù‡).');
  }
  final finishReason = candidates[0]?['finishReason'];
  var text = candidates[0]?['content']?['parts']?[0]?['text'] as String?;
  if (text == null) {
    throw Exception('Ù¾Ø§Ø³Ø® Gemini Ù‚Ø§Ø¨Ù„ Ø®ÙˆØ§Ù†Ø¯Ù† Ù†Ø¨ÙˆØ¯${finishReason != null ? ' (finishReason: $finishReason)' : ''}.');
  }
  // The API is asked for pure JSON, but occasionally still wraps it in a
  // ```json ... ``` markdown fence - strip that defensively before parsing.
  text = text.trim();
  if (text.startsWith('```')) {
    text = text.replaceFirst(RegExp(r'^```[a-zA-Z]*\n?'), '').replaceFirst(RegExp(r'```\s*$'), '').trim();
  }
  try {
    return jsonDecode(text) as Map<String, dynamic>;
  } on FormatException {
    throw Exception('Ù¾Ø§Ø³Ø® Gemini Ø¨Ù‡â€ŒØµÙˆØ±Øª JSON Ù…Ø¹ØªØ¨Ø± Ù†Ø¨ÙˆØ¯.');
  }
}

const _receiptPrompt = 'You are an expert receipt-reading assistant. Read the attached receipt image '
    'and extract structured data. Respond ONLY with compact JSON, no markdown, no explanation, in '
    'exactly this shape: {"merchant": string or null, "date": "YYYY-MM-DD" or null, "total": number or '
    'null, "items": [{"name": string, "quantity": number or null, "price": number or null}], '
    '"category": string or null}. For "items", expand any abbreviated, truncated, or SKU-coded product '
    'names printed on the receipt into their full, clear, human-readable product name (in the same '
    "language as the receipt) - never leave a short code or cut-off abbreviation as the name if you can "
    'reasonably infer the full name from context and common branded products. "quantity" is the number '
    'of units purchased (default 1 if not shown separately). For "category", give a short one- or '
    "two-word general shopping category for this receipt (e.g. \"Ø®ÙˆØ±Ø§Ú©\", \"Ù¾ÙˆØ´Ø§Ú©\", \"Ø¯Ø§Ø±Ùˆ\") in the "
    "receipt's language. Keep merchant name in the receipt's own language/script. Numbers must be plain "
    '(no currency symbols). If a field is unreadable, use null.';

const _payslipPrompt = 'You are an expert German payslip (Lohnabrechnung) reading assistant. Read the '
    'attached payslip image and extract structured data. Respond ONLY with compact JSON, no markdown, '
    'no explanation, in exactly this shape: {"brutto": number or null, "netto": number or null, '
    '"lohnsteuer": number or null, "solidaritaetszuschlag": number or null, "kirchensteuer": number or '
    'null, "krankenversicherung": number or null, "pflegeversicherung": number or null, '
    '"rentenversicherung": number or null, "arbeitslosenversicherung": number or null, "steuerklasse": '
    'string or null, "arbeitgeber": string or null, "abrechnungsmonat": string or null, "date": '
    '"YYYY-MM-DD" or null}. "date" is the actual payment/value date (Auszahlungsdatum or Valuta date) '
    'printed on the payslip - not just the month name. Numbers must be plain (no currency symbols). If '
    'a field is unreadable, use null.';

Future<Map<String, dynamic>?> geminiExtractReceipt(String apiKey, String imagePath) =>
    _geminiRequest(apiKey, imagePath, _receiptPrompt);

Future<Map<String, dynamic>?> geminiExtractPayslip(String apiKey, String imagePath) =>
    _geminiRequest(apiKey, imagePath, _payslipPrompt);

// ============================== Money formatting ==============================

String formatMoney(double amount, String currency) {
  final n = amount.toStringAsFixed(2);
  switch (currency) {
    case 'EUR':
      return ltr('â‚¬$n');
    case 'USD':
      return ltr('\$$n');
    case 'GBP':
      return ltr('Â£$n');
    case 'CHF':
      return ltr('$n CHF');
    case 'TRY':
      return ltr('â‚º$n');
    case 'AED':
      return '${ltr(n)} Ø¯.Ø¥';
    case 'IRR':
      return '${ltr(n)} Ø±ÛŒØ§Ù„';
    default:
      return ltr('$n $currency');
  }
}

// ============================== Home screen ==============================

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Transaction> tx = [];
  List<Category> categories = [];
  List<Account> accounts = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    tx = await Store.loadTransactions();
    categories = await Store.loadCategories();
    accounts = await Store.loadAccounts();
    tx.sort((a, b) => b.date.compareTo(a.date));
    setState(() => loading = false);
  }

  Future<void> _save() async {
    await Store.saveTransactions(tx);
  }

  String categoryName(String id) {
    final c = categories.where((c) => c.id == id).toList();
    return c.isEmpty ? 'Ø¨Ø¯ÙˆÙ†â€ŒØ¯Ø³ØªÙ‡' : c.first.name;
  }

  String currencyOf(String accountId) {
    final a = accounts.where((a) => a.id == accountId).toList();
    return a.isEmpty ? 'EUR' : a.first.currency;
  }

  int get draftCount => tx.where((t) => t.draft).length;

  Map<String, double> get totalBalanceByCurrency {
    final map = <String, double>{};
    for (final t in tx) {
      final cur = currencyOf(t.accountId);
      map[cur] = (map[cur] ?? 0) + (t.type == TxType.income ? t.amount : -t.amount);
    }
    return map;
  }

  DateTime? get lastIncomeDate {
    DateTime? latest;
    for (final t in tx) {
      if (t.type == TxType.income) {
        if (latest == null || t.date.isAfter(latest)) latest = t.date;
      }
    }
    return latest;
  }

  Map<String, Map<String, double>> get periodStatsByCurrency {
    final start = lastIncomeDate;
    final now = DateTime.now();
    final map = <String, Map<String, double>>{};
    for (final t in tx) {
      if (start != null) {
        if (t.date.isBefore(DateTime(start.year, start.month, start.day))) continue;
      } else {
        if (!(t.date.year == now.year && t.date.month == now.month)) continue;
      }
      final cur = currencyOf(t.accountId);
      map.putIfAbsent(cur, () => {'income': 0, 'expense': 0});
      if (t.type == TxType.income) {
        map[cur]!['income'] = map[cur]!['income']! + t.amount;
      } else {
        map[cur]!['expense'] = map[cur]!['expense']! + t.amount;
      }
    }
    return map;
  }

  String get primaryCurrency => accounts.isNotEmpty ? accounts.first.currency : 'EUR';

  /// Top-level category (parent rolled up) expense totals for the current
  /// period (same period as [periodStatsByCurrency]), in [primaryCurrency].
  /// Expense transactions for the current period, in [primaryCurrency] -
  /// aggregation (including drill-down by category) happens inside
  /// [DashboardCharts] itself.
  List<Transaction> get expenseTransactionsForPeriod {
    final start = lastIncomeDate;
    final now = DateTime.now();
    return tx.where((t) {
      if (t.type != TxType.expense) return false;
      if (currencyOf(t.accountId) != primaryCurrency) return false;
      if (start != null) {
        return !t.date.isBefore(DateTime(start.year, start.month, start.day));
      }
      return t.date.year == now.year && t.date.month == now.month;
    }).toList();
  }

  /// Income and expense totals (in [primaryCurrency]) for each of the last
  /// [months] calendar months, oldest first.
  List<({DateTime month, double income, double expense})> monthlyTotals(int months) {
    final now = DateTime.now();
    final result = <({DateTime month, double income, double expense})>[];
    for (var i = months - 1; i >= 0; i--) {
      var y = now.year;
      var m = now.month - i;
      while (m < 1) {
        m += 12;
        y--;
      }
      var income = 0.0, expense = 0.0;
      for (final t in tx) {
        if (currencyOf(t.accountId) != primaryCurrency) continue;
        if (t.date.year == y && t.date.month == m) {
          if (t.type == TxType.income) {
            income += t.amount;
          } else {
            expense += t.amount;
          }
        }
      }
      result.add((month: DateTime(y, m), income: income, expense: expense));
    }
    return result;
  }

  Future<void> _openEditor({Transaction? existing}) async {
    final result = await Navigator.push<Object>(
      context,
      MaterialPageRoute(
        builder: (_) => TransactionEditor(categories: categories, accounts: accounts, existing: existing),
      ),
    );
    if (result == null) return;
    // A new category/subcategory may have been created inside the editor;
    // refresh so it's reflected immediately (otherwise the transaction
    // would look "uncategorized" until the next full reload).
    categories = await Store.loadCategories();
    accounts = await Store.loadAccounts();
    if (result is DeleteTransactionSignal) {
      setState(() => tx.removeWhere((x) => x.id == result.id));
      await _save();
      return;
    }
    if (result is! Transaction) return;
    setState(() {
      final idx = tx.indexWhere((x) => x.id == result.id);
      if (idx >= 0) {
        tx[idx] = result;
      } else {
        tx.add(result);
      }
      tx.sort((a, b) => b.date.compareTo(a.date));
    });
    await _save();
  }

  Future<void> _openScan() async {
    final result = await Navigator.push<Transaction>(context, MaterialPageRoute(builder: (_) => const ScanEntryScreen()));
    if (result == null) return;
    categories = await Store.loadCategories();
    accounts = await Store.loadAccounts();
    setState(() {
      tx.add(result);
      tx.sort((a, b) => b.date.compareTo(a.date));
    });
    await _save();
  }

  Future<void> _openDrafts() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const DraftsScreen()));
    await _load();
  }

  Future<void> _delete(Transaction t) async {
    await NotificationService.instance.cancelForTransaction(t.id);
    setState(() => tx.removeWhere((x) => x.id == t.id));
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final balances = totalBalanceByCurrency;
    final period = periodStatsByCurrency;
    final start = lastIncomeDate;
    final periodLabel = start == null
        ? 'Ø§ÛŒÙ† Ù…Ø§Ù‡'
        : 'Ø§Ø² ${ltr(DateFormat('dd.MM').format(start))} ØªØ§ Ø§Ù…Ø±ÙˆØ² (Ø¨Ø¹Ø¯ Ø§Ø² Ø¢Ø®Ø±ÛŒÙ† Ø­Ù‚ÙˆÙ‚)';
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final exit = await confirmExitApp(context);
        if (exit) SystemNavigator.pop();
      },
      child: Scaffold(
      appBar: AppBar(
        title: const Text('Ù…Ø¯ÛŒØ±ÛŒØª Ù…Ø§Ù„ÛŒ Ø´Ø®ØµÛŒ'),
        actions: [
          Badge(
            label: Text('$draftCount'),
            isLabelVisible: draftCount > 0,
            child: IconButton(icon: const Icon(Icons.drafts_outlined), tooltip: 'Ù¾ÛŒØ´â€ŒÙ†ÙˆÛŒØ³â€ŒÙ‡Ø§', onPressed: _openDrafts),
          ),
          IconButton(icon: const Icon(Icons.document_scanner_outlined), tooltip: 'Ø§Ø³Ú©Ù† Ø±Ø³ÛŒØ¯/ÙÛŒØ´ Ø­Ù‚ÙˆÙ‚ÛŒ', onPressed: _openScan),
        ],
      ),
      drawer: const AppDrawer(currentIndex: 0),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Ù…ÙˆØ¬ÙˆØ¯ÛŒ Ú©Ù„', style: Theme.of(context).textTheme.titleMedium),
                        if (draftCount > 0)
                          Chip(
                            label: Text('$draftCount Ù¾ÛŒØ´â€ŒÙ†ÙˆÛŒØ³'),
                            backgroundColor: Colors.amber.shade100,
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (balances.isEmpty) const Text('Ù‡Ù†ÙˆØ² ØªØ±Ø§Ú©Ù†Ø´ÛŒ Ø«Ø¨Øª Ù†Ø´Ø¯Ù‡.'),
                    ...balances.entries.map((e) => Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            formatMoney(e.value, e.key),
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: e.value >= 0 ? Colors.green.shade700 : Colors.red.shade700,
                            ),
                          ),
                        )),
                    const Divider(height: 24),
                    Text(periodLabel, style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
                    const SizedBox(height: 6),
                    if (period.isEmpty) const Text('Ø¯Ø± Ø§ÛŒÙ† Ø¯ÙˆØ±Ù‡ ØªØ±Ø§Ú©Ù†Ø´ÛŒ Ø«Ø¨Øª Ù†Ø´Ø¯Ù‡.'),
                    ...period.entries.map((e) => Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              _MonthStat(label: 'Ø¯Ø±Ø¢Ù…Ø¯', value: e.value['income']!, currency: e.key, color: Colors.green),
                              _MonthStat(label: 'Ù‡Ø²ÛŒÙ†Ù‡', value: e.value['expense']!, currency: e.key, color: Colors.red),
                            ],
                          ),
                        )),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (tx.isNotEmpty)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: DashboardCharts(
                    expenseTransactions: expenseTransactionsForPeriod,
                    categories: categories,
                    monthly: monthlyTotals(6),
                    currency: primaryCurrency,
                  ),
                ),
              ),
            const SizedBox(height: 16),
            Text('ØªØ±Ø§Ú©Ù†Ø´â€ŒÙ‡Ø§', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            if (tx.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: Text('Ù‡Ù†ÙˆØ² ØªØ±Ø§Ú©Ù†Ø´ÛŒ Ø«Ø¨Øª Ù†Ø´Ø¯Ù‡. Ø¨Ø§ Ø¯Ú©Ù…Ù‡ + Ø´Ø±ÙˆØ¹ Ú©Ù†ÛŒØ¯.')),
              ),
            ...tx.map((t) => Dismissible(
                  key: ValueKey(t.id),
                  direction: DismissDirection.horizontal,
                  background: Container(
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    color: Colors.blue.shade400,
                    child: const Icon(Icons.edit, color: Colors.white),
                  ),
                  secondaryBackground: Container(
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    color: Colors.red.shade400,
                    child: const Icon(Icons.delete, color: Colors.white),
                  ),
                  confirmDismiss: (direction) async {
                    if (direction == DismissDirection.startToEnd) {
                      await _openEditor(existing: t);
                      return false;
                    }
                    return await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Ø­Ø°Ù ØªØ±Ø§Ú©Ù†Ø´'),
                        content: const Text('Ø§ÛŒÙ† ØªØ±Ø§Ú©Ù†Ø´ Ø­Ø°Ù Ø´ÙˆØ¯ØŸ'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Ø§Ù†ØµØ±Ø§Ù')),
                          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Ø­Ø°Ù')),
                        ],
                      ),
                    ) ?? false;
                  },
                  onDismissed: (_) => _delete(t),
                  child: Card(
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: t.type == TxType.income ? Colors.green.shade100 : Colors.red.shade100,
                        child: Icon(
                          iconForCategory(
                            categories.where((c) => c.id == t.categoryId).isEmpty
                                ? Category(id: t.categoryId, name: '', type: t.type)
                                : categories.firstWhere((c) => c.id == t.categoryId),
                            categories,
                          ),
                          color: t.type == TxType.income ? Colors.green.shade800 : Colors.red.shade800,
                        ),
                      ),
                      title: Text(categoryName(t.categoryId)),
                      subtitle: Text(
                        '${ltr(DateFormat('dd.MM.yyyy').format(t.date))}'
                        '${t.isRecurring ? ' â€¢ ØªÚ©Ø±Ø§Ø±Ø´ÙˆÙ†Ø¯Ù‡' : ''}'
                        '${t.draft ? ' â€¢ Ù¾ÛŒØ´â€ŒÙ†ÙˆÛŒØ³' : ''}',
                      ),
                      trailing: Text(
                        ltr(t.type == TxType.income ? '+' : '-') + formatMoney(t.amount, currencyOf(t.accountId)),
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: t.type == TxType.income ? Colors.green.shade700 : Colors.red.shade700,
                        ),
                      ),
                      onTap: () => _openEditor(existing: t),
                    ),
                  ),
                )),
            const SizedBox(height: 80),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.add),
        label: const Text('ØªØ±Ø§Ú©Ù†Ø´ Ø¬Ø¯ÛŒØ¯'),
      ),
    ),
    );
  }
}

class _MonthStat extends StatelessWidget {
  final String label;
  final double value;
  final String currency;
  final MaterialColor color;
  const _MonthStat({required this.label, required this.value, required this.currency, required this.color});
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
        Text(formatMoney(value, currency),
            style: TextStyle(color: color.shade700, fontWeight: FontWeight.bold, fontSize: 16)),
      ],
    );
  }
}

// ============================== Dashboard charts ==============================

class DashboardCharts extends StatefulWidget {
  final List<Transaction> expenseTransactions;
  final List<Category> categories;
  final List<({DateTime month, double income, double expense})> monthly;
  final String currency;
  const DashboardCharts({
    required this.expenseTransactions,
    required this.categories,
    required this.monthly,
    required this.currency,
    super.key,
  });

  @override
  State<DashboardCharts> createState() => _DashboardChartsState();
}

class _DashboardChartsState extends State<DashboardCharts> {
  Category? drilldown;

  static const _palette = [
    Colors.indigo,
    Colors.teal,
    Colors.orange,
    Colors.pink,
    Colors.purple,
    Colors.brown,
  ];

  bool _hasChildren(Category c) => widget.categories.any((x) => x.parentId == c.id);

  /// Aggregates [widget.expenseTransactions] by the direct child of [parent]
  /// (top-level categories when parent is null) - this is what powers the
  /// pie-chart drill-down.
  Map<Category, double> _aggregateFor(Category? parent) {
    final map = <String, double>{};
    for (final t in widget.expenseTransactions) {
      final match = widget.categories.where((c) => c.id == t.categoryId).toList();
      var cat = match.isEmpty ? null : match.first;
      while (cat != null && cat.parentId != parent?.id) {
        if (cat.parentId == null) {
          cat = null;
          break;
        }
        final pm = widget.categories.where((c) => c.id == cat!.parentId).toList();
        cat = pm.isEmpty ? null : pm.first;
      }
      if (cat == null) continue;
      map[cat.id] = (map[cat.id] ?? 0) + t.amount;
    }
    final result = <Category, double>{};
    map.forEach((id, amount) {
      final match = widget.categories.where((c) => c.id == id).toList();
      result[match.isEmpty ? Category(id: id, name: 'Ø¨Ø¯ÙˆÙ†â€ŒØ¯Ø³ØªÙ‡', type: TxType.expense) : match.first] = amount;
    });
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final expenseByCategory = _aggregateFor(drilldown);
    final total = expenseByCategory.values.fold(0.0, (a, b) => a + b);
    final entries = expenseByCategory.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final top = entries.take(6).toList();
    final otherSum = entries.skip(6).fold(0.0, (s, e) => s + e.value);
    final monthly = widget.monthly;
    final maxMonthly = monthly.fold(0.0, (m, e) => [m, e.income, e.expense].reduce((a, b) => a > b ? a : b));
    Widget? comparison;
    if (drilldown == null && monthly.length >= 2) {
      final curr = monthly.last.expense;
      final prev = monthly[monthly.length - 2].expense;
      if (prev > 0) {
        final change = (curr - prev) / prev * 100;
        final up = change >= 0;
        comparison = Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              Icon(up ? Icons.trending_up : Icons.trending_down, color: up ? Colors.red : Colors.green, size: 18),
              const SizedBox(width: 4),
              Text(
                'Ù‡Ø²ÛŒÙ†Ù‡â€ŒÛŒ Ø§ÛŒÙ† Ù…Ø§Ù‡ ${ltr('${change.abs().round()}%')} ${up ? 'Ø¨ÛŒØ´ØªØ±' : 'Ú©Ù…ØªØ±'} Ø§Ø² Ù…Ø§Ù‡ Ù‚Ø¨Ù„',
                style: TextStyle(fontSize: 12, color: up ? Colors.red.shade700 : Colors.green.shade700),
              ),
            ],
          ),
        );
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (comparison != null) comparison,
        if (total > 0 || drilldown != null) ...[
          Row(
            children: [
              if (drilldown != null)
                IconButton(
                  icon: const Icon(Icons.arrow_back, size: 20),
                  tooltip: 'Ø¨Ø§Ø²Ú¯Ø´Øª',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () => setState(() => drilldown = null),
                ),
              if (drilldown != null) const SizedBox(width: 8),
              Expanded(
                child: Text(
                  drilldown == null ? 'Ù‡Ø²ÛŒÙ†Ù‡â€ŒÙ‡Ø§ Ø¨Ø± Ø§Ø³Ø§Ø³ Ø¯Ø³ØªÙ‡â€ŒØ¨Ù†Ø¯ÛŒ' : 'Ø²ÛŒØ±Ù…Ø¬Ù…ÙˆØ¹Ù‡â€ŒÙ‡Ø§ÛŒ Â«${drilldown!.name}Â»',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (total > 0)
            SizedBox(
              height: 170,
              child: Row(
                children: [
                  SizedBox(
                    width: 150,
                    child: PieChart(
                      PieChartData(
                        sectionsSpace: 2,
                        centerSpaceRadius: 30,
                        sections: [
                          for (var i = 0; i < top.length; i++)
                            PieChartSectionData(
                              value: top[i].value,
                              color: _palette[i % _palette.length],
                              title: '${(top[i].value / total * 100).round()}%',
                              radius: 46,
                              titleStyle: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold),
                            ),
                          if (otherSum > 0)
                            PieChartSectionData(
                              value: otherSum,
                              color: Colors.grey,
                              title: '${(otherSum / total * 100).round()}%',
                              radius: 46,
                              titleStyle: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ListView(
                      children: [
                        for (var i = 0; i < top.length; i++) _legendRow(_palette[i % _palette.length], top[i].key, top[i].value),
                        if (otherSum > 0)
                          _legendRow(Colors.grey, const Category(id: '_other_', name: 'Ø³Ø§ÛŒØ±', type: TxType.expense), otherSum),
                      ],
                    ),
                  ),
                ],
              ),
            )
          else
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('Ù‡Ø²ÛŒÙ†Ù‡â€ŒØ§ÛŒ Ø¯Ø± Ø§ÛŒÙ† Ø¯ÙˆØ±Ù‡ Ø¨Ø±Ø§ÛŒ Ø§ÛŒÙ† Ø¯Ø³ØªÙ‡â€ŒØ¨Ù†Ø¯ÛŒ Ø«Ø¨Øª Ù†Ø´Ø¯Ù‡.', style: TextStyle(color: Colors.grey)),
            ),
          const SizedBox(height: 24),
        ],
        Text('Ø±ÙˆÙ†Ø¯ Û¶ Ù…Ø§Ù‡ Ø§Ø®ÛŒØ±', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SizedBox(
          height: 190,
          child: maxMonthly <= 0
              ? const Center(child: Text('Ø¯Ø§Ø¯Ù‡â€ŒØ§ÛŒ Ø¨Ø±Ø§ÛŒ Ù†Ù…Ø§ÛŒØ´ ÙˆØ¬ÙˆØ¯ Ù†Ø¯Ø§Ø±Ø¯.', style: TextStyle(color: Colors.grey)))
              : BarChart(
                  BarChartData(
                    maxY: maxMonthly * 1.15,
                    barGroups: [
                      for (var i = 0; i < monthly.length; i++)
                        BarChartGroupData(x: i, barRods: [
                          BarChartRodData(toY: monthly[i].income, color: Colors.green, width: 8),
                          BarChartRodData(toY: monthly[i].expense, color: Colors.red, width: 8),
                        ]),
                    ],
                    titlesData: FlTitlesData(
                      leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          getTitlesWidget: (value, meta) {
                            final i = value.toInt();
                            if (i < 0 || i >= monthly.length) return const SizedBox.shrink();
                            return Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(ltr(DateFormat('MM/yy').format(monthly[i].month)), style: const TextStyle(fontSize: 10)),
                            );
                          },
                        ),
                      ),
                    ),
                    gridData: const FlGridData(show: false),
                    borderData: FlBorderData(show: false),
                  ),
                ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _dot(Colors.green),
            const SizedBox(width: 4),
            const Text('Ø¯Ø±Ø¢Ù…Ø¯', style: TextStyle(fontSize: 12)),
            const SizedBox(width: 16),
            _dot(Colors.red),
            const SizedBox(width: 4),
            const Text('Ù‡Ø²ÛŒÙ†Ù‡', style: TextStyle(fontSize: 12)),
          ],
        ),
      ],
    );
  }

  Widget _legendRow(Color color, Category category, double amount) {
    final canDrill = _hasChildren(category);
    return InkWell(
      onTap: canDrill ? () => setState(() => drilldown = category) : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                category.name,
                style: TextStyle(fontSize: 12, decoration: canDrill ? TextDecoration.underline : null),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            Text(ltr(formatMoney(amount, widget.currency)), style: const TextStyle(fontSize: 11, color: Colors.grey)),
            if (canDrill) const Icon(Icons.chevron_left, size: 16, color: Colors.grey),
          ],
        ),
      ),
    );
  }

  Widget _dot(Color color) => Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle));
}

// ============================== Drafts ==============================

// ============================== Full image viewer ==============================

class FullImageViewer extends StatelessWidget {
  final String imagePath;
  const FullImageViewer({required this.imagePath, super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, iconTheme: const IconThemeData(color: Colors.white)),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 6,
          child: Image.file(File(imagePath), fit: BoxFit.contain),
        ),
      ),
    );
  }
}

class DraftsScreen extends StatefulWidget {
  const DraftsScreen({super.key});
  @override
  State<DraftsScreen> createState() => _DraftsScreenState();
}

class _DraftsScreenState extends State<DraftsScreen> {
  List<Transaction> tx = [];
  List<Category> categories = [];
  List<Account> accounts = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await Store.loadTransactions();
    tx = all.where((t) => t.draft).toList()..sort((a, b) => b.date.compareTo(a.date));
    categories = await Store.loadCategories();
    accounts = await Store.loadAccounts();
    setState(() => loading = false);
  }

  String categoryName(String id) {
    final c = categories.where((c) => c.id == id).toList();
    return c.isEmpty ? 'Ø¨Ø¯ÙˆÙ†â€ŒØ¯Ø³ØªÙ‡' : c.first.name;
  }

  String currencyOf(String accountId) {
    final a = accounts.where((a) => a.id == accountId).toList();
    return a.isEmpty ? 'EUR' : a.first.currency;
  }

  Future<void> _openEditor(Transaction t) async {
    final result = await Navigator.push<Object>(
      context,
      MaterialPageRoute(builder: (_) => TransactionEditor(categories: categories, accounts: accounts, existing: t)),
    );
    if (result == null) return;
    final all = await Store.loadTransactions();
    if (result is DeleteTransactionSignal) {
      all.removeWhere((x) => x.id == result.id);
    } else if (result is Transaction) {
      final idx = all.indexWhere((x) => x.id == result.id);
      if (idx >= 0) {
        all[idx] = result;
      } else {
        all.add(result);
      }
    }
    await Store.saveTransactions(all);
    await _load();
  }

  Future<void> _delete(Transaction t) async {
    await NotificationService.instance.cancelForTransaction(t.id);
    final all = await Store.loadTransactions();
    all.removeWhere((x) => x.id == t.id);
    await Store.saveTransactions(all);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(title: const Text('Ù¾ÛŒØ´â€ŒÙ†ÙˆÛŒØ³â€ŒÙ‡Ø§')),
      body: tx.isEmpty
          ? const Center(child: Text('Ù¾ÛŒØ´â€ŒÙ†ÙˆÛŒØ³ÛŒ ÙˆØ¬ÙˆØ¯ Ù†Ø¯Ø§Ø±Ø¯.'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: tx.map((t) => Dismissible(
                    key: ValueKey(t.id),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      color: Colors.red.shade400,
                      child: const Icon(Icons.delete, color: Colors.white),
                    ),
                    confirmDismiss: (_) => showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Ø­Ø°Ù Ù¾ÛŒØ´â€ŒÙ†ÙˆÛŒØ³'),
                        content: const Text('Ø§ÛŒÙ† Ù¾ÛŒØ´â€ŒÙ†ÙˆÛŒØ³ Ø­Ø°Ù Ø´ÙˆØ¯ØŸ'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Ø§Ù†ØµØ±Ø§Ù')),
                          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Ø­Ø°Ù')),
                        ],
                      ),
                    ),
                    onDismissed: (_) => _delete(t),
                    child: Card(
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: t.type == TxType.income ? Colors.green.shade100 : Colors.red.shade100,
                          child: Icon(
                            iconForCategory(
                              categories.where((c) => c.id == t.categoryId).isEmpty
                                  ? Category(id: t.categoryId, name: '', type: t.type)
                                  : categories.firstWhere((c) => c.id == t.categoryId),
                              categories,
                            ),
                            color: t.type == TxType.income ? Colors.green.shade800 : Colors.red.shade800,
                          ),
                        ),
                        title: Text(categoryName(t.categoryId)),
                        subtitle: Text(ltr(DateFormat('dd.MM.yyyy').format(t.date))),
                        trailing: Text(
                          ltr(t.type == TxType.income ? '+' : '-') + formatMoney(t.amount, currencyOf(t.accountId)),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: t.type == TxType.income ? Colors.green.shade700 : Colors.red.shade700,
                          ),
                        ),
                        onTap: () => _openEditor(t),
                      ),
                    ),
                  ))
                  .toList(),
            ),
    );
  }
}

// ============================== Recurring transactions ==============================

class RecurringTransactionsScreen extends StatefulWidget {
  const RecurringTransactionsScreen({super.key});
  @override
  State<RecurringTransactionsScreen> createState() => _RecurringTransactionsScreenState();
}

class _RecurringTransactionsScreenState extends State<RecurringTransactionsScreen> {
  List<Transaction> tx = [];
  List<Category> categories = [];
  List<Account> accounts = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await Store.loadTransactions();
    tx = all.where((t) => t.isRecurring).toList()..sort((a, b) => b.date.compareTo(a.date));
    categories = await Store.loadCategories();
    accounts = await Store.loadAccounts();
    setState(() => loading = false);
  }

  String categoryName(String id) {
    final c = categories.where((c) => c.id == id).toList();
    return c.isEmpty ? 'Ø¨Ø¯ÙˆÙ†â€ŒØ¯Ø³ØªÙ‡' : c.first.name;
  }

  String currencyOf(String accountId) {
    final a = accounts.where((a) => a.id == accountId).toList();
    return a.isEmpty ? 'EUR' : a.first.currency;
  }

  String _recurrenceLabel(Transaction t) {
    switch (t.recurrence) {
      case RecurrenceFrequency.monthly:
        return 'Ù…Ø§Ù‡Ø§Ù†Ù‡ (Ø±ÙˆØ² ${t.recurrenceDay ?? '?'})';
      case RecurrenceFrequency.weekly:
        return 'Ù‡ÙØªÚ¯ÛŒ (${_weekdayNames[(t.recurrenceWeekday ?? 1) - 1]})';
      case RecurrenceFrequency.custom:
        return 'Ù‡Ø± ${t.recurrenceIntervalDays ?? '?'} Ø±ÙˆØ²';
      case RecurrenceFrequency.quarterly:
        return 'ÙØµÙ„ÛŒ (Ø±ÙˆØ² ${t.recurrenceDay ?? '?'})';
      case RecurrenceFrequency.yearly:
        return 'Ø³Ø§Ù„Ø§Ù†Ù‡ (${ltr(DateFormat('dd.MM').format(t.date))})';
      case RecurrenceFrequency.none:
        return '';
    }
  }

  Future<void> _openEditor(Transaction t) async {
    final result = await Navigator.push<Object>(
      context,
      MaterialPageRoute(builder: (_) => TransactionEditor(categories: categories, accounts: accounts, existing: t)),
    );
    if (result == null) return;
    final all = await Store.loadTransactions();
    final newCategories = await Store.loadCategories();
    if (result is DeleteTransactionSignal) {
      all.removeWhere((x) => x.id == result.id);
    } else if (result is Transaction) {
      final idx = all.indexWhere((x) => x.id == result.id);
      if (idx >= 0) {
        all[idx] = result;
      } else {
        all.add(result);
      }
    }
    await Store.saveTransactions(all);
    categories = newCategories;
    await _load();
  }

  Future<void> _delete(Transaction t) async {
    await NotificationService.instance.cancelForTransaction(t.id);
    final all = await Store.loadTransactions();
    all.removeWhere((x) => x.id == t.id);
    await Store.saveTransactions(all);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(title: const Text('ØªØ±Ø§Ú©Ù†Ø´â€ŒÙ‡Ø§ÛŒ ØªÚ©Ø±Ø§Ø±Ø´ÙˆÙ†Ø¯Ù‡')),
      body: tx.isEmpty
          ? const Center(child: Text('ØªØ±Ø§Ú©Ù†Ø´ ØªÚ©Ø±Ø§Ø±Ø´ÙˆÙ†Ø¯Ù‡â€ŒØ§ÛŒ ÙˆØ¬ÙˆØ¯ Ù†Ø¯Ø§Ø±Ø¯.'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: tx.map((t) {
                final next = nextOccurrencePreview(t);
                return Dismissible(
                  key: ValueKey(t.id),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    color: Colors.red.shade400,
                    child: const Icon(Icons.delete, color: Colors.white),
                  ),
                  confirmDismiss: (_) => showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Ø­Ø°Ù ØªØ±Ø§Ú©Ù†Ø´ ØªÚ©Ø±Ø§Ø±Ø´ÙˆÙ†Ø¯Ù‡'),
                      content: const Text('Ø§ÛŒÙ† ØªØ±Ø§Ú©Ù†Ø´ ØªÚ©Ø±Ø§Ø±Ø´ÙˆÙ†Ø¯Ù‡ Ø­Ø°Ù Ø´ÙˆØ¯ØŸ'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Ø§Ù†ØµØ±Ø§Ù')),
                        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Ø­Ø°Ù')),
                      ],
                    ),
                  ),
                  onDismissed: (_) => _delete(t),
                  child: Card(
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: t.type == TxType.income ? Colors.green.shade100 : Colors.red.shade100,
                        child: Icon(
                          iconForCategory(
                            categories.where((c) => c.id == t.categoryId).isEmpty
                                ? Category(id: t.categoryId, name: '', type: t.type)
                                : categories.firstWhere((c) => c.id == t.categoryId),
                            categories,
                          ),
                          color: t.type == TxType.income ? Colors.green.shade800 : Colors.red.shade800,
                        ),
                      ),
                      title: Text(categoryName(t.categoryId)),
                      subtitle: Text(
                        '${_recurrenceLabel(t)}'
                        '${next != null ? ' â€¢ Ø³Ø±Ø±Ø³ÛŒØ¯ Ø¨Ø¹Ø¯ÛŒ: ${ltr(DateFormat('dd.MM.yyyy').format(next))}' : ''}',
                      ),
                      trailing: Text(
                        ltr(t.type == TxType.income ? '+' : '-') + formatMoney(t.amount, currencyOf(t.accountId)),
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: t.type == TxType.income ? Colors.green.shade700 : Colors.red.shade700,
                        ),
                      ),
                      onTap: () => _openEditor(t),
                    ),
                  ),
                );
              }).toList(),
            ),
    );
  }
}

// ============================== Affected-by-deletion transactions ==============================

class AffectedTransactionsScreen extends StatefulWidget {
  const AffectedTransactionsScreen({super.key});
  @override
  State<AffectedTransactionsScreen> createState() => _AffectedTransactionsScreenState();
}

class _AffectedTransactionsScreenState extends State<AffectedTransactionsScreen> {
  List<Transaction> tx = [];
  List<Category> categories = [];
  List<Account> accounts = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await Store.loadTransactions();
    tx = all.where((t) => t.categoryId == '_uncategorized_' || t.note.contains('Ø¯Ø³ØªÙ‡â€ŒØ¨Ù†Ø¯ÛŒ Ù‚Ø¨Ù„ÛŒ:')).toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    categories = await Store.loadCategories();
    accounts = await Store.loadAccounts();
    setState(() => loading = false);
  }

  String categoryName(String id) {
    if (id == '_uncategorized_') return 'Ø¨Ø¯ÙˆÙ†â€ŒØ¯Ø³ØªÙ‡';
    final c = categories.where((c) => c.id == id).toList();
    return c.isEmpty ? 'Ø¨Ø¯ÙˆÙ†â€ŒØ¯Ø³ØªÙ‡' : c.first.name;
  }

  String currencyOf(String accountId) {
    final a = accounts.where((a) => a.id == accountId).toList();
    return a.isEmpty ? 'EUR' : a.first.currency;
  }

  Future<void> _openEditor(Transaction t) async {
    final result = await Navigator.push<Object>(
      context,
      MaterialPageRoute(builder: (_) => TransactionEditor(categories: categories, accounts: accounts, existing: t)),
    );
    if (result == null) return;
    final all = await Store.loadTransactions();
    if (result is DeleteTransactionSignal) {
      all.removeWhere((x) => x.id == result.id);
    } else if (result is Transaction) {
      final idx = all.indexWhere((x) => x.id == result.id);
      if (idx >= 0) {
        all[idx] = result;
      } else {
        all.add(result);
      }
    }
    await Store.saveTransactions(all);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(title: const Text('ØªØ±Ø§Ú©Ù†Ø´â€ŒÙ‡Ø§ÛŒ ØªØ­Øªâ€ŒØªØ£Ø«ÛŒØ± Ø­Ø°Ù Ø¯Ø³ØªÙ‡â€ŒØ¨Ù†Ø¯ÛŒ')),
      body: tx.isEmpty
          ? const Center(child: Text('ØªØ±Ø§Ú©Ù†Ø´ÛŒ Ú©Ù‡ ØªØ­Øªâ€ŒØªØ£Ø«ÛŒØ± Ø­Ø°Ù Ø¯Ø³ØªÙ‡â€ŒØ¨Ù†Ø¯ÛŒ Ù‚Ø±Ø§Ø± Ú¯Ø±ÙØªÙ‡ Ø¨Ø§Ø´Ø¯ ÙˆØ¬ÙˆØ¯ Ù†Ø¯Ø§Ø±Ø¯.'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: tx
                  .map((t) => Card(
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: t.type == TxType.income ? Colors.green.shade100 : Colors.red.shade100,
                            child: Icon(
                              t.type == TxType.income ? Icons.add : Icons.remove,
                              color: t.type == TxType.income ? Colors.green.shade800 : Colors.red.shade800,
                            ),
                          ),
                          title: Text(categoryName(t.categoryId)),
                          subtitle: Text(
                            '${ltr(DateFormat('dd.MM.yyyy').format(t.date))}'
                            '${t.note.isNotEmpty ? ' â€¢ ${t.note}' : ''}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Text(
                            ltr(t.type == TxType.income ? '+' : '-') + formatMoney(t.amount, currencyOf(t.accountId)),
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: t.type == TxType.income ? Colors.green.shade700 : Colors.red.shade700,
                            ),
                          ),
                          onTap: () => _openEditor(t),
                        ),
                      ))
                  .toList(),
            ),
    );
  }
}

// ============================== Transaction editor ==============================

const _weekdayNames = ['Ø¯ÙˆØ´Ù†Ø¨Ù‡', 'Ø³Ù‡â€ŒØ´Ù†Ø¨Ù‡', 'Ú†Ù‡Ø§Ø±Ø´Ù†Ø¨Ù‡', 'Ù¾Ù†Ø¬Ø´Ù†Ø¨Ù‡', 'Ø¬Ù…Ø¹Ù‡', 'Ø´Ù†Ø¨Ù‡', 'ÛŒÚ©Ø´Ù†Ø¨Ù‡'];

// ============================== Scan entry ==============================

class ScanEntryScreen extends StatefulWidget {
  const ScanEntryScreen({super.key});
  @override
  State<ScanEntryScreen> createState() => _ScanEntryScreenState();
}

class _ScanEntryScreenState extends State<ScanEntryScreen> {
  bool busy = false;

  Future<void> _process(bool isPayslip, ScanSource source) async {
    String imagePath;
    try {
      if (source == ScanSource.pdf) {
        final res = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
        if (res == null || res.files.single.path == null) return;
        if (!context.mounted) return;
        setState(() => busy = true);
        imagePath = await rasterizeFirstPdfPage(res.files.single.path!);
      } else {
        final img = await ImagePicker().pickImage(
          source: source == ScanSource.camera ? ImageSource.camera : ImageSource.gallery,
          imageQuality: 85,
          maxWidth: 1800,
          maxHeight: 1800,
        );
        if (img == null) return;
        if (!context.mounted) return;
        setState(() => busy = true);
        imagePath = img.path;
      }
      // Give the OS a brief moment to finish flushing the captured file to
      // disk before handing it to ML Kit (some camera apps return the path
      // slightly before the write completes, which can crash the native
      // image decoder with a null-object exception).
      await Future.delayed(const Duration(milliseconds: 300));
      final imgFile = File(imagePath);
      if (!await imgFile.exists() || await imgFile.length() == 0) {
        throw Exception('ÙØ§ÛŒÙ„ ØªØµÙˆÛŒØ± Ø®ÙˆØ§Ù†Ø¯Ù‡ Ù†Ø´Ø¯. Ù„Ø·ÙØ§Ù‹ Ø¯ÙˆØ¨Ø§Ø±Ù‡ Ø§Ù…ØªØ­Ø§Ù† Ú©Ù†ÛŒØ¯.');
      }
      final text = await extractTextFromImage(imagePath);
      if (!context.mounted) return;
      Transaction? result;
      if (isPayslip) {
        final draft = parsePayslipText(text);
        result = await Navigator.push<Transaction>(
            context, MaterialPageRoute(builder: (_) => PayslipReviewScreen(imagePath: imagePath, initial: draft)));
      } else {
        final draft = parseReceiptText(text);
        result = await Navigator.push<Transaction>(
            context, MaterialPageRoute(builder: (_) => ReceiptReviewScreen(imagePath: imagePath, initial: draft)));
      }
      if (!context.mounted) return;
      if (result != null) Navigator.pop(context, result);
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ø®Ø·Ø§: $e')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget _sourceRow(bool isPayslip) {
    final style = OutlinedButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 12),
      textStyle: const TextStyle(fontSize: 13),
    );
    return Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              style: style,
              onPressed: busy ? null : () => _process(isPayslip, ScanSource.camera),
              icon: const Icon(Icons.camera_alt, size: 18),
              label: const Text('Ø¯ÙˆØ±Ø¨ÛŒÙ†', softWrap: false, overflow: TextOverflow.visible),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: OutlinedButton.icon(
              style: style,
              onPressed: busy ? null : () => _process(isPayslip, ScanSource.gallery),
              icon: const Icon(Icons.photo_library, size: 18),
              label: const Text('Ú¯Ø§Ù„Ø±ÛŒ', softWrap: false, overflow: TextOverflow.visible),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: OutlinedButton.icon(
              style: style,
              onPressed: busy ? null : () => _process(isPayslip, ScanSource.pdf),
              icon: const Icon(Icons.picture_as_pdf, size: 18),
              label: const Text('PDF', softWrap: false, overflow: TextOverflow.visible),
            ),
          ),
        ],
      );
  }

  Widget _section(String title, String subtitle, IconData icon, bool isPayslip) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [Icon(icon), const SizedBox(width: 8), Text(title, style: Theme.of(context).textTheme.titleMedium)]),
              const SizedBox(height: 4),
              Text(subtitle, style: const TextStyle(color: Colors.grey)),
              const SizedBox(height: 12),
              _sourceRow(isPayslip),
            ],
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ø§Ø³Ú©Ù† Ø±Ø³ÛŒØ¯ ÛŒØ§ ÙÛŒØ´ Ø­Ù‚ÙˆÙ‚ÛŒ')),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _section('Ø±Ø³ÛŒØ¯ Ø¬Ø¯ÛŒØ¯', 'ØªØ´Ø®ÛŒØµ Ø¢ÙÙ„Ø§ÛŒÙ† + Ø§Ù…Ú©Ø§Ù† Ø¨Ù‡Ø¨ÙˆØ¯ Ø¨Ø§ Ù‡ÙˆØ´ Ù…ØµÙ†ÙˆØ¹ÛŒ', Icons.receipt_long, false),
              const SizedBox(height: 16),
              _section('ÙÛŒØ´ Ø­Ù‚ÙˆÙ‚ÛŒ Ø¬Ø¯ÛŒØ¯', 'Ø§Ø³ØªØ®Ø±Ø§Ø¬ Brutto/NettoØŒ Ù…Ø§Ù„ÛŒØ§ØªØŒ Ø¨ÛŒÙ…Ù‡ Ùˆ Ú©Ù„Ø§Ø³ Ù…Ø§Ù„ÛŒØ§ØªÛŒ', Icons.badge_outlined, true),
            ],
          ),
          if (busy)
            Container(
              color: Colors.black26,
              child: const Center(
                child: Card(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [CircularProgressIndicator(), SizedBox(height: 12), Text('Ø¯Ø± Ø­Ø§Ù„ ØªØ´Ø®ÛŒØµ Ù…ØªÙ†...')],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ============================== Receipt review ==============================

/// Tries to find a category whose name relates to [hint] (a free-text
/// category label, either a known category id from the offline heuristic,
/// or a natural-language guess returned by Gemini). Falls back to null so
/// the user is asked to pick one themselves rather than guessing wrong.
Category? _matchCategoryHint(String? hint, List<Category> categories, TxType type) {
  if (hint == null || hint.trim().isEmpty) return null;
  final candidates = categories.where((c) => c.type == type).toList();
  final byId = candidates.where((c) => c.id == hint).toList();
  if (byId.isNotEmpty) return byId.first;
  final h = hint.trim().toLowerCase();
  for (final c in candidates) {
    final n = c.name.toLowerCase();
    if (n == h || n.contains(h) || h.contains(n)) return c;
  }
  return null;
}

class ReceiptReviewScreen extends StatefulWidget {
  final String imagePath;
  final ReceiptDraft initial;
  const ReceiptReviewScreen({required this.imagePath, required this.initial, super.key});
  @override
  State<ReceiptReviewScreen> createState() => _ReceiptReviewScreenState();
}

class _ReceiptReviewScreenState extends State<ReceiptReviewScreen> {
  final merchantCtrl = TextEditingController();
  final totalCtrl = TextEditingController();
  DateTime date = DateTime.now();
  List<Category> categories = [];
  List<Account> accounts = [];
  List<Transaction> existingTx = [];
  Category? selectedCategory;
  Account? selectedAccount;
  bool loading = true;
  bool improving = false;
  bool geminiFailed = false;
  bool hasGeminiKey = false;
  late List<ReceiptItemEntry> items;

  @override
  void initState() {
    super.initState();
    merchantCtrl.text = widget.initial.merchant;
    totalCtrl.text = widget.initial.total?.toStringAsFixed(2) ?? '';
    date = widget.initial.date ?? DateTime.now();
    items = List.of(widget.initial.items);
    _load();
  }

  Future<void> _load() async {
    categories = await Store.loadCategories();
    accounts = await Store.loadAccounts();
    existingTx = await Store.loadTransactions();
    selectedAccount = accounts.isEmpty ? null : accounts.first;
    selectedCategory = _matchCategoryHint(widget.initial.categoryHint, categories, TxType.expense);
    final key = await Store.loadGeminiKey();
    hasGeminiKey = key != null && key.trim().isNotEmpty;
    setState(() => loading = false);
    if (hasGeminiKey) unawaited(_improveWithGemini());
  }

  Future<void> _improveWithGemini() async {
    final key = await Store.loadGeminiKey();
    if (key == null || key.trim().isEmpty) return;
    setState(() {
      improving = true;
      geminiFailed = false;
    });
    try {
      final result = await geminiExtractReceipt(key.trim(), widget.imagePath);
      if (result != null) {
        if (result['merchant'] != null) merchantCtrl.text = result['merchant'];
        if (result['total'] != null) totalCtrl.text = (result['total'] as num).toStringAsFixed(2);
        if (result['date'] != null) {
          final parsed = DateTime.tryParse(result['date']);
          if (parsed != null) date = parsed;
        }
        if (result['items'] is List) {
          items = (result['items'] as List).whereType<Map>().map((e) {
            return ReceiptItemEntry(
              name: (e['name'] ?? '').toString(),
              quantity: (e['quantity'] as num?)?.toDouble(),
              price: (e['price'] as num?)?.toDouble(),
            );
          }).where((e) => e.name.trim().isNotEmpty).toList();
        }
        final matched = _matchCategoryHint(result['category']?.toString(), categories, TxType.expense);
        if (matched != null) selectedCategory = matched;
      }
    } catch (e) {
      geminiFailed = true;
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Ø®ÙˆØ§Ù†Ø¯Ù† Ù‡ÙˆØ´Ù…Ù†Ø¯ Ø§ÛŒÙ†â€ŒØ¨Ø§Ø± Ù…Ù…Ú©Ù† Ù†Ø´Ø¯ (Ø³Ø±ÙˆØ± Ø´Ù„ÙˆØº Ø§Ø³Øª ÛŒØ§ Ø®Ø·Ø§ÛŒ Ù…ÙˆÙ‚ØªÛŒ Ø±Ø® Ø¯Ø§Ø¯). Ù…ÛŒâ€ŒØªÙˆØ§Ù†ÛŒØ¯ Ø¯ÙˆØ¨Ø§Ø±Ù‡ Ø§Ù…ØªØ­Ø§Ù† Ú©Ù†ÛŒØ¯ ÛŒØ§ ÙÛŒÙ„Ø¯Ù‡Ø§ Ø±Ø§ Ø¯Ø³ØªÛŒ ØªÚ©Ù…ÛŒÙ„ Ùˆ Ø«Ø¨Øª Ú©Ù†ÛŒØ¯.'),
          duration: Duration(seconds: 6),
        ));
      }
    } finally {
      if (mounted) setState(() => improving = false);
    }
  }

  Future<void> _pickCategory() async {
    final picked = await showModalBottomSheet<Category>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => CategoryPicker(type: TxType.expense, categories: categories),
    );
    categories = await Store.loadCategories();
    if (!context.mounted) return;
    setState(() {
      if (picked != null) selectedCategory = picked;
    });
  }

  Future<void> _addItemRow({int? editIndex}) async {
    final existing = editIndex != null ? items[editIndex] : null;
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final qtyCtrl = TextEditingController(text: existing?.quantity?.toString() ?? '1');
    final priceCtrl = TextEditingController(text: existing?.price?.toString() ?? '');
    final added = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(editIndex == null ? 'Ø§ÙØ²ÙˆØ¯Ù† Ú©Ø§Ù„Ø§' : 'ÙˆÛŒØ±Ø§ÛŒØ´ Ú©Ø§Ù„Ø§'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Ù†Ø§Ù… Ú©Ø§Ù„Ø§'), autofocus: true),
            const SizedBox(height: 8),
            TextField(controller: qtyCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'ØªØ¹Ø¯Ø§Ø¯')),
            const SizedBox(height: 8),
            TextField(controller: priceCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Ù‚ÛŒÙ…Øª')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Ø§Ù†ØµØ±Ø§Ù')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(editIndex == null ? 'Ø§ÙØ²ÙˆØ¯Ù†' : 'Ø°Ø®ÛŒØ±Ù‡')),
        ],
      ),
    );
    if (added != true || nameCtrl.text.trim().isEmpty) return;
    final entry = ReceiptItemEntry(
      name: nameCtrl.text.trim(),
      quantity: double.tryParse(qtyCtrl.text.replaceAll(',', '.')),
      price: double.tryParse(priceCtrl.text.replaceAll(',', '.')),
    );
    setState(() {
      if (editIndex != null) {
        items[editIndex] = entry;
      } else {
        items.add(entry);
      }
    });
  }

  Future<void> _save({required bool draft}) async {
    final total = double.tryParse(totalCtrl.text.replaceAll(',', '.'));
    if (total == null || total <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ù…Ø¨Ù„Øº Ú©Ù„ Ù…Ø¹ØªØ¨Ø± ÙˆØ§Ø±Ø¯ Ú©Ù†ÛŒØ¯.')));
      return;
    }
    if (!draft && selectedCategory == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ø¨Ø±Ø§ÛŒ Ø«Ø¨Øª Ù†Ù‡Ø§ÛŒÛŒØŒ Ø¯Ø³ØªÙ‡â€ŒØ¨Ù†Ø¯ÛŒ Ø±Ø§ Ø§Ù†ØªØ®Ø§Ø¨ Ú©Ù†ÛŒØ¯.')));
      return;
    }
    if (!draft && selectedAccount == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ø¨Ø±Ø§ÛŒ Ø«Ø¨Øª Ù†Ù‡Ø§ÛŒÛŒØŒ Ø­Ø³Ø§Ø¨ Ø±Ø§ Ø§Ù†ØªØ®Ø§Ø¨ Ú©Ù†ÛŒØ¯.')));
      return;
    }
    final duplicate = existingTx.any((t) =>
        t.type == TxType.expense &&
        (t.amount - total).abs() < 0.01 &&
        t.date.year == date.year &&
        t.date.month == date.month &&
        t.date.day == date.day);
    if (duplicate) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('ØªØ±Ø§Ú©Ù†Ø´ Ù…Ø´Ø§Ø¨Ù‡'),
          content: const Text('ÛŒÚ© ØªØ±Ø§Ú©Ù†Ø´ Ø¨Ø§ Ù‡Ù…ÛŒÙ† Ù…Ø¨Ù„Øº Ùˆ ØªØ§Ø±ÛŒØ® Ù‚Ø¨Ù„Ø§Ù‹ Ø«Ø¨Øª Ø´Ø¯Ù‡. Ø§ÛŒÙ† Ù…Ù…Ú©Ù† Ø§Ø³Øª Ø§Ø³Ú©Ù† ØªÚ©Ø±Ø§Ø±ÛŒ Ù‡Ù…ÛŒÙ† Ø±Ø³ÛŒØ¯ Ø¨Ø§Ø´Ø¯. Ø¨Ø§Ø² Ù‡Ù… Ø«Ø¨Øª Ø´ÙˆØ¯ØŸ'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Ø§Ù†ØµØ±Ø§Ù')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Ø¨Ù„Ù‡ØŒ Ø«Ø¨Øª Ø´ÙˆØ¯')),
          ],
        ),
      );
      if (proceed != true) return;
    }
    if (!context.mounted) return;
    final result = Transaction(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      type: TxType.expense,
      amount: total,
      categoryId: selectedCategory?.id ?? '_uncategorized_',
      accountId: selectedAccount?.id ?? 'default',
      date: date,
      note: merchantCtrl.text.trim(),
      draft: draft,
      items: items,
    );
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await confirmDiscardChanges(context);
        if (!context.mounted) return;
        if (shouldPop) Navigator.pop(context);
      },
      child: Scaffold(
      appBar: AppBar(title: const Text('Ø¨Ø±Ø±Ø³ÛŒ Ø±Ø³ÛŒØ¯')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          GestureDetector(
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => FullImageViewer(imagePath: widget.imagePath))),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.file(File(widget.imagePath), height: 180, width: double.infinity, fit: BoxFit.cover),
            ),
          ),
          const SizedBox(height: 12),
          if (hasGeminiKey)
            OutlinedButton.icon(
              onPressed: improving ? null : _improveWithGemini,
              icon: improving
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(geminiFailed ? Icons.refresh : Icons.auto_awesome),
              label: Text(improving ? 'Ø¯Ø± Ø­Ø§Ù„ Ø¨Ù‡Ø¨ÙˆØ¯...' : (geminiFailed ? 'ØªÙ„Ø§Ø´ Ù…Ø¬Ø¯Ø¯ Ø¨Ø§ Ù‡ÙˆØ´ Ù…ØµÙ†ÙˆØ¹ÛŒ' : 'Ø¨Ù‡Ø¨ÙˆØ¯ Ø¨Ø§ Ù‡ÙˆØ´ Ù…ØµÙ†ÙˆØ¹ÛŒ')),
            )
          else
            const Text(
              'Ø¨Ø±Ø§ÛŒ Ø¨Ù‡Ø¨ÙˆØ¯ Ø¯Ù‚Øª Ø¨Ø§ Ù‡ÙˆØ´ Ù…ØµÙ†ÙˆØ¹ÛŒØŒ Ú©Ù„ÛŒØ¯ Gemini Ø±Ø§ Ø§Ø² Ù…Ù†ÙˆÛŒ Â«ØªÙ†Ø¸ÛŒÙ…Ø§ØªÂ» ÙˆØ§Ø±Ø¯ Ú©Ù†ÛŒØ¯.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          if (geminiFailed)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'Ø®ÙˆØ§Ù†Ø¯Ù† Ù‡ÙˆØ´Ù…Ù†Ø¯ Ù…Ù…Ú©Ù† Ù†Ø´Ø¯. ÙÛŒÙ„Ø¯Ù‡Ø§ÛŒ Ø²ÛŒØ± Ø±Ø§ Ø¨Ø±Ø±Ø³ÛŒ Ùˆ Ø¯Ø± ØµÙˆØ±Øª Ù†ÛŒØ§Ø² Ø¯Ø³ØªÛŒ Ø§ØµÙ„Ø§Ø­ Ú©Ù†ÛŒØ¯.',
                style: TextStyle(color: Colors.orange, fontSize: 12),
              ),
            ),
          const SizedBox(height: 16),
          TextField(controller: merchantCtrl, decoration: const InputDecoration(labelText: 'ÙØ±ÙˆØ´Ú¯Ø§Ù‡', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(
            controller: totalCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Ù…Ø¨Ù„Øº Ú©Ù„', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          ListTile(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: Colors.grey.shade400)),
            title: Text('ØªØ§Ø±ÛŒØ®: ${ltr(DateFormat('dd.MM.yyyy').format(date))}'),
            trailing: const Icon(Icons.calendar_month),
            onTap: () async {
              final d = await showDatePicker(
                context: context,
                firstDate: DateTime(2000),
                lastDate: DateTime(2100),
                initialDate: date,
                builder: (ctx, child) => Directionality(textDirection: TextDirection.ltr, child: child!),
              );
              if (d != null) setState(() => date = d);
            },
          ),
          const SizedBox(height: 12),
          ListTile(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: Colors.grey.shade400)),
            title: Text(selectedCategory?.name ?? 'Ø§Ù†ØªØ®Ø§Ø¨ Ø¯Ø³ØªÙ‡â€ŒØ¨Ù†Ø¯ÛŒ'),
            trailing: const Icon(Icons.chevron_left),
            onTap: _pickCategory,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<Account>(
            initialValue: selectedAccount,
            decoration: const InputDecoration(labelText: 'Ø­Ø³Ø§Ø¨', border: OutlineInputBorder()),
            items: accounts.map((a) => DropdownMenuItem(value: a, child: Text('${a.name} (${a.currency})'))).toList(),
            onChanged: (v) => setState(() => selectedAccount = v),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Ø§Ù‚Ù„Ø§Ù… Ø®Ø±ÛŒØ¯', style: Theme.of(context).textTheme.titleMedium),
              TextButton.icon(onPressed: _addItemRow, icon: const Icon(Icons.add), label: const Text('Ø§ÙØ²ÙˆØ¯Ù†')),
            ],
          ),
          if (items.isEmpty)
            const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('Ú©Ø§Ù„Ø§ÛŒÛŒ Ø«Ø¨Øª Ù†Ø´Ø¯Ù‡.', style: TextStyle(color: Colors.grey))),
          ...items.asMap().entries.map((e) {
            final i = e.key;
            final it = e.value;
            return Card(
              child: ListTile(
                dense: true,
                title: Text(it.name),
                subtitle: Text(
                  '${it.quantity != null ? 'ØªØ¹Ø¯Ø§Ø¯: ${ltr(it.quantity!.toStringAsFixed(it.quantity! % 1 == 0 ? 0 : 2))}' : ''}'
                  '${it.quantity != null && it.price != null ? ' â€¢ ' : ''}'
                  '${it.price != null ? ltr('â‚¬${it.price!.toStringAsFixed(2)}') : ''}',
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: () => setState(() => items.removeAt(i)),
                ),
                onTap: () => _addItemRow(editIndex: i),
              ),
            );
          }),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(child: OutlinedButton(onPressed: () => _save(draft: true), child: const Text('Ø°Ø®ÛŒØ±Ù‡ Ù¾ÛŒØ´â€ŒÙ†ÙˆÛŒØ³'))),
              const SizedBox(width: 8),
              Expanded(child: FilledButton(onPressed: () => _save(draft: false), child: const Text('ØªØ£ÛŒÛŒØ¯ Ùˆ Ø«Ø¨Øª Ù†Ù‡Ø§ÛŒÛŒ'))),
            ],
          ),
        ],
      ),
    ),
    );
  }
}

// ============================== Payslip review ==============================

const _payslipLabels = <String, String>{
  'brutto': 'Ø­Ù‚ÙˆÙ‚ Ù†Ø§Ø®Ø§Ù„Øµ (Brutto)',
  'netto': 'Ø­Ù‚ÙˆÙ‚ Ø®Ø§Ù„Øµ (Netto)',
  'lohnsteuer': 'Ù…Ø§Ù„ÛŒØ§Øª Ø¨Ø± Ø¯Ø±Ø¢Ù…Ø¯ (Lohnsteuer)',
  'solidaritaetszuschlag': 'Ù…Ø§Ù„ÛŒØ§Øª Ù‡Ù…Ø¨Ø³ØªÚ¯ÛŒ (SolidaritÃ¤tszuschlag)',
  'kirchensteuer': 'Ù…Ø§Ù„ÛŒØ§Øª Ú©Ù„ÛŒØ³Ø§ (Kirchensteuer)',
  'krankenversicherung': 'Ø¨ÛŒÙ…Ù‡ Ø¯Ø±Ù…Ø§Ù†ÛŒ (Krankenversicherung)',
  'pflegeversicherung': 'Ø¨ÛŒÙ…Ù‡ Ù…Ø±Ø§Ù‚Ø¨Øª (Pflegeversicherung)',
  'rentenversicherung': 'Ø¨ÛŒÙ…Ù‡ Ø¨Ø§Ø²Ù†Ø´Ø³ØªÚ¯ÛŒ (Rentenversicherung)',
  'arbeitslosenversicherung': 'Ø¨ÛŒÙ…Ù‡ Ø¨ÛŒÚ©Ø§Ø±ÛŒ (Arbeitslosenversicherung)',
};

class PayslipReviewScreen extends StatefulWidget {
  final String imagePath;
  final Map<String, dynamic> initial;
  const PayslipReviewScreen({required this.imagePath, required this.initial, super.key});
  @override
  State<PayslipReviewScreen> createState() => _PayslipReviewScreenState();
}

class _PayslipReviewScreenState extends State<PayslipReviewScreen> {
  final Map<String, TextEditingController> numCtrls = {};
  final steuerklasseCtrl = TextEditingController();
  final arbeitgeberCtrl = TextEditingController();
  final monatCtrl = TextEditingController();
  DateTime date = DateTime.now();
  List<Category> categories = [];
  List<Account> accounts = [];
  Category? selectedCategory;
  Account? selectedAccount;
  bool loading = true;
  bool improving = false;
  bool geminiFailed = false;
  bool hasGeminiKey = false;
  List<Transaction> existingTx = [];

  @override
  void initState() {
    super.initState();
    for (final key in _payslipLabels.keys) {
      numCtrls[key] = TextEditingController(text: widget.initial[key] != null ? (widget.initial[key] as num).toStringAsFixed(2) : '');
    }
    steuerklasseCtrl.text = widget.initial['steuerklasse']?.toString() ?? '';
    arbeitgeberCtrl.text = widget.initial['arbeitgeber']?.toString() ?? '';
    monatCtrl.text = widget.initial['abrechnungsmonat']?.toString() ?? '';
    if (widget.initial['date'] != null) {
      final parsed = DateTime.tryParse(widget.initial['date'].toString());
      if (parsed != null) date = parsed;
    }
    _load();
  }

  Future<void> _load() async {
    categories = await Store.loadCategories();
    accounts = await Store.loadAccounts();
    existingTx = await Store.loadTransactions();
    selectedAccount = accounts.isEmpty ? null : accounts.first;
    final match = categories.where((c) => c.id == 'i_salary').toList();
    selectedCategory = match.isEmpty ? null : match.first;
    final key = await Store.loadGeminiKey();
    hasGeminiKey = key != null && key.trim().isNotEmpty;
    setState(() => loading = false);
    if (hasGeminiKey) unawaited(_improveWithGemini());
  }

  Future<void> _improveWithGemini() async {
    final key = await Store.loadGeminiKey();
    if (key == null || key.trim().isEmpty) return;
    setState(() {
      improving = true;
      geminiFailed = false;
    });
    try {
      final result = await geminiExtractPayslip(key.trim(), widget.imagePath);
      if (result != null) {
        for (final k in _payslipLabels.keys) {
          if (result[k] != null) numCtrls[k]!.text = (result[k] as num).toStringAsFixed(2);
        }
        if (result['steuerklasse'] != null) steuerklasseCtrl.text = result['steuerklasse'].toString();
        if (result['arbeitgeber'] != null) arbeitgeberCtrl.text = result['arbeitgeber'].toString();
        if (result['abrechnungsmonat'] != null) monatCtrl.text = result['abrechnungsmonat'].toString();
        if (result['date'] != null) {
          final parsed = DateTime.tryParse(result['date'].toString());
          if (parsed != null) setState(() => date = parsed);
        }
      }
    } catch (e) {
      geminiFailed = true;
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Ø®ÙˆØ§Ù†Ø¯Ù† Ù‡ÙˆØ´Ù…Ù†Ø¯ Ø§ÛŒÙ†â€ŒØ¨Ø§Ø± Ù…Ù…Ú©Ù† Ù†Ø´Ø¯ (Ø³Ø±ÙˆØ± Ø´Ù„ÙˆØº Ø§Ø³Øª ÛŒØ§ Ø®Ø·Ø§ÛŒ Ù…ÙˆÙ‚ØªÛŒ Ø±Ø® Ø¯Ø§Ø¯). Ù…ÛŒâ€ŒØªÙˆØ§Ù†ÛŒØ¯ Ø¯ÙˆØ¨Ø§Ø±Ù‡ Ø§Ù…ØªØ­Ø§Ù† Ú©Ù†ÛŒØ¯ ÛŒØ§ ÙÛŒÙ„Ø¯Ù‡Ø§ Ø±Ø§ Ø¯Ø³ØªÛŒ ØªÚ©Ù…ÛŒÙ„ Ùˆ Ø«Ø¨Øª Ú©Ù†ÛŒØ¯.'),
          duration: Duration(seconds: 6),
        ));
      }
    } finally {
      if (mounted) setState(() => improving = false);
    }
  }

  Future<void> _pickCategory() async {
    final picked = await showModalBottomSheet<Category>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => CategoryPicker(type: TxType.income, categories: categories),
    );
    categories = await Store.loadCategories();
    if (!context.mounted) return;
    setState(() {
      if (picked != null) selectedCategory = picked;
    });
  }

  Future<void> _save({required bool draft}) async {
    final netto = double.tryParse(numCtrls['netto']!.text.replaceAll(',', '.'));
    if (netto == null || netto <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ù…Ø¨Ù„Øº Netto Ù…Ø¹ØªØ¨Ø± ÙˆØ§Ø±Ø¯ Ú©Ù†ÛŒØ¯.')));
      return;
    }
    if (!draft && selectedCategory == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ø¨Ø±Ø§ÛŒ Ø«Ø¨Øª Ù†Ù‡Ø§ÛŒÛŒØŒ Ø¯Ø³ØªÙ‡â€ŒØ¨Ù†Ø¯ÛŒ Ø±Ø§ Ø§Ù†ØªØ®Ø§Ø¨ Ú©Ù†ÛŒØ¯.')));
      return;
    }
    if (!draft && selectedAccount == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ø¨Ø±Ø§ÛŒ Ø«Ø¨Øª Ù†Ù‡Ø§ÛŒÛŒØŒ Ø­Ø³Ø§Ø¨ Ø±Ø§ Ø§Ù†ØªØ®Ø§Ø¨ Ú©Ù†ÛŒØ¯.')));
      return;
    }
    double? num_(String k) => double.tryParse(numCtrls[k]!.text.trim().replaceAll(',', '.'));
    final details = PayslipDetails(
      brutto: num_('brutto'),
      netto: num_('netto'),
      lohnsteuer: num_('lohnsteuer'),
      solidaritaetszuschlag: num_('solidaritaetszuschlag'),
      kirchensteuer: num_('kirchensteuer'),
      krankenversicherung: num_('krankenversicherung'),
      pflegeversicherung: num_('pflegeversicherung'),
      rentenversicherung: num_('rentenversicherung'),
      arbeitslosenversicherung: num_('arbeitslosenversicherung'),
      steuerklasse: steuerklasseCtrl.text.trim().isEmpty ? null : steuerklasseCtrl.text.trim(),
      arbeitgeber: arbeitgeberCtrl.text.trim().isEmpty ? null : arbeitgeberCtrl.text.trim(),
      abrechnungsmonat: monatCtrl.text.trim().isEmpty ? null : monatCtrl.text.trim(),
    );
    final duplicate = existingTx.any((t) =>
        t.type == TxType.income &&
        (t.amount - netto).abs() < 0.01 &&
        t.date.year == date.year &&
        t.date.month == date.month &&
        t.date.day == date.day);
    if (duplicate) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('ØªØ±Ø§Ú©Ù†Ø´ Ù…Ø´Ø§Ø¨Ù‡'),
          content: const Text('ÛŒÚ© ØªØ±Ø§Ú©Ù†Ø´ Ø¨Ø§ Ù‡Ù…ÛŒÙ† Ù…Ø¨Ù„Øº Ùˆ ØªØ§Ø±ÛŒØ® Ù‚Ø¨Ù„Ø§Ù‹ Ø«Ø¨Øª Ø´Ø¯Ù‡. Ø§ÛŒÙ† Ù…Ù…Ú©Ù† Ø§Ø³Øª Ø§Ø³Ú©Ù† ØªÚ©Ø±Ø§Ø±ÛŒ Ù‡Ù…ÛŒÙ† ÙÛŒØ´ Ø¨Ø§Ø´Ø¯. Ø¨Ø§Ø² Ù‡Ù… Ø«Ø¨Øª Ø´ÙˆØ¯ØŸ'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Ø§Ù†ØµØ±Ø§Ù')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Ø¨Ù„Ù‡ØŒ Ø«Ø¨Øª Ø´ÙˆØ¯')),
          ],
        ),
      );
      if (proceed != true) return;
    }
    if (!context.mounted) return;
    final result = Transaction(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      type: TxType.income,
      amount: netto,
      categoryId: selectedCategory?.id ?? '_uncategorized_',
      accountId: selectedAccount?.id ?? 'default',
      date: date,
      note: '',
      draft: draft,
      payslipDetails: details,
    );
    if (!context.mounted) return;
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await confirmDiscardChanges(context);
        if (!context.mounted) return;
        if (shouldPop) Navigator.pop(context);
      },
      child: Scaffold(
      appBar: AppBar(title: const Text('Ø¨Ø±Ø±Ø³ÛŒ ÙÛŒØ´ Ø­Ù‚ÙˆÙ‚ÛŒ')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          GestureDetector(
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => FullImageViewer(imagePath: widget.imagePath))),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.file(File(widget.imagePath), height: 180, width: double.infinity, fit: BoxFit.cover),
            ),
          ),
          const SizedBox(height: 12),
          if (hasGeminiKey)
            OutlinedButton.icon(
              onPressed: improving ? null : _improveWithGemini,
              icon: improving
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : Icon(geminiFailed ? Icons.refresh : Icons.auto_awesome),
              label: Text(improving ? 'Ø¯Ø± Ø­Ø§Ù„ Ø¨Ù‡Ø¨ÙˆØ¯...' : (geminiFailed ? 'ØªÙ„Ø§Ø´ Ù…Ø¬Ø¯Ø¯ Ø¨Ø§ Ù‡ÙˆØ´ Ù…ØµÙ†ÙˆØ¹ÛŒ' : 'Ø¨Ù‡Ø¨ÙˆØ¯ Ø¨Ø§ Ù‡ÙˆØ´ Ù…ØµÙ†ÙˆØ¹ÛŒ')),
            )
          else
            const Text(
              'Ø¨Ø±Ø§ÛŒ Ø¨Ù‡Ø¨ÙˆØ¯ Ø¯Ù‚Øª Ø¨Ø§ Ù‡ÙˆØ´ Ù…ØµÙ†ÙˆØ¹ÛŒØŒ Ú©Ù„ÛŒØ¯ Gemini Ø±Ø§ Ø§Ø² Ù…Ù†ÙˆÛŒ Â«ØªÙ†Ø¸ÛŒÙ…Ø§ØªÂ» ÙˆØ§Ø±Ø¯ Ú©Ù†ÛŒØ¯.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          if (geminiFailed)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'Ø®ÙˆØ§Ù†Ø¯Ù† Ù‡ÙˆØ´Ù…Ù†Ø¯ Ù…Ù…Ú©Ù† Ù†Ø´Ø¯. ÙÛŒÙ„Ø¯Ù‡Ø§ÛŒ Ø²ÛŒØ± Ø±Ø§ Ø¨Ø±Ø±Ø³ÛŒ Ùˆ Ø¯Ø± ØµÙˆØ±Øª Ù†ÛŒØ§Ø² Ø¯Ø³ØªÛŒ Ø§ØµÙ„Ø§Ø­ Ú©Ù†ÛŒØ¯.',
                style: TextStyle(color: Colors.orange, fontSize: 12),
              ),
            ),
          const SizedBox(height: 16),
          TextField(controller: arbeitgeberCtrl, decoration: const InputDecoration(labelText: 'Ú©Ø§Ø±ÙØ±Ù…Ø§ (Arbeitgeber)', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(controller: monatCtrl, decoration: const InputDecoration(labelText: 'Ù…Ø§Ù‡ (Abrechnungsmonat)', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(controller: steuerklasseCtrl, decoration: const InputDecoration(labelText: 'Ú©Ù„Ø§Ø³ Ù…Ø§Ù„ÛŒØ§ØªÛŒ (Steuerklasse)', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          ...(_payslipLabels.keys.map((k) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TextField(
                  controller: numCtrls[k],
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: _payslipLabels[k], border: const OutlineInputBorder()),
                ),
              ))),
          ListTile(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: Colors.grey.shade400)),
            title: Text('ØªØ§Ø±ÛŒØ®: ${ltr(DateFormat('dd.MM.yyyy').format(date))}'),
            trailing: const Icon(Icons.calendar_month),
            onTap: () async {
              final d = await showDatePicker(
                context: context,
                firstDate: DateTime(2000),
                lastDate: DateTime(2100),
                initialDate: date,
                builder: (ctx, child) => Directionality(textDirection: TextDirection.ltr, child: child!),
              );
              if (d != null) setState(() => date = d);
            },
          ),
          const SizedBox(height: 12),
          ListTile(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: Colors.grey.shade400)),
            title: Text(selectedCategory?.name ?? 'Ø§Ù†ØªØ®Ø§Ø¨ Ø¯Ø³ØªÙ‡â€ŒØ¨Ù†Ø¯ÛŒ'),
            trailing: const Icon(Icons.chevron_left),
            onTap: _pickCategory,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<Account>(
            initialValue: selectedAccount,
            decoration: const InputDecoration(labelText: 'Ø­Ø³Ø§Ø¨', border: OutlineInputBorder()),
            items: accounts.map((a) => DropdownMenuItem(value: a, child: Text('${a.name} (${a.currency})'))).toList(),
            onChanged: (v) => setState(() => selectedAccount = v),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(child: OutlinedButton(onPressed: () => _save(draft: true), child: const Text('Ø°Ø®ÛŒØ±Ù‡ Ù¾ÛŒØ´â€ŒÙ†ÙˆÛŒØ³'))),
              const SizedBox(width: 8),
              Expanded(child: FilledButton(onPressed: () => _save(draft: false), child: const Text('ØªØ£ÛŒÛŒØ¯ Ùˆ Ø«Ø¨Øª Ù†Ù‡Ø§ÛŒÛŒ'))),
            ],
          ),
        ],
      ),
    ),
    );
  }
}

/// Signals that the user wants to delete the transaction being edited,
/// as opposed to saving it or cancelling.
class DeleteTransactionSignal {
  final String id;
  const DeleteTransactionSignal(this.id);
}

class TransactionEditor extends StatefulWidget {
  final List<Category> categories;
  final List<Account> accounts;
  final Transaction? existing;
  const TransactionEditor({required this.categories, required this.accounts, this.existing, super.key});
  @override
  State<TransactionEditor> createState() => _TransactionEditorState();
}

class _TransactionEditorState extends State<TransactionEditor> {
  late TxType type;
  final amountCtrl = TextEditingController();
  final noteCtrl = TextEditingController();
  final dayCtrl = TextEditingController();
  final intervalCtrl = TextEditingController();
  final installmentsCtrl = TextEditingController();
  Category? selectedCategory;
  Account? selectedAccount;
  DateTime date = DateTime.now();
  RecurrenceFrequency recurrence = RecurrenceFrequency.none;
  int weekday = DateTime.now().weekday;
  DateTime? endDate;
  String endMode = 'unlimited'; // 'unlimited' | 'count' | 'date'
  bool notifyEnabled = false;
  bool notifyLastTwoEnabled = false;
  final notifyMessageCtrl = TextEditingController();
  bool notifyEachEnabled = false;
  final notifyDaysCtrl = TextEditingController();
  bool draft = false;
  bool _dirty = false;
  List<Category> categories = [];
  List<ReceiptItemEntry> items = [];
  final Map<String, TextEditingController> payslipNumCtrls = {
    for (final k in _payslipLabels.keys) k: TextEditingController(),
  };
  final payslipSteuerklasseCtrl = TextEditingController();
  final payslipArbeitgeberCtrl = TextEditingController();
  final payslipMonatCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    categories = widget.categories;
    final e = widget.existing;
    type = e?.type ?? TxType.expense;
    selectedAccount = widget.accounts.isEmpty
        ? null
        : widget.accounts.firstWhere((a) => a.id == e?.accountId, orElse: () => widget.accounts.first);
    if (e != null) {
      amountCtrl.text = e.amount.toStringAsFixed(2);
      noteCtrl.text = e.note;
      date = e.date;
      recurrence = e.recurrence;
      dayCtrl.text = e.recurrenceDay?.toString() ?? date.day.toString();
      weekday = e.recurrenceWeekday ?? date.weekday;
      intervalCtrl.text = e.recurrenceIntervalDays?.toString() ?? '';
      installmentsCtrl.text = e.installments?.toString() ?? '';
      endDate = e.recurrenceEndDate;
      endMode = e.recurrenceEndDate != null ? 'date' : (e.installments != null ? 'count' : 'unlimited');
      notifyEnabled = e.notifyEnabled;
      notifyLastTwoEnabled = e.notifyLastTwoEnabled;
      notifyMessageCtrl.text = e.notifyMessage;
      notifyEachEnabled = e.notifyDaysBeforeEach != null;
      notifyDaysCtrl.text = e.notifyDaysBeforeEach?.toString() ?? '';
      draft = e.draft;
      items = List.of(e.items);
      if (e.payslipDetails != null) {
        final pd = e.payslipDetails!;
        final map = {
          'brutto': pd.brutto,
          'netto': pd.netto,
          'lohnsteuer': pd.lohnsteuer,
          'solidaritaetszuschlag': pd.solidaritaetszuschlag,
          'kirchensteuer': pd.kirchensteuer,
          'krankenversicherung': pd.krankenversicherung,
          'pflegeversicherung': pd.pflegeversicherung,
          'rentenversicherung': pd.rentenversicherung,
          'arbeitslosenversicherung': pd.arbeitslosenversicherung,
        };
        for (final k in _payslipLabels.keys) {
          payslipNumCtrls[k]!.text = map[k] != null ? map[k]!.toStringAsFixed(2) : '';
        }
        payslipSteuerklasseCtrl.text = pd.steuerklasse ?? '';
        payslipArbeitgeberCtrl.text = pd.arbeitgeber ?? '';
        payslipMonatCtrl.text = pd.abrechnungsmonat ?? '';
      }
      final match = categories.where((c) => c.id == e.categoryId).toList();
      selectedCategory = match.isEmpty ? null : match.first;
    }
    amountCtrl.addListener(() => _dirty = true);
    noteCtrl.addListener(() => _dirty = true);
    dayCtrl.addListener(() => _dirty = true);
    intervalCtrl.addListener(() => _dirty = true);
    installmentsCtrl.addListener(() => _dirty = true);
    notifyMessageCtrl.addListener(() => _dirty = true);
    notifyDaysCtrl.addListener(() => _dirty = true);
    for (final c in payslipNumCtrls.values) {
      c.addListener(() => _dirty = true);
    }
    payslipSteuerklasseCtrl.addListener(() => _dirty = true);
    payslipArbeitgeberCtrl.addListener(() => _dirty = true);
    payslipMonatCtrl.addListener(() => _dirty = true);
  }

  Future<void> _pickCategory() async {
    final picked = await showModalBottomSheet<Category>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => CategoryPicker(type: type, categories: categories),
    );
    // refresh in case a new category/subcategory was added inside the picker
    final refreshed = await Store.loadCategories();
    if (!context.mounted) return;
    setState(() {
      categories = refreshed;
      if (picked != null) {
        selectedCategory = picked;
        _dirty = true;
      }
    });
  }

  Future<bool> _save() async {
    final amount = double.tryParse(amountCtrl.text.replaceAll(',', '.'));
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ù…Ø¨Ù„Øº Ù…Ø¹ØªØ¨Ø± ÙˆØ§Ø±Ø¯ Ú©Ù†ÛŒØ¯.')));
      return false;
    }
    if (selectedCategory == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('ÛŒÚ© Ø¯Ø³ØªÙ‡â€ŒØ¨Ù†Ø¯ÛŒ Ø§Ù†ØªØ®Ø§Ø¨ Ú©Ù†ÛŒØ¯.')));
      return false;
    }
    if (selectedAccount == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('ÛŒÚ© Ø­Ø³Ø§Ø¨ Ø§Ù†ØªØ®Ø§Ø¨ Ú©Ù†ÛŒØ¯.')));
      return false;
    }
    int? recDay;
    int? recWeekday;
    int? recInterval;
    int? recInstallments;
    DateTime? recEndDate;
    if (recurrence == RecurrenceFrequency.monthly || recurrence == RecurrenceFrequency.quarterly) {
      recDay = int.tryParse(dayCtrl.text);
      if (recDay == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ø±ÙˆØ² Ø³Ø±Ø±Ø³ÛŒØ¯ Ø¯Ø± Ù…Ø§Ù‡ Ø±Ø§ ÙˆØ§Ø±Ø¯ Ú©Ù†ÛŒØ¯.')));
        return false;
      }
      if (recDay < 1) recDay = 1;
      if (recDay > 31) recDay = 31;
    } else if (recurrence == RecurrenceFrequency.weekly) {
      recWeekday = weekday;
    } else if (recurrence == RecurrenceFrequency.custom) {
      recInterval = int.tryParse(intervalCtrl.text);
      if (recInterval == null || recInterval <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('ØªØ¹Ø¯Ø§Ø¯ Ø±ÙˆØ² Ø¨Ø§Ø²Ù‡ Ø±Ø§ Ø¯Ø±Ø³Øª ÙˆØ§Ø±Ø¯ Ú©Ù†ÛŒØ¯.')));
        return false;
      }
    }
    if (recurrence != RecurrenceFrequency.none) {
      if (endMode == 'date') {
        recEndDate = endDate;
      } else if (endMode == 'count') {
        recInstallments = int.tryParse(installmentsCtrl.text);
      }
      // endMode == 'unlimited': leave both recEndDate and recInstallments null
    }
    final id = widget.existing?.id ?? DateTime.now().microsecondsSinceEpoch.toString();
    PayslipDetails? payslipDetails;
    if (type == TxType.income) {
      double? num_(String k) {
        final t = payslipNumCtrls[k]!.text.trim();
        return t.isEmpty ? null : double.tryParse(t.replaceAll(',', '.'));
      }

      final hasAny = payslipNumCtrls.values.any((c) => c.text.trim().isNotEmpty) ||
          payslipSteuerklasseCtrl.text.trim().isNotEmpty ||
          payslipArbeitgeberCtrl.text.trim().isNotEmpty ||
          payslipMonatCtrl.text.trim().isNotEmpty;
      if (hasAny) {
        payslipDetails = PayslipDetails(
          brutto: num_('brutto'),
          netto: num_('netto'),
          lohnsteuer: num_('lohnsteuer'),
          solidaritaetszuschlag: num_('solidaritaetszuschlag'),
          kirchensteuer: num_('kirchensteuer'),
          krankenversicherung: num_('krankenversicherung'),
          pflegeversicherung: num_('pflegeversicherung'),
          rentenversicherung: num_('rentenversicherung'),
          arbeitslosenversicherung: num_('arbeitslosenversicherung'),
          steuerklasse: payslipSteuerklasseCtrl.text.trim().isEmpty ? null : payslipSteuerklasseCtrl.text.trim(),
          arbeitgeber: payslipArbeitgeberCtrl.text.trim().isEmpty ? null : payslipArbeitgeberCtrl.text.trim(),
          abrechnungsmonat: payslipMonatCtrl.text.trim().isEmpty ? null : payslipMonatCtrl.text.trim(),
        );
      }
    }
    final result = Transaction(
      id: id,
      type: type,
      amount: amount,
      categoryId: selectedCategory!.id,
      accountId: selectedAccount!.id,
      date: date,
      note: noteCtrl.text.trim(),
      recurrence: recurrence,
      recurrenceDay: recDay,
      recurrenceWeekday: recWeekday,
      recurrenceIntervalDays: recInterval,
      installments: recInstallments,
      recurrenceEndDate: recEndDate,
      draft: draft,
      items: items,
      notifyEnabled: notifyEnabled,
      notifyLastTwoEnabled: notifyEnabled && notifyLastTwoEnabled,
      notifyMessage: notifyMessageCtrl.text.trim(),
      notifyDaysBeforeEach: notifyEnabled && notifyEachEnabled ? int.tryParse(notifyDaysCtrl.text) : null,
      payslipDetails: payslipDetails,
    );
    if (notifyEnabled) {
      await NotificationService.instance.scheduleForTransaction(result, selectedCategory!.name);
    } else {
      await NotificationService.instance.cancelForTransaction(result.id);
    }
    if (!context.mounted) return true;
    Navigator.pop(context, result);
    return true;
  }

  Future<void> _addItemRow({int? editIndex}) async {
    final existing = editIndex != null ? items[editIndex] : null;
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final qtyCtrl = TextEditingController(text: existing?.quantity?.toString() ?? '1');
    final priceCtrl = TextEditingController(text: existing?.price?.toString() ?? '');
    final added = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(editIndex == null ? 'Ø§ÙØ²ÙˆØ¯Ù† Ú©Ø§Ù„Ø§' : 'ÙˆÛŒØ±Ø§ÛŒØ´ Ú©Ø§Ù„Ø§'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Ù†Ø§Ù… Ú©Ø§Ù„Ø§'), autofocus: true),
            const SizedBox(height: 8),
            TextField(controller: qtyCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'ØªØ¹Ø¯Ø§Ø¯')),
            const SizedBox(height: 8),
            TextField(controller: priceCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Ù‚ÛŒÙ…Øª')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Ø§Ù†ØµØ±Ø§Ù')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(editIndex == null ? 'Ø§ÙØ²ÙˆØ¯Ù†' : 'Ø°Ø®ÛŒØ±Ù‡')),
        ],
      ),
    );
    if (added != true || nameCtrl.text.trim().isEmpty) return;
    final entry = ReceiptItemEntry(
      name: nameCtrl.text.trim(),
      quantity: double.tryParse(qtyCtrl.text.replaceAll(',', '.')),
      price: double.tryParse(priceCtrl.text.replaceAll(',', '.')),
    );
    setState(() {
      if (editIndex != null) {
        items[editIndex] = entry;
      } else {
        items.add(entry);
      }
      _dirty = true;
    });
  }

  Widget _recurrenceSection() {
    final preview = recurrence == RecurrenceFrequency.none
        ? null
        : nextOccurrencePreview(Transaction(
            id: '_preview',
            type: type,
            amount: 0,
            categoryId: '',
            accountId: '',
            date: date,
            recurrence: recurrence,
            recurrenceDay: int.tryParse(dayCtrl.text),
            recurrenceWeekday: weekday,
            recurrenceIntervalDays: int.tryParse(intervalCtrl.text),
          ));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<RecurrenceFrequency>(
          initialValue: recurrence,
          decoration: const InputDecoration(labelText: 'Ù†ÙˆØ¹ ØªÚ©Ø±Ø§Ø±', border: OutlineInputBorder()),
          items: const [
            DropdownMenuItem(value: RecurrenceFrequency.none, child: Text('Ø¨Ø¯ÙˆÙ† ØªÚ©Ø±Ø§Ø±')),
            DropdownMenuItem(value: RecurrenceFrequency.weekly, child: Text('Ù‡ÙØªÚ¯ÛŒ (Ø±ÙˆØ² Ù…Ø´Ø®ØµÛŒ Ø§Ø² Ù‡ÙØªÙ‡)')),
            DropdownMenuItem(value: RecurrenceFrequency.monthly, child: Text('Ù…Ø§Ù‡Ø§Ù†Ù‡ (Ø±ÙˆØ² Ù…Ø´Ø®ØµÛŒ Ø§Ø² Ù…Ø§Ù‡)')),
            DropdownMenuItem(value: RecurrenceFrequency.quarterly, child: Text('ÙØµÙ„ÛŒ (Ù‡Ø± Ø³Ù‡ Ù…Ø§Ù‡)')),
            DropdownMenuItem(value: RecurrenceFrequency.yearly, child: Text('Ø³Ø§Ù„Ø§Ù†Ù‡ (Ø¯Ø± Ù‡Ù…ÛŒÙ† ØªØ§Ø±ÛŒØ® Ù‡Ø± Ø³Ø§Ù„)')),
            DropdownMenuItem(value: RecurrenceFrequency.custom, child: Text('Ø¨Ø§Ø²Ù‡â€ŒÛŒ Ø¯Ù„Ø®ÙˆØ§Ù‡ (Ù‡Ø± N Ø±ÙˆØ²)')),
          ],
          onChanged: (v) => setState(() {
            recurrence = v ?? RecurrenceFrequency.none;
            _dirty = true;
          }),
        ),
        if (recurrence == RecurrenceFrequency.monthly || recurrence == RecurrenceFrequency.quarterly) ...[
          const SizedBox(height: 12),
          TextField(
            controller: dayCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Ø±ÙˆØ² Ø³Ø±Ø±Ø³ÛŒØ¯ Ø¯Ø± Ù…Ø§Ù‡ (Û± ØªØ§ Û³Û±) *',
              helperText: 'Ø¨Ø±Ø§ÛŒ Ù…Ø§Ù‡â€ŒÙ‡Ø§ÛŒ Ú©ÙˆØªØ§Ù‡â€ŒØªØ±ØŒ Ø¨Ù‡â€ŒØµÙˆØ±Øª Ø®ÙˆØ¯Ú©Ø§Ø± Ø¢Ø®Ø±ÛŒÙ† Ø±ÙˆØ² Ù‡Ù…Ø§Ù† Ù…Ø§Ù‡ Ø¯Ø± Ù†Ø¸Ø± Ú¯Ø±ÙØªÙ‡ Ù…ÛŒâ€ŒØ´ÙˆØ¯.',
              border: OutlineInputBorder(),
            ),
          ),
        ],
        if (recurrence == RecurrenceFrequency.weekly) ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            initialValue: weekday,
            decoration: const InputDecoration(labelText: 'Ø±ÙˆØ² Ù‡ÙØªÙ‡', border: OutlineInputBorder()),
            items: List.generate(
              7,
              (i) => DropdownMenuItem(value: i + 1, child: Text(_weekdayNames[i])),
            ),
            onChanged: (v) => setState(() {
              weekday = v ?? weekday;
              _dirty = true;
            }),
          ),
        ],
        if (recurrence == RecurrenceFrequency.custom) ...[
          const SizedBox(height: 12),
          TextField(
            controller: intervalCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Ù‡Ø± Ú†Ù†Ø¯ Ø±ÙˆØ² ÛŒÚ©â€ŒØ¨Ø§Ø±ØŸ', border: OutlineInputBorder()),
          ),
        ],
        if (recurrence != RecurrenceFrequency.none) ...[
          const SizedBox(height: 12),
          Text('Ù¾Ø§ÛŒØ§Ù† ØªÚ©Ø±Ø§Ø±', style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 6),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'unlimited', label: Text('Ù†Ø§Ù…Ø­Ø¯ÙˆØ¯')),
              ButtonSegment(value: 'count', label: Text('ØªØ¹Ø¯Ø§Ø¯ Ù‚Ø³Ø·')),
              ButtonSegment(value: 'date', label: Text('ØªØ§ ØªØ§Ø±ÛŒØ®')),
            ],
            selected: {endMode},
            onSelectionChanged: (s) => setState(() {
              endMode = s.first;
              _dirty = true;
            }),
          ),
          if (endMode == 'date') ...[
            const SizedBox(height: 12),
            ListTile(
              contentPadding: EdgeInsets.zero,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: Colors.grey.shade400)),
              title: Text(endDate == null ? 'Ø§Ù†ØªØ®Ø§Ø¨ ØªØ§Ø±ÛŒØ® Ø¢Ø®Ø±ÛŒÙ† Ù¾Ø±Ø¯Ø§Ø®Øª' : 'ØªØ§: ${ltr(DateFormat('dd.MM.yyyy').format(endDate!))}'),
              trailing: const Icon(Icons.event),
              onTap: () async {
                final d = await showDatePicker(
                  context: context,
                  firstDate: date,
                  lastDate: DateTime(2100),
                  initialDate: endDate ?? date,
                  builder: (ctx, child) => Directionality(textDirection: TextDirection.ltr, child: child!),
                );
                if (d != null) {
                  setState(() {
                    endDate = d;
                    _dirty = true;
                  });
                }
              },
            ),
          ] else if (endMode == 'count') ...[
            const SizedBox(height: 12),
            TextField(
              controller: installmentsCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'ØªØ¹Ø¯Ø§Ø¯ Ú©Ù„ Ø§Ù‚Ø³Ø§Ø·', border: OutlineInputBorder()),
            ),
          ],
          if (preview != null) ...[
            const SizedBox(height: 8),
            Text(
              'Ø³Ø±Ø±Ø³ÛŒØ¯ Ø¨Ø¹Ø¯ÛŒ: ${ltr(DateFormat('dd.MM.yyyy').format(preview))}',
              style: TextStyle(color: Colors.indigo.shade700, fontWeight: FontWeight.w600),
            ),
          ],
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Ø§Ø¹Ù„Ø§Ù† Ø§Ù‚Ø³Ø§Ø·'),
            value: notifyEnabled,
            onChanged: (v) async {
              if (v) await NotificationService.instance.requestPermission();
              setState(() {
                notifyEnabled = v;
                _dirty = true;
              });
            },
          ),
          if (notifyEnabled) ...[
            if (endMode != 'unlimited')
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('ÛŒØ§Ø¯Ø¢ÙˆØ±ÛŒ Ø±ÙˆØ² Ù‚Ø¨Ù„ Ø§Ø² Ø¯Ùˆ Ù‚Ø³Ø· Ø¢Ø®Ø±'),
                value: notifyLastTwoEnabled,
                onChanged: (v) => setState(() {
                  notifyLastTwoEnabled = v ?? false;
                  _dirty = true;
                }),
              ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Row(
                children: [
                  const Text('ÛŒØ§Ø¯Ø¢ÙˆØ±ÛŒ '),
                  SizedBox(
                    width: 48,
                    child: TextField(
                      controller: notifyDaysCtrl,
                      enabled: notifyEachEnabled,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 4)),
                    ),
                  ),
                  const Text(' Ø±ÙˆØ² Ù‚Ø¨Ù„ Ø§Ø² Ù‡Ø± Ù‚Ø³Ø·'),
                ],
              ),
              value: notifyEachEnabled,
              onChanged: (v) => setState(() {
                notifyEachEnabled = v ?? false;
                _dirty = true;
              }),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: notifyMessageCtrl,
              decoration: const InputDecoration(
                labelText: 'Ù¾ÛŒØ§Ù… ÛŒØ§Ø¯Ø¢ÙˆØ±ÛŒ (Ø§Ø®ØªÛŒØ§Ø±ÛŒ)',
                hintText: 'Ù…Ø«Ù„Ø§Ù‹: ÛŒØ§Ø¯Øª Ù†Ø±Ù‡ Ø§Ø´ØªØ±Ø§Ú© Ø±Ùˆ Ú©Ù†Ø³Ù„ Ú©Ù†ÛŒ',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final shouldPop = await confirmDiscardChanges(context, onSave: () async => _save());
        if (didPop || !context.mounted) return;
        if (shouldPop) {
          // _save() already pops with the saved Transaction when it succeeds;
          // if the user chose to discard instead, pop with no result here.
          if (Navigator.canPop(context)) Navigator.pop(context);
        }
      },
      child: Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'ØªØ±Ø§Ú©Ù†Ø´ Ø¬Ø¯ÛŒØ¯' : 'ÙˆÛŒØ±Ø§ÛŒØ´ ØªØ±Ø§Ú©Ù†Ø´'),
        actions: [
          if (widget.existing != null)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Ø­Ø°Ù ØªØ±Ø§Ú©Ù†Ø´',
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Ø­Ø°Ù ØªØ±Ø§Ú©Ù†Ø´'),
                    content: const Text('Ø§ÛŒÙ† ØªØ±Ø§Ú©Ù†Ø´ Ø­Ø°Ù Ø´ÙˆØ¯ØŸ Ø§ÛŒÙ† Ú©Ø§Ø± Ù‚Ø§Ø¨Ù„ Ø¨Ø§Ø²Ú¯Ø´Øª Ù†ÛŒØ³Øª.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Ø§Ù†ØµØ±Ø§Ù')),
                      FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Ø­Ø°Ù')),
                    ],
                  ),
                );
                if (confirm == true) {
                  if (!context.mounted) return;
                  Navigator.pop(context, DeleteTransactionSignal(widget.existing!.id));
                }
              },
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SegmentedButton<TxType>(
            segments: const [
              ButtonSegment(value: TxType.expense, label: Text('Ù‡Ø²ÛŒÙ†Ù‡'), icon: Icon(Icons.arrow_upward)),
              ButtonSegment(value: TxType.income, label: Text('Ø¯Ø±Ø¢Ù…Ø¯'), icon: Icon(Icons.arrow_downward)),
            ],
            selected: {type},
            onSelectionChanged: (s) => setState(() {
              type = s.first;
              selectedCategory = null;
              _dirty = true;
            }),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: amountCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Ù…Ø¨Ù„Øº', hintText: 'Ù…Ø«Ù„Ø§Ù‹ 12.50 ÛŒØ§ 12,50', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<Account>(
            initialValue: selectedAccount,
            decoration: const InputDecoration(labelText: 'Ø­Ø³Ø§Ø¨', border: OutlineInputBorder()),
            items: widget.accounts
                .map((a) => DropdownMenuItem(value: a, child: Text('${a.name} (${a.currency})')))
                .toList(),
            onChanged: (v) => setState(() {
              selectedAccount = v;
              _dirty = true;
            }),
          ),
          const SizedBox(height: 16),
          ListTile(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: Colors.grey.shade400)),
            title: Text(selectedCategory?.name ?? 'Ø§Ù†ØªØ®Ø§Ø¨ Ø¯Ø³ØªÙ‡â€ŒØ¨Ù†Ø¯ÛŒ'),
            trailing: const Icon(Icons.chevron_left),
            onTap: _pickCategory,
          ),
          const SizedBox(height: 16),
          ListTile(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: Colors.grey.shade400)),
            title: Text('ØªØ§Ø±ÛŒØ®: ${ltr(DateFormat('dd.MM.yyyy').format(date))}'),
            trailing: const Icon(Icons.calendar_month),
            onTap: () async {
              final d = await showDatePicker(
                context: context,
                firstDate: DateTime(2000),
                lastDate: DateTime(2100),
                initialDate: date,
                builder: (ctx, child) => Directionality(textDirection: TextDirection.ltr, child: child!),
              );
              if (d != null) {
                setState(() {
                  date = d;
                  _dirty = true;
                });
              }
            },
          ),
          const SizedBox(height: 16),
          TextField(
            controller: noteCtrl,
            maxLines: null,
            minLines: 1,
            decoration: const InputDecoration(labelText: 'ØªÙˆØ¶ÛŒØ­Ø§Øª (Ø§Ø®ØªÛŒØ§Ø±ÛŒ)', border: OutlineInputBorder(), alignLabelWithHint: true),
          ),
          if (type == TxType.expense) ...[
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Ø§Ù‚Ù„Ø§Ù… Ø®Ø±ÛŒØ¯', style: Theme.of(context).textTheme.titleMedium),
                TextButton.icon(onPressed: _addItemRow, icon: const Icon(Icons.add), label: const Text('Ø§ÙØ²ÙˆØ¯Ù†')),
              ],
            ),
            if (items.isEmpty)
              const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('Ú©Ø§Ù„Ø§ÛŒÛŒ Ø«Ø¨Øª Ù†Ø´Ø¯Ù‡.', style: TextStyle(color: Colors.grey))),
            ...items.asMap().entries.map((e) {
              final i = e.key;
              final it = e.value;
              return Card(
                child: ListTile(
                  dense: true,
                  title: Text(it.name),
                  subtitle: Text(
                    '${it.quantity != null ? 'ØªØ¹Ø¯Ø§Ø¯: ${ltr(it.quantity!.toStringAsFixed(it.quantity! % 1 == 0 ? 0 : 2))}' : ''}'
                    '${it.quantity != null && it.price != null ? ' â€¢ ' : ''}'
                    '${it.price != null ? ltr('â‚¬${it.price!.toStringAsFixed(2)}') : ''}',
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: () => setState(() {
                      items.removeAt(i);
                      _dirty = true;
                    }),
                  ),
                  onTap: () => _addItemRow(editIndex: i),
                ),
              );
            }),
          ],
          if (type == TxType.income) ...[
            const SizedBox(height: 16),
            Text('Ø¬Ø²Ø¦ÛŒØ§Øª ÙÛŒØ´ Ø­Ù‚ÙˆÙ‚ÛŒ (Ø§Ø®ØªÛŒØ§Ø±ÛŒ)', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              controller: payslipArbeitgeberCtrl,
              decoration: const InputDecoration(labelText: 'Ú©Ø§Ø±ÙØ±Ù…Ø§ (Arbeitgeber)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: payslipMonatCtrl,
              decoration: const InputDecoration(labelText: 'Ù…Ø§Ù‡ ØªØ³ÙˆÛŒÙ‡ (Abrechnungsmonat)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: payslipSteuerklasseCtrl,
              decoration: const InputDecoration(labelText: 'Ú©Ù„Ø§Ø³ Ù…Ø§Ù„ÛŒØ§ØªÛŒ (Steuerklasse)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            ..._payslipLabels.keys.map((k) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TextField(
                    controller: payslipNumCtrls[k],
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(labelText: _payslipLabels[k], border: const OutlineInputBorder()),
                  ),
                )),
          ],
          const SizedBox(height: 16),
          _recurrenceSection(),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Ø°Ø®ÛŒØ±Ù‡ Ø¨Ù‡â€ŒØµÙˆØ±Øª Ù¾ÛŒØ´â€ŒÙ†ÙˆÛŒØ³'),
            subtitle: const Text('Ù¾ÛŒØ´â€ŒÙ†ÙˆÛŒØ³â€ŒÙ‡Ø§ Ø¨Ø¹Ø¯Ø§Ù‹ Ù‚Ø§Ø¨Ù„ Ø¨Ø±Ø±Ø³ÛŒ Ùˆ ØªØ£ÛŒÛŒØ¯ Ù†Ù‡Ø§ÛŒÛŒ Ù‡Ø³ØªÙ†Ø¯.'),
            value: draft,
            onChanged: (v) => setState(() {
              draft = v;
              _dirty = true;
            }),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: _save, child: const Text('Ø°Ø®ÛŒØ±Ù‡')),
        ],
      ),
    ),
    );
  }
}

// ============================== Category picker (selection only) ==============================

class CategoryPicker extends StatefulWidget {
  final TxType type;
  final List<Category> categories;
  const CategoryPicker({required this.type, required this.categories, super.key});
  @override
  State<CategoryPicker> createState() => _CategoryPickerState();
}

class _CategoryPickerState extends State<CategoryPicker> {
  List<Category> stack = [];
  late List<Category> categories;

  @override
  void initState() {
    super.initState();
    categories = List.of(widget.categories);
  }

  Future<void> _addCategory({Category? underParent}) async {
    final ctrl = TextEditingController();
    final parentId = underParent?.id ?? (stack.isEmpty ? null : stack.last.id);
    final parentName = underParent?.name ?? (stack.isEmpty ? null : stack.last.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(parentId == null ? 'Ø¯Ø³ØªÙ‡â€ŒØ¨Ù†Ø¯ÛŒ Ø¬Ø¯ÛŒØ¯' : 'Ø²ÛŒØ±Ù…Ø¬Ù…ÙˆØ¹Ù‡â€ŒÛŒ Ø¬Ø¯ÛŒØ¯ Ø¯Ø± Â«$parentNameÂ»'),
        content: TextField(controller: ctrl, decoration: const InputDecoration(labelText: 'Ù†Ø§Ù… Ø¯Ø³ØªÙ‡â€ŒØ¨Ù†Ø¯ÛŒ'), autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Ø§Ù†ØµØ±Ø§Ù')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Ø§ÙØ²ÙˆØ¯Ù†')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final duplicate = categories.any(
        (c) => c.parentId == parentId && c.type == widget.type && c.name.trim().toLowerCase() == name.trim().toLowerCase());
    if (duplicate) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ø§ÛŒÙ† Ù†Ø§Ù… Ù‚Ø¨Ù„Ø§Ù‹ Ø¯Ø± Ù‡Ù…ÛŒÙ† Ú¯Ø±ÙˆÙ‡ Ø§Ø³ØªÙØ§Ø¯Ù‡ Ø´Ø¯Ù‡ Ø§Ø³Øª.')));
      }
      return;
    }
    final icon = await suggestIconForCategory(name, widget.type);
    final newCat = Category(
      id: 'c_${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      parentId: parentId,
      type: widget.type,
      iconCodePoint: icon.codePoint,
    );
    setState(() => categories = [...categories, newCat]);
    await Store.saveCategories(categories);
  }

  @override
  Widget build(BuildContext context) {
    final parentId = stack.isEmpty ? null : stack.last.id;
    final items = categories.where((c) => c.type == widget.type && c.parentId == parentId).toList();
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                stack.isEmpty ? 'Ø¯Ø³ØªÙ‡â€ŒØ¨Ù†Ø¯ÛŒâ€ŒÙ‡Ø§' : stack.last.name,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (stack.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.arrow_forward),
                title: const Text('Ø¨Ø§Ø²Ú¯Ø´Øª'),
                onTap: () => setState(() => stack.removeLast()),
              ),
            if (stack.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.check_circle_outline),
                title: Text('Ø§Ù†ØªØ®Ø§Ø¨ Â«${stack.last.name}Â»'),
                onTap: () => Navigator.pop(context, stack.last),
              ),
            if (items.isEmpty && stack.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Ù‡Ù†ÙˆØ² Ø¯Ø³ØªÙ‡â€ŒØ¨Ù†Ø¯ÛŒâ€ŒØ§ÛŒ ÙˆØ¬ÙˆØ¯ Ù†Ø¯Ø§Ø±Ø¯. Ø¨Ø§ Ø¯Ú©Ù…Ù‡â€ŒÛŒ Ø²ÛŒØ± ÛŒÚ©ÛŒ Ø§Ø¶Ø§ÙÙ‡ Ú©Ù†ÛŒØ¯.'),
              ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: items.map((c) {
                  final hasChildren = categories.any((x) => x.parentId == c.id);
                  return ListTile(
                    leading: Icon(iconForCategory(c, categories)),
                    title: Text(c.name),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.add, size: 20),
                          tooltip: 'Ø§ÙØ²ÙˆØ¯Ù† Ø²ÛŒØ±Ù…Ø¬Ù…ÙˆØ¹Ù‡ Ø¯Ø± Â«${c.name}Â»',
                          onPressed: () => _addCategory(underParent: c),
                        ),
                        if (hasChildren) const Icon(Icons.chevron_left),
                      ],
                    ),
                    onTap: () {
                      if (hasChildren) {
                        setState(() => stack.add(c));
                      } else {
                        Navigator.pop(context, c);
                      }
                    },
                  );
                }).toList(),
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.add),
              title: Text(stack.isEmpty ? 'Ø§ÙØ²ÙˆØ¯Ù† Ø¯Ø³ØªÙ‡â€ŒØ¨Ù†Ø¯ÛŒ Ø¬Ø¯ÛŒØ¯' : 'Ø§ÙØ²ÙˆØ¯Ù† Ø²ÛŒØ±Ù…Ø¬Ù…ÙˆØ¹Ù‡â€ŒÛŒ Ø¬Ø¯ÛŒØ¯'),
              onTap: _addCategory,
            ),
          ],
        ),
      ),
    );
  }
}

// ============================== Category management ==============================

class CategoryManagementScreen extends StatefulWidget {
  const CategoryManagementScreen({super.key});
  @override
  State<CategoryManagementScreen> createState() => _CategoryManagementScreenState();
}

class _CategoryManagementScreenState extends State<CategoryManagementScreen> {
  List<Category> categories = [];
  bool loading = true;
  TxType selectedType = TxType.expense;
  Set<String> collapsed = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    categories = await Store.loadCategories();
    setState(() => loading = false);
  }

  Future<void> _addCategory({String? parentId}) async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(parentId == null ? 'Ø¯Ø³ØªÙ‡â€ŒØ¨Ù†Ø¯ÛŒ Ø¬Ø¯ÛŒØ¯' : 'Ø²ÛŒØ±Ù…Ø¬Ù…ÙˆØ¹Ù‡â€ŒÛŒ Ø¬Ø¯ÛŒØ¯'),
        content: TextField(controller: ctrl, decoration: const InputDecoration(labelText: 'Ù†Ø§Ù… Ø¯Ø³ØªÙ‡â€ŒØ¨Ù†Ø¯ÛŒ'), autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Ø§Ù†ØµØ±Ø§Ù')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Ø§ÙØ²ÙˆØ¯Ù†')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final duplicate = categories
        .any((c) => c.parentId == parentId && c.type == selectedType && c.name.trim().toLowerCase() == name.trim().toLowerCase());
    if (duplicate) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ø§ÛŒÙ† Ù†Ø§Ù… Ù‚Ø¨Ù„Ø§Ù‹ Ø¯Ø± Ù‡Ù…ÛŒÙ† Ú¯Ø±ÙˆÙ‡ Ø§Ø³ØªÙØ§Ø¯Ù‡ Ø´Ø¯Ù‡ Ø§Ø³Øª.')));
      }
      return;
    }
    final icon = await suggestIconForCategory(name, selectedType);
    final newCat = Category(
      id: 'c_${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      parentId: parentId,
      type: selectedType,
      iconCodePoint: icon.codePoint,
    );
    setState(() => categories = [...categories, newCat]);
    await Store.saveCategories(categories);
  }

  Future<void> _rename(Category c) async {
    final ctrl = TextEditingController(text: c.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ØªØºÛŒÛŒØ± Ù†Ø§Ù… Ø¯Ø³ØªÙ‡â€ŒØ¨Ù†Ø¯ÛŒ'),
        content: TextField(controller: ctrl, decoration: const InputDecoration(labelText: 'Ù†Ø§Ù… Ø¬Ø¯ÛŒØ¯'), autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Ø§Ù†ØµØ±Ø§Ù')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Ø°Ø®ÛŒØ±Ù‡')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final duplicate = categories.any(
        (x) => x.id != c.id && x.parentId == c.parentId && x.type == c.type && x.name.trim().toLowerCase() == name.trim().toLowerCase());
    if (duplicate) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ø§ÛŒÙ† Ù†Ø§Ù… Ù‚Ø¨Ù„Ø§Ù‹ Ø¯Ø± Ù‡Ù…ÛŒÙ† Ú¯Ø±ÙˆÙ‡ Ø§Ø³ØªÙØ§Ø¯Ù‡ Ø´Ø¯Ù‡ Ø§Ø³Øª.')));
      }
      return;
    }
    setState(() {
      categories = categories.map((x) => x.id == c.id ? x.copyWith(name: name) : x).toList();
    });
    await Store.saveCategories(categories);
  }

  Future<void> _regenerateIcon(Category c) async {
    final icon = await suggestIconForCategory(c.name, c.type);
    setState(() {
      categories = categories.map((x) => x.id == c.id ? x.copyWith(iconCodePoint: icon.codePoint) : x).toList();
    });
    await Store.saveCategories(categories);
  }

  Future<void> _delete(Category c) async {
    final hasChildren = categories.any((x) => x.parentId == c.id);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ø­Ø°Ù Ø¯Ø³ØªÙ‡â€ŒØ¨Ù†Ø¯ÛŒ'),
        content: Text(
          'Â«${c.name}Â» Ø­Ø°Ù Ø´ÙˆØ¯ØŸ'
          '${hasChildren ? '\nØ²ÛŒØ±Ù…Ø¬Ù…ÙˆØ¹Ù‡â€ŒÙ‡Ø§ÛŒ Ø¢Ù† ÛŒÚ© Ø³Ø·Ø­ Ø¨Ø§Ù„Ø§ØªØ± Ù…Ù†ØªÙ‚Ù„ Ù…ÛŒâ€ŒØ´ÙˆÙ†Ø¯.' : ''}'
          '\nØªØ±Ø§Ú©Ù†Ø´â€ŒÙ‡Ø§ÛŒÛŒ Ú©Ù‡ Ø§Ø² Ø§ÛŒÙ† Ø¯Ø³ØªÙ‡â€ŒØ¨Ù†Ø¯ÛŒ Ø§Ø³ØªÙØ§Ø¯Ù‡ Ú©Ø±Ø¯Ù‡â€ŒØ§Ù†Ø¯ØŒ Ø¨Ù‡ Ø¯Ø³ØªÙ‡â€ŒØ¨Ù†Ø¯ÛŒ Ø¨Ø§Ù„Ø§ØªØ± Ù…Ù†ØªÙ‚Ù„ Ù…ÛŒâ€ŒØ´ÙˆÙ†Ø¯ Ùˆ Ù†Ø§Ù… Â«${c.name}Â» Ø¨Ù‡ ØªÙˆØ¶ÛŒØ­Ø§Øª Ø¢Ù†â€ŒÙ‡Ø§ Ø§Ø¶Ø§ÙÙ‡ Ù…ÛŒâ€ŒØ´ÙˆØ¯.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Ø§Ù†ØµØ±Ø§Ù')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Ø­Ø°Ù')),
        ],
      ),
    );
    if (confirm != true) return;

    final newCategories = categories
        .map((x) => x.parentId == c.id ? x.copyWith(parentId: c.parentId) : x)
        .where((x) => x.id != c.id)
        .toList();

    final tx = await Store.loadTransactions();
    var txChanged = false;
    final newTx = tx.map((t) {
      if (t.categoryId == c.id) {
        txChanged = true;
        final newNote = t.note.isEmpty ? 'Ø¯Ø³ØªÙ‡â€ŒØ¨Ù†Ø¯ÛŒ Ù‚Ø¨Ù„ÛŒ: ${c.name}' : '${t.note} (Ø¯Ø³ØªÙ‡â€ŒØ¨Ù†Ø¯ÛŒ Ù‚Ø¨Ù„ÛŒ: ${c.name})';
        return t.copyWith(categoryId: c.parentId ?? '_uncategorized_', note: newNote);
      }
      return t;
    }).toList();

    setState(() => categories = newCategories);
    await Store.saveCategories(newCategories);
    if (txChanged) await Store.saveTransactions(newTx);
  }

  List<Widget> _buildTree(String? parentId, int depth) {
    final children = categories.where((c) => c.type == selectedType && c.parentId == parentId).toList();
    final widgets = <Widget>[];
    for (final c in children) {
      final hasChildren = categories.any((x) => x.parentId == c.id);
      final isCollapsed = collapsed.contains(c.id);
      widgets.add(Padding(
        padding: EdgeInsets.only(right: depth * 20.0),
        child: ListTile(
          leading: Icon(iconForCategory(c, categories), color: Colors.grey.shade700),
          title: Text(c.name),
          onTap: hasChildren
              ? () => setState(() {
                    if (isCollapsed) {
                      collapsed.remove(c.id);
                    } else {
                      collapsed.add(c.id);
                    }
                  })
              : null,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasChildren) Icon(isCollapsed ? Icons.chevron_left : Icons.expand_more, color: Colors.grey.shade500),
              IconButton(
                icon: const Icon(Icons.add, size: 20),
                tooltip: 'Ø§ÙØ²ÙˆØ¯Ù† Ø²ÛŒØ±Ù…Ø¬Ù…ÙˆØ¹Ù‡',
                onPressed: () => _addCategory(parentId: c.id),
              ),
              IconButton(
                icon: const Icon(Icons.auto_awesome, size: 20),
                tooltip: 'Ø§ÛŒØ¬Ø§Ø¯ ØªØµÙˆÛŒØ± Ø¨Ø§ Ù‡ÙˆØ´ Ù…ØµÙ†ÙˆØ¹ÛŒ',
                onPressed: () => _regenerateIcon(c),
              ),
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 20),
                tooltip: 'ØªØºÛŒÛŒØ± Ù†Ø§Ù…',
                onPressed: () => _rename(c),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                tooltip: 'Ø­Ø°Ù',
                onPressed: () => _delete(c),
              ),
            ],
          ),
        ),
      ));
      if (!isCollapsed) widgets.addAll(_buildTree(c.id, depth + 1));
    }
    return widgets;
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final tree = _buildTree(null, 0);
    return Scaffold(
      appBar: AppBar(title: const Text('Ù…Ø¯ÛŒØ±ÛŒØª Ø¯Ø³ØªÙ‡â€ŒØ¨Ù†Ø¯ÛŒâ€ŒÙ‡Ø§')),
      drawer: const AppDrawer(currentIndex: 1),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: SegmentedButton<TxType>(
              segments: const [
                ButtonSegment(value: TxType.expense, label: Text('Ù‡Ø²ÛŒÙ†Ù‡')),
                ButtonSegment(value: TxType.income, label: Text('Ø¯Ø±Ø¢Ù…Ø¯')),
              ],
              selected: {selectedType},
              onSelectionChanged: (s) => setState(() => selectedType = s.first),
            ),
          ),
          Expanded(
            child: tree.isEmpty
                ? const Center(child: Text('Ø¯Ø³ØªÙ‡â€ŒØ¨Ù†Ø¯ÛŒâ€ŒØ§ÛŒ ÙˆØ¬ÙˆØ¯ Ù†Ø¯Ø§Ø±Ø¯.'))
                : ListView(padding: const EdgeInsets.only(bottom: 88), children: tree),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addCategory(),
        icon: const Icon(Icons.add),
        label: const Text('Ø¯Ø³ØªÙ‡â€ŒØ¨Ù†Ø¯ÛŒ Ø¬Ø¯ÛŒØ¯'),
      ),
    );
  }
}

// ============================== Account management ==============================

class AccountManagementScreen extends StatefulWidget {
  const AccountManagementScreen({super.key});
  @override
  State<AccountManagementScreen> createState() => _AccountManagementScreenState();
}

class _AccountManagementScreenState extends State<AccountManagementScreen> {
  List<Account> accounts = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    accounts = await Store.loadAccounts();
    setState(() => loading = false);
  }

  Future<void> _editAccount({Account? existing}) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    AccountType type = existing?.type ?? AccountType.bank;
    String currency = existing?.currency ?? 'EUR';
    final result = await showDialog<Account>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        return AlertDialog(
          title: Text(existing == null ? 'Ø­Ø³Ø§Ø¨ Ø¬Ø¯ÛŒØ¯' : 'ÙˆÛŒØ±Ø§ÛŒØ´ Ø­Ø³Ø§Ø¨'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Ù†Ø§Ù… Ø­Ø³Ø§Ø¨'), autofocus: true),
              const SizedBox(height: 12),
              DropdownButtonFormField<AccountType>(
                initialValue: type,
                decoration: const InputDecoration(labelText: 'Ù†ÙˆØ¹ Ø­Ø³Ø§Ø¨'),
                items: AccountType.values.map((t) => DropdownMenuItem(value: t, child: Text(t.label))).toList(),
                onChanged: (v) => setLocal(() => type = v ?? type),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: currency,
                decoration: const InputDecoration(labelText: 'ÙˆØ§Ø­Ø¯ Ù¾ÙˆÙ„'),
                items: kCurrencies.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                onChanged: (v) => setLocal(() => currency = v ?? currency),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Ø§Ù†ØµØ±Ø§Ù')),
            FilledButton(
              onPressed: () {
                if (nameCtrl.text.trim().isEmpty) return;
                final acc = Account(
                  id: existing?.id ?? 'a_${DateTime.now().microsecondsSinceEpoch}',
                  name: nameCtrl.text.trim(),
                  type: type,
                  currency: currency,
                );
                Navigator.pop(ctx, acc);
              },
              child: const Text('Ø°Ø®ÛŒØ±Ù‡'),
            ),
          ],
        );
      }),
    );
    if (result == null) return;
    setState(() {
      final idx = accounts.indexWhere((a) => a.id == result.id);
      if (idx >= 0) {
        accounts[idx] = result;
      } else {
        accounts.add(result);
      }
    });
    await Store.saveAccounts(accounts);
  }

  Future<void> _delete(Account a) async {
    final tx = await Store.loadTransactions();
    if (!context.mounted) return;
    final inUse = tx.any((t) => t.accountId == a.id);
    if (inUse) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Ø§Ù…Ú©Ø§Ù† Ø­Ø°Ù Ù†ÛŒØ³Øª'),
          content: Text('Ø­Ø³Ø§Ø¨ Â«${a.name}Â» Ø¯Ø± ØªØ±Ø§Ú©Ù†Ø´â€ŒÙ‡Ø§ÛŒ Ø«Ø¨Øªâ€ŒØ´Ø¯Ù‡ Ø§Ø³ØªÙØ§Ø¯Ù‡ Ø´Ø¯Ù‡ Ø§Ø³Øª. Ø§Ø¨ØªØ¯Ø§ ØªØ±Ø§Ú©Ù†Ø´â€ŒÙ‡Ø§ÛŒ Ø¢Ù† Ø±Ø§ Ø­Ø°Ù ÛŒØ§ Ø¨Ù‡ Ø­Ø³Ø§Ø¨ Ø¯ÛŒÚ¯Ø±ÛŒ Ù…Ù†ØªÙ‚Ù„ Ú©Ù†ÛŒØ¯.'),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Ø¨Ø§Ø´Ù‡'))],
        ),
      );
      return;
    }
    if (accounts.length <= 1) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Ø§Ù…Ú©Ø§Ù† Ø­Ø°Ù Ù†ÛŒØ³Øª'),
          content: const Text('Ø¨Ø§ÛŒØ¯ Ø­Ø¯Ø§Ù‚Ù„ ÛŒÚ© Ø­Ø³Ø§Ø¨ Ø¯Ø± Ø¨Ø±Ù†Ø§Ù…Ù‡ Ø¨Ø§Ù‚ÛŒ Ø¨Ù…Ø§Ù†Ø¯.'),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Ø¨Ø§Ø´Ù‡'))],
        ),
      );
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ø­Ø°Ù Ø­Ø³Ø§Ø¨'),
        content: Text('Ø­Ø³Ø§Ø¨ Â«${a.name}Â» Ø­Ø°Ù Ø´ÙˆØ¯ØŸ'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Ø§Ù†ØµØ±Ø§Ù')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Ø­Ø°Ù')),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => accounts.removeWhere((x) => x.id == a.id));
    await Store.saveAccounts(accounts);
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(title: const Text('Ø­Ø³Ø§Ø¨â€ŒÙ‡Ø§')),
      drawer: const AppDrawer(currentIndex: 2),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: accounts
            .map((a) => Card(
                  child: ListTile(
                    leading: const Icon(Icons.account_balance_wallet_outlined),
                    title: Text(a.name),
                    subtitle: Text('${a.type.label} â€¢ ${a.currency}'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(icon: const Icon(Icons.edit_outlined), onPressed: () => _editAccount(existing: a)),
                        IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _delete(a)),
                      ],
                    ),
                  ),
                ))
            .toList(),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _editAccount(),
        icon: const Icon(Icons.add),
        label: const Text('Ø­Ø³Ø§Ø¨ Ø¬Ø¯ÛŒØ¯'),
      ),
    );
  }
}
