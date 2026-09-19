import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart' show SystemNavigator, SystemChrome, SystemUiMode, Clipboard, ClipboardData;
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
import 'package:crypto/crypto.dart';
import 'package:local_auth/local_auth.dart';
import 'package:excel/excel.dart' as xls;
import 'package:share_plus/share_plus.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Full-screen: hide the status bar and Android's gesture/nav bar; either
  // can be revealed temporarily by swiping from that edge, then auto-hides
  // again, so on-screen content never sits underneath the system bars.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  await NotificationService.instance.init();
  currentLanguage.value = await Store.loadLanguage();
  currentThemeMode.value = await Store.loadThemeMode();
  currentCalendarSystem.value = await Store.loadCalendarSystem();
  runApp(const MoneyApp());
}

// Isolates an LTR chunk (numbers, dates, currency) inside RTL Persian text
// so it always renders left-to-right in the right place, instead of the
// Unicode bidi algorithm re-ordering symbols/signs relative to the digits.
enum CalendarSystem { gregorian, jalali }

final ValueNotifier<CalendarSystem> currentCalendarSystem = ValueNotifier(CalendarSystem.gregorian);

const _jalaliMonthNames = [
  'فروردین',
  'اردیبهشت',
  'خرداد',
  'تیر',
  'مرداد',
  'شهریور',
  'مهر',
  'آبان',
  'آذر',
  'دی',
  'بهمن',
  'اسفند',
];

/// Gregorian -> Jalali (Solar Hijri) conversion. Standard algorithm (as
/// used by jalaali-js and most Persian-calendar libraries) - no external
/// package needed.
List<int> gregorianToJalali(int gy, int gm, int gd) {
  const gDaysInMonth = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334];
  var jy = gy > 1600 ? 979 : 0;
  gy = gy > 1600 ? gy - 1600 : gy - 621;
  final gy2 = gm > 2 ? gy + 1 : gy;
  var days = 365 * gy + ((gy2 + 3) ~/ 4) - ((gy2 + 99) ~/ 100) + ((gy2 + 399) ~/ 400) - 80 + gd + gDaysInMonth[gm - 1];
  jy += 33 * (days ~/ 12053);
  days %= 12053;
  jy += 4 * (days ~/ 1461);
  days %= 1461;
  if (days > 365) {
    jy += (days - 1) ~/ 365;
    days = (days - 1) % 365;
  }
  int jm, jd;
  if (days < 186) {
    jm = 1 + (days ~/ 31);
    jd = 1 + (days % 31);
  } else {
    jm = 7 + ((days - 186) ~/ 30);
    jd = 1 + ((days - 186) % 30);
  }
  return [jy, jm, jd];
}

/// Jalali (Solar Hijri) -> Gregorian conversion, inverse of the above.
List<int> jalaliToGregorian(int jy, int jm, int jd) {
  var gy = jy > 979 ? 1600 : 621;
  jy = jy > 979 ? jy - 979 : jy;
  var days = 365 * jy + ((jy ~/ 33) * 8) + (((jy % 33) + 3) ~/ 4) + 78 + jd + (jm < 7 ? (jm - 1) * 31 : ((jm - 7) * 30) + 186);
  gy += 400 * (days ~/ 146097);
  days %= 146097;
  if (days > 36524) {
    days--;
    gy += 100 * (days ~/ 36524);
    days %= 36524;
    if (days >= 365) days++;
  }
  gy += 4 * (days ~/ 1461);
  days %= 1461;
  if (days > 365) {
    gy += (days - 1) ~/ 365;
    days = (days - 1) % 365;
  }
  var gd = days + 1;
  final isLeap = (gy % 4 == 0 && gy % 100 != 0) || (gy % 400 == 0);
  final salA = [0, 31, isLeap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  var gm = 1;
  for (gm = 1; gm <= 12; gm++) {
    if (gd <= salA[gm]) break;
    gd -= salA[gm];
  }
  return [gy, gm, gd];
}

String ltr(String s) => '\u2066$s\u2069';

const _persianDigits = ['۰', '۱', '۲', '۳', '۴', '۵', '۶', '۷', '۸', '۹'];

/// Converts ASCII digits to Persian numerals when the app language is
/// Persian; passes other characters (and other languages' text) through
/// unchanged.
String persianDigits(String input) {
  if (currentLanguage.value != AppLanguage.fa) return input;
  final buffer = StringBuffer();
  for (final rune in input.runes) {
    if (rune >= 0x30 && rune <= 0x39) {
      buffer.write(_persianDigits[rune - 0x30]);
    } else {
      buffer.writeCharCode(rune);
    }
  }
  return buffer.toString();
}

/// Formats a date as dd.MM.yyyy, in Persian digits when the app language
/// is Persian, LTR-isolated so it doesn't get visually reordered inside
/// RTL text.
/// Formats a date as dd.MM.yyyy (Gregorian) or the Jalali equivalent
/// depending on the chosen calendar system, in Persian digits when the
/// app language is Persian, LTR-isolated so it doesn't get visually
/// reordered inside RTL text.
String formatDate(DateTime d) {
  if (currentCalendarSystem.value == CalendarSystem.jalali) {
    final j = gregorianToJalali(d.year, d.month, d.day);
    final jd = j[2].toString().padLeft(2, '0');
    final jm = j[1].toString().padLeft(2, '0');
    return ltr(persianDigits('$jd.$jm.${j[0]}'));
  }
  return ltr(persianDigits(DateFormat('dd.MM.yyyy').format(d)));
}

Future<bool> confirmExitApp(BuildContext context) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('خروج از برنامه'),
      content: const Text('آیا می‌خواهید از برنامه خارج شوید؟'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('خیر')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('بله')),
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
      title: const Text('تغییرات ذخیره نشده'),
      content: const Text('چیزی تغییر کرده یا اضافه شده که هنوز ذخیره نشده. چه کار کنم؟'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'), child: Text(tr('cancel'))),
        TextButton(onPressed: () => Navigator.pop(ctx, 'discard'), child: const Text('خروج بدون ذخیره')),
        if (onSave != null) FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('ذخیره و خروج')),
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

enum AccountType { cash, bank, creditCard, savings, investment, other }

enum ScanSource { camera, gallery, pdf }

extension AccountTypeLabel on AccountType {
  String get label {
    switch (this) {
      case AccountType.cash:
        return 'نقدی';
      case AccountType.bank:
        return 'بانکی';
      case AccountType.creditCard:
        return 'کارت اعتباری';
      case AccountType.savings:
        return 'پس‌انداز';
      case AccountType.investment:
        return 'سرمایه‌گذاری';
      case AccountType.other:
        return 'سایر';
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

// Traditional Persian alphabetical order - Unicode code-point order does
// NOT match this (e.g. 'پ' sorts after 'ت' by code point, but belongs right
// after 'ب' in Persian), which made some categories (e.g. "پوشاک") sort
// into the wrong place. Characters not in this list (numbers, spaces,
// ZWNJ, Latin letters, etc.) fall back to plain code-point order, ranked
// after all mapped letters.
const _persianAlphabetOrder = 'ا آ ب پ ت ث ج چ ح خ د ذ ر ز ژ س ش ص ض ط ظ ع غ ف ق ک گ ل م ن و ه ی';
final Map<int, int> _persianLetterRank = () {
  final map = <int, int>{};
  final letters = _persianAlphabetOrder.split(' ');
  for (var i = 0; i < letters.length; i++) {
    map[letters[i].codeUnitAt(0)] = i;
  }
  // Common alternate/Arabic forms some input methods produce, mapped to
  // their Persian equivalent's rank.
  map[0x064A] = map[0x06CC]!; // Arabic yeh -> Persian yeh (ی)
  map[0x0643] = map[0x06A9]!; // Arabic kaf -> Persian kaf (ک)
  return map;
}();

int persianCompare(String a, String b) {
  final la = a.trim();
  final lb = b.trim();
  final len = la.length < lb.length ? la.length : lb.length;
  for (var i = 0; i < len; i++) {
    final ca = la.codeUnitAt(i);
    final cb = lb.codeUnitAt(i);
    if (ca == cb) continue;
    final ra = _persianLetterRank[ca];
    final rb = _persianLetterRank[cb];
    if (ra != null && rb != null) return ra.compareTo(rb);
    if (ra != null) return -1; // mapped Persian letters sort before anything unmapped
    if (rb != null) return 1;
    return ca.compareTo(cb);
  }
  return la.length.compareTo(lb.length);
}

class Category {
  final String id;
  final String name;
  final String? parentId;
  final TxType type;
  final int? iconCodePoint; // custom icon for user-created categories (Material icon codePoint)
  final bool iconNeedsRetry; // true if only a generic fallback icon was assigned so far
  const Category({
    required this.id,
    required this.name,
    this.parentId,
    required this.type,
    this.iconCodePoint,
    this.iconNeedsRetry = false,
  });

  Category copyWith({String? name, String? parentId, int? iconCodePoint, bool? iconNeedsRetry}) => Category(
        id: id,
        name: name ?? this.name,
        parentId: parentId ?? this.parentId,
        type: type,
        iconCodePoint: iconCodePoint ?? this.iconCodePoint,
        iconNeedsRetry: iconNeedsRetry ?? this.iconNeedsRetry,
      );

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'parentId': parentId, 'type': type.name, 'iconCodePoint': iconCodePoint, 'iconNeedsRetry': iconNeedsRetry};
  factory Category.fromJson(Map<String, dynamic> j) => Category(
        id: j['id'],
        name: j['name'],
        parentId: j['parentId'],
        type: TxType.values.byName(j['type']),
        iconCodePoint: j['iconCodePoint'],
        iconNeedsRetry: j['iconNeedsRetry'] ?? false,
      );
}

class BudgetGoal {
  final String categoryId;
  final double monthlyAmount;
  const BudgetGoal({required this.categoryId, required this.monthlyAmount});

  Map<String, dynamic> toJson() => {'categoryId': categoryId, 'monthlyAmount': monthlyAmount};
  factory BudgetGoal.fromJson(Map<String, dynamic> j) =>
      BudgetGoal(categoryId: j['categoryId'], monthlyAmount: (j['monthlyAmount'] as num).toDouble());
}

class SavingsGoal {
  final String id;
  final String name;
  final double targetAmount;
  final DateTime? targetDate;
  final String currency;
  const SavingsGoal({required this.id, required this.name, required this.targetAmount, this.targetDate, this.currency = 'EUR'});

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'targetAmount': targetAmount, 'targetDate': targetDate?.toIso8601String(), 'currency': currency};
  factory SavingsGoal.fromJson(Map<String, dynamic> j) => SavingsGoal(
        id: j['id'],
        name: j['name'],
        targetAmount: (j['targetAmount'] as num).toDouble(),
        targetDate: j['targetDate'] != null ? DateTime.tryParse(j['targetDate']) : null,
        currency: j['currency'] ?? 'EUR',
      );
}

class SavingsContribution {
  final String id;
  final String goalId;
  final double amount;
  final DateTime date;
  final String note;
  const SavingsContribution({required this.id, required this.goalId, required this.amount, required this.date, this.note = ''});

  Map<String, dynamic> toJson() => {'id': id, 'goalId': goalId, 'amount': amount, 'date': date.toIso8601String(), 'note': note};
  factory SavingsContribution.fromJson(Map<String, dynamic> j) => SavingsContribution(
        id: j['id'],
        goalId: j['goalId'],
        amount: (j['amount'] as num).toDouble(),
        date: DateTime.parse(j['date']),
        note: j['note'] ?? '',
      );
}

class Account {
  final String id;
  final String name;
  final AccountType type;
  final String currency;
  final double initialBalance;
  const Account({required this.id, required this.name, required this.type, required this.currency, this.initialBalance = 0});

  Account copyWith({String? name, AccountType? type, String? currency, double? initialBalance}) => Account(
        id: id,
        name: name ?? this.name,
        type: type ?? this.type,
        currency: currency ?? this.currency,
        initialBalance: initialBalance ?? this.initialBalance,
      );

  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'type': type.name, 'currency': currency, 'initialBalance': initialBalance};
  factory Account.fromJson(Map<String, dynamic> j) => Account(
        id: j['id'],
        name: j['name'],
        type: AccountType.values.byName(j['type'] ?? 'bank'),
        currency: j['currency'] ?? 'EUR',
        initialBalance: (j['initialBalance'] as num?)?.toDouble() ?? 0,
      );
}

class ReceiptItemEntry {
  final String name;
  final double? quantity;
  final double? price;
  final DateTime? warrantyUntil; // for physical/durable goods, if inferable from the receipt
  final DateTime? returnUntil; // last day the item can be returned/exchanged
  final String? warrantyNote; // free-text terms, e.g. "۲ سال گارانتی شرکتی"
  const ReceiptItemEntry({
    required this.name,
    this.quantity,
    this.price,
    this.warrantyUntil,
    this.returnUntil,
    this.warrantyNote,
  });

  bool get hasWarrantyInfo => warrantyUntil != null || returnUntil != null || (warrantyNote?.isNotEmpty ?? false);

  Map<String, dynamic> toJson() => {
        'name': name,
        'quantity': quantity,
        'price': price,
        'warrantyUntil': warrantyUntil?.toIso8601String(),
        'returnUntil': returnUntil?.toIso8601String(),
        'warrantyNote': warrantyNote,
      };
  factory ReceiptItemEntry.fromJson(Map<String, dynamic> j) => ReceiptItemEntry(
        name: j['name'] ?? '',
        quantity: (j['quantity'] as num?)?.toDouble(),
        price: (j['price'] as num?)?.toDouble(),
        warrantyUntil: j['warrantyUntil'] != null ? DateTime.tryParse(j['warrantyUntil']) : null,
        returnUntil: j['returnUntil'] != null ? DateTime.tryParse(j['returnUntil']) : null,
        warrantyNote: j['warrantyNote'],
      );
}

class PayslipDetails {
  final double? brutto;
  final double? netto;
  final double? depositedAmount; // مبلغ واریز شده به حساب - can differ from netto (advances, deductions via payroll, etc.)
  final double? lohnsteuer;
  final double? solidaritaetszuschlag;
  final double? kirchensteuer;
  final double? krankenversicherung;
  final double? pflegeversicherung;
  final double? rentenversicherung;
  final double? arbeitslosenversicherung;
  final double? vermoegenswirksameLeistungen;
  final double? betrieblicheAltersvorsorge;
  final double? vorschuss;
  final double? sonstigeAbzuege;
  final String? steuerklasse;
  final String? arbeitgeber;
  final String? abrechnungsmonat;

  const PayslipDetails({
    this.brutto,
    this.netto,
    this.depositedAmount,
    this.lohnsteuer,
    this.solidaritaetszuschlag,
    this.kirchensteuer,
    this.krankenversicherung,
    this.pflegeversicherung,
    this.rentenversicherung,
    this.arbeitslosenversicherung,
    this.vermoegenswirksameLeistungen,
    this.betrieblicheAltersvorsorge,
    this.vorschuss,
    this.sonstigeAbzuege,
    this.steuerklasse,
    this.arbeitgeber,
    this.abrechnungsmonat,
  });

  Map<String, dynamic> toJson() => {
        'brutto': brutto,
        'netto': netto,
        'depositedAmount': depositedAmount,
        'lohnsteuer': lohnsteuer,
        'solidaritaetszuschlag': solidaritaetszuschlag,
        'kirchensteuer': kirchensteuer,
        'krankenversicherung': krankenversicherung,
        'pflegeversicherung': pflegeversicherung,
        'rentenversicherung': rentenversicherung,
        'arbeitslosenversicherung': arbeitslosenversicherung,
        'vermoegenswirksameLeistungen': vermoegenswirksameLeistungen,
        'betrieblicheAltersvorsorge': betrieblicheAltersvorsorge,
        'vorschuss': vorschuss,
        'sonstigeAbzuege': sonstigeAbzuege,
        'steuerklasse': steuerklasse,
        'arbeitgeber': arbeitgeber,
        'abrechnungsmonat': abrechnungsmonat,
      };

  factory PayslipDetails.fromJson(Map<String, dynamic> j) => PayslipDetails(
        brutto: (j['brutto'] as num?)?.toDouble(),
        netto: (j['netto'] as num?)?.toDouble(),
        depositedAmount: (j['depositedAmount'] as num?)?.toDouble(),
        lohnsteuer: (j['lohnsteuer'] as num?)?.toDouble(),
        solidaritaetszuschlag: (j['solidaritaetszuschlag'] as num?)?.toDouble(),
        kirchensteuer: (j['kirchensteuer'] as num?)?.toDouble(),
        krankenversicherung: (j['krankenversicherung'] as num?)?.toDouble(),
        pflegeversicherung: (j['pflegeversicherung'] as num?)?.toDouble(),
        rentenversicherung: (j['rentenversicherung'] as num?)?.toDouble(),
        arbeitslosenversicherung: (j['arbeitslosenversicherung'] as num?)?.toDouble(),
        vermoegenswirksameLeistungen: (j['vermoegenswirksameLeistungen'] as num?)?.toDouble(),
        betrieblicheAltersvorsorge: (j['betrieblicheAltersvorsorge'] as num?)?.toDouble(),
        vorschuss: (j['vorschuss'] as num?)?.toDouble(),
        sonstigeAbzuege: (j['sonstigeAbzuege'] as num?)?.toDouble(),
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
  final String? imagePath; // persisted copy of the scanned receipt/payslip image (drafts only)

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
    this.imagePath,
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
    String? imagePath,
    bool clearImagePath = false,
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
        imagePath: clearImagePath ? null : (imagePath ?? this.imagePath),
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
        'imagePath': imagePath,
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
      imagePath: j['imagePath'],
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
/// reached. For a truly unlimited transaction (no installments and no end
/// date), generation is capped at 200 occurrences as a safety bound.
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

/// Represents one occurrence of a transaction on a specific date, for
/// building future-looking views (upcoming payments, calendar, month tabs)
/// that need to show recurring transactions' not-yet-due occurrences
/// alongside real stored transactions. [isReal] is true when this
/// occurrence IS the transaction's own stored record (safe to edit/delete
/// directly); false for a virtual projected future occurrence of a
/// recurring transaction (view-only - edit the recurring template itself).
/// Whether an occurrence is "not yet due" is a separate question decided by
/// comparing [date] to today, regardless of [isReal].
typedef TxOccurrence = ({DateTime date, Transaction t, bool isReal});

/// Every real stored transaction, plus a virtual entry for each future
/// occurrence of every recurring transaction, up to [horizonDays] ahead.
/// Virtual entries are never persisted - they exist only to power
/// forward-looking displays.
List<TxOccurrence> occurrencesWithRecurringProjections(List<Transaction> tx, {int horizonDays = 400}) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final horizon = today.add(Duration(days: horizonDays));
  final result = <TxOccurrence>[];
  for (final t in tx) {
    result.add((date: t.date, t: t, isReal: true));
    if (!t.isRecurring) continue;
    final anchor = DateTime(t.date.year, t.date.month, t.date.day);
    for (final d in computeRecurrenceOccurrences(t)) {
      final dd = DateTime(d.year, d.month, d.day);
      if (dd == anchor) continue; // already represented by the real stored transaction above
      if (!dd.isAfter(today) || dd.isAfter(horizon)) continue;
      result.add((date: dd, t: t, isReal: false));
    }
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

  /// Shows an immediate (not scheduled) notification, e.g. for a budget
  /// goal threshold that was just crossed.
  Future<void> showNow(int id, String title, String body) async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails('budget_goals', 'اهداف هزینه', importance: Importance.high, priority: Priority.high),
    );
    await _plugin.show(id, title, body, details);
  }

  int _idFor(String txId, int slot) => (txId.hashCode & 0xffff) * 1000 + slot;

  Future<void> cancelForTransaction(String txId) async {
    // slot 0/1 = second-to-last/last reminders, slots 2..201 = optional
    // per-installment reminders (capped at 200 upcoming installments).
    // Run these in parallel rather than one at a time - awaiting 202
    // sequential platform-channel round-trips was the main reason saving a
    // transaction felt slow.
    await Future.wait([for (var slot = 0; slot < 202; slot++) _plugin.cancel(_idFor(txId, slot))]);
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
    final body = t.notifyMessage.trim().isNotEmpty ? t.notifyMessage.trim() : 'سررسید این تراکنش تکرارشونده نزدیک است.';
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'recurring_due',
        'یادآوری تراکنش‌های تکرارشونده',
        channelDescription: 'یادآوری قبل از سررسیدهای یک تراکنش تکرارشونده',
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
    final scheduleCalls = <Future<void>>[];
    for (final entry in targets.entries) {
      final when = DateTime(entry.value.year, entry.value.month, entry.value.day, 9).subtract(const Duration(days: 1));
      if (!when.isAfter(now)) continue;
      scheduleCalls.add(_plugin.zonedSchedule(
        _idFor(t.id, entry.key),
        categoryName,
        body,
        _asTZDateTime(when),
        details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
      ));
    }
    final days = t.notifyDaysBeforeEach;
    if (days != null && days > 0) {
      final capped = occurrences.take(200).toList();
      for (var i = 0; i < capped.length; i++) {
        final due = capped[i];
        final when = DateTime(due.year, due.month, due.day, 9).subtract(Duration(days: days));
        if (!when.isAfter(now)) continue;
        scheduleCalls.add(_plugin.zonedSchedule(
          _idFor(t.id, 2 + i),
          categoryName,
          '$days روز تا سررسید این قسط (${formatDate(due)})${t.notifyMessage.trim().isNotEmpty ? ' • ${t.notifyMessage.trim()}' : ''}',
          _asTZDateTime(when),
          details,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          uiLocalNotificationDateInterpretation: UILocalNotificationDateInterpretation.absoluteTime,
        ));
      }
    }
    // Fire all the schedule calls in parallel instead of awaiting each one
    // sequentially - this is what made saving a recurring transaction with
    // per-installment reminders feel slow.
    await Future.wait(scheduleCalls);
  }
}

// ============================== Default seed data ==============================

const defaultCategories = <Category>[
  Category(id: 'e_food', name: 'خوراک و خواربار', type: TxType.expense),
  Category(id: 'e_food_market', name: 'سوپرمارکت', parentId: 'e_food', type: TxType.expense),
  Category(id: 'e_food_restaurant', name: 'رستوران', parentId: 'e_food', type: TxType.expense),
  Category(id: 'e_food_produce', name: 'میوه و تره‌بار', parentId: 'e_food', type: TxType.expense),
  Category(id: 'e_housing', name: 'مسکن', type: TxType.expense),
  Category(id: 'e_housing_rent', name: 'اجاره / رهن', parentId: 'e_housing', type: TxType.expense),
  Category(id: 'e_housing_fee', name: 'شارژ ساختمان', parentId: 'e_housing', type: TxType.expense),
  Category(id: 'e_housing_repair', name: 'تعمیرات', parentId: 'e_housing', type: TxType.expense),
  Category(id: 'e_transport', name: 'حمل و نقل', type: TxType.expense),
  Category(id: 'e_transport_fuel', name: 'بنزین', parentId: 'e_transport', type: TxType.expense),
  Category(id: 'e_transport_repair', name: 'تعمیر خودرو', parentId: 'e_transport', type: TxType.expense),
  Category(id: 'e_transport_public', name: 'حمل‌ونقل عمومی', parentId: 'e_transport', type: TxType.expense),
  Category(id: 'e_car', name: 'خودرو', type: TxType.expense),
  Category(id: 'e_car_insurance', name: 'بیمه خودرو', parentId: 'e_car', type: TxType.expense),
  Category(id: 'e_car_service', name: 'تعمیر و سرویس', parentId: 'e_car', type: TxType.expense),
  Category(id: 'e_car_fuel', name: 'بنزین', parentId: 'e_car', type: TxType.expense),
  Category(id: 'e_car_fine', name: 'جریمه رانندگی', parentId: 'e_car', type: TxType.expense),
  Category(id: 'e_car_parking', name: 'پارکینگ', parentId: 'e_car', type: TxType.expense),
  Category(id: 'e_bills', name: 'قبوض', type: TxType.expense),
  Category(id: 'e_bills_power', name: 'برق', parentId: 'e_bills', type: TxType.expense),
  Category(id: 'e_bills_water', name: 'آب', parentId: 'e_bills', type: TxType.expense),
  Category(id: 'e_bills_gas', name: 'گاز', parentId: 'e_bills', type: TxType.expense),
  Category(id: 'e_bills_internet', name: 'اینترنت', parentId: 'e_bills', type: TxType.expense),
  Category(id: 'e_bills_phone', name: 'تلفن', parentId: 'e_bills', type: TxType.expense),
  Category(id: 'e_health', name: 'درمان', type: TxType.expense),
  Category(id: 'e_leisure', name: 'تفریح', type: TxType.expense),
  Category(id: 'e_clothing', name: 'پوشاک', type: TxType.expense),
  Category(id: 'e_loans', name: 'اقساط و وام', type: TxType.expense),
  Category(id: 'e_loans_car', name: 'قسط خودرو', parentId: 'e_loans', type: TxType.expense),
  Category(id: 'e_loans_home', name: 'قسط مسکن', parentId: 'e_loans', type: TxType.expense),
  Category(id: 'e_loans_personal', name: 'وام شخصی', parentId: 'e_loans', type: TxType.expense),
  Category(id: 'e_loans_installment_purchase', name: 'خرید قسطی', parentId: 'e_loans', type: TxType.expense),
  Category(id: 'e_subscription', name: 'اشتراک', type: TxType.expense),
  Category(id: 'e_subscription_software', name: 'اشتراک نرم‌افزار', parentId: 'e_subscription', type: TxType.expense),
  Category(id: 'e_insurance', name: 'بیمه', type: TxType.expense),
  Category(id: 'e_misc', name: 'متفرقه', type: TxType.expense),
  Category(id: '_transfer_out_', name: 'انتقال بین حساب‌ها', type: TxType.expense),
  Category(id: 'i_salary', name: 'حقوق', type: TxType.income),
  Category(id: 'i_freelance', name: 'فریلنسری', type: TxType.income),
  Category(id: 'i_investment', name: 'سرمایه‌گذاری', type: TxType.income),
  Category(id: 'i_gift', name: 'هدیه', type: TxType.income),
  Category(id: 'i_misc', name: 'متفرقه', type: TxType.income),
  Category(id: '_transfer_in_', name: 'انتقال بین حساب‌ها', type: TxType.income),
];

const defaultAccount = Account(id: 'default', name: 'حساب اصلی', type: AccountType.bank, currency: 'EUR');

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
  '_transfer_out_': Icons.swap_horiz,
  'i_salary': Icons.payments_outlined,
  'i_freelance': Icons.laptop_mac_outlined,
  'i_investment': Icons.trending_up,
  'i_gift': Icons.card_giftcard_outlined,
  'i_misc': Icons.more_horiz,
  '_transfer_in_': Icons.swap_horiz,
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
  'خوراک': Icons.restaurant_outlined,
  'غذا': Icons.restaurant_outlined,
  'رستوران': Icons.restaurant_outlined,
  'کافه': Icons.local_cafe_outlined,
  'قهوه': Icons.local_cafe_outlined,
  'خانه': Icons.home_outlined,
  'مسکن': Icons.home_outlined,
  'اجاره': Icons.home_outlined,
  'خودرو': Icons.directions_car_outlined,
  'ماشین': Icons.directions_car_outlined,
  'بنزین': Icons.local_gas_station_outlined,
  'سوخت': Icons.local_gas_station_outlined,
  'پارکینگ': Icons.local_parking_outlined,
  'تعمیر': Icons.build_outlined,
  'حمل‌ونقل': Icons.directions_bus_outlined,
  'اتوبوس': Icons.directions_bus_outlined,
  'مترو': Icons.subway_outlined,
  'قطار': Icons.train_outlined,
  'هواپیما': Icons.flight_outlined,
  'سفر': Icons.flight_outlined,
  'برق': Icons.bolt_outlined,
  'آب': Icons.water_drop_outlined,
  'گاز': Icons.local_fire_department_outlined,
  'اینترنت': Icons.wifi_outlined,
  'تلفن': Icons.phone_iphone_outlined,
  'موبایل': Icons.phone_iphone_outlined,
  'درمان': Icons.medical_services_outlined,
  'دارو': Icons.medication_outlined,
  'پزشک': Icons.medical_services_outlined,
  'دندان': Icons.medical_services_outlined,
  'بیمه': Icons.health_and_safety_outlined,
  'ورزش': Icons.fitness_center_outlined,
  'باشگاه': Icons.fitness_center_outlined,
  'تفریح': Icons.sports_esports_outlined,
  'سینما': Icons.movie_outlined,
  'فیلم': Icons.movie_outlined,
  'موسیقی': Icons.music_note_outlined,
  'پوشاک': Icons.checkroom_outlined,
  'لباس': Icons.checkroom_outlined,
  'کفش': Icons.checkroom_outlined,
  'قسط': Icons.credit_card_outlined,
  'اقساط': Icons.credit_card_outlined,
  'وام': Icons.credit_card_outlined,
  'اشتراک': Icons.subscriptions_outlined,
  'حقوق': Icons.payments_outlined,
  'فریلنس': Icons.laptop_mac_outlined,
  'سرمایه': Icons.trending_up,
  'سهام': Icons.trending_up,
  'هدیه': Icons.card_giftcard_outlined,
  'کتاب': Icons.menu_book_outlined,
  'آموزش': Icons.school_outlined,
  'مدرسه': Icons.school_outlined,
  'دانشگاه': Icons.school_outlined,
  'بچه': Icons.child_care_outlined,
  'کودک': Icons.child_care_outlined,
  'حیوان': Icons.pets_outlined,
  'خیریه': Icons.volunteer_activism_outlined,
  'کمک': Icons.volunteer_activism_outlined,
  'مالیات': Icons.receipt_long_outlined,
  'جریمه': Icons.gavel_outlined,
  'آرایش': Icons.face_retouching_natural_outlined,
  'زیبایی': Icons.face_retouching_natural_outlined,
};

Future<IconData?> _suggestIconViaGemini(String categoryName) async {
  final key = await Store.loadGeminiKey();
  if (key == null || key.trim().isEmpty) return null;
  try {
    final options = _iconKeywordHints.keys.join('، ');
    final uri = Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/${_geminiModels.first}:generateContent?key=$key');
    final body = jsonEncode({
      'contents': [
        {
          'parts': [
            {
              'text':
                  'یک دسته‌بندی مالی با نام "$categoryName" داریم. از این لیست کلمات، فقط دقیقاً یکی را که مفهوماً نزدیک‌ترین به این دسته‌بندی است انتخاب کن و فقط همان یک کلمه را بدون هیچ توضیح دیگری برگردان: $options',
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

/// Returns the chosen icon plus whether it's just the generic fallback
/// (neither a keyword match nor Gemini succeeded) - callers use this to
/// mark the category for a background retry on a later app launch.
Future<({IconData icon, bool isFallback})> suggestIconForCategory(String name, TxType type) async {
  for (final entry in _iconKeywordHints.entries) {
    if (name.contains(entry.key)) return (icon: entry.value, isFallback: false);
  }
  final aiIcon = await _suggestIconViaGemini(name);
  if (aiIcon != null) return (icon: aiIcon, isFallback: false);
  final fallback = type == TxType.expense ? Icons.category_outlined : Icons.attach_money_outlined;
  return (icon: fallback, isFallback: true);
}

/// Retries choosing a real icon (via Gemini) for any category still stuck
/// with the generic fallback icon. Meant to be called once per app launch,
/// but throttled to at most once per calendar day - this shares the same
/// small daily Gemini quota as receipt/payslip scanning, which matters
/// much more, so it shouldn't compete for it on every single launch.
Future<void> retryPendingCategoryIcons() async {
  final categories = await Store.loadCategories();
  final pending = categories.where((c) => c.iconNeedsRetry).toList();
  if (pending.isEmpty) return;
  final lastTry = await Store.loadLastIconRetryDate();
  final today = DateTime.now();
  if (lastTry != null && lastTry.year == today.year && lastTry.month == today.month && lastTry.day == today.day) {
    return;
  }
  await Store.saveLastIconRetryDate(today);
  var changed = false;
  var updated = categories;
  for (final c in pending) {
    final result = await suggestIconForCategory(c.name, c.type);
    if (!result.isFallback) {
      updated = updated.map((x) => x.id == c.id ? x.copyWith(iconCodePoint: result.icon.codePoint, iconNeedsRetry: false) : x).toList();
      changed = true;
    }
  }
  if (changed) await Store.saveCategories(updated);
}

/// Compares this month's spending against any configured budget goals and
/// fires a one-time notification the first time a category crosses 80%
/// (approaching), 100% (met), or passes 100% (exceeded) of its goal for
/// the month - never repeats the same threshold twice in one month.
Future<void> checkBudgetGoals() async {
  final goals = await Store.loadBudgetGoals();
  if (goals.isEmpty) return;
  final tx = await Store.loadTransactions();
  final categories = await Store.loadCategories();
  final now = DateTime.now();
  final monthKey = '${now.year}-${now.month}';
  final notifyState = await Store.loadBudgetNotifyState();
  var changed = false;

  String categoryName(String id) {
    final m = categories.where((c) => c.id == id).toList();
    return m.isEmpty ? '' : m.first.name;
  }

  for (final goal in goals) {
    if (goal.monthlyAmount <= 0) continue;
    double spend = 0;
    for (final t in tx) {
      if (t.type != TxType.expense) continue;
      if (t.date.year != now.year || t.date.month != now.month) continue;
      final match = categories.where((c) => c.id == t.categoryId).toList();
      var cat = match.isEmpty ? null : match.first;
      while (cat?.parentId != null) {
        final pm = categories.where((c) => c.id == cat!.parentId).toList();
        if (pm.isEmpty) break;
        cat = pm.first;
      }
      if (cat?.id == goal.categoryId) spend += t.amount;
    }
    final ratio = spend / goal.monthlyAmount;
    String? level;
    if (ratio >= 1.05) {
      level = 'exceeded';
    } else if (ratio >= 1.0) {
      level = 'met';
    } else if (ratio >= 0.8) {
      level = 'approaching';
    }
    if (level == null) continue;
    const severity = {'approaching': 1, 'met': 2, 'exceeded': 3};
    final key = '${goal.categoryId}_$monthKey';
    final already = notifyState[key];
    if (already != null && severity[already]! >= severity[level]!) continue;
    notifyState[key] = level;
    changed = true;
    final name = categoryName(goal.categoryId);
    final title = switch (level) {
      'exceeded' => 'هدف هزینه‌ی «$name» رد شد',
      'met' => 'هدف هزینه‌ی «$name» به پایان رسید',
      _ => 'نزدیک شدن به هدف هزینه‌ی «$name»',
    };
    final body = '${(ratio * 100).round()}% از هدف این ماه (${spend.toStringAsFixed(0)} از ${goal.monthlyAmount.toStringAsFixed(0)}) خرج شده.';
    await NotificationService.instance.showNow(goal.categoryId.hashCode & 0xffff, title, body);
  }
  if (changed) await Store.saveBudgetNotifyState(notifyState);
}

// ============================== Storage ==============================

class Store {
  static const _txKey = 'transactions';
  static const _catKey = 'categories_v2';
  static const _budgetKey = 'budget_goals';
  static const _budgetNotifyKey = 'budget_goal_notify_state';
  static const _savingsGoalKey = 'savings_goals';

  static Future<List<SavingsGoal>> loadSavingsGoals() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getStringList(_savingsGoalKey) ?? [];
    return raw.map((s) => SavingsGoal.fromJson(jsonDecode(s))).toList();
  }

  static Future<void> saveSavingsGoals(List<SavingsGoal> list) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(_savingsGoalKey, list.map((g) => jsonEncode(g.toJson())).toList());
  }

  static const _savingsContribKey = 'savings_contributions';

  static Future<List<SavingsContribution>> loadSavingsContributions() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getStringList(_savingsContribKey) ?? [];
    return raw.map((s) => SavingsContribution.fromJson(jsonDecode(s))).toList();
  }

  static Future<void> saveSavingsContributions(List<SavingsContribution> list) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(_savingsContribKey, list.map((c) => jsonEncode(c.toJson())).toList());
  }

  static Future<List<BudgetGoal>> loadBudgetGoals() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getStringList(_budgetKey) ?? [];
    return raw.map((s) => BudgetGoal.fromJson(jsonDecode(s))).toList();
  }

  static Future<void> saveBudgetGoals(List<BudgetGoal> list) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(_budgetKey, list.map((g) => jsonEncode(g.toJson())).toList());
  }

  /// Which notification threshold ("approaching"/"met"/"exceeded") was
  /// already sent for each "categoryId_yyyy-mm" this month, so the same
  /// alert isn't repeated every time the check runs.
  static Future<Map<String, String>> loadBudgetNotifyState() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_budgetNotifyKey);
    if (raw == null) return {};
    return Map<String, String>.from(jsonDecode(raw));
  }

  static Future<void> saveBudgetNotifyState(Map<String, String> state) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_budgetNotifyKey, jsonEncode(state));
  }


  static const _accKey = 'accounts_v2';
  static const _geminiKey = 'gemini_api_key';
  static const _langKey = 'app_language';
  static const _themeModeKey = 'app_theme_mode';
  static const _iconRetryDateKey = 'last_icon_retry_date';

  static Future<DateTime?> loadLastIconRetryDate() async {
    final sp = await SharedPreferences.getInstance();
    final s = sp.getString(_iconRetryDateKey);
    return s == null ? null : DateTime.tryParse(s);
  }

  static Future<void> saveLastIconRetryDate(DateTime date) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_iconRetryDateKey, date.toIso8601String());
  }
  static const _lockEnabledKey = 'app_lock_enabled';
  static const _pinHashKey = 'app_lock_pin_hash';
  static const _pinSaltKey = 'app_lock_pin_salt';
  static const _biometricKey = 'app_lock_use_biometric';

  static Future<void> saveGeminiKey(String key) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_geminiKey, key);
  }

  static Future<String?> loadGeminiKey() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_geminiKey);
  }

  static Future<bool> loadAppLockEnabled() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(_lockEnabledKey) ?? false;
  }

  static Future<void> saveAppLockEnabled(bool enabled) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_lockEnabledKey, enabled);
  }

  static Future<bool> loadUseBiometric() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(_biometricKey) ?? false;
  }

  static Future<void> saveUseBiometric(bool enabled) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_biometricKey, enabled);
  }

  static Future<bool> hasPinSet() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_pinHashKey) != null;
  }

  static Future<void> savePin(String pin) async {
    final sp = await SharedPreferences.getInstance();
    final salt = List.generate(16, (_) => Random.secure().nextInt(256)).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final hash = sha256.convert(utf8.encode(salt + pin)).toString();
    await sp.setString(_pinSaltKey, salt);
    await sp.setString(_pinHashKey, hash);
  }

  static Future<bool> verifyPin(String pin) async {
    final sp = await SharedPreferences.getInstance();
    final salt = sp.getString(_pinSaltKey);
    final storedHash = sp.getString(_pinHashKey);
    if (salt == null || storedHash == null) return false;
    final hash = sha256.convert(utf8.encode(salt + pin)).toString();
    return hash == storedHash;
  }

  static Future<void> clearPin() async {
    final sp = await SharedPreferences.getInstance();
    await sp.remove(_pinHashKey);
    await sp.remove(_pinSaltKey);
  }

  /// Full-data backup as a JSON-encodable map (transactions, categories,
  /// accounts). Deliberately excludes the Gemini key and lock PIN/hash -
  /// those are per-device secrets, not app data.
  static Future<Map<String, dynamic>> exportBackupData() async {
    final tx = await loadTransactions();
    final categories = await loadCategories();
    final accounts = await loadAccounts();
    return {
      'backupVersion': 1,
      'exportedAt': DateTime.now().toIso8601String(),
      'transactions': tx.map((t) => t.toJson()).toList(),
      'categories': categories.map((c) => c.toJson()).toList(),
      'accounts': accounts.map((a) => a.toJson()).toList(),
    };
  }

  /// Replaces ALL current transactions/categories/accounts with the
  /// contents of a previously exported backup map. Throws a descriptive
  /// [FormatException] if the data doesn't look like a valid backup.
  static Future<void> restoreBackupData(Map<String, dynamic> data) async {
    if (data['transactions'] is! List || data['categories'] is! List || data['accounts'] is! List) {
      throw const FormatException('این فایل یک نسخه‌ی پشتیبان معتبر برنامه نیست.');
    }
    final tx = (data['transactions'] as List).map((j) => Transaction.fromJson(j)).toList();
    final categories = (data['categories'] as List).map((j) => Category.fromJson(j)).toList();
    final accounts = (data['accounts'] as List).map((j) => Account.fromJson(j)).toList();
    await saveTransactions(tx);
    await saveCategories(categories);
    await saveAccounts(accounts);
  }

  static Future<AppLanguage> loadLanguage() async {
    final sp = await SharedPreferences.getInstance();
    final code = sp.getString(_langKey);
    return AppLanguage.values.firstWhere((l) => l.name == code, orElse: () => AppLanguage.fa);
  }

  static Future<void> saveLanguage(AppLanguage lang) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_langKey, lang.name);
  }

  static Future<ThemeMode> loadThemeMode() async {
    final sp = await SharedPreferences.getInstance();
    final code = sp.getString(_themeModeKey);
    return ThemeMode.values.firstWhere((m) => m.name == code, orElse: () => ThemeMode.system);
  }

  static Future<void> saveThemeMode(ThemeMode mode) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_themeModeKey, mode.name);
  }

  static const _calendarSystemKey = 'app_calendar_system';

  static Future<CalendarSystem> loadCalendarSystem() async {
    final sp = await SharedPreferences.getInstance();
    final code = sp.getString(_calendarSystemKey);
    return CalendarSystem.values.firstWhere((c) => c.name == code, orElse: () => CalendarSystem.gregorian);
  }

  static Future<void> saveCalendarSystem(CalendarSystem system) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_calendarSystemKey, system.name);
  }

  static Future<List<Transaction>> loadTransactions() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getStringList(_txKey) ?? [];
    var list = raw.map((s) => Transaction.fromJson(jsonDecode(s))).toList();
    // One-time fix: payslip transactions used to be recorded at the netto
    // amount; the amount credited to the account (depositedAmount) can
    // differ, so realign the transaction's amount to it where available.
    var changed = false;
    list = list.map((t) {
      final deposited = t.payslipDetails?.depositedAmount;
      if (deposited != null && deposited > 0 && (t.amount - deposited).abs() >= 0.01) {
        changed = true;
        return t.copyWith(amount: deposited);
      }
      return t;
    }).toList();
    if (changed) await saveTransactions(list);
    return list;
  }

  static Future<void> saveTransactions(List<Transaction> list) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(_txKey, list.map((t) => jsonEncode(t.toJson())).toList());
  }

  /// A transfer between accounts is stored as two linked transactions
  /// (ids "<base>_out" and "<base>_in"). Given either leg's id, returns
  /// the other leg's id, or null if this isn't a transfer transaction.
  static String? _transferPairId(String id) {
    if (id.endsWith('_out')) return '${id.substring(0, id.length - 4)}_in';
    if (id.endsWith('_in')) return '${id.substring(0, id.length - 3)}_out';
    return null;
  }

  /// Adds or updates a single transaction against the LATEST persisted
  /// list (re-read fresh, not whatever stale copy a screen happened to be
  /// holding). This avoids two screens' full-list overwrites racing and
  /// silently clobbering each other's edits - the likely cause of
  /// transactions occasionally "not saving" despite the save button
  /// appearing to work.
  static Future<void> upsertTransaction(Transaction t) async {
    final list = await loadTransactions();
    final idx = list.indexWhere((x) => x.id == t.id);
    if (idx >= 0) {
      list[idx] = t;
    } else {
      list.add(t);
    }
    // A transfer is really one event told from two accounts' sides -
    // editing the amount/date/recurrence on one leg should keep the other
    // leg (kept in its own type/category/account/note) in sync, so the
    // pair doesn't silently drift apart.
    if (t.categoryId == '_transfer_out_' || t.categoryId == '_transfer_in_') {
      final pairId = _transferPairId(t.id);
      if (pairId != null) {
        final pairIdx = list.indexWhere((x) => x.id == pairId);
        if (pairIdx >= 0) {
          list[pairIdx] = list[pairIdx].copyWith(
            amount: t.amount,
            date: t.date,
            recurrence: t.recurrence,
            recurrenceDay: t.recurrenceDay,
            recurrenceWeekday: t.recurrenceWeekday,
            recurrenceIntervalDays: t.recurrenceIntervalDays,
            installments: t.installments,
            recurrenceEndDate: t.recurrenceEndDate,
          );
        }
      }
    }
    await saveTransactions(list);
  }

  static Future<void> deleteTransaction(String id) async {
    final list = await loadTransactions();
    list.removeWhere((x) => x.id == id);
    // Deleting one leg of a transfer without the other would leave a
    // one-sided "phantom" transaction behind - remove both together.
    final pairId = _transferPairId(id);
    if (pairId != null) list.removeWhere((x) => x.id == pairId);
    await saveTransactions(list);
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
      // transactions that used it to the parent "خودرو" category instead.
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
        !list.any((c) => c.parentId == 'e_car' && c.type == TxType.expense && c.name.trim() == 'پارکینگ')) {
      list = [...list, ...defaultCategories.where((c) => c.id == 'e_car_parking')];
      changed = true;
    }
    for (final newId in [
      'e_loans_installment_purchase',
      'e_subscription',
      'e_insurance',
      'e_subscription_software',
      '_transfer_out_',
      '_transfer_in_',
    ]) {
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
    // Always return in sorted order - saveCategories sorts what it writes
    // to disk, but without this the in-memory list handed back here (right
    // after a migration added something) would still be in insertion
    // order, which is exactly what caused newly-added categories to
    // stubbornly appear at the end of the list instead of alphabetically.
    return List.of(list)..sort((a, b) => persianCompare(a.name, b.name));
  }

  static Future<void> saveCategories(List<Category> list) async {
    // Sort alphabetically (by name) every time; since children are always
    // filtered by parentId when rendered, a flat alphabetical sort keeps
    // each level's items alphabetical too.
    final sorted = List.of(list)..sort((a, b) => persianCompare(a.name, b.name));
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

enum AppLanguage { fa, en, de }

extension AppLanguageX on AppLanguage {
  String get label => switch (this) {
        AppLanguage.fa => 'فارسی',
        AppLanguage.en => 'English',
        AppLanguage.de => 'Deutsch',
      };
  TextDirection get direction => this == AppLanguage.fa ? TextDirection.rtl : TextDirection.ltr;
  Locale get locale => switch (this) {
        AppLanguage.fa => const Locale('fa'),
        AppLanguage.en => const Locale('en'),
        AppLanguage.de => const Locale('de'),
      };
}

final ValueNotifier<AppLanguage> currentLanguage = ValueNotifier(AppLanguage.fa);
final ValueNotifier<ThemeMode> currentThemeMode = ValueNotifier(ThemeMode.system);

/// Minimal, hand-maintained translation table. Covers the app's highest
/// traffic labels first (navigation, home screen, settings); the rest of
/// the app's strings remain Persian-only for now and will be migrated
/// into this table incrementally.
const Map<String, Map<AppLanguage, String>> _translations = {
  'app_title': {AppLanguage.fa: 'مدیریت مالی شخصی', AppLanguage.en: 'Personal Finance', AppLanguage.de: 'Persönliche Finanzen'},
  'home': {AppLanguage.fa: 'خانه', AppLanguage.en: 'Home', AppLanguage.de: 'Start'},
  'category_management': {AppLanguage.fa: 'مدیریت دسته‌بندی‌ها', AppLanguage.en: 'Manage categories', AppLanguage.de: 'Kategorien verwalten'},
  'accounts': {AppLanguage.fa: 'حساب‌ها', AppLanguage.en: 'Accounts', AppLanguage.de: 'Konten'},
  'settings': {AppLanguage.fa: 'تنظیمات', AppLanguage.en: 'Settings', AppLanguage.de: 'Einstellungen'},
  'recurring_transactions': {AppLanguage.fa: 'تراکنش‌های تکرارشونده', AppLanguage.en: 'Recurring transactions', AppLanguage.de: 'Wiederkehrende Buchungen'},
  'affected_by_category_delete': {
    AppLanguage.fa: 'تراکنش‌های تحت‌تأثیر حذف دسته‌بندی',
    AppLanguage.en: 'Transactions affected by a deleted category',
    AppLanguage.de: 'Von gelöschter Kategorie betroffene Buchungen',
  },
  'new_transaction': {AppLanguage.fa: 'تراکنش جدید', AppLanguage.en: 'New transaction', AppLanguage.de: 'Neue Buchung'},
  'transactions': {AppLanguage.fa: 'تراکنش‌ها', AppLanguage.en: 'Transactions', AppLanguage.de: 'Buchungen'},
  'income': {AppLanguage.fa: 'درآمد', AppLanguage.en: 'Income', AppLanguage.de: 'Einnahme'},
  'expense': {AppLanguage.fa: 'هزینه', AppLanguage.en: 'Expense', AppLanguage.de: 'Ausgabe'},
  'app_language': {AppLanguage.fa: 'زبان برنامه', AppLanguage.en: 'App language', AppLanguage.de: 'App-Sprache'},
  'save': {AppLanguage.fa: 'ذخیره', AppLanguage.en: 'Save', AppLanguage.de: 'Speichern'},
  'cancel': {AppLanguage.fa: 'انصراف', AppLanguage.en: 'Cancel', AppLanguage.de: 'Abbrechen'},
  'delete': {AppLanguage.fa: 'حذف', AppLanguage.en: 'Delete', AppLanguage.de: 'Löschen'},
  'amount': {AppLanguage.fa: 'مبلغ', AppLanguage.en: 'Amount', AppLanguage.de: 'Betrag'},
  'category': {AppLanguage.fa: 'دسته‌بندی', AppLanguage.en: 'Category', AppLanguage.de: 'Kategorie'},
  'select_category': {AppLanguage.fa: 'انتخاب دسته‌بندی', AppLanguage.en: 'Select category', AppLanguage.de: 'Kategorie wählen'},
  'account': {AppLanguage.fa: 'حساب', AppLanguage.en: 'Account', AppLanguage.de: 'Konto'},
  'date': {AppLanguage.fa: 'تاریخ', AppLanguage.en: 'Date', AppLanguage.de: 'Datum'},
  'note': {AppLanguage.fa: 'توضیحات (اختیاری)', AppLanguage.en: 'Notes (optional)', AppLanguage.de: 'Notizen (optional)'},
  'new_category': {AppLanguage.fa: 'دسته‌بندی جدید', AppLanguage.en: 'New category', AppLanguage.de: 'Neue Kategorie'},
  'add': {AppLanguage.fa: 'افزودن', AppLanguage.en: 'Add', AppLanguage.de: 'Hinzufügen'},
  'rename': {AppLanguage.fa: 'تغییر نام', AppLanguage.en: 'Rename', AppLanguage.de: 'Umbenennen'},
  'scan_receipt_or_payslip': {AppLanguage.fa: 'اسکن رسید یا فیش حقوقی', AppLanguage.en: 'Scan receipt or payslip', AppLanguage.de: 'Beleg oder Lohnabrechnung scannen'},
  'camera': {AppLanguage.fa: 'دوربین', AppLanguage.en: 'Camera', AppLanguage.de: 'Kamera'},
  'gallery': {AppLanguage.fa: 'گالری', AppLanguage.en: 'Gallery', AppLanguage.de: 'Galerie'},
  'new_receipt': {AppLanguage.fa: 'رسید جدید', AppLanguage.en: 'New receipt', AppLanguage.de: 'Neuer Beleg'},
  'new_payslip': {AppLanguage.fa: 'فیش حقوقی جدید', AppLanguage.en: 'New payslip', AppLanguage.de: 'Neue Lohnabrechnung'},
  'drafts': {AppLanguage.fa: 'پیش‌نویس‌ها', AppLanguage.en: 'Drafts', AppLanguage.de: 'Entwürfe'},
  'total_balance': {AppLanguage.fa: 'موجودی کل', AppLanguage.en: 'Total balance', AppLanguage.de: 'Gesamtsaldo'},
  'recurring': {AppLanguage.fa: 'تکرارشونده', AppLanguage.en: 'Recurring', AppLanguage.de: 'Wiederkehrend'},
  'draft': {AppLanguage.fa: 'پیش‌نویس', AppLanguage.en: 'Draft', AppLanguage.de: 'Entwurf'},
  'confirm_delete_transaction': {
    AppLanguage.fa: 'این تراکنش حذف شود؟',
    AppLanguage.en: 'Delete this transaction?',
    AppLanguage.de: 'Diese Buchung löschen?',
  },
  'expense_by_category': {AppLanguage.fa: 'هزینه‌ها بر اساس دسته‌بندی', AppLanguage.en: 'Expenses by category', AppLanguage.de: 'Ausgaben nach Kategorie'},
  'last_6_months': {AppLanguage.fa: 'روند ۶ ماه اخیر', AppLanguage.en: 'Last 6 months trend', AppLanguage.de: 'Trend der letzten 6 Monate'},
  'gemini_key': {AppLanguage.fa: 'کلید Gemini API', AppLanguage.en: 'Gemini API key', AppLanguage.de: 'Gemini-API-Schlüssel'},
  'upcoming_payments': {AppLanguage.fa: 'پرداخت‌های پیش‌رو', AppLanguage.en: 'Upcoming payments', AppLanguage.de: 'Bevorstehende Zahlungen'},
  'budget_goals': {AppLanguage.fa: 'اهداف هزینه', AppLanguage.en: 'Budget goals', AppLanguage.de: 'Budgetziele'},
  'savings_goals': {AppLanguage.fa: 'اهداف پس‌انداز', AppLanguage.en: 'Savings goals', AppLanguage.de: 'Sparziele'},
  'transfer_between_accounts': {AppLanguage.fa: 'انتقال بین حساب‌ها', AppLanguage.en: 'Transfer between accounts', AppLanguage.de: 'Kontoübertragung'},
  'all_transactions': {AppLanguage.fa: 'همه‌ی تراکنش‌ها', AppLanguage.en: 'All transactions', AppLanguage.de: 'Alle Buchungen'},
  'full_reporting': {AppLanguage.fa: 'گزارش‌گیری کامل', AppLanguage.en: 'Full reporting', AppLanguage.de: 'Vollständiger Bericht'},
  'expense_forecast': {AppLanguage.fa: 'پیش‌بینی هزینه', AppLanguage.en: 'Expense forecast', AppLanguage.de: 'Ausgabenprognose'},
  'month_calendar': {AppLanguage.fa: 'خلاصه ماه در یک نگاه', AppLanguage.en: 'Month at a glance', AppLanguage.de: 'Monat im Überblick'},
  'search': {AppLanguage.fa: 'جستجو', AppLanguage.en: 'Search', AppLanguage.de: 'Suche'},
  'filter': {AppLanguage.fa: 'فیلتر', AppLanguage.en: 'Filter', AppLanguage.de: 'Filter'},
  'sort': {AppLanguage.fa: 'مرتب‌سازی', AppLanguage.en: 'Sort', AppLanguage.de: 'Sortieren'},
  'from_account': {AppLanguage.fa: 'از حساب', AppLanguage.en: 'From account', AppLanguage.de: 'Von Konto'},
  'to_account': {AppLanguage.fa: 'به حساب', AppLanguage.en: 'To account', AppLanguage.de: 'Zu Konto'},
  'all_accounts': {AppLanguage.fa: 'همه‌ی حساب‌ها', AppLanguage.en: 'All accounts', AppLanguage.de: 'Alle Konten'},
  'new_goal': {AppLanguage.fa: 'هدف جدید', AppLanguage.en: 'New goal', AppLanguage.de: 'Neues Ziel'},
  'transfer': {AppLanguage.fa: 'انتقال', AppLanguage.en: 'Transfer', AppLanguage.de: 'Überweisen'},
  'this_month': {AppLanguage.fa: 'این ماه', AppLanguage.en: 'This month', AppLanguage.de: 'Diesen Monat'},
  'next_month': {AppLanguage.fa: 'ماه بعد', AppLanguage.en: 'Next month', AppLanguage.de: 'Nächsten Monat'},
  'custom_month': {AppLanguage.fa: 'ماه دلخواه', AppLanguage.en: 'Custom month', AppLanguage.de: 'Bestimmter Monat'},
  'add_account': {AppLanguage.fa: 'حساب جدید', AppLanguage.en: 'New account', AppLanguage.de: 'Neues Konto'},
  'delete_target': {AppLanguage.fa: 'حذف هدف', AppLanguage.en: 'Delete goal', AppLanguage.de: 'Ziel löschen'},
  'quantity': {AppLanguage.fa: 'تعداد', AppLanguage.en: 'Quantity', AppLanguage.de: 'Menge'},
  'price': {AppLanguage.fa: 'قیمت', AppLanguage.en: 'Price', AppLanguage.de: 'Preis'},
  'item_name': {AppLanguage.fa: 'نام کالا', AppLanguage.en: 'Item name', AppLanguage.de: 'Artikelname'},
  'recurrence_type': {AppLanguage.fa: 'نوع تکرار', AppLanguage.en: 'Recurrence type', AppLanguage.de: 'Wiederholungstyp'},
  'weekday': {AppLanguage.fa: 'روز هفته', AppLanguage.en: 'Weekday', AppLanguage.de: 'Wochentag'},
  'total_installments': {AppLanguage.fa: 'تعداد کل اقساط', AppLanguage.en: 'Total installments', AppLanguage.de: 'Gesamtzahl der Raten'},
  'save_as_draft': {AppLanguage.fa: 'ذخیره به‌صورت پیش‌نویس', AppLanguage.en: 'Save as draft', AppLanguage.de: 'Als Entwurf speichern'},
  'installment_reminder': {AppLanguage.fa: 'اعلان اقساط', AppLanguage.en: 'Installment reminder', AppLanguage.de: 'Ratenerinnerung'},
  'reminder_note': {AppLanguage.fa: 'پیام یادآوری (اختیاری)', AppLanguage.en: 'Reminder note (optional)', AppLanguage.de: 'Erinnerungsnotiz (optional)'},
  'delete_transaction_confirm': {
    AppLanguage.fa: 'این تراکنش حذف شود؟',
    AppLanguage.en: 'Delete this transaction?',
    AppLanguage.de: 'Diese Buchung löschen?',
  },
  'app_lock_title': {AppLanguage.fa: 'قفل برنامه', AppLanguage.en: 'App lock', AppLanguage.de: 'App-Sperre'},
  'backup_restore_title': {AppLanguage.fa: 'پشتیبان‌گیری و بازیابی', AppLanguage.en: 'Backup & restore', AppLanguage.de: 'Sicherung & Wiederherstellung'},
  'scan_title': {AppLanguage.fa: 'اسکن رسید یا فیش حقوقی', AppLanguage.en: 'Scan receipt or payslip', AppLanguage.de: 'Beleg oder Lohnabrechnung scannen'},
  'review_receipt': {AppLanguage.fa: 'بررسی رسید', AppLanguage.en: 'Review receipt', AppLanguage.de: 'Beleg prüfen'},
  'review_payslip': {AppLanguage.fa: 'بررسی فیش حقوقی', AppLanguage.en: 'Review payslip', AppLanguage.de: 'Lohnabrechnung prüfen'},
  'items': {AppLanguage.fa: 'اقلام خرید', AppLanguage.en: 'Purchase items', AppLanguage.de: 'Kaufartikel'},
  'total': {AppLanguage.fa: 'جمع کل', AppLanguage.en: 'Total', AppLanguage.de: 'Gesamt'},
  'edit': {AppLanguage.fa: 'ویرایش', AppLanguage.en: 'Edit', AppLanguage.de: 'Bearbeiten'},
  'confirm': {AppLanguage.fa: 'تأیید', AppLanguage.en: 'Confirm', AppLanguage.de: 'Bestätigen'},
  'retry': {AppLanguage.fa: 'تلاش دوباره', AppLanguage.en: 'Retry', AppLanguage.de: 'Erneut versuchen'},
  'no_items_yet': {AppLanguage.fa: 'کالایی ثبت نشده.', AppLanguage.en: 'No items yet.', AppLanguage.de: 'Noch keine Artikel.'},
};

/// Looks up [key] in the current UI language; falls back to the Persian
/// string (or the key itself) if a translation is missing.
String tr(String key) {
  final row = _translations[key];
  if (row == null) return key;
  return row[currentLanguage.value] ?? row[AppLanguage.fa] ?? key;
}

class MoneyApp extends StatefulWidget {
  const MoneyApp({super.key});
  @override
  State<MoneyApp> createState() => _MoneyAppState();
}

class _MoneyAppState extends State<MoneyApp> {
  @override
  void initState() {
    super.initState();
    currentLanguage.addListener(_onChanged);
    currentThemeMode.addListener(_onChanged);
    currentCalendarSystem.addListener(_onChanged);
  }

  @override
  void dispose() {
    currentLanguage.removeListener(_onChanged);
    currentThemeMode.removeListener(_onChanged);
    currentCalendarSystem.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: tr('app_title'),
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true, brightness: Brightness.light),
      darkTheme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true, brightness: Brightness.dark),
      themeMode: currentThemeMode.value,
      locale: currentLanguage.value.locale,
      supportedLocales: const [Locale('fa'), Locale('en'), Locale('de')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) => Directionality(textDirection: currentLanguage.value.direction, child: child!),
      home: const AppLockGate(child: HomeScreen()),
    );
  }
}

// ============================== App lock ==============================

class AppLockGate extends StatefulWidget {
  final Widget child;
  const AppLockGate({required this.child, super.key});
  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  bool _loading = true;
  bool _lockEnabled = false;
  bool _unlocked = false;
  DateTime? _pausedAt;
  static const _graceDuration = Duration(minutes: 5);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _init() async {
    final enabled = await Store.loadAppLockEnabled();
    if (!mounted) return;
    setState(() {
      _lockEnabled = enabled;
      _unlocked = !enabled;
      _loading = false;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_lockEnabled) return;
    // The app also goes to "paused" for brief in-app interruptions (camera,
    // gallery/file picker, share sheet, permission dialogs) - only actually
    // re-lock if it's been away long enough to look like a real backgrounding.
    if (state == AppLifecycleState.paused) {
      _pausedAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final pausedAt = _pausedAt;
      _pausedAt = null;
      if (pausedAt != null && DateTime.now().difference(pausedAt) >= _graceDuration) {
        setState(() => _unlocked = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (!_unlocked) {
      return PinLockScreen(onUnlocked: () => setState(() => _unlocked = true));
    }
    return widget.child;
  }
}

class PinLockScreen extends StatefulWidget {
  final VoidCallback onUnlocked;
  const PinLockScreen({required this.onUnlocked, super.key});
  @override
  State<PinLockScreen> createState() => _PinLockScreenState();
}

class _PinLockScreenState extends State<PinLockScreen> {
  final pinCtrl = TextEditingController();
  String? error;
  bool checking = false;
  bool biometricAvailable = false;

  @override
  void initState() {
    super.initState();
    _checkBiometric();
  }

  Future<void> _checkBiometric() async {
    final useBio = await Store.loadUseBiometric();
    if (!useBio) return;
    final auth = LocalAuthentication();
    try {
      final canCheck = await auth.canCheckBiometrics;
      final isSupported = await auth.isDeviceSupported();
      if (!mounted) return;
      if (canCheck && isSupported) {
        setState(() => biometricAvailable = true);
        _tryBiometric();
      }
    } catch (_) {
      // biometric hardware unavailable/unqueryable - fall back to PIN only
    }
  }

  Future<void> _tryBiometric() async {
    final auth = LocalAuthentication();
    try {
      final ok = await auth.authenticate(
        localizedReason: 'برای باز کردن برنامه هویت خود را تأیید کنید',
        options: const AuthenticationOptions(biometricOnly: false, stickyAuth: true),
      );
      if (ok) widget.onUnlocked();
    } catch (_) {
      // user cancelled or biometric failed - they can still use the PIN field
    }
  }

  Future<void> _submitPin() async {
    setState(() => checking = true);
    final ok = await Store.verifyPin(pinCtrl.text);
    if (!mounted) return;
    setState(() => checking = false);
    if (ok) {
      widget.onUnlocked();
    } else {
      setState(() => error = 'رمز اشتباه است');
      pinCtrl.clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_outline, size: 64),
                const SizedBox(height: 16),
                Text('برنامه قفل است', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 24),
                TextField(
                  controller: pinCtrl,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 8,
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(labelText: 'رمز عبور', errorText: error, border: const OutlineInputBorder()),
                  onSubmitted: (_) => _submitPin(),
                ),
                const SizedBox(height: 12),
                FilledButton(onPressed: checking ? null : _submitPin, child: const Text('باز کردن')),
                if (biometricAvailable) ...[
                  const SizedBox(height: 12),
                  TextButton.icon(onPressed: _tryBiometric, icon: const Icon(Icons.fingerprint), label: const Text('استفاده از اثرانگشت')),
                ],
              ],
            ),
          ),
        ),
      ),
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
    Widget sectionLabel(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(text, style: TextStyle(fontSize: 12, color: Colors.grey.shade600, fontWeight: FontWeight.w600)),
        );
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            const DrawerHeader(
              child: Align(
                alignment: Alignment.centerRight,
                child: Text('مدیریت مالی شخصی', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              ),
            ),
            item(0, Icons.home_outlined, tr('home'), () => const HomeScreen()),
            const Divider(height: 1),
            sectionLabel('دسته‌بندی‌ها و حساب‌ها'),
            item(1, Icons.category_outlined, tr('category_management'), () => const CategoryManagementScreen()),
            item(2, Icons.account_balance_wallet_outlined, tr('accounts'), () => const AccountManagementScreen()),
            item(13, Icons.swap_horiz, 'انتقال بین حساب‌ها', () => const TransferScreen()),
            item(14, Icons.flag_outlined, 'اهداف هزینه', () => const BudgetGoalsScreen()),
            item(15, Icons.savings_outlined, 'اهداف پس‌انداز', () => const SavingsGoalsScreen()),
            const Divider(height: 1),
            sectionLabel('تراکنش‌ها'),
            item(12, Icons.list_alt, 'همه‌ی تراکنش‌ها', () => const AllTransactionsScreen()),
            item(5, Icons.category_outlined, tr('affected_by_category_delete'), () => const AffectedTransactionsScreen()),
            const Divider(height: 1),
            sectionLabel('داده'),
            item(8, Icons.upcoming_outlined, 'پرداخت‌های پیش‌رو', () => const UpcomingPaymentsScreen()),
            item(6, Icons.backup_outlined, 'پشتیبان‌گیری و بازیابی', () => const BackupRestoreScreen()),
            item(7, Icons.bar_chart_outlined, 'گزارش‌گیری کامل', () => const ReportsScreen()),
            item(9, Icons.trending_up, 'پیش‌بینی هزینه', () => const ForecastScreen()),
            item(10, Icons.calendar_month_outlined, 'خلاصه ماه در یک نگاه', () => const MonthCalendarScreen()),
            item(11, Icons.search, 'جستجوی کالا', () => const ItemSearchScreen()),
            const Divider(height: 1),
            item(3, Icons.settings_outlined, tr('settings'), () => const SettingsScreen()),
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
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('settings'))),
      drawer: const AppDrawer(currentIndex: 3),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.language_outlined),
            title: Text(tr('app_language')),
            subtitle: ValueListenableBuilder<AppLanguage>(
              valueListenable: currentLanguage,
              builder: (context, lang, _) => Text(lang.label),
            ),
            trailing: const Icon(Icons.chevron_left),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const LanguageSettingsScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.dark_mode_outlined),
            title: const Text('ظاهر برنامه'),
            subtitle: ValueListenableBuilder<ThemeMode>(
              valueListenable: currentThemeMode,
              builder: (context, mode, _) => Text(switch (mode) {
                ThemeMode.system => 'پیش‌فرض سیستم',
                ThemeMode.light => 'روشن',
                ThemeMode.dark => 'تیره',
              }),
            ),
            trailing: const Icon(Icons.chevron_left),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AppearanceSettingsScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.calendar_month_outlined),
            title: const Text('تقویم'),
            subtitle: ValueListenableBuilder<CalendarSystem>(
              valueListenable: currentCalendarSystem,
              builder: (context, system, _) => Text(system == CalendarSystem.jalali ? 'هجری شمسی' : 'میلادی'),
            ),
            trailing: const Icon(Icons.chevron_left),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CalendarSettingsScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.auto_awesome_outlined),
            title: const Text('هوش مصنوعی (Gemini)'),
            subtitle: const Text('کلید API برای بهبود خواندن رسید و فیش حقوقی'),
            trailing: const Icon(Icons.chevron_left),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const GeminiSettingsScreen())),
          ),
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: const Text('قفل برنامه'),
            subtitle: const Text('رمز عبور و اثرانگشت/چهره'),
            trailing: const Icon(Icons.chevron_left),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AppLockSettingsScreen())),
          ),
        ],
      ),
    );
  }
}

class LanguageSettingsScreen extends StatelessWidget {
  const LanguageSettingsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('app_language'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ValueListenableBuilder<AppLanguage>(
            valueListenable: currentLanguage,
            builder: (context, lang, _) => DropdownButtonFormField<AppLanguage>(
              initialValue: lang,
              decoration: const InputDecoration(border: OutlineInputBorder()),
              items: AppLanguage.values.map((l) => DropdownMenuItem(value: l, child: Text(l.label))).toList(),
              onChanged: (v) async {
                if (v == null) return;
                currentLanguage.value = v;
                await Store.saveLanguage(v);
              },
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'ترجمه در حال تکمیل است؛ فعلاً بخش‌های اصلی برنامه ترجمه شده‌اند.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class AppearanceSettingsScreen extends StatelessWidget {
  const AppearanceSettingsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ظاهر برنامه')),
      body: ValueListenableBuilder<ThemeMode>(
        valueListenable: currentThemeMode,
        builder: (context, mode, _) => RadioGroup<ThemeMode>(
          groupValue: mode,
          onChanged: (v) async {
            if (v == null) return;
            currentThemeMode.value = v;
            await Store.saveThemeMode(v);
          },
          child: ListView(
            children: const [
              RadioListTile<ThemeMode>(
                title: Text('پیش‌فرض سیستم'),
                subtitle: Text('تنظیم روشن/تیره‌ی گوشی را دنبال کند'),
                value: ThemeMode.system,
              ),
              RadioListTile<ThemeMode>(
                title: Text('روشن'),
                value: ThemeMode.light,
              ),
              RadioListTile<ThemeMode>(
                title: Text('تیره'),
                value: ThemeMode.dark,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class CalendarSettingsScreen extends StatelessWidget {
  const CalendarSettingsScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('تقویم')),
      body: ValueListenableBuilder<CalendarSystem>(
        valueListenable: currentCalendarSystem,
        builder: (context, system, _) => RadioGroup<CalendarSystem>(
          groupValue: system,
          onChanged: (v) async {
            if (v == null) return;
            currentCalendarSystem.value = v;
            await Store.saveCalendarSystem(v);
          },
          child: ListView(
            children: const [
              RadioListTile<CalendarSystem>(
                title: Text('هجری شمسی'),
                subtitle: Text('مثلاً ۰۱.۰۷.۱۴۰۵'),
                value: CalendarSystem.jalali,
              ),
              RadioListTile<CalendarSystem>(
                title: Text('میلادی'),
                subtitle: Text('مثلاً 23.09.2026'),
                value: CalendarSystem.gregorian,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class GeminiSettingsScreen extends StatefulWidget {
  const GeminiSettingsScreen({super.key});
  @override
  State<GeminiSettingsScreen> createState() => _GeminiSettingsScreenState();
}

class _GeminiSettingsScreenState extends State<GeminiSettingsScreen> {
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
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('ذخیره شد.')));
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(title: const Text('هوش مصنوعی (Gemini)')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('کلید Gemini API', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text(
            'برای بهبود خواندن رسید و فیش حقوقی با هوش مصنوعی (اختیاری). اگر خالی بگذارید، فقط از تشخیص متن آفلاین استفاده می‌شود.',
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
          FilledButton(onPressed: _save, child: Text(tr('save'))),
        ],
      ),
    );
  }
}

class AppLockSettingsScreen extends StatefulWidget {
  const AppLockSettingsScreen({super.key});
  @override
  State<AppLockSettingsScreen> createState() => _AppLockSettingsScreenState();
}

class _AppLockSettingsScreenState extends State<AppLockSettingsScreen> {
  bool loading = true;
  bool lockEnabled = false;
  bool useBiometric = false;
  bool hasPin = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    lockEnabled = await Store.loadAppLockEnabled();
    useBiometric = await Store.loadUseBiometric();
    hasPin = await Store.hasPinSet();
    setState(() => loading = false);
  }

  Future<void> _promptSetPin({required bool enableLockAfter}) async {
    final ctrl1 = TextEditingController();
    final ctrl2 = TextEditingController();
    String? err;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            title: const Text('تنظیم رمز عبور'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: ctrl1,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 8,
                  decoration: const InputDecoration(labelText: 'رمز جدید (۴ تا ۸ رقم)'),
                ),
                TextField(
                  controller: ctrl2,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  maxLength: 8,
                  decoration: const InputDecoration(labelText: 'تکرار رمز'),
                ),
                if (err != null) Text(err!, style: const TextStyle(color: Colors.red)),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
              FilledButton(
                onPressed: () {
                  if (ctrl1.text.length < 4) {
                    setDialogState(() => err = 'رمز باید حداقل ۴ رقم باشد.');
                    return;
                  }
                  if (ctrl1.text != ctrl2.text) {
                    setDialogState(() => err = 'دو رمز یکسان نیستند.');
                    return;
                  }
                  Navigator.pop(ctx, true);
                },
                child: Text(tr('save')),
              ),
            ],
          );
        },
      ),
    );
    if (result != true) return;
    await Store.savePin(ctrl1.text);
    hasPin = true;
    if (enableLockAfter) {
      await Store.saveAppLockEnabled(true);
      lockEnabled = true;
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(title: Text(tr('app_lock_title'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('فعال بودن قفل'),
            subtitle: const Text('هنگام باز کردن برنامه رمز یا اثرانگشت بپرسد'),
            value: lockEnabled,
            onChanged: (v) async {
              if (v && !hasPin) {
                await _promptSetPin(enableLockAfter: true);
                return;
              }
              await Store.saveAppLockEnabled(v);
              setState(() => lockEnabled = v);
            },
          ),
          if (lockEnabled) ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('استفاده از اثرانگشت/چهره'),
              subtitle: const Text('در صورت پشتیبانی گوشی، به‌جای رمز از بیومتریک استفاده شود'),
              value: useBiometric,
              onChanged: (v) async {
                await Store.saveUseBiometric(v);
                setState(() => useBiometric = v);
              },
            ),
            TextButton(
              onPressed: () => _promptSetPin(enableLockAfter: false),
              child: const Text('تغییر رمز عبور'),
            ),
          ],
        ],
      ),
    );
  }
}

// ============================== OCR service ==============================

/// Renders the first page of a PDF at [path] to a temporary JPEG image and
/// returns the image file path. Only the first page is processed for now.
/// Copies a scanned receipt/payslip image (which otherwise lives in a
/// temp directory the OS can clear at any time) into permanent app
/// storage, so a saved draft can still show/re-run AI on its image later.
Future<String> persistDraftImage(String tempPath, String txId) async {
  final dir = await getApplicationDocumentsDirectory();
  final draftsDir = Directory('${dir.path}/draft_receipts');
  if (!await draftsDir.exists()) await draftsDir.create(recursive: true);
  final ext = tempPath.split('.').last;
  final destPath = '${draftsDir.path}/$txId.$ext';
  await File(tempPath).copy(destPath);
  return destPath;
}

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

const _totalKeywords = ['zu zahlen', 'endbetrag', 'gesamtbetrag', 'betrag', 'total', 'summe', 'gesamt', 'جمع', 'مبلغ کل'];

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
  'solidaritaetszuschlag': ['solidaritätszuschlag', 'soli'],
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

/// Carries both a short Persian message for the UI and the full raw
/// technical detail (HTTP status, response body, or network error) so the
/// user can view/copy the real underlying error when troubleshooting.
class GeminiException implements Exception {
  final String friendlyMessage;
  final String rawDetail;
  GeminiException(this.friendlyMessage, this.rawDetail);
  @override
  String toString() => friendlyMessage;
}

// Gemini model names/aliases change fairly often as Google retires older
// models; try the primary one first and fall back to an alternative if it
// 404s (model retired/renamed) rather than failing outright.
// Lite variants have a much more generous free-tier daily quota (roughly
// 1000+ requests/day) than the full Flash models (as low as ~20/day for
// some newer ones), so try those first to avoid hitting quota limits.
const _geminiModels = ['gemini-2.5-flash-lite', 'gemini-2.0-flash-lite', 'gemini-2.5-flash', 'gemini-3.5-flash'];

Future<Map<String, dynamic>?> _geminiRequest(String apiKey, String imagePath, String prompt) async {
  final bytes = await File(imagePath).readAsBytes();
  final b64 = base64Encode(bytes);
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

  http.Response? resp;
  Object? lastNetworkError;
  final attemptedModels = <String>[];
  for (final model in _geminiModels) {
    attemptedModels.add(model);
    final uri = Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey');
    // Gemini occasionally returns a transient 503 "model overloaded" error;
    // retry a couple of times with a short backoff before giving up on this
    // model and moving to the next one in the fallback list.
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        resp = await http
            .post(uri, headers: {'Content-Type': 'application/json'}, body: body)
            .timeout(const Duration(seconds: 45));
        lastNetworkError = null;
      } catch (e) {
        lastNetworkError = e;
        resp = null;
        if (attempt == 2) break;
        await Future.delayed(Duration(seconds: 2 * (attempt + 1)));
        continue;
      }
      if (resp.statusCode == 200) break;
      if ((resp.statusCode == 503 || resp.statusCode == 429) && attempt < 2) {
        await Future.delayed(Duration(seconds: 2 * (attempt + 1)));
        continue;
      }
      break;
    }
    if (resp != null && resp.statusCode == 200) break;
    // 404 (model retired/renamed) or 429 (this model's own quota exhausted,
    // a different model may still have quota) - try the next fallback.
    if (resp != null && resp.statusCode != 404 && resp.statusCode != 429) break;
  }
  if (resp == null || resp.statusCode != 200) {
    final code = resp?.statusCode;
    final raw = resp != null
        ? 'مدل‌های امتحان‌شده: ${attemptedModels.join(', ')}\nHTTP ${resp.statusCode}\n${resp.body}'
        : 'مدل‌های امتحان‌شده: ${attemptedModels.join(', ')}\nخطای شبکه: $lastNetworkError';
    if (code == 503) {
      throw GeminiException('سرورهای Gemini موقتاً شلوغ هستند. لطفاً چند لحظه دیگر دوباره امتحان کنید.', raw);
    }
    if (code == 429) {
      throw GeminiException('سهمیه‌ی رایگان روزانه‌ی Gemini برای امروز تمام شده. فردا دوباره امتحان کنید.', raw);
    }
    throw GeminiException('خطای Gemini API (${code ?? '—'})', raw);
  }
  final rawBody = utf8.decode(resp.bodyBytes);
  final decoded = jsonDecode(rawBody);
  final candidates = decoded['candidates'];
  if (candidates == null || candidates is! List || candidates.isEmpty) {
    final blockReason = decoded['promptFeedback']?['blockReason'];
    if (blockReason != null) {
      throw GeminiException('Gemini این تصویر را پردازش نکرد (دلیل: $blockReason).', rawBody);
    }
    throw GeminiException('پاسخ نامعتبر از Gemini دریافت شد (بدون نتیجه).', rawBody);
  }
  final finishReason = candidates[0]?['finishReason'];
  var text = candidates[0]?['content']?['parts']?[0]?['text'] as String?;
  if (text == null) {
    throw GeminiException('پاسخ Gemini قابل خواندن نبود${finishReason != null ? ' (finishReason: $finishReason)' : ''}.', rawBody);
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
    throw GeminiException('پاسخ Gemini به‌صورت JSON معتبر نبود.', text);
  }
}

const _receiptPrompt = 'You are an expert receipt-reading assistant. Read the attached receipt image '
    'and extract structured data. Respond ONLY with compact JSON, no markdown, no explanation, in '
    'exactly this shape: {"merchant": string or null, "date": "YYYY-MM-DD" or null, "total": number or '
    'null, "items": [{"name": string, "quantity": number or null, "price": number or null, "isPhysicalGood": '
    'boolean, "warrantyUntil": "YYYY-MM-DD" or null, "returnUntil": "YYYY-MM-DD" or null, "warrantyNote": '
    'string or null}], "category": string or null, "keepReceipt": boolean, "keepReceiptReason": string}. '
    'For "items", expand any abbreviated, truncated, or SKU-coded product names printed on the receipt '
    'into their full, clear, human-readable product name (in the same language as the receipt) - never '
    'leave a short code or cut-off abbreviation as the name if you can reasonably infer the full name '
    'from context and common branded products. "quantity" is the number of units purchased (default 1 '
    'if not shown separately). "isPhysicalGood" is true for a durable physical item that could plausibly '
    'have a warranty or be returned/exchanged later (appliances, electronics, tools, furniture, '
    'cookware/dishware, clothing, shoes, toys, etc.) and false for consumables (food, drinks, groceries, '
    'toiletries, and similar). For an item where "isPhysicalGood" is true, if the receipt itself prints '
    'a warranty period or a return/exchange window (e.g. "14 Tage Rückgaberecht", "2 Jahre Garantie", '
    '"return within 30 days"), compute "warrantyUntil" and/or "returnUntil" as absolute dates (receipt '
    "date plus that period) and put the printed terms verbatim (in the receipt's language) into "
    '"warrantyNote". If the receipt states a general store-wide policy that applies to all physical '
    'items, apply it to each qualifying item. If nothing about warranty/returns is printed anywhere on '
    'the receipt, leave "warrantyUntil", "returnUntil" and "warrantyNote" all null - do not guess a '
    'period that is not actually printed on the receipt. "category" is a short one- or two-word general '
    'shopping category for this receipt (e.g. "خوراک", "پوشاک", "دارو") in the receipt\'s language. '
    '"keepReceipt" is true if any item has warranty/return relevance (isPhysicalGood true, or actual '
    'warranty/return terms found) - in that case physical receipts often matter as proof of purchase - '
    'and false if every item is a consumable with no such relevance. "keepReceiptReason" is one short '
    "sentence in the receipt's language explaining why (or why not) to keep the physical receipt. Keep "
    'merchant name in the receipt\'s own language/script. Numbers must be plain (no currency symbols). '
    'If a field is unreadable, use null.';

const _payslipPrompt = 'You are an expert German payslip (Lohnabrechnung) reading assistant. Read the '
    'attached payslip image and extract structured data. Respond ONLY with compact JSON, no markdown, '
    'no explanation, in exactly this shape: {"brutto": number or null, "netto": number or null, '
    '"depositedAmount": number or null, "lohnsteuer": number or null, "solidaritaetszuschlag": number or null, '
    '"kirchensteuer": number or null, "krankenversicherung": number or null, "pflegeversicherung": number or '
    'null, "rentenversicherung": number or null, "arbeitslosenversicherung": number or null, '
    '"vermoegenswirksameLeistungen": number or null, "betrieblicheAltersvorsorge": number or null, '
    '"vorschuss": number or null, "sonstigeAbzuege": number or null, "steuerklasse": '
    'string or null, "arbeitgeber": string or null, "abrechnungsmonat": string or null, "date": '
    '"YYYY-MM-DD" or null}. "depositedAmount" is the actual amount transferred/paid out to the bank '
    'account (Auszahlungsbetrag) if shown separately from "netto" (they can differ due to advances or '
    'other payroll deductions). "vermoegenswirksameLeistungen" is VL/capital-formation benefits, '
    '"betrieblicheAltersvorsorge" is employer-sponsored supplementary pension deductions, "vorschuss" is '
    'any advance payment deducted, "sonstigeAbzuege" is any other deduction not covered by the other '
    'fields. "date" is the actual payment/value date (Auszahlungsdatum or Valuta date) '
    'printed on the payslip - not just the month name. Numbers must be plain (no currency symbols). If '
    'a field is unreadable, use null.';

Future<Map<String, dynamic>?> geminiExtractReceipt(String apiKey, String imagePath) =>
    _geminiRequest(apiKey, imagePath, _receiptPrompt);

Future<Map<String, dynamic>?> geminiExtractPayslip(String apiKey, String imagePath) =>
    _geminiRequest(apiKey, imagePath, _payslipPrompt);

// ============================== Money formatting ==============================

String formatMoney(double amount, String currency) {
  final n = persianDigits(amount.toStringAsFixed(2));
  switch (currency) {
    case 'EUR':
      return ltr('€$n');
    case 'USD':
      return ltr('\$$n');
    case 'GBP':
      return ltr('£$n');
    case 'CHF':
      return ltr('$n CHF');
    case 'TRY':
      return ltr('₺$n');
    case 'AED':
      return '${ltr(n)} د.إ';
    case 'IRR':
      return '${ltr(n)} ریال';
    default:
      return ltr('$n $currency');
  }
}

/// The main, memorable title for a transaction list row: the item name if
/// there's exactly one, "first item + N more" if there are several, the
/// transaction's own note if there are no items but a note was entered,
/// and the category name as a last resort so the line is never blank.
String txMainTitle(Transaction t, String categoryName) {
  if (t.items.length == 1) return t.items.first.name;
  if (t.items.length > 1) return '${t.items.first.name} +${t.items.length - 1} قلم دیگر';
  if (t.note.trim().isNotEmpty) return t.note.trim();
  return categoryName;
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
  String? dashboardAccountFilter;

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
    // Best-effort background retry for categories that only got a generic
    // icon last time (e.g. Gemini was unavailable); does nothing if none
    // are pending.
    unawaited(retryPendingCategoryIcons());
    unawaited(checkBudgetGoals());
  }

  String categoryName(String id) {
    final c = categories.where((c) => c.id == id).toList();
    return c.isEmpty ? 'بدون‌دسته' : c.first.name;
  }

  String currencyOf(String accountId) {
    final a = accounts.where((a) => a.id == accountId).toList();
    return a.isEmpty ? 'EUR' : a.first.currency;
  }

  int get draftCount => tx.where((t) => t.draft).length;

  Map<String, double> get totalBalanceByCurrency {
    final map = <String, double>{};
    for (final a in accounts) {
      if (a.initialBalance != 0) {
        map[a.currency] = (map[a.currency] ?? 0) + a.initialBalance;
      }
    }
    for (final t in tx) {
      final cur = currencyOf(t.accountId);
      map[cur] = (map[cur] ?? 0) + (t.type == TxType.income ? t.amount : -t.amount);
    }
    return map;
  }

  Map<String, Map<String, double>> get periodStatsByCurrency {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final map = <String, Map<String, double>>{};
    for (final t in tx) {
      // Not-yet-due (future-dated) transactions shouldn't count toward the
      // period's totals until their own date actually arrives.
      if (t.date.isAfter(today)) continue;
      if (!(t.date.year == now.year && t.date.month == now.month)) continue;
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

  String get primaryCurrency {
    if (dashboardAccountFilter != null) return currencyOf(dashboardAccountFilter!);
    if (accounts.isEmpty) return 'EUR';
    final counts = <String, int>{};
    for (final a in accounts) {
      counts[a.currency] = (counts[a.currency] ?? 0) + 1;
    }
    return (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
  }

  /// Top-level category (parent rolled up) expense totals for the current
  /// period (same period as [periodStatsByCurrency]), in [primaryCurrency].
  /// Expense transactions for the current period, in [primaryCurrency] -
  /// aggregation (including drill-down by category) happens inside
  /// [DashboardCharts] itself.
  List<Transaction> get expenseTransactionsForPeriod {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return tx.where((t) {
      if (t.type != TxType.expense) return false;
      if (dashboardAccountFilter != null ? t.accountId != dashboardAccountFilter : currencyOf(t.accountId) != primaryCurrency) return false;
      if (t.date.isAfter(today)) return false;
      return t.date.year == now.year && t.date.month == now.month;
    }).toList();
  }

  /// Income and expense totals (in [primaryCurrency]) for each of the last
  /// [months] calendar months, oldest first.
  List<({DateTime month, double income, double expense})> monthlyTotals(int months) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
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
        if (dashboardAccountFilter != null ? t.accountId != dashboardAccountFilter : currencyOf(t.accountId) != primaryCurrency) continue;
        if (t.date.isAfter(today)) continue;
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
      await Store.deleteTransaction(result.id);
    } else if (result is Transaction) {
      await Store.upsertTransaction(result);
    } else {
      return;
    }
    // Always reload from storage after a write, rather than trusting this
    // screen's own (possibly stale) in-memory list - upsertTransaction /
    // deleteTransaction already operate on the freshest persisted data, so
    // this keeps the UI in sync with what was actually saved.
    tx = await Store.loadTransactions();
    tx.sort((a, b) => b.date.compareTo(a.date));
    if (mounted) setState(() {});
  }

  Future<void> _openDrafts() async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const DraftsScreen()));
    await _load();
  }

  Future<void> _delete(Transaction t) async {
    await NotificationService.instance.cancelForTransaction(t.id);
    await Store.deleteTransaction(t.id);
    tx = await Store.loadTransactions();
    tx.sort((a, b) => b.date.compareTo(a.date));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final balances = totalBalanceByCurrency;
    final period = periodStatsByCurrency;
    const periodLabel = 'این ماه';
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final exit = await confirmExitApp(context);
        if (exit) SystemNavigator.pop();
      },
      child: Scaffold(
      appBar: AppBar(
        title: Text(tr('app_title')),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'جستجوی کالا (گارانتی/مرجوعی)',
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ItemSearchScreen())),
          ),
          Badge(
            label: Text('$draftCount'),
            isLabelVisible: draftCount > 0,
            child: IconButton(icon: const Icon(Icons.drafts_outlined), tooltip: 'پیش‌نویس‌ها', onPressed: _openDrafts),
          ),
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
                        Text('موجودی کل', style: Theme.of(context).textTheme.titleMedium),
                        if (draftCount > 0)
                          Chip(
                            label: Text('$draftCount پیش‌نویس'),
                            backgroundColor: Colors.amber.shade100,
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (balances.isEmpty) const Text('هنوز تراکنشی ثبت نشده.'),
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
                    if (period.isEmpty) const Text('در این دوره تراکنشی ثبت نشده.'),
                    ...period.entries.map((e) => Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              _MonthStat(label: 'درآمد', value: e.value['income']!, currency: e.key, color: Colors.green),
                              _MonthStat(label: 'هزینه', value: e.value['expense']!, currency: e.key, color: Colors.red),
                            ],
                          ),
                        )),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (tx.isNotEmpty) ...[
              if (accounts.length > 1)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: DropdownButtonFormField<String?>(
                    initialValue: dashboardAccountFilter,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'حساب', border: OutlineInputBorder(), isDense: true),
                    items: [
                      DropdownMenuItem(value: null, child: Text(tr('all_accounts'))),
                      ...accounts.map((a) => DropdownMenuItem(value: a.id, child: Text('${a.name} (${a.currency})'))),
                    ],
                    onChanged: (v) => setState(() => dashboardAccountFilter = v),
                  ),
                ),
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
            ],
            const SizedBox(height: 16),
            Text(tr('transactions'), style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            if (tx.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: Text('هنوز تراکنشی ثبت نشده. با دکمه + شروع کنید.')),
              )
            else ...[
              () {
                final today = DateTime.now();
                final todayMidnight = DateTime(today.year, today.month, today.day);
                final pastOrDue = tx.where((t) => !t.date.isAfter(todayMidnight)).toList();
                var nextMonthNum = today.month + 1;
                var nextMonthYear = today.year;
                if (nextMonthNum > 12) {
                  nextMonthNum = 1;
                  nextMonthYear++;
                }
                final endOfNextMonth = DateTime(nextMonthYear, nextMonthNum + 1, 0);
                // Not-yet-due entries through the end of next calendar month
                // (covers the rest of this month plus all of next month,
                // but no further): real future-dated transactions, plus
                // projected occurrences of recurring transactions.
                final future = occurrencesWithRecurringProjections(tx, horizonDays: 60)
                    .where((e) => e.date.isAfter(todayMidnight) && !e.date.isAfter(endOfNextMonth))
                    .toList()
                  ..sort((a, b) => a.date.compareTo(b.date));

                // Group already-due transactions by month, most recent first
                // (tx is already sorted by date descending), keeping only
                // the last 2 months that actually have transactions.
                final monthKeys = <String>[];
                final grouped = <String, List<Transaction>>{};
                for (final t in pastOrDue) {
                  final key = '${t.date.year}-${t.date.month}';
                  if (!grouped.containsKey(key)) {
                    monthKeys.add(key);
                    grouped[key] = [];
                  }
                  grouped[key]!.add(t);
                }
                final limitedKeys = monthKeys.take(2).toList();

                return Column(
                  children: [
                    if (future.isNotEmpty)
                      Theme(
                        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                        child: ExpansionTile(
                          initiallyExpanded: false,
                          tilePadding: EdgeInsets.zero,
                          title: Text(
                            '${_gregorianMonthNames[nextMonthNum - 1]} $nextMonthYear (${future.length})',
                            style: TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.w500),
                          ),
                          children: future
                              .map((e) => _buildTxTile(e.t, dimmed: true, projected: !e.isReal, displayDate: e.date))
                              .toList(),
                        ),
                      ),
                    ...limitedKeys.map((key) {
                      final parts = key.split('-');
                      final y = int.parse(parts[0]);
                      final m = int.parse(parts[1]);
                      final monthTx = grouped[key]!;
                      return Theme(
                        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                        child: ExpansionTile(
                          initiallyExpanded: true,
                          tilePadding: EdgeInsets.zero,
                          title: Text('${_gregorianMonthNames[m - 1]} $y', style: Theme.of(context).textTheme.titleMedium),
                          children: monthTx.map((t) => _buildTxTile(t)).toList(),
                        ),
                      );
                    }),
                  ],
                );
              }(),
            ],
            const SizedBox(height: 80),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(),
        icon: const Icon(Icons.add),
        label: Text(tr('new_transaction')),
      ),
    ),
    );
  }

  Widget _buildTxTile(Transaction t, {bool dimmed = false, bool projected = false, DateTime? displayDate}) {
    final opacity = dimmed ? 0.55 : 1.0;
    final tile = Card(
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
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${categoryName(t.categoryId)} • ${formatDate(displayDate ?? t.date)}'
              '${projected ? ' • سررسیدنشده' : (t.isRecurring ? ' • تکرارشونده' : '')}'
              '${t.draft ? ' • پیش‌نویس' : ''}',
              style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 1),
            Text(
              txMainTitle(t, categoryName(t.categoryId)),
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
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
    );
    if (projected) {
      // A projected occurrence isn't its own stored transaction, so it
      // can't be edited/deleted directly - tapping opens the underlying
      // recurring transaction instead, and swipe actions are disabled.
      return Opacity(opacity: opacity, child: tile);
    }
    return Opacity(
      opacity: opacity,
      child: Dismissible(
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
                  title: const Text('حذف تراکنش'),
                  content: const Text('این تراکنش حذف شود؟'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
                    FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('delete'))),
                  ],
                ),
              ) ??
              false;
        },
        onDismissed: (_) => _delete(t),
        child: tile,
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
      result[match.isEmpty ? Category(id: id, name: 'بدون‌دسته', type: TxType.expense) : match.first] = amount;
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
                'هزینه‌ی این ماه ${ltr('${change.abs().round()}%')} ${up ? 'بیشتر' : 'کمتر'} از ماه قبل',
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
                  tooltip: 'بازگشت',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: () => setState(() => drilldown = null),
                ),
              if (drilldown != null) const SizedBox(width: 8),
              Expanded(
                child: Text(
                  drilldown == null ? 'هزینه‌ها بر اساس دسته‌بندی' : 'زیرمجموعه‌های «${drilldown!.name}»',
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
                          _legendRow(Colors.grey, const Category(id: '_other_', name: 'سایر', type: TxType.expense), otherSum),
                      ],
                    ),
                  ),
                ],
              ),
            )
          else
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text('هزینه‌ای در این دوره برای این دسته‌بندی ثبت نشده.', style: TextStyle(color: Colors.grey)),
            ),
          const SizedBox(height: 24),
        ],
        Text('روند ۶ ماه اخیر', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SizedBox(
          height: 190,
          child: maxMonthly <= 0
              ? const Center(child: Text('داده‌ای برای نمایش وجود ندارد.', style: TextStyle(color: Colors.grey)))
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
                              child: Text(ltr(persianDigits(DateFormat('MM/yy').format(monthly[i].month))), style: const TextStyle(fontSize: 10)),
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
            const Text('درآمد', style: TextStyle(fontSize: 12)),
            const SizedBox(width: 16),
            _dot(Colors.red),
            const SizedBox(width: 4),
            const Text('هزینه', style: TextStyle(fontSize: 12)),
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
    return c.isEmpty ? 'بدون‌دسته' : c.first.name;
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
    if (result is DeleteTransactionSignal) {
      await Store.deleteTransaction(result.id);
    } else if (result is Transaction) {
      await Store.upsertTransaction(result);
    }
    await _load();
  }

  Future<void> _delete(Transaction t) async {
    await NotificationService.instance.cancelForTransaction(t.id);
    await Store.deleteTransaction(t.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(title: Text(tr('drafts'))),
      body: tx.isEmpty
          ? const Center(child: Text('پیش‌نویسی وجود ندارد.'))
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
                        title: const Text('حذف پیش‌نویس'),
                        content: const Text('این پیش‌نویس حذف شود؟'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
                          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('delete'))),
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
                        subtitle: Text(formatDate(t.date)),
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
    return c.isEmpty ? 'بدون‌دسته' : c.first.name;
  }

  String currencyOf(String accountId) {
    final a = accounts.where((a) => a.id == accountId).toList();
    return a.isEmpty ? 'EUR' : a.first.currency;
  }

  String _recurrenceLabel(Transaction t) {
    switch (t.recurrence) {
      case RecurrenceFrequency.monthly:
        return 'ماهانه (روز ${t.recurrenceDay ?? '?'})';
      case RecurrenceFrequency.weekly:
        return 'هفتگی (${_weekdayNames[(t.recurrenceWeekday ?? 1) - 1]})';
      case RecurrenceFrequency.custom:
        return 'هر ${t.recurrenceIntervalDays ?? '?'} روز';
      case RecurrenceFrequency.quarterly:
        return 'فصلی (روز ${t.recurrenceDay ?? '?'})';
      case RecurrenceFrequency.yearly:
        return 'سالانه (${ltr(persianDigits(DateFormat('dd.MM').format(t.date)))})';
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
    final newCategories = await Store.loadCategories();
    if (result is DeleteTransactionSignal) {
      await Store.deleteTransaction(result.id);
    } else if (result is Transaction) {
      await Store.upsertTransaction(result);
    }
    categories = newCategories;
    await _load();
  }

  Future<void> _delete(Transaction t) async {
    await NotificationService.instance.cancelForTransaction(t.id);
    await Store.deleteTransaction(t.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(title: Text(tr('recurring_transactions'))),
      body: tx.isEmpty
          ? const Center(child: Text('تراکنش تکرارشونده‌ای وجود ندارد.'))
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
                      title: const Text('حذف تراکنش تکرارشونده'),
                      content: const Text('این تراکنش تکرارشونده حذف شود؟'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
                        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('delete'))),
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
                        '${next != null ? ' • سررسید بعدی: ${formatDate(next)}' : ''}',
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

// ============================== Upcoming payments ==============================

class UpcomingPaymentsScreen extends StatefulWidget {
  const UpcomingPaymentsScreen({super.key});
  @override
  State<UpcomingPaymentsScreen> createState() => _UpcomingPaymentsScreenState();
}

enum _UpcomingRange { endOfThisMonth, nextMonth, custom }

class _UpcomingPaymentsScreenState extends State<UpcomingPaymentsScreen> {
  bool loading = true;
  List<Transaction> tx = [];
  List<Category> categories = [];
  List<Account> accounts = [];
  _UpcomingRange range = _UpcomingRange.endOfThisMonth;
  DateTime customMonth = DateTime(DateTime.now().year, DateTime.now().month, 1);
  bool showChart = false;
  String? accountFilter;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    tx = await Store.loadTransactions();
    categories = await Store.loadCategories();
    accounts = await Store.loadAccounts();
    setState(() => loading = false);
  }

  String categoryName(String id) {
    final m = categories.where((c) => c.id == id).toList();
    return m.isEmpty ? 'بدون‌دسته' : m.first.name;
  }

  String currencyOf(String accountId) {
    final m = accounts.where((a) => a.id == accountId).toList();
    return m.isEmpty ? 'EUR' : m.first.currency;
  }

  String get primaryCurrency {
    if (accountFilter != null) return currencyOf(accountFilter!);
    if (accounts.isEmpty) return 'EUR';
    final counts = <String, int>{};
    for (final a in accounts) {
      counts[a.currency] = (counts[a.currency] ?? 0) + 1;
    }
    return (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
  }

  Future<void> _pickCustomMonth() async {
    var y = customMonth.year;
    var m = customMonth.month;
    final picked = await showDialog<DateTime>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('انتخاب ماه'),
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Expanded(
                child: DropdownButtonFormField<int>(
                  initialValue: m,
                  decoration: const InputDecoration(labelText: 'ماه'),
                  items: List.generate(12, (i) => i + 1).map((mo) => DropdownMenuItem(value: mo, child: Text(_gregorianMonthNames[mo - 1]))).toList(),
                  onChanged: (v) => setLocal(() => m = v ?? m),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<int>(
                  initialValue: y,
                  decoration: const InputDecoration(labelText: 'سال'),
                  items: List.generate(4, (i) => DateTime.now().year + i)
                      .map((yr) => DropdownMenuItem(value: yr, child: Text(ltr('$yr'))))
                      .toList(),
                  onChanged: (v) => setLocal(() => y = v ?? y),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, DateTime(y, m, 1)), child: Text(tr('confirm'))),
          ],
        ),
      ),
    );
    if (picked == null) return;
    setState(() {
      customMonth = picked;
      range = _UpcomingRange.custom;
    });
  }

  DateTimeRange _rangeFor(_UpcomingRange r, DateTime today) {
    switch (r) {
      case _UpcomingRange.endOfThisMonth:
        return DateTimeRange(start: today, end: DateTime(today.year, today.month + 1, 0));
      case _UpcomingRange.nextMonth:
        final start = DateTime(today.year, today.month + 1, 1);
        return DateTimeRange(start: start, end: DateTime(start.year, start.month + 1, 0));
      case _UpcomingRange.custom:
        return DateTimeRange(start: customMonth, end: DateTime(customMonth.year, customMonth.month + 1, 0));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final selectedRange = _rangeFor(range, today);
    final currency = primaryCurrency;

    final allOccurrences = occurrencesWithRecurringProjections(tx, horizonDays: 220);
    final entries = allOccurrences
        .where((e) =>
            !e.date.isAfter(selectedRange.end) &&
            // A recurring transaction's occurrence (today or later) always
            // counts as an upcoming/scheduled payment; a one-off
            // transaction only counts if it's genuinely in the future -
            // one dated today has already happened (it's just today's
            // regular spending), not something still "coming up".
            (e.t.isRecurring ? !e.date.isBefore(today) : e.date.isAfter(today)) &&
            !e.date.isBefore(selectedRange.start) &&
            (accountFilter == null || e.t.accountId == accountFilter))
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));

    final totalsByCurrency = <String, double>{};
    for (final e in entries) {
      if (e.t.type != TxType.expense) continue;
      final cur = currencyOf(e.t.accountId);
      totalsByCurrency[cur] = (totalsByCurrency[cur] ?? 0) + e.t.amount;
    }

    // 6-month lookahead chart data (projected expense per month, including
    // recurring occurrences).
    final chartMonths = <({DateTime month, double expense})>[];
    for (var i = 0; i < 6; i++) {
      var y = today.year;
      var m = today.month + i;
      while (m > 12) {
        m -= 12;
        y++;
      }
      final mStart = DateTime(y, m, 1);
      final mEnd = DateTime(y, m + 1, 0);
      final total = allOccurrences
          .where((e) =>
              e.t.type == TxType.expense &&
              (accountFilter != null ? e.t.accountId == accountFilter : currencyOf(e.t.accountId) == currency) &&
              !e.date.isBefore(mStart) &&
              !e.date.isAfter(mEnd))
          .fold(0.0, (s, e) => s + e.t.amount);
      chartMonths.add((month: mStart, expense: total));
    }
    final maxChart = chartMonths.fold(0.0, (m, c) => c.expense > m ? c.expense : m);

    return Scaffold(
      appBar: AppBar(title: Text(tr('upcoming_payments'))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('تا آخر این ماه'),
                  selected: range == _UpcomingRange.endOfThisMonth,
                  onSelected: (_) => setState(() => range = _UpcomingRange.endOfThisMonth),
                ),
                ChoiceChip(
                  label: const Text('ماه بعد'),
                  selected: range == _UpcomingRange.nextMonth,
                  onSelected: (_) => setState(() => range = _UpcomingRange.nextMonth),
                ),
                ActionChip(
                  label: Text(range == _UpcomingRange.custom
                      ? '${_gregorianMonthNames[customMonth.month - 1]} ${customMonth.year}'
                      : 'ماه دلخواه'),
                  avatar: const Icon(Icons.calendar_month_outlined, size: 18),
                  onPressed: _pickCustomMonth,
                ),
                FilterChip(
                  label: const Text('نمودار ۶ ماه آینده'),
                  selected: showChart,
                  onSelected: (v) => setState(() => showChart = v),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: DropdownButtonFormField<String?>(
              initialValue: accountFilter,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'حساب', border: OutlineInputBorder(), isDense: true),
              items: [
                DropdownMenuItem(value: null, child: Text(tr('all_accounts'))),
                ...accounts.map((a) => DropdownMenuItem(value: a.id, child: Text('${a.name} (${a.currency})'))),
              ],
              onChanged: (v) => setState(() => accountFilter = v),
            ),
          ),
          if (showChart)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('هزینه‌ی پیش‌بینی‌شده (شامل تراکنش‌های تکرارشونده)', style: Theme.of(context).textTheme.titleSmall),
                      const SizedBox(height: 12),
                      SizedBox(
                        height: 180,
                        child: maxChart <= 0
                            ? const Center(child: Text('داده‌ای برای نمایش نیست.', style: TextStyle(color: Colors.grey)))
                            : Row(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  for (var i = 0; i < chartMonths.length; i++)
                                    Expanded(
                                      child: Column(
                                        mainAxisAlignment: MainAxisAlignment.end,
                                        children: [
                                          Text(
                                            chartMonths[i].expense > 0 ? ltr(formatMoney(chartMonths[i].expense, currency)) : '',
                                            style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold),
                                            textAlign: TextAlign.center,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          const SizedBox(height: 4),
                                          Container(
                                            height: maxChart > 0 ? 110 * (chartMonths[i].expense / maxChart).clamp(0.02, 1.0) : 2,
                                            margin: const EdgeInsets.symmetric(horizontal: 4),
                                            decoration: BoxDecoration(
                                              color: Colors.red.shade400,
                                              borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            _gregorianMonthNames[chartMonths[i].month.month - 1].substring(0, 3),
                                            style: const TextStyle(fontSize: 10),
                                          ),
                                        ],
                                      ),
                                    ),
                                ],
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (totalsByCurrency.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('جمع هزینه‌های پیش‌رو', style: TextStyle(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 4),
                      ...totalsByCurrency.entries.map((e) => Text(ltr(formatMoney(e.value, e.key)), style: const TextStyle(color: Colors.red))),
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(height: 8),
          Expanded(
            child: entries.isEmpty
                ? const Center(child: Text('در این بازه پرداخت پیش‌رویی وجود ندارد.'))
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: entries.length,
                    itemBuilder: (context, i) {
                      final e = entries[i];
                      final daysLeft = e.date.difference(today).inDays;
                      return Card(
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: e.t.type == TxType.income ? Colors.green.shade100 : Colors.red.shade100,
                            child: Icon(
                              e.t.type == TxType.income ? Icons.add : Icons.remove,
                              color: e.t.type == TxType.income ? Colors.green.shade800 : Colors.red.shade800,
                            ),
                          ),
                          title: Text(categoryName(e.t.categoryId)),
                          subtitle: Text(
                            daysLeft == 0
                                ? 'امروز'
                                : '${formatDate(e.date)} • ${ltr(persianDigits('$daysLeft'))} روز دیگر',
                          ),
                          trailing: Text(
                            ltr(e.t.type == TxType.income ? '+' : '-') + formatMoney(e.t.amount, currencyOf(e.t.accountId)),
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: e.t.type == TxType.income ? Colors.green.shade700 : Colors.red.shade700,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
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
    tx = all.where((t) => t.categoryId == '_uncategorized_' || t.note.contains('دسته‌بندی قبلی:')).toList()
      ..sort((a, b) => b.date.compareTo(a.date));
    categories = await Store.loadCategories();
    accounts = await Store.loadAccounts();
    setState(() => loading = false);
  }

  String categoryName(String id) {
    if (id == '_uncategorized_') return 'بدون‌دسته';
    final c = categories.where((c) => c.id == id).toList();
    return c.isEmpty ? 'بدون‌دسته' : c.first.name;
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
    if (result is DeleteTransactionSignal) {
      await Store.deleteTransaction(result.id);
    } else if (result is Transaction) {
      await Store.upsertTransaction(result);
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(title: Text(tr('affected_by_category_delete'))),
      body: tx.isEmpty
          ? const Center(child: Text('تراکنشی که تحت‌تأثیر حذف دسته‌بندی قرار گرفته باشد وجود ندارد.'))
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
                            '${formatDate(t.date)}'
                            '${t.note.isNotEmpty ? ' • ${t.note}' : ''}',
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

// ============================== Backup, restore & Excel export ==============================

Future<String> _buildBackupFile() async {
  final data = await Store.exportBackupData();
  final json = const JsonEncoder.withIndent('  ').convert(data);
  final dir = await getTemporaryDirectory();
  final path = '${dir.path}/money_management_backup_${DateTime.now().millisecondsSinceEpoch}.json';
  await File(path).writeAsString(json);
  return path;
}

Future<String> _buildExcelFile() async {
  final tx = await Store.loadTransactions();
  final categories = await Store.loadCategories();
  final accounts = await Store.loadAccounts();
  final wb = xls.Excel.createExcel();
  final sheet = wb['تراکنش‌ها'];
  if (wb.tables.containsKey('Sheet1')) wb.delete('Sheet1');

  String categoryName(String id) {
    final m = categories.where((c) => c.id == id).toList();
    return m.isEmpty ? 'بدون‌دسته' : m.first.name;
  }

  String accountName(String id) {
    final m = accounts.where((a) => a.id == id).toList();
    return m.isEmpty ? id : m.first.name;
  }

  String currencyOf(String id) {
    final m = accounts.where((a) => a.id == id).toList();
    return m.isEmpty ? '' : m.first.currency;
  }

  sheet.appendRow([
    xls.TextCellValue('تاریخ'),
    xls.TextCellValue('نوع'),
    xls.TextCellValue('دسته‌بندی'),
    xls.TextCellValue('حساب'),
    xls.TextCellValue('ارز'),
    xls.TextCellValue('مبلغ'),
    xls.TextCellValue('توضیحات'),
    xls.TextCellValue('تکرارشونده'),
    xls.TextCellValue('پیش‌نویس'),
  ]);
  for (final t in tx) {
    sheet.appendRow([
      xls.TextCellValue(ltr(DateFormat('yyyy-MM-dd').format(t.date))),
      xls.TextCellValue(t.type == TxType.income ? 'درآمد' : 'هزینه'),
      xls.TextCellValue(categoryName(t.categoryId)),
      xls.TextCellValue(accountName(t.accountId)),
      xls.TextCellValue(currencyOf(t.accountId)),
      xls.DoubleCellValue(t.amount),
      xls.TextCellValue(t.note),
      xls.TextCellValue(t.isRecurring ? 'بله' : 'خیر'),
      xls.TextCellValue(t.draft ? 'بله' : 'خیر'),
    ]);
  }
  final bytes = wb.encode();
  if (bytes == null) throw Exception('ساخت فایل اکسل ممکن نشد.');
  final dir = await getTemporaryDirectory();
  final path = '${dir.path}/money_management_export_${DateTime.now().millisecondsSinceEpoch}.xlsx';
  await File(path).writeAsBytes(bytes);
  return path;
}

// ============================== Reports ==============================

enum _ReportPreset { thisMonth, lastMonth, thisQuarter, lastQuarter, thisYear, lastYear, custom }

// ============================== Item search (warranty/returns lookup) ==============================

// ============================== All transactions (search/filter/sort) ==============================

enum _TxSortMode { dateDesc, dateAsc, createdDesc, createdAsc, amountDesc, amountAsc }

// ============================== Transfer between accounts ==============================

// ============================== Budget goals ==============================

class BudgetGoalsScreen extends StatefulWidget {
  const BudgetGoalsScreen({super.key});
  @override
  State<BudgetGoalsScreen> createState() => _BudgetGoalsScreenState();
}

class _BudgetGoalsScreenState extends State<BudgetGoalsScreen> {
  bool loading = true;
  List<Category> categories = [];
  List<Transaction> tx = [];
  List<BudgetGoal> goals = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    categories = await Store.loadCategories();
    tx = await Store.loadTransactions();
    goals = await Store.loadBudgetGoals();
    setState(() => loading = false);
  }

  double _spendFor(String categoryId) {
    final now = DateTime.now();
    var spend = 0.0;
    for (final t in tx) {
      if (t.type != TxType.expense) continue;
      if (t.date.year != now.year || t.date.month != now.month) continue;
      var cat = categories.where((c) => c.id == t.categoryId).toList();
      var current = cat.isEmpty ? null : cat.first;
      while (current?.parentId != null) {
        final pm = categories.where((c) => c.id == current!.parentId).toList();
        if (pm.isEmpty) break;
        current = pm.first;
      }
      if (current?.id == categoryId) spend += t.amount;
    }
    return spend;
  }

  Future<void> _editGoal(Category c) async {
    final existing = goals.where((g) => g.categoryId == c.id).toList();
    final ctrl = TextEditingController(text: existing.isEmpty ? '' : existing.first.monthlyAmount.toStringAsFixed(0));
    final result = await showDialog<double?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('هدف هزینه‌ی ${c.name}'),
        content: TextField(
          controller: ctrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'مبلغ هدف در ماه', hintText: 'مثلاً 200'),
          autofocus: true,
        ),
        actions: [
          if (existing.isNotEmpty)
            TextButton(
              onPressed: () => Navigator.pop(ctx, 0.0),
              child: const Text('حذف هدف', style: TextStyle(color: Colors.red)),
            ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('cancel'))),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, double.tryParse(ctrl.text.replaceAll(',', '.'))),
            child: Text(tr('save')),
          ),
        ],
      ),
    );
    if (result == null) return;
    final updated = goals.where((g) => g.categoryId != c.id).toList();
    if (result > 0) updated.add(BudgetGoal(categoryId: c.id, monthlyAmount: result));
    await Store.saveBudgetGoals(updated);
    setState(() => goals = updated);
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final topCategories = categories.where((c) => c.type == TxType.expense && c.parentId == null).toList()
      ..sort((a, b) => persianCompare(a.name, b.name));
    return Scaffold(
      appBar: AppBar(title: Text(tr('budget_goals'))),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: topCategories.length,
        itemBuilder: (context, i) {
          final c = topCategories[i];
          final goalMatch = goals.where((g) => g.categoryId == c.id).toList();
          final goal = goalMatch.isEmpty ? null : goalMatch.first;
          final spend = goal == null ? 0.0 : _spendFor(c.id);
          final ratio = goal == null ? 0.0 : (spend / goal.monthlyAmount).clamp(0.0, 1.5);
          final color = ratio >= 1.0 ? Colors.red : (ratio >= 0.8 ? Colors.orange : Colors.green);
          return Card(
            child: ListTile(
              leading: Icon(iconForCategory(c, categories)),
              title: Text(c.name),
              subtitle: goal == null
                  ? const Text('هدفی تنظیم نشده', style: TextStyle(color: Colors.grey, fontSize: 12))
                  : Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: ratio > 1.0 ? 1.0 : ratio,
                              minHeight: 8,
                              backgroundColor: Colors.grey.shade200,
                              color: color,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${spend.toStringAsFixed(0)} از ${goal.monthlyAmount.toStringAsFixed(0)} (${(ratio * 100).round()}%)',
                            style: TextStyle(fontSize: 11, color: color),
                          ),
                        ],
                      ),
                    ),
              trailing: const Icon(Icons.edit_outlined, size: 18),
              onTap: () => _editGoal(c),
            ),
          );
        },
      ),
    );
  }
}

// ============================== Savings goals ==============================

class SavingsGoalsScreen extends StatefulWidget {
  const SavingsGoalsScreen({super.key});
  @override
  State<SavingsGoalsScreen> createState() => _SavingsGoalsScreenState();
}

class _SavingsGoalsScreenState extends State<SavingsGoalsScreen> {
  bool loading = true;
  List<SavingsGoal> goals = [];
  List<SavingsContribution> contributions = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    goals = await Store.loadSavingsGoals();
    contributions = await Store.loadSavingsContributions();
    setState(() => loading = false);
  }

  double _totalFor(String goalId) => contributions.where((c) => c.goalId == goalId).fold(0.0, (s, c) => s + c.amount);

  /// Average monthly contribution based on months since the first
  /// contribution to this goal - used for a rough "at this pace" estimate.
  double _avgMonthlyContribution(String goalId) {
    final list = contributions.where((c) => c.goalId == goalId).toList();
    if (list.isEmpty) return 0;
    list.sort((a, b) => a.date.compareTo(b.date));
    final first = list.first.date;
    final now = DateTime.now();
    final months = ((now.year - first.year) * 12 + now.month - first.month + 1).clamp(1, 1000);
    final total = list.fold(0.0, (s, c) => s + c.amount);
    return total / months;
  }

  Future<void> _addOrEditGoal({SavingsGoal? existing}) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final amountCtrl = TextEditingController(text: existing?.targetAmount.toStringAsFixed(0) ?? '');
    String currency = existing?.currency ?? 'EUR';
    DateTime? targetDate = existing?.targetDate;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        return AlertDialog(
          title: Text(existing == null ? 'هدف پس‌انداز جدید' : 'ویرایش هدف'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'نام هدف (مثلاً خرید ماشین)'), autofocus: true),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: amountCtrl,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'مبلغ هدف'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: currency,
                        decoration: const InputDecoration(labelText: 'واحد پول'),
                        items: kCurrencies.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                        onChanged: (v) => setLocal(() => currency = v ?? currency),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(targetDate == null ? 'تاریخ هدف (اختیاری)' : formatDate(targetDate!)),
                  trailing: const Icon(Icons.calendar_today, size: 18),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: ctx,
                      initialDate: targetDate ?? DateTime.now().add(const Duration(days: 365)),
                      firstDate: DateTime.now(),
                      lastDate: DateTime.now().add(const Duration(days: 365 * 20)),
                      builder: (ctx2, child) => Directionality(textDirection: TextDirection.ltr, child: child!),
                    );
                    if (picked != null) setLocal(() => targetDate = picked);
                  },
                ),
              ],
            ),
          ),
          actions: [
            if (existing != null)
              TextButton(onPressed: () => Navigator.pop(ctx, null), child: const Text('حذف هدف', style: TextStyle(color: Colors.red))),
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('save'))),
          ],
        );
      }),
    );
    if (result == null && existing != null) {
      goals.removeWhere((g) => g.id == existing.id);
      contributions.removeWhere((c) => c.goalId == existing.id);
      await Store.saveSavingsGoals(goals);
      await Store.saveSavingsContributions(contributions);
      setState(() {});
      return;
    }
    if (result != true) return;
    final amount = double.tryParse(amountCtrl.text.replaceAll(',', '.'));
    if (nameCtrl.text.trim().isEmpty || amount == null || amount <= 0) return;
    final goal = SavingsGoal(
      id: existing?.id ?? 'sg_${DateTime.now().microsecondsSinceEpoch}',
      name: nameCtrl.text.trim(),
      targetAmount: amount,
      targetDate: targetDate,
      currency: currency,
    );
    goals = [...goals.where((g) => g.id != goal.id), goal];
    await Store.saveSavingsGoals(goals);
    setState(() {});
  }

  Future<void> _addContribution(SavingsGoal g) async {
    final amountCtrl = TextEditingController();
    DateTime date = DateTime.now();
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        return AlertDialog(
          title: Text('واریز به «${g.name}»'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: amountCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: 'مبلغ واریزی (${g.currency})'),
                autofocus: true,
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(formatDate(date)),
                trailing: const Icon(Icons.calendar_today, size: 18),
                onTap: () async {
                  final picked =
                      await showDatePicker(
                        context: ctx,
                        initialDate: date,
                        firstDate: DateTime(2015),
                        lastDate: DateTime.now(),
                        builder: (ctx2, child) => Directionality(textDirection: TextDirection.ltr, child: child!),
                      );
                  if (picked != null) setLocal(() => date = picked);
                },
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('confirm'))),
          ],
        );
      }),
    );
    if (result != true) return;
    final amount = double.tryParse(amountCtrl.text.replaceAll(',', '.'));
    if (amount == null || amount <= 0) return;
    final contribution = SavingsContribution(
      id: 'sc_${DateTime.now().microsecondsSinceEpoch}',
      goalId: g.id,
      amount: amount,
      date: date,
    );
    contributions = [...contributions, contribution];
    await Store.saveSavingsContributions(contributions);
    setState(() {});
  }

  Future<void> _showContributions(SavingsGoal g) async {
    final list = contributions.where((c) => c.goalId == g.id).toList()..sort((a, b) => b.date.compareTo(a.date));
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        builder: (ctx, scrollController) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('واریزی\u200cهای «${g.name}»', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              Expanded(
                child: list.isEmpty
                    ? const Center(child: Text('هنوز واریزی\u200cای ثبت نشده.'))
                    : ListView.builder(
                        controller: scrollController,
                        itemCount: list.length,
                        itemBuilder: (context, i) {
                          final c = list[i];
                          return ListTile(
                            title: Text(ltr(formatMoney(c.amount, g.currency))),
                            subtitle: Text(formatDate(c.date)),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline, size: 20),
                              onPressed: () async {
                                contributions.removeWhere((x) => x.id == c.id);
                                await Store.saveSavingsContributions(contributions);
                                if (context.mounted) Navigator.pop(context);
                                setState(() {});
                              },
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(title: Text(tr('savings_goals'))),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addOrEditGoal(),
        icon: const Icon(Icons.add),
        label: Text(tr('new_goal')),
      ),
      body: goals.isEmpty
          ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('هنوز هدف پس\u200cاندازی تعریف نشده.')))
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
              itemCount: goals.length,
              itemBuilder: (context, i) {
                final g = goals[i];
                final current = _totalFor(g.id);
                final ratio = (current / g.targetAmount).clamp(0.0, 1.0);
                final growth = _avgMonthlyContribution(g.id);
                String? projection;
                if (current >= g.targetAmount) {
                  projection = 'به هدف رسیدی! \u{1F389}';
                } else if (growth > 0) {
                  final monthsLeft = ((g.targetAmount - current) / growth).ceil();
                  projection = 'با روند فعلی، حدود $monthsLeft ماه دیگر به هدف می\u200cرسی.';
                }
                return Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(child: Text(g.name, style: Theme.of(context).textTheme.titleMedium)),
                            IconButton(
                              icon: const Icon(Icons.edit_outlined, size: 18),
                              onPressed: () => _addOrEditGoal(existing: g),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: ratio,
                            minHeight: 10,
                            backgroundColor: Colors.grey.shade200,
                            color: ratio >= 1.0 ? Colors.green : Colors.indigo,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '${ltr(formatMoney(current, g.currency))} از ${ltr(formatMoney(g.targetAmount, g.currency))} (${(ratio * 100).round()}%)',
                          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                        ),
                        if (g.targetDate != null)
                          Text(
                            'تا ${formatDate(g.targetDate!)}',
                            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                          ),
                        if (projection != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(projection, style: TextStyle(fontSize: 12, color: Colors.indigo.shade700)),
                          ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            TextButton.icon(
                              onPressed: () => _addContribution(g),
                              icon: const Icon(Icons.add, size: 16),
                              label: const Text('واریز'),
                            ),
                            TextButton.icon(
                              onPressed: () => _showContributions(g),
                              icon: const Icon(Icons.history, size: 16),
                              label: const Text('تاریخچه'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

class TransferScreen extends StatefulWidget {
  const TransferScreen({super.key});
  @override
  State<TransferScreen> createState() => _TransferScreenState();
}

class _TransferScreenState extends State<TransferScreen> {
  bool loading = true;
  List<Account> accounts = [];
  Account? fromAccount;
  Account? toAccount;
  final amountCtrl = TextEditingController();
  final noteCtrl = TextEditingController();
  DateTime date = DateTime.now();
  bool saving = false;
  RecurrenceFrequency recurrence = RecurrenceFrequency.none;
  final dayCtrl = TextEditingController();
  int weekday = 1;
  final intervalCtrl = TextEditingController(text: '30');
  final installmentsCtrl = TextEditingController();
  DateTime? endDate;
  String endMode = 'unlimited'; // 'unlimited' | 'installments' | 'date'

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    accounts = await Store.loadAccounts();
    if (accounts.length >= 2) {
      fromAccount = accounts[0];
      toAccount = accounts[1];
    } else if (accounts.length == 1) {
      fromAccount = accounts[0];
    }
    setState(() => loading = false);
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: date,
      firstDate: DateTime(2015),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      builder: (ctx, child) => Directionality(textDirection: TextDirection.ltr, child: child!),
    );
    if (picked != null) setState(() => date = picked);
  }

  Future<void> _save() async {
    final amount = double.tryParse(amountCtrl.text.replaceAll(',', '.'));
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('مبلغ معتبر وارد کنید.')));
      return;
    }
    if (fromAccount == null || toAccount == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('حساب مبدأ و مقصد را انتخاب کنید.')));
      return;
    }
    if (fromAccount!.id == toAccount!.id) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('حساب مبدأ و مقصد نمی‌توانند یکسان باشند.')));
      return;
    }
    if (fromAccount!.currency != toAccount!.currency) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('انتقال بین حساب‌های با ارز متفاوت پشتیبانی نمی‌شود (نرخ تبدیل لازم است).'),
      ));
      return;
    }
    int? recDay;
    int? recWeekday;
    int? recInterval;
    int? recInstallments;
    DateTime? recEndDate;
    if (recurrence == RecurrenceFrequency.monthly || recurrence == RecurrenceFrequency.quarterly) {
      recDay = int.tryParse(dayCtrl.text);
      if (recDay == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('روز سررسید در ماه را وارد کنید.')));
        return;
      }
      if (recDay < 1) recDay = 1;
      if (recDay > 31) recDay = 31;
    } else if (recurrence == RecurrenceFrequency.weekly) {
      recWeekday = weekday;
    } else if (recurrence == RecurrenceFrequency.custom) {
      recInterval = int.tryParse(intervalCtrl.text);
      if (recInterval == null || recInterval <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعداد روز بازه را درست وارد کنید.')));
        return;
      }
    }
    if (recurrence != RecurrenceFrequency.none) {
      if (endMode == 'installments') {
        recInstallments = int.tryParse(installmentsCtrl.text);
        if (recInstallments == null || recInstallments <= 0) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعداد کل اقساط را درست وارد کنید.')));
          return;
        }
      } else if (endMode == 'date') {
        if (endDate == null) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تاریخ پایان را انتخاب کنید.')));
          return;
        }
        recEndDate = endDate;
      }
    }
    setState(() => saving = true);
    final baseId = DateTime.now().microsecondsSinceEpoch.toString();
    final note = noteCtrl.text.trim();
    final outTx = Transaction(
      id: '${baseId}_out',
      type: TxType.expense,
      amount: amount,
      categoryId: '_transfer_out_',
      accountId: fromAccount!.id,
      date: date,
      note: note.isEmpty ? 'انتقال به ${toAccount!.name}' : note,
      recurrence: recurrence,
      recurrenceDay: recDay,
      recurrenceWeekday: recWeekday,
      recurrenceIntervalDays: recInterval,
      installments: recInstallments,
      recurrenceEndDate: recEndDate,
    );
    final inTx = Transaction(
      id: '${baseId}_in',
      type: TxType.income,
      amount: amount,
      categoryId: '_transfer_in_',
      accountId: toAccount!.id,
      date: date,
      note: note.isEmpty ? 'انتقال از ${fromAccount!.name}' : note,
      recurrence: recurrence,
      recurrenceDay: recDay,
      recurrenceWeekday: recWeekday,
      recurrenceIntervalDays: recInterval,
      installments: recInstallments,
      recurrenceEndDate: recEndDate,
    );
    await Store.upsertTransaction(outTx);
    await Store.upsertTransaction(inTx);
    if (!mounted) return;
    setState(() => saving = false);
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (accounts.length < 2) {
      return Scaffold(
        appBar: AppBar(title: Text(tr('transfer_between_accounts'))),
        body: const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('برای انتقال، حداقل به دو حساب نیاز دارید.'))),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(tr('transfer_between_accounts'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          DropdownButtonFormField<Account>(
            initialValue: fromAccount,
            decoration: InputDecoration(labelText: tr('from_account'), border: const OutlineInputBorder()),
            items: accounts.map((a) => DropdownMenuItem(value: a, child: Text('${a.name} (${a.currency})'))).toList(),
            onChanged: (v) => setState(() => fromAccount = v),
          ),
          const SizedBox(height: 12),
          Center(child: Icon(Icons.arrow_downward, color: Colors.grey.shade500)),
          const SizedBox(height: 12),
          DropdownButtonFormField<Account>(
            initialValue: toAccount,
            decoration: InputDecoration(labelText: tr('to_account'), border: const OutlineInputBorder()),
            items: accounts.map((a) => DropdownMenuItem(value: a, child: Text('${a.name} (${a.currency})'))).toList(),
            onChanged: (v) => setState(() => toAccount = v),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: amountCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: tr('amount'), hintText: 'مثلاً 100.00', border: const OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr('date')),
            subtitle: Text(formatDate(date)),
            trailing: const Icon(Icons.calendar_today, size: 18),
            onTap: _pickDate,
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<RecurrenceFrequency>(
            initialValue: recurrence,
            decoration: InputDecoration(labelText: tr('recurrence_type'), border: const OutlineInputBorder()),
            items: const [
              DropdownMenuItem(value: RecurrenceFrequency.none, child: Text('بدون تکرار')),
              DropdownMenuItem(value: RecurrenceFrequency.weekly, child: Text('هفتگی')),
              DropdownMenuItem(value: RecurrenceFrequency.monthly, child: Text('ماهانه')),
              DropdownMenuItem(value: RecurrenceFrequency.quarterly, child: Text('فصلی (هر سه ماه)')),
              DropdownMenuItem(value: RecurrenceFrequency.yearly, child: Text('سالانه')),
              DropdownMenuItem(value: RecurrenceFrequency.custom, child: Text('بازه‌ی دلخواه (هر N روز)')),
            ],
            onChanged: (v) => setState(() => recurrence = v ?? RecurrenceFrequency.none),
          ),
          if (recurrence == RecurrenceFrequency.monthly || recurrence == RecurrenceFrequency.quarterly) ...[
            const SizedBox(height: 12),
            TextField(
              controller: dayCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'روز سررسید در ماه (۱ تا ۳۱) *', border: OutlineInputBorder()),
            ),
          ],
          if (recurrence == RecurrenceFrequency.weekly) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: weekday,
              decoration: InputDecoration(labelText: tr('weekday'), border: const OutlineInputBorder()),
              items: List.generate(7, (i) => i + 1).map((w) => DropdownMenuItem(value: w, child: Text(_weekdayNames[w - 1]))).toList(),
              onChanged: (v) => setState(() => weekday = v ?? weekday),
            ),
          ],
          if (recurrence == RecurrenceFrequency.custom) ...[
            const SizedBox(height: 12),
            TextField(
              controller: intervalCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'هر چند روز یک‌بار؟', border: OutlineInputBorder()),
            ),
          ],
          if (recurrence != RecurrenceFrequency.none) ...[
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'unlimited', label: Text('نامحدود')),
                ButtonSegment(value: 'installments', label: Text('تعداد قسط')),
                ButtonSegment(value: 'date', label: Text('تاریخ پایان')),
              ],
              selected: {endMode},
              onSelectionChanged: (s) => setState(() => endMode = s.first),
            ),
            if (endMode == 'installments') ...[
              const SizedBox(height: 12),
              TextField(
                controller: installmentsCtrl,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: tr('total_installments'), border: const OutlineInputBorder()),
              ),
            ],
            if (endMode == 'date') ...[
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(endDate == null ? 'تاریخ پایان را انتخاب کنید' : formatDate(endDate!)),
                trailing: const Icon(Icons.calendar_today, size: 18),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: endDate ?? date.add(const Duration(days: 30)),
                    firstDate: date,
                    lastDate: DateTime.now().add(const Duration(days: 365 * 20)),
                    builder: (ctx, child) => Directionality(textDirection: TextDirection.ltr, child: child!),
                  );
                  if (picked != null) setState(() => endDate = picked);
                },
              ),
            ],
          ],
          const SizedBox(height: 8),
          TextField(
            controller: noteCtrl,
            decoration: const InputDecoration(labelText: 'توضیحات (اختیاری)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: saving ? null : _save,
            icon: saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.swap_horiz),
            label: Text(tr('transfer')),
          ),
        ],
      ),
    );
  }
}

class AllTransactionsScreen extends StatefulWidget {
  const AllTransactionsScreen({super.key});
  @override
  State<AllTransactionsScreen> createState() => _AllTransactionsScreenState();
}

class _AllTransactionsScreenState extends State<AllTransactionsScreen> {
  bool loading = true;
  List<Transaction> tx = [];
  List<Category> categories = [];
  List<Account> accounts = [];
  final queryCtrl = TextEditingController();
  String query = '';
  TxType? typeFilter;
  String? categoryFilter;
  String? accountFilter;
  bool? recurringFilter; // null = all, true = recurring only, false = non-recurring only
  _TxSortMode sort = _TxSortMode.createdDesc;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    tx = await Store.loadTransactions();
    categories = await Store.loadCategories();
    accounts = await Store.loadAccounts();
    setState(() => loading = false);
  }

  String categoryName(String id) {
    final m = categories.where((c) => c.id == id).toList();
    return m.isEmpty ? 'بدون‌دسته' : m.first.name;
  }

  String currencyOf(String accountId) {
    final m = accounts.where((a) => a.id == accountId).toList();
    return m.isEmpty ? 'EUR' : m.first.currency;
  }

  Future<void> _openEditor(Transaction t) async {
    final result = await Navigator.push<Object>(
      context,
      MaterialPageRoute(builder: (_) => TransactionEditor(categories: categories, accounts: accounts, existing: t)),
    );
    if (result == null) return;
    if (result is DeleteTransactionSignal) {
      await Store.deleteTransaction(result.id);
    } else if (result is Transaction) {
      await Store.upsertTransaction(result);
    }
    await _load();
  }

  int get _activeFilterCount =>
      (typeFilter != null ? 1 : 0) +
      (categoryFilter != null ? 1 : 0) +
      (accountFilter != null ? 1 : 0) +
      (recurringFilter != null ? 1 : 0);

  Future<void> _openFilterSheet() async {
    TxType? localType = typeFilter;
    String? localCategory = categoryFilter;
    String? localAccount = accountFilter;
    bool? localRecurring = recurringFilter;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: StatefulBuilder(builder: (ctx, setLocal) {
          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(tr('filter'), style: Theme.of(context).textTheme.titleMedium),
                    TextButton(
                      onPressed: () => setLocal(() {
                        localType = null;
                        localCategory = null;
                        localAccount = null;
                        localRecurring = null;
                      }),
                      child: const Text('پاک‌کردن همه'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text('نوع تراکنش', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                const SizedBox(height: 6),
                DropdownButtonFormField<TxType?>(
                  initialValue: localType,
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12)),
                  items: const [
                    DropdownMenuItem(value: null, child: Text('همه‌ی انواع')),
                    DropdownMenuItem(value: TxType.income, child: Text('درآمد')),
                    DropdownMenuItem(value: TxType.expense, child: Text('هزینه')),
                  ],
                  onChanged: (v) => setLocal(() => localType = v),
                ),
                const SizedBox(height: 16),
                Text('تکرارشوندگی', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                const SizedBox(height: 6),
                DropdownButtonFormField<bool?>(
                  initialValue: localRecurring,
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12)),
                  items: const [
                    DropdownMenuItem(value: null, child: Text('همه')),
                    DropdownMenuItem(value: true, child: Text('فقط تکرارشونده')),
                    DropdownMenuItem(value: false, child: Text('فقط غیرتکرارشونده')),
                  ],
                  onChanged: (v) => setLocal(() => localRecurring = v),
                ),
                const SizedBox(height: 16),
                Text('دسته‌بندی', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                const SizedBox(height: 6),
                DropdownButtonFormField<String?>(
                  initialValue: localCategory,
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12)),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('همه‌ی دسته‌بندی‌ها')),
                    ...categories.map((c) => DropdownMenuItem(value: c.id, child: Text(c.name))),
                  ],
                  onChanged: (v) => setLocal(() => localCategory = v),
                ),
                const SizedBox(height: 16),
                Text('حساب', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                const SizedBox(height: 6),
                DropdownButtonFormField<String?>(
                  initialValue: localAccount,
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12)),
                  items: [
                    DropdownMenuItem(value: null, child: Text(tr('all_accounts'))),
                    ...accounts.map((a) => DropdownMenuItem(value: a.id, child: Text(a.name))),
                  ],
                  onChanged: (v) => setLocal(() => localAccount = v),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                  onPressed: () {
                    setState(() {
                      typeFilter = localType;
                      categoryFilter = localCategory;
                      accountFilter = localAccount;
                      recurringFilter = localRecurring;
                    });
                    Navigator.pop(ctx);
                  },
                  child: const Text('اعمال فیلتر'),
                ),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _appliedFilterChip(String label, VoidCallback onClear) {
    return Chip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      onDeleted: onClear,
      deleteIconColor: Colors.grey.shade600,
      visualDensity: VisualDensity.compact,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
    );
  }

  Widget _filterPill<T>({
    required BuildContext context,
    required IconData icon,
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Colors.grey.shade600),
          const SizedBox(width: 6),
          DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              value: value,
              isDense: true,
              icon: const Icon(Icons.expand_more, size: 16),
              style: TextStyle(fontSize: 13, color: Theme.of(context).textTheme.bodyMedium?.color),
              items: items,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final q = query.trim().toLowerCase();
    var filtered = tx.where((t) {
      if (typeFilter != null && t.type != typeFilter) return false;
      if (categoryFilter != null && t.categoryId != categoryFilter) return false;
      if (accountFilter != null && t.accountId != accountFilter) return false;
      if (recurringFilter != null && t.isRecurring != recurringFilter) return false;
      if (q.isNotEmpty) {
        final hay = [
          categoryName(t.categoryId),
          t.note,
          ...t.items.map((i) => i.name),
        ].join(' ').toLowerCase();
        if (!hay.contains(q)) return false;
      }
      return true;
    }).toList();

    int createdAtOf(Transaction t) => int.tryParse(t.id) ?? 0;
    switch (sort) {
      case _TxSortMode.dateDesc:
        filtered.sort((a, b) => b.date.compareTo(a.date));
        break;
      case _TxSortMode.dateAsc:
        filtered.sort((a, b) => a.date.compareTo(b.date));
        break;
      case _TxSortMode.createdDesc:
        filtered.sort((a, b) => createdAtOf(b).compareTo(createdAtOf(a)));
        break;
      case _TxSortMode.createdAsc:
        filtered.sort((a, b) => createdAtOf(a).compareTo(createdAtOf(b)));
        break;
      case _TxSortMode.amountDesc:
        filtered.sort((a, b) => b.amount.compareTo(a.amount));
        break;
      case _TxSortMode.amountAsc:
        filtered.sort((a, b) => a.amount.compareTo(b.amount));
        break;
    }

    return Scaffold(
      appBar: AppBar(title: Text(tr('all_transactions'))),
      body: Column(
        children: [
          Container(
            margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            padding: const EdgeInsets.symmetric(horizontal: 4),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(12),
            ),
            child: TextField(
              controller: queryCtrl,
              decoration: const InputDecoration(
                hintText: 'جستجو در دسته‌بندی، توضیحات یا اقلام...',
                prefixIcon: Icon(Icons.search),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 14),
              ),
              onChanged: (v) => setState(() => query = v),
            ),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                OutlinedButton.icon(
                  onPressed: _openFilterSheet,
                  icon: Badge(
                    label: Text('$_activeFilterCount'),
                    isLabelVisible: _activeFilterCount > 0,
                    child: const Icon(Icons.filter_list, size: 18),
                  ),
                  label: Text(tr('filter')),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _filterPill<_TxSortMode>(
                    context: context,
                    icon: Icons.sort,
                    value: sort,
                    items: _TxSortMode.values.map((m) => DropdownMenuItem(value: m, child: Text(_sortLabel(m)))).toList(),
                    onChanged: (v) => setState(() => sort = v ?? sort),
                  ),
                ),
              ],
            ),
          ),
          if (_activeFilterCount > 0) ...[
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (typeFilter != null)
                    _appliedFilterChip(
                      typeFilter == TxType.income ? 'نوع: درآمد' : 'نوع: هزینه',
                      () => setState(() => typeFilter = null),
                    ),
                  if (recurringFilter != null)
                    _appliedFilterChip(
                      recurringFilter! ? 'فقط تکرارشونده' : 'فقط غیرتکرارشونده',
                      () => setState(() => recurringFilter = null),
                    ),
                  if (categoryFilter != null)
                    _appliedFilterChip(
                      'دسته‌بندی: ${categoryName(categoryFilter!)}',
                      () => setState(() => categoryFilter = null),
                    ),
                  if (accountFilter != null)
                    _appliedFilterChip(
                      'حساب: ${accounts.where((a) => a.id == accountFilter).isEmpty ? '' : accounts.firstWhere((a) => a.id == accountFilter).name}',
                      () => setState(() => accountFilter = null),
                    ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerRight,
              child: Text('${filtered.length} تراکنش', style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: filtered.isEmpty
                ? const Center(child: Text('تراکنشی با این شرایط پیدا نشد.'))
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: filtered.length,
                    itemBuilder: (context, i) {
                      final t = filtered[i];
                      return Card(
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: t.type == TxType.income ? Colors.green.shade100 : Colors.red.shade100,
                            child: Icon(
                              t.type == TxType.income ? Icons.add : Icons.remove,
                              color: t.type == TxType.income ? Colors.green.shade800 : Colors.red.shade800,
                            ),
                          ),
                          title: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${categoryName(t.categoryId)} • ${formatDate(t.date)}'
                                '${t.isRecurring ? ' • تکرارشونده' : ''}'
                                '${t.draft ? ' • پیش‌نویس' : ''}',
                                style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 1),
                              Text(
                                txMainTitle(t, categoryName(t.categoryId)),
                                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
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
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class ItemSearchScreen extends StatefulWidget {
  const ItemSearchScreen({super.key});
  @override
  State<ItemSearchScreen> createState() => _ItemSearchScreenState();
}

class _ItemSearchScreenState extends State<ItemSearchScreen> {
  bool loading = true;
  List<Transaction> tx = [];
  List<Category> categories = [];
  List<Account> accounts = [];
  final queryCtrl = TextEditingController();
  String query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    tx = await Store.loadTransactions();
    categories = await Store.loadCategories();
    accounts = await Store.loadAccounts();
    setState(() => loading = false);
  }

  String categoryName(String id) {
    final m = categories.where((c) => c.id == id).toList();
    return m.isEmpty ? 'بدون‌دسته' : m.first.name;
  }

  String currencyOf(String accountId) {
    final m = accounts.where((a) => a.id == accountId).toList();
    return m.isEmpty ? 'EUR' : m.first.currency;
  }

  Future<void> _openEditor(Transaction t) async {
    final result = await Navigator.push<Object>(
      context,
      MaterialPageRoute(builder: (_) => TransactionEditor(categories: categories, accounts: accounts, existing: t)),
    );
    if (result == null) return;
    if (result is DeleteTransactionSignal) {
      await Store.deleteTransaction(result.id);
    } else if (result is Transaction) {
      await Store.upsertTransaction(result);
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final q = query.trim();
    final matches = <({Transaction t, ReceiptItemEntry item})>[];
    if (q.isNotEmpty) {
      for (final t in tx) {
        for (final it in t.items) {
          if (it.name.toLowerCase().contains(q.toLowerCase())) {
            matches.add((t: t, item: it));
          }
        }
      }
      matches.sort((a, b) => b.t.date.compareTo(a.t.date));
    }
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: queryCtrl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'جستجوی کالا (مثلاً یخچال، کفش...)', border: InputBorder.none),
          onChanged: (v) => setState(() => query = v),
        ),
      ),
      body: q.isEmpty
          ? const Center(child: Text('نام کالایی را که دنبالشی تایپ کن.', style: TextStyle(color: Colors.grey)))
          : matches.isEmpty
              ? const Center(child: Text('کالایی با این نام پیدا نشد.'))
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: matches.length,
                  itemBuilder: (context, i) {
                    final m = matches[i];
                    return Card(
                      child: ListTile(
                        title: Text(m.item.name),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${categoryName(m.t.categoryId)} • ${formatDate(m.t.date)}'),
                            if (m.item.warrantyNote != null) ...[
                              const SizedBox(height: 4),
                              Text(m.item.warrantyNote!, style: const TextStyle(fontSize: 12)),
                            ],
                            if (m.item.warrantyUntil != null || m.item.returnUntil != null) ...[
                              const SizedBox(height: 4),
                              Wrap(
                                spacing: 6,
                                children: [
                                  if (m.item.warrantyUntil != null)
                                    Chip(
                                      label: Text('گارانتی تا ${ltr(persianDigits(DateFormat('yyyy-MM-dd').format(m.item.warrantyUntil!)))}',
                                          style: const TextStyle(fontSize: 11)),
                                      visualDensity: VisualDensity.compact,
                                      backgroundColor: Colors.blue.shade50,
                                    ),
                                  if (m.item.returnUntil != null)
                                    Chip(
                                      label: Text('مرجوعی تا ${ltr(persianDigits(DateFormat('yyyy-MM-dd').format(m.item.returnUntil!)))}',
                                          style: const TextStyle(fontSize: 11)),
                                      visualDensity: VisualDensity.compact,
                                      backgroundColor: Colors.orange.shade50,
                                    ),
                                ],
                              ),
                            ],
                          ],
                        ),
                        trailing: Text(
                          m.item.price != null ? ltr(formatMoney(m.item.price!, currencyOf(m.t.accountId))) : '',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        isThreeLine: true,
                        onTap: () => _openEditor(m.t),
                      ),
                    );
                  },
                ),
    );
  }
}

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});
  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  bool loading = true;
  List<Transaction> tx = [];
  List<Category> categories = [];
  List<Account> accounts = [];

  _ReportPreset preset = _ReportPreset.thisMonth;
  DateTime rangeStart = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTime rangeEnd = DateTime.now();
  String? categoryFilter; // category id, null = all
  String? accountFilter; // account id, null = all
  TxType? typeFilter; // null = both

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    tx = await Store.loadTransactions();
    categories = await Store.loadCategories();
    accounts = await Store.loadAccounts();
    setState(() => loading = false);
  }

  void _applyPreset(_ReportPreset p) {
    final now = DateTime.now();
    setState(() {
      preset = p;
      switch (p) {
        case _ReportPreset.thisMonth:
          rangeStart = DateTime(now.year, now.month, 1);
          rangeEnd = now;
          break;
        case _ReportPreset.lastMonth:
          final lastMonthEnd = DateTime(now.year, now.month, 1).subtract(const Duration(days: 1));
          rangeStart = DateTime(lastMonthEnd.year, lastMonthEnd.month, 1);
          rangeEnd = lastMonthEnd;
          break;
        case _ReportPreset.thisQuarter:
          final qStartMonth = ((now.month - 1) ~/ 3) * 3 + 1;
          rangeStart = DateTime(now.year, qStartMonth, 1);
          rangeEnd = now;
          break;
        case _ReportPreset.lastQuarter:
          final qStartMonth = ((now.month - 1) ~/ 3) * 3 + 1;
          final thisQStart = DateTime(now.year, qStartMonth, 1);
          final lastQEnd = thisQStart.subtract(const Duration(days: 1));
          final lastQStartMonth = ((lastQEnd.month - 1) ~/ 3) * 3 + 1;
          rangeStart = DateTime(lastQEnd.year, lastQStartMonth, 1);
          rangeEnd = lastQEnd;
          break;
        case _ReportPreset.thisYear:
          rangeStart = DateTime(now.year, 1, 1);
          rangeEnd = now;
          break;
        case _ReportPreset.lastYear:
          rangeStart = DateTime(now.year - 1, 1, 1);
          rangeEnd = DateTime(now.year - 1, 12, 31);
          break;
        case _ReportPreset.custom:
          break;
      }
    });
  }

  Future<void> _pickCustomRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2015),
      lastDate: DateTime.now(),
      initialDateRange: DateTimeRange(start: rangeStart, end: rangeEnd),
    );
    if (picked == null) return;
    setState(() {
      preset = _ReportPreset.custom;
      rangeStart = picked.start;
      rangeEnd = picked.end;
    });
  }

  /// The equivalent-length period immediately before [rangeStart].
  DateTimeRange get _previousRange {
    final days = rangeEnd.difference(rangeStart).inDays + 1;
    final prevEnd = rangeStart.subtract(const Duration(days: 1));
    final prevStart = prevEnd.subtract(Duration(days: days - 1));
    return DateTimeRange(start: prevStart, end: prevEnd);
  }

  bool _matchesFilters(Transaction t) {
    if (categoryFilter != null && t.categoryId != categoryFilter) return false;
    if (accountFilter != null && t.accountId != accountFilter) return false;
    if (typeFilter != null && t.type != typeFilter) return false;
    return true;
  }

  List<Transaction> _inRange(DateTimeRange range) {
    return tx.where((t) {
      if (!_matchesFilters(t)) return false;
      final d = DateTime(t.date.year, t.date.month, t.date.day);
      return !d.isBefore(range.start) && !d.isAfter(range.end);
    }).toList();
  }

  String categoryName(String id) {
    final m = categories.where((c) => c.id == id).toList();
    return m.isEmpty ? 'بدون‌دسته' : m.first.name;
  }

  String currencyOf(String accountId) {
    final m = accounts.where((a) => a.id == accountId).toList();
    return m.isEmpty ? 'EUR' : m.first.currency;
  }

  Map<Category, double> _expenseByTopCategory(List<Transaction> list, String currency) {
    final map = <String, double>{};
    for (final t in list) {
      if (t.type != TxType.expense) continue;
      if (currencyOf(t.accountId) != currency) continue;
      final match = categories.where((c) => c.id == t.categoryId).toList();
      var cat = match.isEmpty ? null : match.first;
      while (cat?.parentId != null) {
        final pm = categories.where((c) => c.id == cat!.parentId).toList();
        if (pm.isEmpty) break;
        cat = pm.first;
      }
      final key = cat?.id ?? '_uncategorized_';
      map[key] = (map[key] ?? 0) + t.amount;
    }
    final result = <Category, double>{};
    map.forEach((id, amount) {
      final match = categories.where((c) => c.id == id).toList();
      result[match.isEmpty ? Category(id: id, name: 'بدون‌دسته', type: TxType.expense) : match.first] = amount;
    });
    return result;
  }

  String _presetLabel(_ReportPreset p) => switch (p) {
        _ReportPreset.thisMonth => 'این ماه',
        _ReportPreset.lastMonth => 'ماه قبل',
        _ReportPreset.thisQuarter => 'این فصل',
        _ReportPreset.lastQuarter => 'فصل قبل',
        _ReportPreset.thisYear => 'امسال',
        _ReportPreset.lastYear => 'پارسال',
        _ReportPreset.custom => 'بازه‌ی دلخواه',
      };

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final currentTx = _inRange(DateTimeRange(start: rangeStart, end: rangeEnd));
    final prevRange = _previousRange;
    final prevTx = _inRange(prevRange);

    // Primary currency for this report = most common currency among the
    // filtered accounts (or the filtered account itself, if one is chosen).
    String primaryCurrency;
    if (accountFilter != null) {
      primaryCurrency = currencyOf(accountFilter!);
    } else {
      final counts = <String, int>{};
      for (final a in accounts) {
        counts[a.currency] = (counts[a.currency] ?? 0) + 1;
      }
      primaryCurrency = counts.isEmpty ? 'EUR' : (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
    }

    double sumFor(List<Transaction> list, TxType type) => list
        .where((t) => t.type == type && currencyOf(t.accountId) == primaryCurrency)
        .fold(0.0, (s, t) => s + t.amount);

    final curIncome = sumFor(currentTx, TxType.income);
    final curExpense = sumFor(currentTx, TxType.expense);
    final prevIncome = sumFor(prevTx, TxType.income);
    final prevExpense = sumFor(prevTx, TxType.expense);

    final byCategory = _expenseByTopCategory(currentTx, primaryCurrency).entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final maxCategoryAmount = byCategory.isEmpty ? 0.0 : byCategory.first.value;

    Widget comparisonRow(String label, double cur, double prev, {required bool higherIsBad}) {
      String changeText = '';
      Color changeColor = Colors.grey;
      if (prev > 0) {
        final change = (cur - prev) / prev * 100;
        final up = change >= 0;
        final bad = higherIsBad ? up : !up;
        changeColor = bad ? Colors.red.shade700 : Colors.green.shade700;
        changeText = '${ltr('${up ? '+' : ''}${change.round()}%')} نسبت به دوره‌ی قبل';
      }
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(ltr(formatMoney(cur, primaryCurrency)), style: const TextStyle(fontWeight: FontWeight.bold)),
                if (changeText.isNotEmpty) Text(changeText, style: TextStyle(fontSize: 11, color: changeColor)),
              ],
            ),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(tr('full_reporting'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in _ReportPreset.values.where((p) => p != _ReportPreset.custom))
                ChoiceChip(label: Text(_presetLabel(p)), selected: preset == p, onSelected: (_) => _applyPreset(p)),
              ActionChip(
                label: Text(preset == _ReportPreset.custom
                    ? '${ltr(persianDigits(DateFormat('dd.MM.yy').format(rangeStart)))} - ${ltr(persianDigits(DateFormat('dd.MM.yy').format(rangeEnd)))}'
                    : 'بازه‌ی دلخواه'),
                avatar: const Icon(Icons.date_range, size: 18),
                onPressed: _pickCustomRange,
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String?>(
                  initialValue: categoryFilter,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'دسته‌بندی', border: OutlineInputBorder(), isDense: true),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('همه')),
                    ...categories.map((c) => DropdownMenuItem(value: c.id, child: Text(c.name, overflow: TextOverflow.ellipsis))),
                  ],
                  onChanged: (v) => setState(() => categoryFilter = v),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: DropdownButtonFormField<String?>(
                  initialValue: accountFilter,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'حساب', border: OutlineInputBorder(), isDense: true),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('همه')),
                    ...accounts.map((a) => DropdownMenuItem(value: a.id, child: Text(a.name, overflow: TextOverflow.ellipsis))),
                  ],
                  onChanged: (v) => setState(() => accountFilter = v),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SegmentedButton<TxType?>(
            segments: const [
              ButtonSegment(value: null, label: Text('همه')),
              ButtonSegment(value: TxType.income, label: Text('درآمد')),
              ButtonSegment(value: TxType.expense, label: Text('هزینه')),
            ],
            selected: {typeFilter},
            onSelectionChanged: (s) => setState(() => typeFilter = s.first),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('خلاصه (${currentTx.length} تراکنش)', style: Theme.of(context).textTheme.titleMedium),
                  const Divider(),
                  if (typeFilter != TxType.expense) comparisonRow('درآمد', curIncome, prevIncome, higherIsBad: false),
                  if (typeFilter != TxType.income) comparisonRow('هزینه', curExpense, prevExpense, higherIsBad: true),
                  if (typeFilter == null)
                    comparisonRow('خالص', curIncome - curExpense, prevIncome - prevExpense, higherIsBad: false),
                ],
              ),
            ),
          ),
          if (byCategory.isNotEmpty && typeFilter != TxType.income) ...[
            const SizedBox(height: 16),
            Text('هزینه بر اساس دسته‌بندی', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ...byCategory.map((e) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(e.key.name),
                          Text(ltr(formatMoney(e.value, primaryCurrency)), style: const TextStyle(fontWeight: FontWeight.w600)),
                        ],
                      ),
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: maxCategoryAmount > 0 ? e.value / maxCategoryAmount : 0,
                          minHeight: 6,
                          backgroundColor: Colors.grey.withValues(alpha: 0.2),
                          color: Colors.indigo.shade300,
                        ),
                      ),
                    ],
                  ),
                )),
          ],
        ],
      ),
    );
  }
}

// ============================== Expense forecast ==============================

const _gregorianMonthNames = [
  'ژانویه',
  'فوریه',
  'مارس',
  'آوریل',
  'مه',
  'ژوئن',
  'ژوئیه',
  'اوت',
  'سپتامبر',
  'اکتبر',
  'نوامبر',
  'دسامبر',
];

class ForecastScreen extends StatefulWidget {
  const ForecastScreen({super.key});
  @override
  State<ForecastScreen> createState() => _ForecastScreenState();
}

class _ForecastScreenState extends State<ForecastScreen> {
  bool loading = true;
  List<Transaction> tx = [];
  List<Category> categories = [];
  List<Account> accounts = [];
  late int targetMonth;

  @override
  void initState() {
    super.initState();
    targetMonth = DateTime.now().month;
    _load();
  }

  Future<void> _load() async {
    tx = await Store.loadTransactions();
    categories = await Store.loadCategories();
    accounts = await Store.loadAccounts();
    setState(() => loading = false);
  }

  String currencyOf(String accountId) {
    final m = accounts.where((a) => a.id == accountId).toList();
    return m.isEmpty ? 'EUR' : m.first.currency;
  }

  String get primaryCurrency {
    if (accounts.isEmpty) return 'EUR';
    final counts = <String, int>{};
    for (final a in accounts) {
      counts[a.currency] = (counts[a.currency] ?? 0) + 1;
    }
    return (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final currency = primaryCurrency;
    final now = DateTime.now();

    // Only count a past occurrence of the target month if that whole month
    // has already elapsed - an in-progress month would unfairly drag the
    // average down.
    final years = <int>{};
    for (final t in tx) {
      if (t.type != TxType.expense) continue;
      if (t.date.month != targetMonth) continue;
      final monthEnd = DateTime(t.date.year, t.date.month + 1, 0);
      if (monthEnd.isAfter(now)) continue;
      years.add(t.date.year);
    }

    final yearTotal = <int, double>{};
    final categoryYearTotal = <String, Map<int, double>>{};
    for (final t in tx) {
      if (t.type != TxType.expense) continue;
      if (t.date.month != targetMonth) continue;
      if (!years.contains(t.date.year)) continue;
      if (currencyOf(t.accountId) != currency) continue;
      yearTotal[t.date.year] = (yearTotal[t.date.year] ?? 0) + t.amount;
      final match = categories.where((c) => c.id == t.categoryId).toList();
      var cat = match.isEmpty ? null : match.first;
      while (cat?.parentId != null) {
        final pm = categories.where((c) => c.id == cat!.parentId).toList();
        if (pm.isEmpty) break;
        cat = pm.first;
      }
      final key = cat?.id ?? '_uncategorized_';
      categoryYearTotal.putIfAbsent(key, () => {});
      categoryYearTotal[key]![t.date.year] = (categoryYearTotal[key]![t.date.year] ?? 0) + t.amount;
    }

    final avgTotal = years.isEmpty ? 0.0 : yearTotal.values.fold(0.0, (a, b) => a + b) / years.length;
    final categoryAverages = <Category, double>{};
    categoryYearTotal.forEach((id, yearMap) {
      final avg = yearMap.values.fold(0.0, (a, b) => a + b) / years.length;
      final match = categories.where((c) => c.id == id).toList();
      categoryAverages[match.isEmpty ? Category(id: id, name: 'بدون‌دسته', type: TxType.expense) : match.first] = avg;
    });
    final sortedCategories = categoryAverages.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    final maxCategoryAvg = sortedCategories.isEmpty ? 0.0 : sortedCategories.first.value;

    // What's actually spent so far, if the target month is the current
    // (in-progress) month - useful as a live comparison point.
    double? spentSoFar;
    if (targetMonth == now.month) {
      spentSoFar = tx
          .where((t) =>
              t.type == TxType.expense && t.date.year == now.year && t.date.month == now.month && currencyOf(t.accountId) == currency)
          .fold<double>(0.0, (s, t) => s + t.amount);
    }

    return Scaffold(
      appBar: AppBar(title: Text(tr('expense_forecast'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('ماه مورد نظر برای پیش‌بینی:', style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var m = 1; m <= 12; m++)
                ChoiceChip(
                  label: Text(_gregorianMonthNames[m - 1]),
                  selected: targetMonth == m,
                  onSelected: (_) => setState(() => targetMonth = m),
                ),
            ],
          ),
          const SizedBox(height: 20),
          if (years.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'برای این ماه، داده‌ی کافی از سال‌های قبل ثبت نشده تا بشه پیش‌بینی کرد.',
                style: TextStyle(color: Colors.grey),
              ),
            )
          else ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'میانگین هزینه‌ی ${_gregorianMonthNames[targetMonth - 1]} بر اساس ${years.length} سال گذشته',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(ltr(formatMoney(avgTotal, currency)), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
                    if (spentSoFar != null) ...[
                      const Divider(height: 24),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('هزینه‌ی این ماه تا الان'),
                          Text(ltr(formatMoney(spentSoFar, currency)), style: const TextStyle(fontWeight: FontWeight.bold)),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        spentSoFar > avgTotal
                            ? 'تا الان بیشتر از میانگین سال‌های قبل خرج شده.'
                            : 'تا الان کمتر از میانگین سال‌های قبل خرج شده.',
                        style: TextStyle(fontSize: 12, color: spentSoFar > avgTotal ? Colors.red.shade700 : Colors.green.shade700),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (sortedCategories.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text('میانگین بر اساس دسته‌بندی', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              ...sortedCategories.map((e) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(e.key.name),
                            Text(ltr(formatMoney(e.value, currency)), style: const TextStyle(fontWeight: FontWeight.w600)),
                          ],
                        ),
                        const SizedBox(height: 4),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: maxCategoryAvg > 0 ? e.value / maxCategoryAvg : 0,
                            minHeight: 6,
                            backgroundColor: Colors.grey.shade200,
                          ),
                        ),
                      ],
                    ),
                  )),
            ],
          ],
        ],
      ),
    );
  }
}

// ============================== Month calendar summary ==============================

class MonthCalendarScreen extends StatefulWidget {
  const MonthCalendarScreen({super.key});
  @override
  State<MonthCalendarScreen> createState() => _MonthCalendarScreenState();
}

class _MonthCalendarScreenState extends State<MonthCalendarScreen> {
  bool loading = true;
  List<Transaction> tx = [];
  List<Account> accounts = [];
  List<Category> categories = [];
  late DateTime month;
  String? accountFilter;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    month = DateTime(now.year, now.month, 1);
    _load();
  }

  Future<void> _load() async {
    tx = await Store.loadTransactions();
    accounts = await Store.loadAccounts();
    categories = await Store.loadCategories();
    setState(() => loading = false);
  }

  String currencyOf(String accountId) {
    final m = accounts.where((a) => a.id == accountId).toList();
    return m.isEmpty ? 'EUR' : m.first.currency;
  }

  String categoryName(String id) {
    final m = categories.where((c) => c.id == id).toList();
    return m.isEmpty ? 'بدون‌دسته' : m.first.name;
  }

  Future<void> _showDayTransactions(DateTime date) async {
    final dayTx = tx
        .where((t) =>
            t.date.year == date.year &&
            t.date.month == date.month &&
            t.date.day == date.day &&
            (accountFilter == null || t.accountId == accountFilter))
        .toList();
    if (dayTx.isEmpty) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        builder: (ctx, scrollController) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(formatDate(date), style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 12),
              Expanded(
                child: ListView.builder(
                  controller: scrollController,
                  itemCount: dayTx.length,
                  itemBuilder: (context, i) {
                    final t = dayTx[i];
                    return Card(
                      child: ListTile(
                        title: Text(categoryName(t.categoryId)),
                        subtitle: t.note.isNotEmpty ? Text(t.note, maxLines: 1, overflow: TextOverflow.ellipsis) : null,
                        trailing: Text(
                          ltr(t.type == TxType.income ? '+' : '-') + formatMoney(t.amount, currencyOf(t.accountId)),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: t.type == TxType.income ? Colors.green.shade700 : Colors.red.shade700,
                          ),
                        ),
                        onTap: () async {
                          Navigator.pop(ctx);
                          await Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => TransactionEditor(categories: categories, accounts: accounts, existing: t)),
                          );
                          await _load();
                        },
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String get primaryCurrency {
    if (accountFilter != null) return currencyOf(accountFilter!);
    if (accounts.isEmpty) return 'EUR';
    final counts = <String, int>{};
    for (final a in accounts) {
      counts[a.currency] = (counts[a.currency] ?? 0) + 1;
    }
    return (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final currency = primaryCurrency;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final dayIncome = <int, double>{};
    final dayExpense = <int, double>{};
    final dayIncomeProjected = <int, double>{};
    final dayExpenseProjected = <int, double>{};
    for (final e in occurrencesWithRecurringProjections(tx, horizonDays: 400)) {
      if (accountFilter != null ? e.t.accountId != accountFilter : currencyOf(e.t.accountId) != currency) continue;
      if (e.date.year != month.year || e.date.month != month.month) continue;
      final notYetDue = e.date.isAfter(today);
      if (e.t.type == TxType.income) {
        if (notYetDue) {
          dayIncomeProjected[e.date.day] = (dayIncomeProjected[e.date.day] ?? 0) + e.t.amount;
        } else {
          dayIncome[e.date.day] = (dayIncome[e.date.day] ?? 0) + e.t.amount;
        }
      } else {
        if (notYetDue) {
          dayExpenseProjected[e.date.day] = (dayExpenseProjected[e.date.day] ?? 0) + e.t.amount;
        } else {
          dayExpense[e.date.day] = (dayExpense[e.date.day] ?? 0) + e.t.amount;
        }
      }
    }

    double dueIncome = 0, dueExpense = 0, plannedIncome = 0, plannedExpense = 0;
    for (var d = 1; d <= daysInMonth; d++) {
      dueIncome += dayIncome[d] ?? 0;
      dueExpense += dayExpense[d] ?? 0;
      plannedIncome += dayIncomeProjected[d] ?? 0;
      plannedExpense += dayExpenseProjected[d] ?? 0;
    }

    // DateTime.weekday: Monday=1 .. Sunday=7. Grid starts on Saturday
    // (common start-of-week for a Persian-speaking audience): map so
    // Saturday=0 .. Friday=6.
    final firstWeekday = DateTime(month.year, month.month, 1).weekday; // 1..7, Mon..Sun
    final leadingBlanks = (firstWeekday + 1) % 7; // Sat=6->0, Sun=7->1, Mon=1->2, ... Fri=5->6

    return Scaffold(
      appBar: AppBar(title: Text(tr('month_calendar'))),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back_ios, size: 18),
                  tooltip: 'ماه بعد',
                  onPressed: () => setState(() => month = DateTime(month.year, month.month + 1, 1)),
                ),
                Text('${_gregorianMonthNames[month.month - 1]} ${month.year}', style: Theme.of(context).textTheme.titleLarge),
                IconButton(
                  icon: const Icon(Icons.arrow_forward_ios, size: 18),
                  tooltip: 'ماه قبل',
                  onPressed: () => setState(() => month = DateTime(month.year, month.month - 1, 1)),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: DropdownButtonFormField<String?>(
              initialValue: accountFilter,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'حساب', border: OutlineInputBorder(), isDense: true),
              items: [
                DropdownMenuItem(value: null, child: Text(tr('all_accounts'))),
                ...accounts.map((a) => DropdownMenuItem(value: a.id, child: Text('${a.name} (${a.currency})'))),
              ],
              onChanged: (v) => setState(() => accountFilter = v),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('جمع تا امروز', style: TextStyle(fontWeight: FontWeight.bold)),
                        Row(
                          children: [
                            Text(ltr('+${formatMoney(dueIncome, currency)}'),
                                style: const TextStyle(fontSize: 12, color: Colors.green, fontWeight: FontWeight.w600)),
                            const SizedBox(width: 8),
                            Text(ltr('-${formatMoney(dueExpense, currency)}'),
                                style: const TextStyle(fontSize: 12, color: Colors.red, fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ],
                    ),
                    if (plannedIncome > 0 || plannedExpense > 0) ...[
                      const SizedBox(height: 4),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('جمع سررسیدنشده', style: TextStyle(color: Colors.grey.shade600)),
                          Row(
                            children: [
                              Text(ltr('+${formatMoney(plannedIncome, currency)}'),
                                  style: TextStyle(fontSize: 12, color: Colors.green.shade200, fontWeight: FontWeight.w600)),
                              const SizedBox(width: 8),
                              Text(ltr('-${formatMoney(plannedExpense, currency)}'),
                                  style: TextStyle(fontSize: 12, color: Colors.red.shade200, fontWeight: FontWeight.w600)),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: ['ش', 'ی', 'د', 'س', 'چ', 'پ', 'ج']
                  .map((d) => Expanded(child: Center(child: Text(d, style: TextStyle(color: Colors.grey.shade600, fontSize: 12)))))
                  .toList(),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: GridView.builder(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 7, childAspectRatio: 0.72),
                itemCount: leadingBlanks + daysInMonth,
                itemBuilder: (context, index) {
                  if (index < leadingBlanks) return const SizedBox.shrink();
                  final day = index - leadingBlanks + 1;
                  final date = DateTime(month.year, month.month, day);
                  final future = date.isAfter(today);
                  final isToday = date.year == today.year && date.month == today.month && date.day == today.day;
                  final inc = (dayIncome[day] ?? 0) + (dayIncomeProjected[day] ?? 0);
                  final exp = (dayExpense[day] ?? 0) + (dayExpenseProjected[day] ?? 0);
                  return InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => _showDayTransactions(date),
                    child: Container(
                    margin: const EdgeInsets.all(2),
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    decoration: BoxDecoration(
                      color: isToday ? Colors.indigo.shade50 : null,
                      border: Border.all(color: isToday ? Colors.indigo.shade200 : Colors.grey.shade200),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.start,
                      children: [
                        Text(
                          ltr(persianDigits('$day')),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: future ? Colors.grey.shade400 : null,
                          ),
                        ),
                        if (exp > 0)
                          Text(
                            ltr('-${exp.toStringAsFixed(0)}'),
                            style: TextStyle(fontSize: 9, color: future ? Colors.red.shade200 : Colors.red.shade700),
                          ),
                        if (inc > 0)
                          Text(
                            ltr('+${inc.toStringAsFixed(0)}'),
                            style: TextStyle(fontSize: 9, color: future ? Colors.green.shade200 : Colors.green.shade700),
                          ),
                      ],
                    ),
                  ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class BackupRestoreScreen extends StatefulWidget {
  const BackupRestoreScreen({super.key});
  @override
  State<BackupRestoreScreen> createState() => _BackupRestoreScreenState();
}

class _BackupRestoreScreenState extends State<BackupRestoreScreen> {
  bool busy = false;

  Future<void> _backup() async {
    setState(() => busy = true);
    try {
      final path = await _buildBackupFile();
      await Share.shareXFiles([XFile(path)], text: 'نسخه‌ی پشتیبان مدیریت مالی شخصی');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('خطا: $e')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _exportExcel() async {
    setState(() => busy = true);
    try {
      final path = await _buildExcelFile();
      await Share.shareXFiles([XFile(path)], text: 'خروجی اکسل تراکنش‌ها');
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('خطا: $e')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _restore() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['json']);
    if (result == null || result.files.single.path == null) return;
    if (!context.mounted) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('بازیابی نسخه‌ی پشتیبان'),
        content: const Text(
          'همه‌ی اطلاعات فعلی برنامه (تراکنش‌ها، دسته‌بندی‌ها، حساب‌ها) با محتوای این فایل جایگزین می‌شود. این کار قابل بازگشت نیست. ادامه می‌دهید؟',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('بازیابی')),
        ],
      ),
    );
    if (confirm != true) return;
    setState(() => busy = true);
    try {
      final content = await File(result.files.single.path!).readAsString();
      final data = jsonDecode(content) as Map<String, dynamic>;
      await Store.restoreBackupData(data);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('بازیابی با موفقیت انجام شد.')));
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('خطا در بازیابی: $e')));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('backup_restore_title'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: ListTile(
              leading: const Icon(Icons.cloud_upload_outlined),
              title: const Text('تهیه‌ی نسخه‌ی پشتیبان'),
              subtitle: const Text('خروجی کامل تراکنش‌ها، دسته‌بندی‌ها و حساب‌ها'),
              trailing: busy
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.chevron_left),
              onTap: busy ? null : _backup,
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.cloud_download_outlined),
              title: const Text('بازیابی از نسخه‌ی پشتیبان'),
              subtitle: const Text('جایگزینی اطلاعات فعلی با یک فایل پشتیبان'),
              trailing: busy ? null : const Icon(Icons.chevron_left),
              onTap: busy ? null : _restore,
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.table_chart_outlined),
              title: const Text('خروجی اکسل'),
              subtitle: const Text('خروجی تراکنش‌ها به فایل اکسل'),
              trailing: busy ? null : const Icon(Icons.chevron_left),
              onTap: busy ? null : _exportExcel,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================== Transaction editor ==============================

const _weekdayNames = ['دوشنبه', 'سه‌شنبه', 'چهارشنبه', 'پنجشنبه', 'جمعه', 'شنبه', 'یکشنبه'];

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
        throw Exception('فایل تصویر خوانده نشد. لطفاً دوباره امتحان کنید.');
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
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('خطا: $e')));
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
              label: Text(tr('camera'), softWrap: false, overflow: TextOverflow.visible),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: OutlinedButton.icon(
              style: style,
              onPressed: busy ? null : () => _process(isPayslip, ScanSource.gallery),
              icon: const Icon(Icons.photo_library, size: 18),
              label: Text(tr('gallery'), softWrap: false, overflow: TextOverflow.visible),
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
      appBar: AppBar(title: Text(tr('scan_title'))),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _section('رسید جدید', 'تشخیص آفلاین + امکان بهبود با هوش مصنوعی', Icons.receipt_long, false),
              const SizedBox(height: 16),
              _section('فیش حقوقی جدید', 'استخراج Brutto/Netto، مالیات، بیمه و کلاس مالیاتی', Icons.badge_outlined, true),
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
                      children: [CircularProgressIndicator(), SizedBox(height: 12), Text('در حال تشخیص متن...')],
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
  String? lastGeminiErrorDetail;
  bool hasGeminiKey = false;
  bool? keepReceipt;
  String? keepReceiptReason;
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
              warrantyUntil: e['warrantyUntil'] != null ? DateTime.tryParse(e['warrantyUntil'].toString()) : null,
              returnUntil: e['returnUntil'] != null ? DateTime.tryParse(e['returnUntil'].toString()) : null,
              warrantyNote: e['warrantyNote']?.toString(),
            );
          }).where((e) => e.name.trim().isNotEmpty).toList();
        }
        if (result['keepReceipt'] is bool) keepReceipt = result['keepReceipt'] as bool;
        if (result['keepReceiptReason'] != null) keepReceiptReason = result['keepReceiptReason'].toString();
        final matched = _matchCategoryHint(result['category']?.toString(), categories, TxType.expense);
        if (matched != null) selectedCategory = matched;
      }
    } catch (e) {
      geminiFailed = true;
      lastGeminiErrorDetail = e is GeminiException ? e.rawDetail : e.toString();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('خواندن هوشمند ممکن نشد. دوباره امتحان کنید یا دستی تکمیل کنید.'),
          duration: const Duration(seconds: 6),
          action: SnackBarAction(label: 'جزئیات خطا', onPressed: () => _showGeminiErrorDetail(context)),
        ));
      }
    } finally {
      if (mounted) setState(() => improving = false);
    }
  }

  void _showGeminiErrorDetail(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('جزئیات خطای هوش مصنوعی'),
        content: SingleChildScrollView(
          child: SelectableText(lastGeminiErrorDetail ?? 'جزئیاتی موجود نیست.'),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: lastGeminiErrorDetail ?? ''));
              ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('کپی شد.')));
            },
            child: const Text('کپی'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('cancel'))),
        ],
      ),
    );
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
    final warrantyCtrl = TextEditingController(text: existing?.warrantyNote ?? '');
    final added = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(editIndex == null ? 'افزودن کالا' : 'ویرایش کالا'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: nameCtrl, decoration: InputDecoration(labelText: tr('item_name')), autofocus: true),
              const SizedBox(height: 8),
              TextField(controller: qtyCtrl, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: tr('quantity'))),
              const SizedBox(height: 8),
              TextField(controller: priceCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: tr('price'))),
              const SizedBox(height: 8),
              TextField(
                controller: warrantyCtrl,
                decoration: const InputDecoration(labelText: 'یادداشت گارانتی/مرجوعی (اختیاری)', border: OutlineInputBorder()),
                maxLines: 2,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(editIndex == null ? 'افزودن' : 'ذخیره')),
        ],
      ),
    );
    if (added != true || nameCtrl.text.trim().isEmpty) return;
    final entry = ReceiptItemEntry(
      name: nameCtrl.text.trim(),
      quantity: double.tryParse(qtyCtrl.text.replaceAll(',', '.')),
      price: double.tryParse(priceCtrl.text.replaceAll(',', '.')),
      warrantyUntil: existing?.warrantyUntil,
      returnUntil: existing?.returnUntil,
      warrantyNote: warrantyCtrl.text.trim().isEmpty ? null : warrantyCtrl.text.trim(),
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('مبلغ کل معتبر وارد کنید.')));
      return;
    }
    if (!draft && selectedCategory == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('برای ثبت نهایی، دسته‌بندی را انتخاب کنید.')));
      return;
    }
    if (!draft && selectedAccount == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('برای ثبت نهایی، حساب را انتخاب کنید.')));
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
          title: const Text('تراکنش مشابه'),
          content: const Text('یک تراکنش با همین مبلغ و تاریخ قبلاً ثبت شده. این ممکن است اسکن تکراری همین رسید باشد. باز هم ثبت شود؟'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('بله، ثبت شود')),
          ],
        ),
      );
      if (proceed != true) return;
    }
    if (!context.mounted) return;
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    String? persistedImage;
    if (draft) {
      try {
        persistedImage = await persistDraftImage(widget.imagePath, id);
      } catch (_) {
        // best-effort only - saving the draft itself matters more than the image copy
      }
    }
    final result = Transaction(
      id: id,
      type: TxType.expense,
      amount: total,
      categoryId: selectedCategory?.id ?? '_uncategorized_',
      accountId: selectedAccount?.id ?? 'default',
      date: date,
      note: merchantCtrl.text.trim(),
      draft: draft,
      items: items,
      imagePath: persistedImage,
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
      appBar: AppBar(title: Text(tr('review_receipt'))),
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
              label: Text(improving ? 'در حال بهبود...' : (geminiFailed ? 'تلاش مجدد با هوش مصنوعی' : 'بهبود با هوش مصنوعی')),
            )
          else
            InkWell(
              onTap: () async {
                await Navigator.push(context, MaterialPageRoute(builder: (_) => const GeminiSettingsScreen()));
                final key = await Store.loadGeminiKey();
                if (!mounted) return;
                setState(() => hasGeminiKey = key != null && key.trim().isNotEmpty);
              },
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 16, color: Colors.grey),
                    SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'برای بهبود دقت با هوش مصنوعی، یک کلید Gemini در «تنظیمات › هوش مصنوعی (Gemini)» وارد کنید.',
                        style: TextStyle(color: Colors.grey, fontSize: 12, decoration: TextDecoration.underline),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (geminiFailed)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'خواندن هوشمند ممکن نشد.',
                      style: TextStyle(color: Colors.orange, fontSize: 12),
                    ),
                  ),
                  TextButton(
                    onPressed: () => _showGeminiErrorDetail(context),
                    child: const Text('جزئیات خطا', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 16),
          TextField(controller: merchantCtrl, decoration: const InputDecoration(labelText: 'فروشگاه', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(
            controller: totalCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'مبلغ کل', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          ListTile(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: Colors.grey.shade400)),
            title: Text('تاریخ: ${formatDate(date)}'),
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
            title: Text(selectedCategory?.name ?? tr('select_category')),
            trailing: const Icon(Icons.chevron_left),
            onTap: _pickCategory,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<Account>(
            initialValue: selectedAccount,
            decoration: InputDecoration(labelText: tr('account'), border: const OutlineInputBorder()),
            items: accounts.map((a) => DropdownMenuItem(value: a, child: Text('${a.name} (${a.currency})'))).toList(),
            onChanged: (v) => setState(() => selectedAccount = v),
          ),
          const SizedBox(height: 16),
          if (keepReceipt != null)
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: keepReceipt! ? Colors.amber.shade50 : Colors.green.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: keepReceipt! ? Colors.amber.shade200 : Colors.green.shade200),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    keepReceipt! ? Icons.receipt_long : Icons.check_circle_outline,
                    color: keepReceipt! ? Colors.amber.shade800 : Colors.green.shade800,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          keepReceipt! ? 'بهتر است فیش را نگه دارید' : 'نیازی به نگه‌داشتن فیش نیست',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: keepReceipt! ? Colors.amber.shade900 : Colors.green.shade900,
                          ),
                        ),
                        if (keepReceiptReason != null) ...[
                          const SizedBox(height: 2),
                          Text(keepReceiptReason!, style: const TextStyle(fontSize: 12)),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(tr('items'), style: Theme.of(context).textTheme.titleMedium),
              TextButton.icon(onPressed: _addItemRow, icon: const Icon(Icons.add), label: Text(tr('add'))),
            ],
          ),
          if (items.isEmpty)
            Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(tr('no_items_yet'), style: const TextStyle(color: Colors.grey))),
          ...items.asMap().entries.map((e) {
            final i = e.key;
            final it = e.value;
            return Card(
              child: ListTile(
                dense: true,
                title: Text(it.name),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${it.quantity != null ? 'تعداد: ${ltr(it.quantity!.toStringAsFixed(it.quantity! % 1 == 0 ? 0 : 2))}' : ''}'
                      '${it.quantity != null && it.price != null ? ' • ' : ''}'
                      '${it.price != null ? ltr('€${it.price!.toStringAsFixed(2)}') : ''}',
                    ),
                    if (it.hasWarrantyInfo) ...[
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          if (it.warrantyUntil != null)
                            Chip(
                              avatar: const Icon(Icons.verified_outlined, size: 14),
                              label: Text('گارانتی تا ${ltr(persianDigits(DateFormat('yyyy-MM-dd').format(it.warrantyUntil!)))}', style: const TextStyle(fontSize: 11)),
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              backgroundColor: Colors.blue.shade50,
                            ),
                          if (it.returnUntil != null)
                            Chip(
                              avatar: const Icon(Icons.assignment_return_outlined, size: 14),
                              label: Text('مرجوعی تا ${ltr(persianDigits(DateFormat('yyyy-MM-dd').format(it.returnUntil!)))}', style: const TextStyle(fontSize: 11)),
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              backgroundColor: Colors.orange.shade50,
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
                isThreeLine: it.hasWarrantyInfo,
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
              Expanded(child: OutlinedButton(onPressed: () => _save(draft: true), child: const Text('ذخیره پیش‌نویس'))),
              const SizedBox(width: 8),
              Expanded(child: FilledButton(onPressed: () => _save(draft: false), child: const Text('تأیید و ثبت نهایی'))),
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
  'brutto': 'حقوق ناخالص',
  'netto': 'حقوق خالص',
  'depositedAmount': 'مبلغ واریز شده به حساب',
  'lohnsteuer': 'مالیات بر درآمد',
  'solidaritaetszuschlag': 'مالیات همبستگی',
  'kirchensteuer': 'مالیات کلیسا',
  'krankenversicherung': 'بیمه درمانی',
  'pflegeversicherung': 'بیمه مراقبت',
  'rentenversicherung': 'بیمه بازنشستگی',
  'arbeitslosenversicherung': 'بیمه بیکاری',
  'vermoegenswirksameLeistungen': 'مزایای پس‌انداز (VL)',
  'betrieblicheAltersvorsorge': 'بازنشستگی تکمیلی کارفرما',
  'vorschuss': 'پیش‌پرداخت کسرشده',
  'sonstigeAbzuege': 'سایر کسورات',
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
  String? lastGeminiErrorDetail;
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
      lastGeminiErrorDetail = e is GeminiException ? e.rawDetail : e.toString();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('خواندن هوشمند ممکن نشد. دوباره امتحان کنید یا دستی تکمیل کنید.'),
          duration: const Duration(seconds: 6),
          action: SnackBarAction(label: 'جزئیات خطا', onPressed: () => _showGeminiErrorDetail(context)),
        ));
      }
    } finally {
      if (mounted) setState(() => improving = false);
    }
  }

  void _showGeminiErrorDetail(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('جزئیات خطای هوش مصنوعی'),
        content: SingleChildScrollView(
          child: SelectableText(lastGeminiErrorDetail ?? 'جزئیاتی موجود نیست.'),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: lastGeminiErrorDetail ?? ''));
              ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('کپی شد.')));
            },
            child: const Text('کپی'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('cancel'))),
        ],
      ),
    );
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('مبلغ Netto معتبر وارد کنید.')));
      return;
    }
    final depositedAmount = double.tryParse(numCtrls['depositedAmount']!.text.replaceAll(',', '.'));
    // The actual amount credited to the account can differ from netto (e.g.
    // advances or other payroll-side deductions) - prefer it when present.
    final transactionAmount = (depositedAmount != null && depositedAmount > 0) ? depositedAmount : netto;
    if (!draft && selectedCategory == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('برای ثبت نهایی، دسته‌بندی را انتخاب کنید.')));
      return;
    }
    if (!draft && selectedAccount == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('برای ثبت نهایی، حساب را انتخاب کنید.')));
      return;
    }
    double? num_(String k) => double.tryParse(numCtrls[k]!.text.trim().replaceAll(',', '.'));
    final details = PayslipDetails(
      brutto: num_('brutto'),
      netto: num_('netto'),
      depositedAmount: num_('depositedAmount'),
      lohnsteuer: num_('lohnsteuer'),
      solidaritaetszuschlag: num_('solidaritaetszuschlag'),
      kirchensteuer: num_('kirchensteuer'),
      krankenversicherung: num_('krankenversicherung'),
      pflegeversicherung: num_('pflegeversicherung'),
      rentenversicherung: num_('rentenversicherung'),
      arbeitslosenversicherung: num_('arbeitslosenversicherung'),
      vermoegenswirksameLeistungen: num_('vermoegenswirksameLeistungen'),
      betrieblicheAltersvorsorge: num_('betrieblicheAltersvorsorge'),
      vorschuss: num_('vorschuss'),
      sonstigeAbzuege: num_('sonstigeAbzuege'),
      steuerklasse: steuerklasseCtrl.text.trim().isEmpty ? null : steuerklasseCtrl.text.trim(),
      arbeitgeber: arbeitgeberCtrl.text.trim().isEmpty ? null : arbeitgeberCtrl.text.trim(),
      abrechnungsmonat: monatCtrl.text.trim().isEmpty ? null : monatCtrl.text.trim(),
    );
    final duplicate = existingTx.any((t) =>
        t.type == TxType.income &&
        (t.amount - transactionAmount).abs() < 0.01 &&
        t.date.year == date.year &&
        t.date.month == date.month &&
        t.date.day == date.day);
    if (duplicate) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('تراکنش مشابه'),
          content: const Text('یک تراکنش با همین مبلغ و تاریخ قبلاً ثبت شده. این ممکن است اسکن تکراری همین فیش باشد. باز هم ثبت شود؟'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('بله، ثبت شود')),
          ],
        ),
      );
      if (proceed != true) return;
    }
    if (!context.mounted) return;
    final id = DateTime.now().microsecondsSinceEpoch.toString();
    String? persistedImage;
    if (draft) {
      try {
        persistedImage = await persistDraftImage(widget.imagePath, id);
      } catch (_) {
        // best-effort only - saving the draft itself matters more than the image copy
      }
    }
    final result = Transaction(
      id: id,
      type: TxType.income,
      amount: transactionAmount,
      categoryId: selectedCategory?.id ?? '_uncategorized_',
      accountId: selectedAccount?.id ?? 'default',
      date: date,
      note: '',
      draft: draft,
      payslipDetails: details,
      imagePath: persistedImage,
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
      appBar: AppBar(title: Text(tr('review_payslip'))),
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
              label: Text(improving ? 'در حال بهبود...' : (geminiFailed ? 'تلاش مجدد با هوش مصنوعی' : 'بهبود با هوش مصنوعی')),
            )
          else
            InkWell(
              onTap: () async {
                await Navigator.push(context, MaterialPageRoute(builder: (_) => const GeminiSettingsScreen()));
                final key = await Store.loadGeminiKey();
                if (!mounted) return;
                setState(() => hasGeminiKey = key != null && key.trim().isNotEmpty);
              },
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 16, color: Colors.grey),
                    SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'برای بهبود دقت با هوش مصنوعی، یک کلید Gemini در «تنظیمات › هوش مصنوعی (Gemini)» وارد کنید.',
                        style: TextStyle(color: Colors.grey, fontSize: 12, decoration: TextDecoration.underline),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (geminiFailed)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'خواندن هوشمند ممکن نشد.',
                      style: TextStyle(color: Colors.orange, fontSize: 12),
                    ),
                  ),
                  TextButton(
                    onPressed: () => _showGeminiErrorDetail(context),
                    child: const Text('جزئیات خطا', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 16),
          TextField(controller: arbeitgeberCtrl, decoration: const InputDecoration(labelText: 'کارفرما', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(controller: monatCtrl, decoration: const InputDecoration(labelText: 'ماه', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(controller: steuerklasseCtrl, decoration: const InputDecoration(labelText: 'کلاس مالیاتی', border: OutlineInputBorder())),
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
            title: Text('تاریخ: ${formatDate(date)}'),
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
            title: Text(selectedCategory?.name ?? tr('select_category')),
            trailing: const Icon(Icons.chevron_left),
            onTap: _pickCategory,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<Account>(
            initialValue: selectedAccount,
            decoration: InputDecoration(labelText: tr('account'), border: const OutlineInputBorder()),
            items: accounts.map((a) => DropdownMenuItem(value: a, child: Text('${a.name} (${a.currency})'))).toList(),
            onChanged: (v) => setState(() => selectedAccount = v),
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(child: OutlinedButton(onPressed: () => _save(draft: true), child: const Text('ذخیره پیش‌نویس'))),
              const SizedBox(width: 8),
              Expanded(child: FilledButton(onPressed: () => _save(draft: false), child: const Text('تأیید و ثبت نهایی'))),
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
          'depositedAmount': pd.depositedAmount,
          'lohnsteuer': pd.lohnsteuer,
          'solidaritaetszuschlag': pd.solidaritaetszuschlag,
          'kirchensteuer': pd.kirchensteuer,
          'krankenversicherung': pd.krankenversicherung,
          'pflegeversicherung': pd.pflegeversicherung,
          'rentenversicherung': pd.rentenversicherung,
          'arbeitslosenversicherung': pd.arbeitslosenversicherung,
          'vermoegenswirksameLeistungen': pd.vermoegenswirksameLeistungen,
          'betrieblicheAltersvorsorge': pd.betrieblicheAltersvorsorge,
          'vorschuss': pd.vorschuss,
          'sonstigeAbzuege': pd.sonstigeAbzuege,
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('مبلغ معتبر وارد کنید.')));
      return false;
    }
    if (selectedCategory == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('یک دسته‌بندی انتخاب کنید.')));
      return false;
    }
    if (selectedAccount == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('یک حساب انتخاب کنید.')));
      return false;
    }
    final existingList = await Store.loadTransactions();
    final duplicate = existingList.any((t) =>
        t.id != widget.existing?.id &&
        t.type == type &&
        (t.amount - amount).abs() < 0.01 &&
        t.date.year == date.year &&
        t.date.month == date.month &&
        t.date.day == date.day &&
        t.categoryId == selectedCategory!.id);
    if (duplicate) {
      if (!context.mounted) return false;
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('تراکنش مشابه'),
          content: const Text('یک تراکنش با همین مبلغ، تاریخ و دسته‌بندی قبلاً ثبت شده. ممکن است این تراکنش تکراری باشد. باز هم ثبت شود؟'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('بله، ثبت شود')),
          ],
        ),
      );
      if (proceed != true) return false;
    }
    int? recDay;
    int? recWeekday;
    int? recInterval;
    int? recInstallments;
    DateTime? recEndDate;
    if (recurrence == RecurrenceFrequency.monthly || recurrence == RecurrenceFrequency.quarterly) {
      recDay = int.tryParse(dayCtrl.text);
      if (recDay == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('روز سررسید در ماه را وارد کنید.')));
        return false;
      }
      if (recDay < 1) recDay = 1;
      if (recDay > 31) recDay = 31;
    } else if (recurrence == RecurrenceFrequency.weekly) {
      recWeekday = weekday;
    } else if (recurrence == RecurrenceFrequency.custom) {
      recInterval = int.tryParse(intervalCtrl.text);
      if (recInterval == null || recInterval <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعداد روز بازه را درست وارد کنید.')));
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
          depositedAmount: num_('depositedAmount'),
          lohnsteuer: num_('lohnsteuer'),
          solidaritaetszuschlag: num_('solidaritaetszuschlag'),
          kirchensteuer: num_('kirchensteuer'),
          krankenversicherung: num_('krankenversicherung'),
          pflegeversicherung: num_('pflegeversicherung'),
          rentenversicherung: num_('rentenversicherung'),
          arbeitslosenversicherung: num_('arbeitslosenversicherung'),
          vermoegenswirksameLeistungen: num_('vermoegenswirksameLeistungen'),
          betrieblicheAltersvorsorge: num_('betrieblicheAltersvorsorge'),
          vorschuss: num_('vorschuss'),
          sonstigeAbzuege: num_('sonstigeAbzuege'),
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
    // Scheduling/cancelling reminders doesn't need to block the save flow -
    // let it run in the background so the screen closes immediately.
    if (notifyEnabled) {
      unawaited(NotificationService.instance.scheduleForTransaction(result, selectedCategory!.name));
    } else {
      unawaited(NotificationService.instance.cancelForTransaction(result.id));
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
    final warrantyCtrl = TextEditingController(text: existing?.warrantyNote ?? '');
    final added = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(editIndex == null ? 'افزودن کالا' : 'ویرایش کالا'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: nameCtrl, decoration: InputDecoration(labelText: tr('item_name')), autofocus: true),
              const SizedBox(height: 8),
              TextField(controller: qtyCtrl, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: tr('quantity'))),
              const SizedBox(height: 8),
              TextField(controller: priceCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: tr('price'))),
              const SizedBox(height: 8),
              TextField(
                controller: warrantyCtrl,
                decoration: const InputDecoration(labelText: 'یادداشت گارانتی/مرجوعی (اختیاری)', border: OutlineInputBorder()),
                maxLines: 2,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(editIndex == null ? 'افزودن' : 'ذخیره')),
        ],
      ),
    );
    if (added != true || nameCtrl.text.trim().isEmpty) return;
    final entry = ReceiptItemEntry(
      name: nameCtrl.text.trim(),
      quantity: double.tryParse(qtyCtrl.text.replaceAll(',', '.')),
      price: double.tryParse(priceCtrl.text.replaceAll(',', '.')),
      warrantyUntil: existing?.warrantyUntil,
      returnUntil: existing?.returnUntil,
      warrantyNote: warrantyCtrl.text.trim().isEmpty ? null : warrantyCtrl.text.trim(),
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
          decoration: InputDecoration(labelText: tr('recurrence_type'), border: const OutlineInputBorder()),
          items: const [
            DropdownMenuItem(value: RecurrenceFrequency.none, child: Text('بدون تکرار')),
            DropdownMenuItem(value: RecurrenceFrequency.weekly, child: Text('هفتگی (روز مشخصی از هفته)')),
            DropdownMenuItem(value: RecurrenceFrequency.monthly, child: Text('ماهانه (روز مشخصی از ماه)')),
            DropdownMenuItem(value: RecurrenceFrequency.quarterly, child: Text('فصلی (هر سه ماه)')),
            DropdownMenuItem(value: RecurrenceFrequency.yearly, child: Text('سالانه (در همین تاریخ هر سال)')),
            DropdownMenuItem(value: RecurrenceFrequency.custom, child: Text('بازه‌ی دلخواه (هر N روز)')),
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
              labelText: 'روز سررسید در ماه (۱ تا ۳۱) *',
              helperText: 'برای ماه‌های کوتاه‌تر، به‌صورت خودکار آخرین روز همان ماه در نظر گرفته می‌شود.',
              border: OutlineInputBorder(),
            ),
          ),
        ],
        if (recurrence == RecurrenceFrequency.weekly) ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            initialValue: weekday,
            decoration: InputDecoration(labelText: tr('weekday'), border: const OutlineInputBorder()),
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
            decoration: const InputDecoration(labelText: 'هر چند روز یک‌بار؟', border: OutlineInputBorder()),
          ),
        ],
        if (recurrence != RecurrenceFrequency.none) ...[
          const SizedBox(height: 12),
          Text('پایان تکرار', style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 6),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'unlimited', label: Text('نامحدود')),
              ButtonSegment(value: 'count', label: Text('تعداد قسط')),
              ButtonSegment(value: 'date', label: Text('تا تاریخ')),
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
              title: Text(endDate == null ? 'انتخاب تاریخ آخرین پرداخت' : 'تا: ${formatDate(endDate!)}'),
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
              decoration: InputDecoration(labelText: tr('total_installments'), border: const OutlineInputBorder()),
            ),
          ],
          if (preview != null) ...[
            const SizedBox(height: 8),
            Text(
              'سررسید بعدی: ${formatDate(preview)}',
              style: TextStyle(color: Colors.indigo.shade700, fontWeight: FontWeight.w600),
            ),
          ],
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(tr('installment_reminder')),
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
                title: const Text('یادآوری روز قبل از دو قسط آخر'),
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
                  const Text('یادآوری '),
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
                  const Text(' روز قبل از هر قسط'),
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
              decoration: InputDecoration(
                labelText: tr('reminder_note'),
                hintText: 'مثلاً: یادت نره اشتراک رو کنسل کنی',
                border: const OutlineInputBorder(),
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
        title: Text(widget.existing == null ? 'تراکنش جدید' : 'ویرایش تراکنش'),
        actions: [
          if (widget.existing?.imagePath != null)
            IconButton(
              icon: const Icon(Icons.image_search_outlined),
              tooltip: 'بازبینی تصویر رسید/فیش (اجرای دوباره‌ی هوش مصنوعی)',
              onPressed: () async {
                final existing = widget.existing!;
                Transaction? result;
                if (existing.type == TxType.expense) {
                  final draftInit = ReceiptDraft(
                    merchant: existing.note,
                    date: existing.date,
                    total: existing.amount,
                    items: existing.items,
                    categoryHint: selectedCategory?.name,
                  );
                  result = await Navigator.push<Transaction>(
                    context,
                    MaterialPageRoute(builder: (_) => ReceiptReviewScreen(imagePath: existing.imagePath!, initial: draftInit)),
                  );
                } else {
                  result = await Navigator.push<Transaction>(
                    context,
                    MaterialPageRoute(builder: (_) => PayslipReviewScreen(imagePath: existing.imagePath!, initial: const {})),
                  );
                }
                if (result == null) return;
                if (!context.mounted) return;
                // Keep the same id as the transaction being edited, so
                // saving replaces it instead of creating a duplicate.
                _dirty = false;
                Navigator.pop(
                  context,
                  Transaction(
                    id: existing.id,
                    type: result.type,
                    amount: result.amount,
                    categoryId: result.categoryId,
                    accountId: result.accountId,
                    date: result.date,
                    note: result.note,
                    draft: result.draft,
                    items: result.items,
                    payslipDetails: result.payslipDetails,
                    imagePath: result.imagePath ?? existing.imagePath,
                  ),
                );
              },
            ),
          if (widget.existing != null)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'حذف تراکنش',
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('حذف تراکنش'),
                    content: const Text('این تراکنش حذف شود؟ این کار قابل بازگشت نیست.'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
                      FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('delete'))),
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
          if (widget.existing == null) ...[
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
              icon: const Icon(Icons.document_scanner_outlined),
              label: const Text('خواندن از عکس یا فایل رسید/فیش حقوقی', style: TextStyle(fontSize: 15)),
              onPressed: () async {
                final result = await Navigator.push<Transaction>(context, MaterialPageRoute(builder: (_) => const ScanEntryScreen()));
                if (result == null) return;
                if (!context.mounted) return;
                // A scanned transaction supersedes anything typed manually
                // so far in this form; bypass the "unsaved changes" guard
                // instead of letting it swallow the scan result.
                _dirty = false;
                Navigator.pop(context, result);
              },
            ),
            const SizedBox(height: 16),
            const Row(
              children: [
                Expanded(child: Divider()),
                Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('یا وارد کنید', style: TextStyle(color: Colors.grey, fontSize: 12))),
                Expanded(child: Divider()),
              ],
            ),
            const SizedBox(height: 16),
          ],
          SegmentedButton<TxType>(
            segments: const [
              ButtonSegment(value: TxType.expense, label: Text('هزینه'), icon: Icon(Icons.arrow_upward)),
              ButtonSegment(value: TxType.income, label: Text('درآمد'), icon: Icon(Icons.arrow_downward)),
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
            decoration: InputDecoration(labelText: tr('amount'), hintText: 'مثلاً 12.50 یا 12,50', border: const OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<Account>(
            initialValue: selectedAccount,
            decoration: InputDecoration(labelText: tr('account'), border: const OutlineInputBorder()),
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
            title: Text(selectedCategory?.name ?? tr('select_category')),
            trailing: const Icon(Icons.chevron_left),
            onTap: _pickCategory,
          ),
          const SizedBox(height: 16),
          ListTile(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: Colors.grey.shade400)),
            title: Text('تاریخ: ${formatDate(date)}'),
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
            decoration: InputDecoration(labelText: tr('note'), border: const OutlineInputBorder(), alignLabelWithHint: true),
          ),
          if (type == TxType.expense) ...[
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(tr('items'), style: Theme.of(context).textTheme.titleMedium),
                TextButton.icon(onPressed: _addItemRow, icon: const Icon(Icons.add), label: Text(tr('add'))),
              ],
            ),
            if (items.isEmpty)
              Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(tr('no_items_yet'), style: const TextStyle(color: Colors.grey))),
            ...items.asMap().entries.map((e) {
              final i = e.key;
              final it = e.value;
              return Card(
                child: ListTile(
                  dense: true,
                  title: Text(it.name),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${it.quantity != null ? 'تعداد: ${ltr(it.quantity!.toStringAsFixed(it.quantity! % 1 == 0 ? 0 : 2))}' : ''}'
                        '${it.quantity != null && it.price != null ? ' • ' : ''}'
                        '${it.price != null ? ltr('€${it.price!.toStringAsFixed(2)}') : ''}',
                      ),
                      if (it.hasWarrantyInfo) ...[
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            if (it.warrantyUntil != null)
                              Chip(
                                avatar: const Icon(Icons.verified_outlined, size: 14),
                                label: Text('گارانتی تا ${ltr(persianDigits(DateFormat('yyyy-MM-dd').format(it.warrantyUntil!)))}', style: const TextStyle(fontSize: 11)),
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                backgroundColor: Colors.blue.shade50,
                              ),
                            if (it.returnUntil != null)
                              Chip(
                                avatar: const Icon(Icons.assignment_return_outlined, size: 14),
                                label: Text('مرجوعی تا ${ltr(persianDigits(DateFormat('yyyy-MM-dd').format(it.returnUntil!)))}', style: const TextStyle(fontSize: 11)),
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                backgroundColor: Colors.orange.shade50,
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                  isThreeLine: it.hasWarrantyInfo,
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
            Text('جزئیات فیش حقوقی (اختیاری)', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              controller: payslipArbeitgeberCtrl,
              decoration: const InputDecoration(labelText: 'کارفرما', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: payslipMonatCtrl,
              decoration: const InputDecoration(labelText: 'ماه تسویه', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: payslipSteuerklasseCtrl,
              decoration: const InputDecoration(labelText: 'کلاس مالیاتی', border: OutlineInputBorder()),
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
            title: Text(tr('save_as_draft')),
            subtitle: const Text('پیش‌نویس‌ها بعداً قابل بررسی و تأیید نهایی هستند.'),
            value: draft,
            onChanged: (v) => setState(() {
              draft = v;
              _dirty = true;
            }),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: _save, child: Text(tr('save'))),
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
        title: Text(parentId == null ? 'دسته‌بندی جدید' : 'زیرمجموعه‌ی جدید در «$parentName»'),
        content: TextField(controller: ctrl, decoration: const InputDecoration(labelText: 'نام دسته‌بندی'), autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: Text(tr('add'))),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final duplicate = categories.any(
        (c) => c.parentId == parentId && c.type == widget.type && c.name.trim().toLowerCase() == name.trim().toLowerCase());
    if (duplicate) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('این نام قبلاً در همین گروه استفاده شده است.')));
      }
      return;
    }
    final iconResult = await suggestIconForCategory(name, widget.type);
    final newCat = Category(
      id: 'c_${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      parentId: parentId,
      type: widget.type,
      iconCodePoint: iconResult.icon.codePoint,
      iconNeedsRetry: iconResult.isFallback,
    );
    setState(() => categories = [...categories, newCat]..sort((a, b) => persianCompare(a.name, b.name)));
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
                stack.isEmpty ? 'دسته‌بندی‌ها' : stack.last.name,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (stack.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.arrow_forward),
                title: const Text('بازگشت'),
                onTap: () => setState(() => stack.removeLast()),
              ),
            if (stack.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.check_circle_outline),
                title: Text('انتخاب «${stack.last.name}»'),
                onTap: () => Navigator.pop(context, stack.last),
              ),
            if (items.isEmpty && stack.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text('هنوز دسته‌بندی‌ای وجود ندارد. با دکمه‌ی زیر یکی اضافه کنید.'),
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
                          tooltip: 'افزودن زیرمجموعه در «${c.name}»',
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
              title: Text(stack.isEmpty ? 'افزودن دسته‌بندی جدید' : 'افزودن زیرمجموعه‌ی جدید'),
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
    // Start with every top-level category collapsed, so the list is
    // compact when first opening this screen.
    collapsed = categories.where((c) => c.parentId == null && categories.any((x) => x.parentId == c.id)).map((c) => c.id).toSet();
    setState(() => loading = false);
  }

  Future<void> _addCategory({String? parentId}) async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(parentId == null ? 'دسته‌بندی جدید' : 'زیرمجموعه‌ی جدید'),
        content: TextField(controller: ctrl, decoration: const InputDecoration(labelText: 'نام دسته‌بندی'), autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: Text(tr('add'))),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final duplicate = categories
        .any((c) => c.parentId == parentId && c.type == selectedType && c.name.trim().toLowerCase() == name.trim().toLowerCase());
    if (duplicate) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('این نام قبلاً در همین گروه استفاده شده است.')));
      }
      return;
    }
    final iconResult = await suggestIconForCategory(name, selectedType);
    final newCat = Category(
      id: 'c_${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      parentId: parentId,
      type: selectedType,
      iconCodePoint: iconResult.icon.codePoint,
      iconNeedsRetry: iconResult.isFallback,
    );
    setState(() => categories = [...categories, newCat]..sort((a, b) => persianCompare(a.name, b.name)));
    await Store.saveCategories(categories);
  }

  Future<void> _rename(Category c) async {
    final ctrl = TextEditingController(text: c.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('تغییر نام دسته‌بندی'),
        content: TextField(controller: ctrl, decoration: const InputDecoration(labelText: 'نام جدید'), autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: Text(tr('save'))),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final duplicate = categories.any(
        (x) => x.id != c.id && x.parentId == c.parentId && x.type == c.type && x.name.trim().toLowerCase() == name.trim().toLowerCase());
    if (duplicate) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('این نام قبلاً در همین گروه استفاده شده است.')));
      }
      return;
    }
    setState(() {
      categories = categories.map((x) => x.id == c.id ? x.copyWith(name: name) : x).toList()
        ..sort((a, b) => persianCompare(a.name, b.name));
    });
    await Store.saveCategories(categories);
  }

  Future<void> _delete(Category c) async {
    final hasChildren = categories.any((x) => x.parentId == c.id);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف دسته‌بندی'),
        content: Text(
          '«${c.name}» حذف شود؟'
          '${hasChildren ? '\nزیرمجموعه‌های آن یک سطح بالاتر منتقل می‌شوند.' : ''}'
          '\nتراکنش‌هایی که از این دسته‌بندی استفاده کرده‌اند، به دسته‌بندی بالاتر منتقل می‌شوند و نام «${c.name}» به توضیحات آن‌ها اضافه می‌شود.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('delete'))),
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
        final newNote = t.note.isEmpty ? 'دسته‌بندی قبلی: ${c.name}' : '${t.note} (دسته‌بندی قبلی: ${c.name})';
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
                tooltip: 'افزودن زیرمجموعه',
                onPressed: () => _addCategory(parentId: c.id),
              ),
              IconButton(
                icon: const Icon(Icons.edit_outlined, size: 20),
                tooltip: 'تغییر نام',
                onPressed: () => _rename(c),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                tooltip: 'حذف',
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
      appBar: AppBar(title: Text(tr('category_management'))),
      drawer: const AppDrawer(currentIndex: 1),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: SegmentedButton<TxType>(
              segments: const [
                ButtonSegment(value: TxType.expense, label: Text('هزینه')),
                ButtonSegment(value: TxType.income, label: Text('درآمد')),
              ],
              selected: {selectedType},
              onSelectionChanged: (s) => setState(() => selectedType = s.first),
            ),
          ),
          Expanded(
            child: tree.isEmpty
                ? const Center(child: Text('دسته‌بندی‌ای وجود ندارد.'))
                : ListView(padding: const EdgeInsets.only(bottom: 88), children: tree),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addCategory(),
        icon: const Icon(Icons.add),
        label: const Text('دسته‌بندی جدید'),
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
    final balanceCtrl = TextEditingController(text: existing?.initialBalance != null && existing!.initialBalance != 0
        ? existing.initialBalance.toStringAsFixed(2)
        : '');
    AccountType type = existing?.type ?? AccountType.bank;
    String currency = existing?.currency ?? 'EUR';
    final result = await showDialog<Account>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        return AlertDialog(
          title: Text(existing == null ? 'حساب جدید' : 'ویرایش حساب'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'نام حساب'), autofocus: true),
                const SizedBox(height: 12),
                DropdownButtonFormField<AccountType>(
                  initialValue: type,
                  decoration: const InputDecoration(labelText: 'نوع حساب'),
                  items: AccountType.values.map((t) => DropdownMenuItem(value: t, child: Text(t.label))).toList(),
                  onChanged: (v) => setLocal(() => type = v ?? type),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: currency,
                  decoration: const InputDecoration(labelText: 'واحد پول'),
                  items: kCurrencies.map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                  onChanged: (v) => setLocal(() => currency = v ?? currency),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: balanceCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                  decoration: const InputDecoration(labelText: 'موجودی اولیه', hintText: '0'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('cancel'))),
            FilledButton(
              onPressed: () {
                if (nameCtrl.text.trim().isEmpty) return;
                final acc = Account(
                  id: existing?.id ?? 'a_${DateTime.now().microsecondsSinceEpoch}',
                  name: nameCtrl.text.trim(),
                  type: type,
                  currency: currency,
                  initialBalance: double.tryParse(balanceCtrl.text.replaceAll(',', '.')) ?? 0,
                );
                Navigator.pop(ctx, acc);
              },
              child: Text(tr('save')),
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
          title: const Text('امکان حذف نیست'),
          content: Text('حساب «${a.name}» در تراکنش‌های ثبت‌شده استفاده شده است. ابتدا تراکنش‌های آن را حذف یا به حساب دیگری منتقل کنید.'),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('باشه'))],
        ),
      );
      return;
    }
    if (accounts.length <= 1) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('امکان حذف نیست'),
          content: const Text('باید حداقل یک حساب در برنامه باقی بماند.'),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('باشه'))],
        ),
      );
      return;
    }
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف حساب'),
        content: Text('حساب «${a.name}» حذف شود؟'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('delete'))),
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
      appBar: AppBar(title: Text(tr('accounts'))),
      drawer: const AppDrawer(currentIndex: 2),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: accounts
            .map((a) => Card(
                  child: ListTile(
                    leading: const Icon(Icons.account_balance_wallet_outlined),
                    title: Text(a.name),
                    subtitle: Text(
                      a.initialBalance != 0
                          ? '${a.type.label} • ${a.currency} • موجودی اولیه: ${ltr(formatMoney(a.initialBalance, a.currency))}'
                          : '${a.type.label} • ${a.currency}',
                    ),
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
        label: const Text('حساب جدید'),
      ),
    );
  }
}
