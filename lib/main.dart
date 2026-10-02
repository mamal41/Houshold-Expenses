import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart'
    show SystemNavigator, SystemChrome, SystemUiMode, Clipboard, ClipboardData, TextInputFormatter, TextEditingValue, TextSelection;
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

// Jalali (Solar Hijri) is the default; a calendar the user picked in Settings
// is saved and restored on start-up.
final ValueNotifier<CalendarSystem> currentCalendarSystem = ValueNotifier(CalendarSystem.jalali);

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

/// Formats a date the way it is written for the chosen calendar:
/// - Jalali (Solar Hijri): year/month/day with slashes, e.g. ۱۴۰۵/۰۷/۰۶
/// - Gregorian: dd.MM.yyyy
/// Digits are Persian when the app language is Persian, and the result is
/// LTR-isolated so it doesn't get visually reordered inside RTL text.
String formatDate(DateTime d) {
  if (currentCalendarSystem.value == CalendarSystem.jalali) {
    final j = gregorianToJalali(d.year, d.month, d.day);
    final jd = j[2].toString().padLeft(2, '0');
    final jm = j[1].toString().padLeft(2, '0');
    return ltr(persianDigits('${j[0]}/$jm/$jd'));
  }
  return ltr(persianDigits(DateFormat('dd.MM.yyyy').format(d)));
}

/// Month and day only (e.g. for "every year on ..."): month/day in Jalali,
/// dd.MM in Gregorian.
String formatDayMonth(DateTime d) {
  if (currentCalendarSystem.value == CalendarSystem.jalali) {
    final j = gregorianToJalali(d.year, d.month, d.day);
    return ltr(persianDigits('${j[1].toString().padLeft(2, '0')}/${j[2].toString().padLeft(2, '0')}'));
  }
  return ltr(persianDigits(DateFormat('dd.MM').format(d)));
}

/// One calendar month in the chosen calendar system (Gregorian or Jalali):
/// first/last day as Gregorian dates, plus its display name and year text.
class CalendarMonth {
  final DateTime start;
  final DateTime end;
  final String name;
  final String yearText;
  const CalendarMonth({required this.start, required this.end, required this.name, required this.yearText});
}

/// The calendar month containing [d], shifted by [monthOffset] months, in
/// the chosen calendar system.
CalendarMonth calendarMonthOf(DateTime d, [int monthOffset = 0]) {
  if (currentCalendarSystem.value == CalendarSystem.jalali) {
    final j = gregorianToJalali(d.year, d.month, d.day);
    final total = j[0] * 12 + (j[1] - 1) + monthOffset;
    final y = total ~/ 12;
    final m = total % 12 + 1;
    final s = jalaliToGregorian(y, m, 1);
    final n = jalaliToGregorian(m == 12 ? y + 1 : y, m == 12 ? 1 : m + 1, 1);
    return CalendarMonth(
      start: DateTime(s[0], s[1], s[2]),
      end: DateTime(n[0], n[1], n[2] - 1),
      name: _jalaliMonthNames[m - 1],
      yearText: persianDigits('$y'),
    );
  }
  final total = d.year * 12 + (d.month - 1) + monthOffset;
  final y = total ~/ 12;
  final m = total % 12 + 1;
  return CalendarMonth(
    start: DateTime(y, m, 1),
    end: DateTime(y, m + 1, 0),
    name: _gregorianMonthNames[m - 1],
    yearText: persianDigits('$y'),
  );
}

// ---------------------------------------------------------------- date pickers

/// Date picker that follows the chosen calendar: a Solar Hijri (Jalali)
/// dialog when Jalali is selected, the standard Material picker otherwise.
Future<DateTime?> showAppDatePicker({
  required BuildContext context,
  required DateTime initialDate,
  required DateTime firstDate,
  required DateTime lastDate,
  TransitionBuilder? builder,
}) {
  if (currentCalendarSystem.value == CalendarSystem.jalali) {
    return showDialog<DateTime>(
      context: context,
      builder: (_) => JalaliDatePickerDialog(initial: initialDate, first: firstDate, last: lastDate),
    );
  }
  final base = builder ?? (ctx, child) => Directionality(textDirection: TextDirection.ltr, child: child!);
  return showDatePicker(
    context: context,
    initialDate: initialDate,
    firstDate: firstDate,
    lastDate: lastDate,
    // In Persian the Material picker starts weeks on Saturday; that's only
    // right for the Jalali calendar - a Gregorian month starts on Monday.
    builder: currentLanguage.value == AppLanguage.fa
        ? (ctx, child) => Localizations.override(
              context: ctx,
              delegates: const [_MondayFirstFaMaterialDelegate()],
              child: base(ctx, child),
            )
        : base,
  );
}

/// Persian Material texts, but with Monday as the first day of the week.
class _MondayFirstFaMaterialLocalizations extends MaterialLocalizationFa {
  _MondayFirstFaMaterialLocalizations()
      : super(
          fullYearFormat: DateFormat.y('fa'),
          compactDateFormat: DateFormat.yMd('fa'),
          shortDateFormat: DateFormat.yMMMd('fa'),
          mediumDateFormat: DateFormat.MMMEd('fa'),
          longDateFormat: DateFormat.yMMMMEEEEd('fa'),
          yearMonthFormat: DateFormat.yMMMM('fa'),
          shortMonthDayFormat: DateFormat.MMMd('fa'),
          decimalFormat: NumberFormat.decimalPattern('fa'),
          twoDigitZeroPaddedFormat: NumberFormat('00', 'fa'),
        );

  @override
  int get firstDayOfWeekIndex => 1;
}

class _MondayFirstFaMaterialDelegate extends LocalizationsDelegate<MaterialLocalizations> {
  const _MondayFirstFaMaterialDelegate();
  @override
  bool isSupported(Locale locale) => locale.languageCode == 'fa';
  @override
  Future<MaterialLocalizations> load(Locale locale) => SynchronousFuture(_MondayFirstFaMaterialLocalizations());
  @override
  bool shouldReload(covariant LocalizationsDelegate<MaterialLocalizations> old) => false;
}

/// Date-range picker: Material's in Gregorian mode; in Jalali mode two
/// Jalali pickers are shown one after the other (start, then end).
Future<DateTimeRange?> showAppDateRangePicker({
  required BuildContext context,
  required DateTime firstDate,
  required DateTime lastDate,
  required DateTimeRange initialDateRange,
}) async {
  if (currentCalendarSystem.value != CalendarSystem.jalali) {
    return showDateRangePicker(context: context, firstDate: firstDate, lastDate: lastDate, initialDateRange: initialDateRange);
  }
  final start = await showAppDatePicker(context: context, initialDate: initialDateRange.start, firstDate: firstDate, lastDate: lastDate);
  if (start == null || !context.mounted) return null;
  final endInitial = initialDateRange.end.isBefore(start) ? start : initialDateRange.end;
  final end = await showAppDatePicker(context: context, initialDate: endInitial, firstDate: start, lastDate: lastDate);
  if (end == null) return null;
  return DateTimeRange(start: start, end: end);
}

class JalaliDatePickerDialog extends StatefulWidget {
  final DateTime initial;
  final DateTime first;
  final DateTime last;
  const JalaliDatePickerDialog({required this.initial, required this.first, required this.last, super.key});
  @override
  State<JalaliDatePickerDialog> createState() => _JalaliDatePickerDialogState();
}

class _JalaliDatePickerDialogState extends State<JalaliDatePickerDialog> {
  late DateTime selected;
  late int viewYear;
  late int viewMonth;

  DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  @override
  void initState() {
    super.initState();
    final first = _day(widget.first);
    final last = _day(widget.last);
    var init = _day(widget.initial);
    if (init.isBefore(first)) init = first;
    if (init.isAfter(last)) init = last;
    selected = init;
    final j = gregorianToJalali(init.year, init.month, init.day);
    viewYear = j[0];
    viewMonth = j[1];
  }

  DateTime _startOf(int y, int m) {
    final g = jalaliToGregorian(y, m, 1);
    return DateTime(g[0], g[1], g[2]);
  }

  int _lengthOf(int y, int m) {
    final next = m == 12 ? _startOf(y + 1, 1) : _startOf(y, m + 1);
    return next.difference(_startOf(y, m)).inDays;
  }

  void _shiftMonth(int delta) {
    final total = viewYear * 12 + (viewMonth - 1) + delta;
    setState(() {
      viewYear = total ~/ 12;
      viewMonth = total % 12 + 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    final first = _day(widget.first);
    final last = _day(widget.last);
    final firstJ = gregorianToJalali(first.year, first.month, first.day);
    final lastJ = gregorianToJalali(last.year, last.month, last.day);
    final years = [for (var y = firstJ[0]; y <= lastJ[0]; y++) y];
    if (!years.contains(viewYear)) years.add(viewYear);
    years.sort();

    final monthStart = _startOf(viewYear, viewMonth);
    final leading = (monthStart.weekday + 1) % 7; // Saturday = 0
    final days = _lengthOf(viewYear, viewMonth);
    final today = _day(DateTime.now());
    final cells = <Widget>[];
    for (var i = 0; i < leading; i++) {
      cells.add(const SizedBox.shrink());
    }
    for (var d = 1; d <= days; d++) {
      final g = jalaliToGregorian(viewYear, viewMonth, d);
      final date = DateTime(g[0], g[1], g[2]);
      final enabled = !date.isBefore(first) && !date.isAfter(last);
      final isSelected = date == selected;
      final isToday = date == today;
      final scheme = Theme.of(context).colorScheme;
      cells.add(
        Padding(
          padding: const EdgeInsets.all(2),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: enabled ? () => setState(() => selected = date) : null,
            child: Container(
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isSelected ? scheme.primary : null,
                border: isToday && !isSelected ? Border.all(color: scheme.primary) : null,
              ),
              child: Text(
                persianDigits('$d'),
                style: TextStyle(
                  fontSize: 14,
                  color: isSelected ? scheme.onPrimary : (enabled ? null : Theme.of(context).disabledColor),
                ),
              ),
            ),
          ),
        ),
      );
    }
    while (cells.length % 7 != 0) {
      cells.add(const SizedBox.shrink());
    }
    const weekdayLetters = ['ش', 'ی', 'د', 'س', 'چ', 'پ', 'ج'];

    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
        content: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(formatDate(selected), style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Row(
                children: [
                  IconButton(icon: const Icon(Icons.chevron_left), tooltip: 'ماه بعد', onPressed: () => _shiftMonth(1)),
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        DropdownButton<int>(
                          value: viewMonth,
                          underline: const SizedBox.shrink(),
                          items: List.generate(12, (i) => DropdownMenuItem(value: i + 1, child: Text(_jalaliMonthNames[i]))),
                          onChanged: (v) => setState(() => viewMonth = v ?? viewMonth),
                        ),
                        const SizedBox(width: 8),
                        DropdownButton<int>(
                          value: viewYear,
                          underline: const SizedBox.shrink(),
                          items: years.map((y) => DropdownMenuItem(value: y, child: Text(persianDigits('$y')))).toList(),
                          onChanged: (v) => setState(() => viewYear = v ?? viewYear),
                        ),
                      ],
                    ),
                  ),
                  IconButton(icon: const Icon(Icons.chevron_right), tooltip: 'ماه قبل', onPressed: () => _shiftMonth(-1)),
                ],
              ),
              Row(
                children: weekdayLetters
                    .map((w) => Expanded(
                          child: Center(child: Text(w, style: TextStyle(fontSize: 12, color: Colors.grey.shade600))),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 4),
              GridView.count(
                crossAxisCount: 7,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                children: cells,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('cancel'))),
          TextButton(
            onPressed: () {
              final t = _day(DateTime.now());
              if (!t.isBefore(first) && !t.isAfter(last)) {
                final j = gregorianToJalali(t.year, t.month, t.day);
                setState(() {
                  selected = t;
                  viewYear = j[0];
                  viewMonth = j[1];
                });
              }
            },
            child: const Text('امروز'),
          ),
          FilledButton(onPressed: () => Navigator.pop(context, selected), child: Text(tr('confirm'))),
        ],
      ),
    );
  }
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

/// Shown on the scan review screens when the receipt/payslip is in a
/// different currency than the chosen account, so amounts aren't saved in
/// the wrong unit (e.g. Rial read into a Toman account).
Widget currencyMismatchWarning(String detected, String accountCurrency) {
  return Container(
    margin: const EdgeInsets.only(top: 12),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.orange.shade50,
      border: Border.all(color: Colors.orange.shade300),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.warning_amber_rounded, color: Colors.orange.shade800),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'واحد پول این سند (${currencyLabel(detected)}) با واحد پول حساب انتخاب‌شده (${currencyLabel(accountCurrency)}) '
            'یکی نیست. مبلغ را بررسی کنید یا حساب دیگری انتخاب کنید.',
            style: TextStyle(color: Colors.orange.shade900, fontSize: 13),
          ),
        ),
      ],
    ),
  );
}

/// Asked when leaving a screen for an already saved transaction whose
/// fields were changed. Returns 'save', 'discard' or null (stay).
Future<String?> askSaveChanges(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('ذخیره تغییرات'),
      content: const Text('آیا تغییرات انجام شده ذخیره شود؟'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('cancel'))),
        TextButton(onPressed: () => Navigator.pop(ctx, 'discard'), child: const Text('خیر')),
        FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('بله، ذخیره شود')),
      ],
    ),
  );
}

/// Pinned bottom bar for the save buttons of a form screen, so they stay
/// reachable without scrolling to the end of the page.
/// [trailing] widgets (e.g. icon buttons) sit after the buttons - on the
/// left side in the right-to-left layout - at their natural size.
Widget pinnedBottomButtons(BuildContext context, List<Widget> buttons, {List<Widget> trailing = const []}) {
  final children = <Widget>[];
  for (var i = 0; i < buttons.length; i++) {
    if (i > 0) children.add(const SizedBox(width: 12));
    children.add(Expanded(child: buttons[i]));
  }
  if (trailing.isNotEmpty) {
    children.add(const SizedBox(width: 4));
    children.addAll(trailing);
  }
  return Material(
    elevation: 8,
    color: Theme.of(context).colorScheme.surface,
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        child: Row(children: children),
      ),
    ),
  );
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

const kCurrencies = ['IRT', 'IRR', 'EUR', 'USD', 'GBP', 'TRY', 'AED', 'CHF'];

// App identity/version shown in the "درباره‌ی برنامه" screen and used for
// store listings. Keep this in sync with pubspec.yaml's `version:` field
// whenever you bump the version for a new release.
const kAppVersion = '1.0.0';
const kAppBuildNumber = 1;
// TODO: replace with your real support email and developer/company name
// before publishing (shown in the About screen and often required by app
// stores like Bazaar/Google Play).
const kSupportEmail = 'mm41.d@proton.me';
const kDeveloperName = 'MM41';

// ============================== Date helpers ==============================

int daysInMonth(int year, int month) {
  final beginningNextMonth = (month < 12) ? DateTime(year, month + 1, 1) : DateTime(year + 1, 1, 1);
  return beginningNextMonth.subtract(const Duration(days: 1)).day;
}

DateTime clampedMonthDate(int year, int month, int day) {
  final maxDay = daysInMonth(year, month);
  return DateTime(year, month, day > maxDay ? maxDay : day);
}

/// Day of the month of [d] in the calendar chosen in settings (a recurring
/// transaction's "day of month" means a Jalali day in Jalali mode).
int dayOfMonthInCalendar(DateTime d) =>
    currentCalendarSystem.value == CalendarSystem.jalali ? gregorianToJalali(d.year, d.month, d.day)[2] : d.day;

/// The date on [day] (clamped to the month's length) of the month that is
/// [addMonths] months after [ref]'s month, in the calendar chosen in
/// settings - so a monthly payment on "day 1" falls on 1 Mehr, 1 Aban...
/// in Jalali mode instead of on the 1st of each Gregorian month.
DateTime calendarMonthDate(DateTime ref, int addMonths, int day) {
  if (currentCalendarSystem.value == CalendarSystem.jalali) {
    final j = gregorianToJalali(ref.year, ref.month, ref.day);
    final total = j[0] * 12 + (j[1] - 1) + addMonths;
    final y = total ~/ 12;
    final m = total % 12 + 1;
    final start = jalaliToGregorian(y, m, 1);
    final next = m == 12 ? jalaliToGregorian(y + 1, 1, 1) : jalaliToGregorian(y, m + 1, 1);
    final len = DateTime.utc(next[0], next[1], next[2]).difference(DateTime.utc(start[0], start[1], start[2])).inDays;
    final g = jalaliToGregorian(y, m, day > len ? len : (day < 1 ? 1 : day));
    return DateTime(g[0], g[1], g[2]);
  }
  final total = ref.year * 12 + (ref.month - 1) + addMonths;
  return clampedMonthDate(total ~/ 12, total % 12 + 1, day);
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

/// Categories for [type], ordered as: each top-level category (Persian
/// alphabetical), immediately followed by its own subcategories (also
/// Persian alphabetical) - for filter/picker lists where subcategories
/// should visually nest under their parent instead of being mixed into
/// one flat alphabetical list.
List<Category> categoriesInHierarchicalOrder(List<Category> categories, TxType type) {
  final result = <Category>[];
  final tops = categories.where((c) => c.type == type && c.parentId == null).toList()..sort((a, b) => persianCompare(a.name, b.name));
  for (final top in tops) {
    result.add(top);
    final children = categories.where((c) => c.type == type && c.parentId == top.id).toList()..sort((a, b) => persianCompare(a.name, b.name));
    result.addAll(children);
  }
  return result;
}

/// True if [txCategoryId] is exactly [filterCategoryId], or a descendant
/// of it (so picking a top-level category in a filter also matches every
/// transaction filed under one of its subcategories).
bool categoryMatchesFilter(String txCategoryId, String filterCategoryId, List<Category> categories) {
  if (txCategoryId == filterCategoryId) return true;
  var current = categories.where((c) => c.id == txCategoryId).toList();
  var cat = current.isEmpty ? null : current.first;
  while (cat?.parentId != null) {
    if (cat!.parentId == filterCategoryId) return true;
    final pm = categories.where((c) => c.id == cat!.parentId).toList();
    if (pm.isEmpty) break;
    cat = pm.first;
  }
  return false;
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
  const SavingsGoal({required this.id, required this.name, required this.targetAmount, this.targetDate, this.currency = 'IRT'});

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

class ShoppingListItem {
  final String id;
  final String name;
  final double? quantity;
  final double? estimatedPrice;
  final bool checked;
  const ShoppingListItem({required this.id, required this.name, this.quantity, this.estimatedPrice, this.checked = false});

  ShoppingListItem copyWith({String? name, double? quantity, double? estimatedPrice, bool? checked, bool clearQuantity = false, bool clearPrice = false}) =>
      ShoppingListItem(
        id: id,
        name: name ?? this.name,
        quantity: clearQuantity ? null : (quantity ?? this.quantity),
        estimatedPrice: clearPrice ? null : (estimatedPrice ?? this.estimatedPrice),
        checked: checked ?? this.checked,
      );

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'quantity': quantity, 'estimatedPrice': estimatedPrice, 'checked': checked};
  factory ShoppingListItem.fromJson(Map<String, dynamic> j) => ShoppingListItem(
        id: j['id'],
        name: j['name'] ?? '',
        quantity: (j['quantity'] as num?)?.toDouble(),
        estimatedPrice: (j['estimatedPrice'] as num?)?.toDouble(),
        checked: j['checked'] ?? false,
      );
}

class ShoppingList {
  final String id;
  final String name;
  final List<ShoppingListItem> items;
  const ShoppingList({required this.id, required this.name, this.items = const []});

  ShoppingList copyWith({String? name, List<ShoppingListItem>? items}) =>
      ShoppingList(id: id, name: name ?? this.name, items: items ?? this.items);

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'items': items.map((i) => i.toJson()).toList()};
  factory ShoppingList.fromJson(Map<String, dynamic> j) => ShoppingList(
        id: j['id'],
        name: j['name'] ?? '',
        items: (j['items'] as List? ?? []).map((e) => ShoppingListItem.fromJson(e)).toList(),
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
  // Units of the MAIN account's currency that 1 unit of this account's own
  // currency is worth (1.0 for the main account itself, or any account that
  // already shares its currency). Lets the home screen show one combined
  // total across accounts with different currencies.
  final double exchangeRateToMain;
  const Account({
    required this.id,
    required this.name,
    required this.type,
    required this.currency,
    this.initialBalance = 0,
    this.exchangeRateToMain = 1.0,
  });

  Account copyWith({String? name, AccountType? type, String? currency, double? initialBalance, double? exchangeRateToMain}) => Account(
        id: id,
        name: name ?? this.name,
        type: type ?? this.type,
        currency: currency ?? this.currency,
        initialBalance: initialBalance ?? this.initialBalance,
        exchangeRateToMain: exchangeRateToMain ?? this.exchangeRateToMain,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type.name,
        'currency': currency,
        'initialBalance': initialBalance,
        'exchangeRateToMain': exchangeRateToMain,
      };
  factory Account.fromJson(Map<String, dynamic> j) => Account(
        id: j['id'],
        name: j['name'],
        type: AccountType.values.byName(j['type'] ?? 'bank'),
        currency: j['currency'] ?? 'EUR',
        initialBalance: (j['initialBalance'] as num?)?.toDouble() ?? 0,
        exchangeRateToMain: (j['exchangeRateToMain'] as num?)?.toDouble() ?? 1.0,
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

  ReceiptItemEntry scaled(double f) => ReceiptItemEntry(
        name: name,
        quantity: quantity,
        price: price == null ? null : roundMoney(price! * f),
        warrantyUntil: warrantyUntil,
        returnUntil: returnUntil,
        warrantyNote: warrantyNote,
      );

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

class PayslipCustomField {
  final String label;
  final double value;
  const PayslipCustomField({required this.label, required this.value});
  Map<String, dynamic> toJson() => {'label': label, 'value': value};
  factory PayslipCustomField.fromJson(Map<String, dynamic> j) => PayslipCustomField(label: j['label'] ?? '', value: (j['value'] as num? ?? 0).toDouble());
}

class PayslipDetails {
  final double? brutto;
  final double? netto;
  final double? depositedAmount; // مبلغ واریز شده به حساب - can differ from netto (advances, deductions via payroll, etc.)
  final double? lohnsteuer;
  final double? solidaritaetszuschlag;
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
  // Free-form fields the user adds themselves - lets a payslip from any
  // country/format (e.g. Iranian payslip items like حق مسکن، حق اولاد،
  // بیمه‌ی تأمین اجتماعی) be recorded without needing a hardcoded field
  // for every country's terminology.
  final List<PayslipCustomField> customFields;

  const PayslipDetails({
    this.brutto,
    this.netto,
    this.depositedAmount,
    this.lohnsteuer,
    this.solidaritaetszuschlag,
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
    this.customFields = const [],
  });

  PayslipDetails scaled(double f) {
    double? m(double? v) => v == null ? null : roundMoney(v * f);
    return PayslipDetails(
      brutto: m(brutto),
      netto: m(netto),
      depositedAmount: m(depositedAmount),
      lohnsteuer: m(lohnsteuer),
      solidaritaetszuschlag: m(solidaritaetszuschlag),
      krankenversicherung: m(krankenversicherung),
      pflegeversicherung: m(pflegeversicherung),
      rentenversicherung: m(rentenversicherung),
      arbeitslosenversicherung: m(arbeitslosenversicherung),
      vermoegenswirksameLeistungen: m(vermoegenswirksameLeistungen),
      betrieblicheAltersvorsorge: m(betrieblicheAltersvorsorge),
      vorschuss: m(vorschuss),
      sonstigeAbzuege: m(sonstigeAbzuege),
      steuerklasse: steuerklasse,
      arbeitgeber: arbeitgeber,
      abrechnungsmonat: abrechnungsmonat,
      customFields: customFields.map((c) => PayslipCustomField(label: c.label, value: roundMoney(c.value * f))).toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'brutto': brutto,
        'netto': netto,
        'depositedAmount': depositedAmount,
        'lohnsteuer': lohnsteuer,
        'solidaritaetszuschlag': solidaritaetszuschlag,
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
        'customFields': customFields.map((f) => f.toJson()).toList(),
      };

  factory PayslipDetails.fromJson(Map<String, dynamic> j) => PayslipDetails(
        brutto: (j['brutto'] as num?)?.toDouble(),
        netto: (j['netto'] as num?)?.toDouble(),
        depositedAmount: (j['depositedAmount'] as num?)?.toDouble(),
        lohnsteuer: (j['lohnsteuer'] as num?)?.toDouble(),
        solidaritaetszuschlag: (j['solidaritaetszuschlag'] as num?)?.toDouble(),
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
        customFields: (j['customFields'] as List? ?? []).map((e) => PayslipCustomField.fromJson(e)).toList(),
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
  final String merchant; // shop / store name (expenses); shown first in lists when filled

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
    this.merchant = '',
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
    String? merchant,
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
        merchant: merchant ?? this.merchant,
      );

  /// Same transaction with every money amount multiplied by [f] (used when an
  /// account's currency unit changes, e.g. Rial -> Toman is f = 0.1).
  Transaction scaled(double f) => copyWith(
        amount: roundMoney(amount * f),
        items: items.map((e) => e.scaled(f)).toList(),
        payslipDetails: payslipDetails?.scaled(f),
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
        'merchant': merchant,
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
      merchant: j['merchant'] ?? '',
    );
  }
}

/// Shows a short explanation dialog - used for the (i) info button next to a
/// screen's title on screens whose purpose isn't obvious at a glance.
Future<void> showInfoDialog(BuildContext context, String title, String text) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(text, style: const TextStyle(fontSize: 13, height: 1.7)),
      actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('confirm')))],
    ),
  );
}

Widget infoButton(BuildContext context, String title, String text) => IconButton(
      icon: const Icon(Icons.info_outline),
      tooltip: 'توضیحات',
      onPressed: () => showInfoDialog(context, title, text),
    );

/// The app's main currency: the currency of the first ("main") account.
String mainCurrencyOf(List<Account> accounts) => accounts.isEmpty ? 'IRT' : accounts.first.currency;

/// Rounds a converted amount so repeated x10 / x0.1 conversions don't leave
/// floating-point noise (12345.600000001).
double roundMoney(double v) => (v * 10000).round() / 10000;

DateTime? nextOccurrencePreview(Transaction t) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  switch (t.recurrence) {
    case RecurrenceFrequency.monthly:
      if (t.recurrenceDay == null) return null;
      var d = calendarMonthDate(today, 0, t.recurrenceDay!);
      if (d.isBefore(today)) d = calendarMonthDate(today, 1, t.recurrenceDay!);
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
      var probe = calendarMonthDate(t.date, 0, t.recurrenceDay!);
      while (!probe.isAfter(today)) {
        probe = calendarMonthDate(probe, 3, t.recurrenceDay!);
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
        next = calendarMonthDate(current, 1, t.recurrenceDay ?? dayOfMonthInCalendar(current));
        break;
      case RecurrenceFrequency.weekly:
        next = current.add(const Duration(days: 7));
        break;
      case RecurrenceFrequency.custom:
        next = current.add(Duration(days: t.recurrenceIntervalDays ?? 30));
        break;
      case RecurrenceFrequency.quarterly:
        next = calendarMonthDate(current, 3, t.recurrenceDay ?? dayOfMonthInCalendar(current));
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
///
/// Projections normally start today (an occurrence falling due today shows
/// up on its day); pass [from] to also include recurring occurrences from
/// that day on (e.g. earlier in this month).
List<TxOccurrence> occurrencesWithRecurringProjections(List<Transaction> tx, {int horizonDays = 400, DateTime? from}) {
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
      if (dd.isBefore(from ?? today) || dd.isAfter(horizon)) continue;
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
    await _plugin.initialize(
      const InitializationSettings(android: androidInit),
      onDidReceiveNotificationResponse: (response) => openTransactionFromNotification(response.payload),
    );
    // The app may have been cold-started BY tapping a notification - handle
    // that case too, once the navigator exists.
    final launchDetails = await _plugin.getNotificationAppLaunchDetails();
    if (launchDetails?.didNotificationLaunchApp ?? false) {
      final payload = launchDetails?.notificationResponse?.payload;
      WidgetsBinding.instance.addPostFrameCallback((_) => openTransactionFromNotification(payload));
    }
    _initialized = true;
  }

  Future<void> requestPermission() async {
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  /// Shows an immediate (not scheduled) notification, e.g. for a budget
  /// goal threshold that was just crossed.
  Future<void> showNow(int id, String title, String body, {String? payload}) async {
    const details = NotificationDetails(
      android: AndroidNotificationDetails('budget_goals', 'اهداف هزینه', importance: Importance.high, priority: Priority.high),
    );
    await _plugin.show(id, title, body, details, payload: payload);
  }

  int _idFor(String txId, int slot) => (txId.hashCode & 0xffff) * 1000 + slot;

  Future<void> cancelForTransaction(String txId) async {
    // slot 0/1 = second-to-last/last reminders, slots 2..201 = optional
    // per-installment reminders (capped at 200 upcoming installments).
    // Firing 202 cancel calls over the platform channel on every save
    // (even for transactions that never had a reminder) noticeably froze
    // the app for a few seconds, especially on older phones - so ask once
    // which reminders are actually pending and cancel only this
    // transaction's.
    if (!_initialized) return;
    final ids = {for (var slot = 0; slot < 202; slot++) _idFor(txId, slot)};
    List<PendingNotificationRequest> pending;
    try {
      pending = await _plugin.pendingNotificationRequests();
    } catch (_) {
      await Future.wait(ids.map(_plugin.cancel));
      return;
    }
    final mine = pending.map((p) => p.id).where(ids.contains).toList();
    if (mine.isEmpty) return;
    await Future.wait(mine.map(_plugin.cancel));
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

const defaultAccount = Account(id: 'default', name: 'حساب اصلی', type: AccountType.bank, currency: 'IRT');

const kCategoryIcons = <String, IconData>{
  'e_food': Icons.restaurant_outlined,
  'e_food_market': Icons.local_grocery_store_outlined,
  'e_food_produce': Icons.eco_outlined,
  'e_food_restaurant': Icons.restaurant_menu_outlined,
  'e_housing': Icons.home_outlined,
  'e_transport': Icons.directions_bus_outlined,
  'e_car': Icons.directions_car_outlined,
  'e_bills': Icons.request_quote_outlined,
  'e_bills_power': Icons.bolt_outlined,
  'e_bills_water': Icons.water_drop_outlined,
  'e_bills_gas': Icons.local_fire_department_outlined,
  'e_bills_internet': Icons.wifi_outlined,
  'e_bills_phone': Icons.phone_iphone_outlined,
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

// Names whose icon should always follow the name, even over an icon picked
// automatically when the category was created.
const _preferredNameIcons = <String, IconData>{
  'ابزار': Icons.handyman_outlined,
  'کارمزد': Icons.percent,
  'سوپرمارکت': Icons.local_grocery_store_outlined,
  'میوه': Icons.eco_outlined,
  'تره‌بار': Icons.eco_outlined,
  'قبوض': Icons.request_quote_outlined,
  'قبض': Icons.request_quote_outlined,
};

/// The generic placeholder icons given to a category no better icon was
/// found for yet (shapes for expenses, money for income).
bool _isGenericIcon(int? codePoint) =>
    codePoint != null &&
    (codePoint == Icons.category_outlined.codePoint || codePoint == Icons.attach_money_outlined.codePoint);

IconData iconForCategory(Category? c, List<Category> all) {
  if (c != null) {
    for (final entry in _preferredNameIcons.entries) {
      if (c.name.contains(entry.key)) return entry.value;
    }
  }
  final stored = c?.iconCodePoint;
  // A stored generic placeholder icon (no better match was found when the
  // category was created) gives way to a keyword match on its name.
  final isGenericStored = _isGenericIcon(stored);
  if (stored != null && !isGenericStored) {
    return IconData(stored, fontFamily: 'MaterialIcons');
  }
  if (c != null && isGenericStored) {
    for (final entry in _iconKeywordHints.entries) {
      if (c.name.contains(entry.key)) return entry.value;
    }
  }
  if (stored != null) return IconData(stored, fontFamily: 'MaterialIcons');
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
  // More specific names first - the first matching keyword wins (e.g.
  // "آبمیوه" should get the fruit icon, not the water one).
  'سوپرمارکت': Icons.local_grocery_store_outlined,
  'سوپر': Icons.local_grocery_store_outlined,
  'هایپر': Icons.local_grocery_store_outlined,
  'خواربار': Icons.local_grocery_store_outlined,
  'میوه': Icons.eco_outlined,
  'تره‌بار': Icons.eco_outlined,
  'تره بار': Icons.eco_outlined,
  'سبزی': Icons.eco_outlined,
  'قبوض': Icons.request_quote_outlined,
  'قبض': Icons.request_quote_outlined,
  'ابزار': Icons.handyman_outlined,
  'کارمزد': Icons.percent,
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

// Icons Gemini can choose from for a category no keyword matched, by
// Material icon name. The name list is sent in the prompt and the reply is
// matched back to the icon here.
const _aiIconChoices = <String, IconData>{
  'restaurant': Icons.restaurant_outlined,
  'local_grocery_store': Icons.local_grocery_store_outlined,
  'eco': Icons.eco_outlined,
  'local_cafe': Icons.local_cafe_outlined,
  'fastfood': Icons.fastfood_outlined,
  'lunch_dining': Icons.lunch_dining_outlined,
  'bakery_dining': Icons.bakery_dining_outlined,
  'local_pizza': Icons.local_pizza_outlined,
  'icecream': Icons.icecream_outlined,
  'cake': Icons.cake_outlined,
  'local_bar': Icons.local_bar_outlined,
  'liquor': Icons.liquor_outlined,
  'home': Icons.home_outlined,
  'chair': Icons.chair_outlined,
  'kitchen': Icons.kitchen_outlined,
  'bed': Icons.bed_outlined,
  'cleaning_services': Icons.cleaning_services_outlined,
  'local_laundry_service': Icons.local_laundry_service_outlined,
  'yard': Icons.yard_outlined,
  'grass': Icons.grass_outlined,
  'roofing': Icons.roofing_outlined,
  'plumbing': Icons.plumbing_outlined,
  'electrical_services': Icons.electrical_services_outlined,
  'construction': Icons.construction_outlined,
  'handyman': Icons.handyman_outlined,
  'build': Icons.build_outlined,
  'engineering': Icons.engineering_outlined,
  'directions_car': Icons.directions_car_outlined,
  'local_gas_station': Icons.local_gas_station_outlined,
  'ev_station': Icons.ev_station_outlined,
  'car_repair': Icons.car_repair_outlined,
  'tire_repair': Icons.tire_repair_outlined,
  'local_parking': Icons.local_parking_outlined,
  'local_taxi': Icons.local_taxi_outlined,
  'directions_bus': Icons.directions_bus_outlined,
  'subway': Icons.subway_outlined,
  'train': Icons.train_outlined,
  'flight': Icons.flight_outlined,
  'hotel': Icons.hotel_outlined,
  'two_wheeler': Icons.two_wheeler_outlined,
  'directions_bike': Icons.directions_bike_outlined,
  'commute': Icons.commute_outlined,
  'local_shipping': Icons.local_shipping_outlined,
  'bolt': Icons.bolt_outlined,
  'water_drop': Icons.water_drop_outlined,
  'local_fire_department': Icons.local_fire_department_outlined,
  'wifi': Icons.wifi_outlined,
  'phone_iphone': Icons.phone_iphone_outlined,
  'router': Icons.router_outlined,
  'tv': Icons.tv_outlined,
  'devices': Icons.devices_outlined,
  'computer': Icons.computer_outlined,
  'laptop_mac': Icons.laptop_mac_outlined,
  'headphones': Icons.headphones_outlined,
  'photo_camera': Icons.photo_camera_outlined,
  'print': Icons.print_outlined,
  'medical_services': Icons.medical_services_outlined,
  'medication': Icons.medication_outlined,
  'local_hospital': Icons.local_hospital_outlined,
  'local_pharmacy': Icons.local_pharmacy_outlined,
  'health_and_safety': Icons.health_and_safety_outlined,
  'fitness_center': Icons.fitness_center_outlined,
  'spa': Icons.spa_outlined,
  'face_retouching_natural': Icons.face_retouching_natural_outlined,
  'content_cut': Icons.content_cut_outlined,
  'sports_esports': Icons.sports_esports_outlined,
  'sports_soccer': Icons.sports_soccer_outlined,
  'pool': Icons.pool_outlined,
  'hiking': Icons.hiking_outlined,
  'beach_access': Icons.beach_access_outlined,
  'park': Icons.park_outlined,
  'movie': Icons.movie_outlined,
  'theater_comedy': Icons.theater_comedy_outlined,
  'music_note': Icons.music_note_outlined,
  'palette': Icons.palette_outlined,
  'celebration': Icons.celebration_outlined,
  'casino': Icons.casino_outlined,
  'checkroom': Icons.checkroom_outlined,
  'shopping_bag': Icons.shopping_bag_outlined,
  'shopping_cart': Icons.shopping_cart_outlined,
  'storefront': Icons.storefront_outlined,
  'local_mall': Icons.local_mall_outlined,
  'toys': Icons.toys_outlined,
  'child_care': Icons.child_care_outlined,
  'baby_changing_station': Icons.baby_changing_station_outlined,
  'elderly': Icons.elderly_outlined,
  'family_restroom': Icons.family_restroom_outlined,
  'pets': Icons.pets_outlined,
  'school': Icons.school_outlined,
  'menu_book': Icons.menu_book_outlined,
  'work': Icons.work_outlined,
  'business_center': Icons.business_center_outlined,
  'account_balance': Icons.account_balance_outlined,
  'savings': Icons.savings_outlined,
  'payments': Icons.payments_outlined,
  'attach_money': Icons.attach_money_outlined,
  'currency_exchange': Icons.currency_exchange_outlined,
  'credit_card': Icons.credit_card_outlined,
  'percent': Icons.percent_outlined,
  'request_quote': Icons.request_quote_outlined,
  'receipt_long': Icons.receipt_long_outlined,
  'description': Icons.description_outlined,
  'gavel': Icons.gavel_outlined,
  'subscriptions': Icons.subscriptions_outlined,
  'cloud': Icons.cloud_outlined,
  'security': Icons.security_outlined,
  'volunteer_activism': Icons.volunteer_activism_outlined,
  'card_giftcard': Icons.card_giftcard_outlined,
  'mosque': Icons.mosque_outlined,
  'church': Icons.church_outlined,
  'local_post_office': Icons.local_post_office_outlined,
  'smoking_rooms': Icons.smoking_rooms_outlined,
  'lightbulb': Icons.lightbulb_outlined,
  'agriculture': Icons.agriculture_outlined,
  'trending_up': Icons.trending_up_outlined,
};

Future<IconData?> _suggestIconViaGemini(String categoryName) async {
  final key = await Store.loadGeminiKey();
  if (key == null || key.trim().isEmpty) return null;
  try {
    // Uses the shared Gemini request helper (model fallback, retries on
    // overload, generous timeout) - a single quick call to one model with
    // an 8-second timeout failed far too often, leaving the generic icon.
    final reply = await geminiTextRequest(
      key.trim(),
      'A personal finance app has a spending/income category named "$categoryName" (the name may be Persian). '
      'Pick the single Material icon from this list that best represents it and reply with only the icon name, '
      'nothing else: ${_aiIconChoices.keys.join(', ')}',
    );
    final text = reply.toLowerCase();
    // Longest names first, so e.g. "car_repair" wins over "car".
    final names = _aiIconChoices.keys.toList()..sort((a, b) => b.length.compareTo(a.length));
    for (final n in names) {
      if (text.contains(n)) return _aiIconChoices[n];
    }
  } catch (_) {
    // best-effort only; the category keeps the generic icon and is retried later
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
  // Anything still showing the generic placeholder icon (also older
  // categories saved before the retry flag existed) - capped per day so a
  // long list can't eat the day's Gemini quota.
  final pending = categories.where((c) => c.iconNeedsRetry || _isGenericIcon(c.iconCodePoint)).take(10).toList();
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
  final accountList = await Store.loadAccounts();
  final mainCur = mainCurrencyOf(accountList);
  final curById = {for (final a in accountList) a.id: a.currency};
  final tx = (await Store.loadConfirmedTransactions()).where((t) => (curById[t.accountId] ?? mainCur) == mainCur).toList();
  final categories = await Store.loadCategories();
  final now = DateTime.now();
  final monthKey = '${now.year}-${now.month}';
  final notifyState = await Store.loadBudgetNotifyState();
  var changed = false;

  // Build lookup structures once (instead of scanning the full category
  // list per transaction, which made this noticeably slow with many
  // transactions/categories) - a map for O(1) lookup, and a cache of each
  // category's resolved top-level ancestor id.
  final categoryById = {for (final c in categories) c.id: c};
  final topCache = <String, String?>{};
  String? topIdOf(String id) {
    return topCache.putIfAbsent(id, () {
      var cat = categoryById[id];
      while (cat?.parentId != null) {
        cat = categoryById[cat!.parentId];
      }
      return cat?.id;
    });
  }

  for (final goal in goals) {
    if (goal.monthlyAmount <= 0) continue;
    double spend = 0;
    for (final t in tx) {
      if (t.type != TxType.expense) continue;
      if (t.date.year != now.year || t.date.month != now.month) continue;
      if (topIdOf(t.categoryId) == goal.categoryId) spend += t.amount;
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
    final name = categoryById[goal.categoryId]?.name ?? '';
    final title = switch (level) {
      'exceeded' => 'هدف هزینه‌ی «$name» رد شد',
      'met' => 'هدف هزینه‌ی «$name» به پایان رسید',
      _ => 'نزدیک شدن به هدف هزینه‌ی «$name»',
    };
    final percentText = persianDigits('${(ratio * 100).round()}%');
    final body = '$percentText از هدف این ماه (${formatAmountInput(spend)} از ${formatAmountInput(goal.monthlyAmount)}) خرج شده.';
    await NotificationService.instance.showNow(goal.categoryId.hashCode & 0xffff, title, body);
  }
  if (changed) await Store.saveBudgetNotifyState(notifyState);
}

/// Compares this month's spending in each top-level expense category
/// against the average of the previous [lookbackMonths] months (not
/// counting the current, still-in-progress month), and fires a one-time
/// notification when the current pace is unusually high - a spike worth
/// noticing even if no budget goal was ever set for that category.
Future<void> checkSpendingAnomalies({int lookbackMonths = 3}) async {
  final accountList = await Store.loadAccounts();
  final mainCur = mainCurrencyOf(accountList);
  final curById = {for (final a in accountList) a.id: a.currency};
  final tx = (await Store.loadConfirmedTransactions()).where((t) => (curById[t.accountId] ?? mainCur) == mainCur).toList();
  final categories = await Store.loadCategories();
  final now = DateTime.now();
  final monthKey = '${now.year}-${now.month}';
  final notifyState = await Store.loadAnomalyNotifyState();
  var changed = false;

  final categoryById = {for (final c in categories) c.id: c};
  final topCache = <String, String?>{};
  String? topIdOf(String id) {
    return topCache.putIfAbsent(id, () {
      var cat = categoryById[id];
      while (cat?.parentId != null) {
        cat = categoryById[cat!.parentId];
      }
      return cat?.id;
    });
  }

  // Bucket every relevant transaction by its top-level category ONCE,
  // rather than re-scanning the whole transaction list per category.
  final currentSpendByTop = <String, double>{};
  final pastSpendByTop = <String, Map<int, double>>{};
  for (final t in tx) {
    if (t.type != TxType.expense || t.categoryId == '_transfer_out_') continue;
    final topId = topIdOf(t.categoryId);
    if (topId == null) continue;
    if (t.date.year == now.year && t.date.month == now.month) {
      currentSpendByTop[topId] = (currentSpendByTop[topId] ?? 0) + t.amount;
      continue;
    }
    for (var i = 1; i <= lookbackMonths; i++) {
      var y = now.year;
      var m = now.month - i;
      while (m < 1) {
        m += 12;
        y--;
      }
      if (t.date.year == y && t.date.month == m) {
        final byMonth = pastSpendByTop.putIfAbsent(topId, () => {});
        byMonth[i] = (byMonth[i] ?? 0) + t.amount;
      }
    }
  }

  final topExpenseCategories = categories.where((c) => c.type == TxType.expense && c.parentId == null);
  for (final cat in topExpenseCategories) {
    final currentSpend = currentSpendByTop[cat.id] ?? 0;
    final pastMonthTotals = pastSpendByTop[cat.id];
    if (pastMonthTotals == null || pastMonthTotals.isEmpty) continue; // no history yet to compare against
    final avg = pastMonthTotals.values.fold(0.0, (s, v) => s + v) / lookbackMonths;
    // Ignore tiny categories (noise) and require a meaningfully higher pace.
    if (avg < 10 || currentSpend < 20) continue;
    if (currentSpend < avg * 1.5) continue;
    final key = '${cat.id}_$monthKey';
    if (notifyState.contains(key)) continue;
    notifyState.add(key);
    changed = true;
    final name = cat.name;
    final pct = ((currentSpend / avg - 1) * 100).round();
    await NotificationService.instance.showNow(
      (cat.id.hashCode & 0xffff) ^ 0x4000, // distinct id range from budget-goal notifications
      'هزینه‌ی «$name» این ماه غیرعادی بالاست',
      'تا الان ${formatAmountInput(currentSpend)} خرج شده، حدود ${persianDigits('$pct%')} بیشتر از میانگین ${persianDigits('$lookbackMonths')} ماه قبل (${formatAmountInput(avg)}).',
    );
  }
  if (changed) await Store.saveAnomalyNotifyState(notifyState);
}

/// Warns 2 days ahead of an item's return deadline (recognized by AI from a
/// receipt, or entered by hand) so it isn't missed. Tapping the notification
/// opens that transaction. Fires once per item, whenever the app is opened
/// from 2 days before the deadline through the deadline itself (so it still
/// catches up if the app wasn't opened exactly 2 days before).
Future<void> checkReturnDeadlines() async {
  final tx = await Store.loadConfirmedTransactions();
  final today = DateTime.now();
  final todayMidnight = DateTime(today.year, today.month, today.day);
  final notifyState = await Store.loadReturnNotifyState();
  var changed = false;
  for (final t in tx) {
    for (var i = 0; i < t.items.length; i++) {
      final item = t.items[i];
      final until = item.returnUntil;
      if (until == null) continue;
      final untilDay = DateTime(until.year, until.month, until.day);
      final daysLeft = untilDay.difference(todayMidnight).inDays;
      if (daysLeft < 0 || daysLeft > 2) continue;
      final key = '${t.id}_$i';
      if (notifyState.contains(key)) continue;
      notifyState.add(key);
      changed = true;
      await NotificationService.instance.showNow(
        (key.hashCode & 0xffff) ^ 0x7000,
        'مهلت مرجوعی نزدیک است',
        daysLeft == 0 ? '${item.name} امروز آخرین مهلت مرجوعی است.' : '${item.name} تا ${formatDate(untilDay)} امکان مرجوع کردن دارد.',
        payload: t.id,
      );
    }
  }
  if (changed) await Store.saveReturnNotifyState(notifyState);
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

  static const _shoppingListsKey = 'shopping_lists';

  static Future<List<ShoppingList>> loadShoppingLists() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getStringList(_shoppingListsKey) ?? [];
    return raw.map((s) => ShoppingList.fromJson(jsonDecode(s))).toList();
  }

  static Future<void> saveShoppingLists(List<ShoppingList> list) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(_shoppingListsKey, list.map((l) => jsonEncode(l.toJson())).toList());
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

  static const _anomalyNotifyKey = 'spending_anomaly_notify_state';

  /// Which "categoryId_yyyy-mm" spending-spike alerts have already been
  /// sent, so the same one isn't repeated every time the check runs.
  static Future<Set<String>> loadAnomalyNotifyState() async {
    final sp = await SharedPreferences.getInstance();
    return (sp.getStringList(_anomalyNotifyKey) ?? []).toSet();
  }

  static Future<void> saveAnomalyNotifyState(Set<String> state) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(_anomalyNotifyKey, state.toList());
  }

  static const _returnNotifyKey = 'return_deadline_notify_state';

  static Future<Set<String>> loadReturnNotifyState() async {
    final sp = await SharedPreferences.getInstance();
    return (sp.getStringList(_returnNotifyKey) ?? []).toSet();
  }

  static Future<void> saveReturnNotifyState(Set<String> state) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(_returnNotifyKey, state.toList());
  }

  static const _autoBackupFreqKey = 'auto_backup_frequency';
  static const _lastAutoBackupKey = 'auto_backup_last_at';

  static Future<AutoBackupFrequency> loadAutoBackupFrequency() async {
    final sp = await SharedPreferences.getInstance();
    final name = sp.getString(_autoBackupFreqKey);
    return AutoBackupFrequency.values.firstWhere((f) => f.name == name, orElse: () => AutoBackupFrequency.off);
  }

  static Future<void> saveAutoBackupFrequency(AutoBackupFrequency freq) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_autoBackupFreqKey, freq.name);
  }

  static Future<DateTime?> loadLastAutoBackupAt() async {
    final sp = await SharedPreferences.getInstance();
    final v = sp.getString(_lastAutoBackupKey);
    return v == null ? null : DateTime.tryParse(v);
  }

  static Future<void> saveLastAutoBackupAt(DateTime when) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_lastAutoBackupKey, when.toIso8601String());
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
    for (final c in CalendarSystem.values) {
      if (c.name == code) return c;
    }
    // Nothing chosen yet. A brand-new install starts on the Jalali calendar,
    // but someone who already used the app before this option existed keeps
    // the Gregorian calendar they were seeing - an update must not switch it.
    final hadData = sp.containsKey(_txKey) || sp.containsKey(_accKey) || sp.containsKey(_catKey);
    final chosen = hadData ? CalendarSystem.gregorian : CalendarSystem.jalali;
    await sp.setString(_calendarSystemKey, chosen.name);
    return chosen;
  }

  static Future<void> saveCalendarSystem(CalendarSystem system) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_calendarSystemKey, system.name);
  }

  static const _baseCurrencyKey = 'net_worth_base_currency';
  static const _exchangeRatesKey = 'net_worth_exchange_rates';

  static Future<String?> loadBaseCurrency() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString(_baseCurrencyKey);
  }

  static Future<void> saveBaseCurrency(String currency) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_baseCurrencyKey, currency);
  }

  /// Manual exchange rates: units of the base currency per 1 unit of the
  /// map's key currency (e.g. {'USD': 0.93} if base is EUR). Used only for
  /// the net-worth trend chart, which otherwise couldn't combine
  /// multi-currency accounts into one line.
  static Future<Map<String, double>> loadExchangeRates() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_exchangeRatesKey);
    if (raw == null) return {};
    return (jsonDecode(raw) as Map<String, dynamic>).map((k, v) => MapEntry(k, (v as num).toDouble()));
  }

  static Future<void> saveExchangeRates(Map<String, double> rates) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_exchangeRatesKey, jsonEncode(rates));
  }

  /// Transactions that count in balances, totals, budgets, charts and
  /// reports. Drafts are excluded until they are confirmed.
  static Future<List<Transaction>> loadConfirmedTransactions() async {
    final all = await loadTransactions();
    return all.where((t) => !t.draft).toList();
  }

  // In-memory copy of the transactions: decoding + migrating the whole list
  // on every screen and every save was the main cost behind slow saves and
  // refreshes. Transaction objects are immutable, so a shallow list copy is
  // enough to keep callers from disturbing the cache.
  static List<Transaction>? _txCache;
  // id -> that transaction's own encoded JSON string, reused across saves so
  // only the transaction(s) that actually changed get re-encoded - encoding
  // the whole list on every single save is what made saving (and the
  // keyboard-close right after it) get slower as the number of transactions
  // grew.
  static final Map<String, String> _txJsonCache = {};

  static Future<List<Transaction>> loadTransactions() async {
    final cached = _txCache;
    if (cached != null) return List.of(cached);
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
    // One-time fix: a transaction's date used to default to DateTime.now()
    // (which carries the current time-of-day), not just the calendar date.
    // Any "due vs not-yet-due" check compares against exact midnight, so a
    // same-day transaction saved with, say, 14:35 on it would wrongly test
    // as being "after" midnight and show up as not-yet-due. Strip the time
    // component so every date is a clean midnight-anchored calendar date.
    list = list.map((t) {
      final d = t.date;
      if (d.hour != 0 || d.minute != 0 || d.second != 0 || d.millisecond != 0 || d.microsecond != 0) {
        changed = true;
        return t.copyWith(date: DateTime(d.year, d.month, d.day));
      }
      return t;
    }).toList();
    if (changed) await saveTransactions(list);
    _txCache = List.of(list);
    _txJsonCache.clear();
    return list;
  }

  static Future<void> saveTransactions(List<Transaction> list) async {
    _txCache = List.of(list);
    final ids = list.map((t) => t.id).toSet();
    _txJsonCache.removeWhere((id, _) => !ids.contains(id)); // drop deleted ones
    final encoded = [
      for (final t in list) _txJsonCache[t.id] ??= jsonEncode(t.toJson()),
    ];
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(_txKey, encoded);
  }

  /// Same as [saveTransactions], but for callers that already know exactly
  /// which transactions changed (upsert/delete) - re-encodes only those,
  /// instead of every entry in [list].
  static Future<void> _saveTransactionsIncremental(List<Transaction> list, Iterable<String> changedIds) async {
    _txCache = List.of(list);
    for (final id in changedIds) {
      _txJsonCache.remove(id);
    }
    final ids = list.map((t) => t.id).toSet();
    _txJsonCache.removeWhere((id, _) => !ids.contains(id));
    final encoded = [
      for (final t in list) _txJsonCache[t.id] ??= jsonEncode(t.toJson()),
    ];
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(_txKey, encoded);
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
    final changedIds = <String>{t.id};
    final idx = list.indexWhere((x) => x.id == t.id);
    if (idx >= 0) {
      list[idx] = t;
    } else {
      list.add(t);
    }
    // A transfer is really one event told from two accounts' sides -
    // editing the date/recurrence on one leg should keep the other leg
    // (kept in its own type/category/account/note) in sync, so the pair
    // doesn't silently drift apart.
    if (t.categoryId == '_transfer_out_' || t.categoryId == '_transfer_in_') {
      final pairId = _transferPairId(t.id);
      if (pairId != null) {
        final pairIdx = list.indexWhere((x) => x.id == pairId);
        if (pairIdx >= 0) {
          // The amount is only kept identical between the two legs when
          // their accounts share the same currency - for a cross-currency
          // transfer the legs are meant to differ (by the exchange rate
          // applied when the transfer was made), so overwriting one side's
          // amount here would silently corrupt that conversion.
          final accounts = await loadAccounts();
          String currencyOf(String accountId) {
            final m = accounts.where((a) => a.id == accountId).toList();
            return m.isEmpty ? '' : m.first.currency;
          }

          final sameCurrency = currencyOf(t.accountId) == currencyOf(list[pairIdx].accountId);
          changedIds.add(list[pairIdx].id);
          list[pairIdx] = list[pairIdx].copyWith(
            amount: sameCurrency ? t.amount : null,
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
    await _saveTransactionsIncremental(list, changedIds);
  }

  /// Deletes a transaction (and its transfer pair, if it has one) and
  /// returns everything that was removed, so the caller can offer an
  /// "undo" that restores them exactly.
  static Future<List<Transaction>> deleteTransaction(String id) async {
    final list = await loadTransactions();
    final removed = <Transaction>[];
    final target = list.where((x) => x.id == id).toList();
    if (target.isNotEmpty) removed.add(target.first);
    list.removeWhere((x) => x.id == id);
    // Deleting one leg of a transfer without the other would leave a
    // one-sided "phantom" transaction behind - remove both together.
    final pairId = _transferPairId(id);
    if (pairId != null) {
      final pair = list.where((x) => x.id == pairId).toList();
      if (pair.isNotEmpty) removed.add(pair.first);
      list.removeWhere((x) => x.id == pairId);
    }
    await saveTransactions(list);
    return removed;
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

  /// The app's main currency = the currency of the first ("main") account.
  /// Amounts that belong to no account (budget limits, savings goals) are in
  /// this currency, and totals that can't mix currencies count only accounts
  /// that use it.
  static Future<String> loadMainCurrency() async {
    final accounts = await loadAccounts();
    return accounts.isEmpty ? 'IRT' : accounts.first.currency;
  }

  /// Changes the currency of [accountIds] to [newCurrency] and multiplies
  /// every amount that belongs to those accounts by [factor] (initial
  /// balance, transactions, item prices, payslip lines). When the main
  /// account is among them, the budget limits and savings goals - which live
  /// in the main currency - are scaled by the same factor.
  static Future<void> convertAccountsCurrency({
    required Set<String> accountIds,
    required String newCurrency,
    required double factor,
  }) async {
    final accounts = await loadAccounts();
    final mainId = accounts.isEmpty ? null : accounts.first.id;
    final mainConverted = mainId != null && accountIds.contains(mainId);

    await saveAccounts([
      for (final a in accounts)
        accountIds.contains(a.id)
            ? a.copyWith(currency: newCurrency, initialBalance: roundMoney(a.initialBalance * factor))
            : a,
    ]);

    final tx = await loadTransactions();
    await saveTransactions([for (final t in tx) accountIds.contains(t.accountId) ? t.scaled(factor) : t]);

    if (mainConverted) {
      final budgets = await loadBudgetGoals();
      await saveBudgetGoals([for (final b in budgets) BudgetGoal(categoryId: b.categoryId, monthlyAmount: roundMoney(b.monthlyAmount * factor))]);
      final goals = await loadSavingsGoals();
      await saveSavingsGoals([
        for (final g in goals)
          SavingsGoal(id: g.id, name: g.name, targetAmount: roundMoney(g.targetAmount * factor), targetDate: g.targetDate, currency: newCurrency),
      ]);
      final contributions = await loadSavingsContributions();
      await saveSavingsContributions([
        for (final c in contributions)
          SavingsContribution(id: c.id, goalId: c.goalId, amount: roundMoney(c.amount * factor), date: c.date, note: c.note),
      ]);
    }
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
  'upcoming_payments': {AppLanguage.fa: 'هزینه‌های پیش‌رو', AppLanguage.en: 'Upcoming expenses', AppLanguage.de: 'Bevorstehende Ausgaben'},
  'budget_goals': {AppLanguage.fa: 'اهداف هزینه', AppLanguage.en: 'Budget goals', AppLanguage.de: 'Budgetziele'},
  'savings_goals': {AppLanguage.fa: 'اهداف پس‌انداز', AppLanguage.en: 'Savings goals', AppLanguage.de: 'Sparziele'},
  'transfer_between_accounts': {AppLanguage.fa: 'انتقال بین حساب‌ها', AppLanguage.en: 'Transfer between accounts', AppLanguage.de: 'Kontoübertragung'},
  'all_transactions': {AppLanguage.fa: 'همه‌ی تراکنش‌ها', AppLanguage.en: 'All transactions', AppLanguage.de: 'Alle Buchungen'},
  'full_reporting': {AppLanguage.fa: 'گزارش', AppLanguage.en: 'Report', AppLanguage.de: 'Bericht'},
  'expense_forecast': {AppLanguage.fa: 'پیش‌بینی هزینه', AppLanguage.en: 'Expense forecast', AppLanguage.de: 'Ausgabenprognose'},
  'month_calendar': {AppLanguage.fa: 'خلاصه ماه در یک نگاه', AppLanguage.en: 'Month at a glance', AppLanguage.de: 'Monat im Überblick'},
  'item_search_title': {AppLanguage.fa: 'جستجوی کالا', AppLanguage.en: 'Search items', AppLanguage.de: 'Artikel suchen'},
  'net_worth_title': {AppLanguage.fa: 'روند ارزش خالص دارایی', AppLanguage.en: 'Net worth trend', AppLanguage.de: 'Vermögensentwicklung'},
  'section_accounts_categories': {AppLanguage.fa: 'حساب‌ها و دسته‌بندی‌ها', AppLanguage.en: 'Accounts & categories', AppLanguage.de: 'Konten & Kategorien'},
  'section_transactions': {AppLanguage.fa: 'تراکنش‌ها', AppLanguage.en: 'Transactions', AppLanguage.de: 'Buchungen'},
  'section_budget_goals': {AppLanguage.fa: 'بودجه و اهداف', AppLanguage.en: 'Budget & goals', AppLanguage.de: 'Budget & Ziele'},
  'section_reports': {AppLanguage.fa: 'گزارش‌ها و تحلیل', AppLanguage.en: 'Reports & analysis', AppLanguage.de: 'Berichte & Analyse'},
  'section_data': {AppLanguage.fa: 'داده', AppLanguage.en: 'Data', AppLanguage.de: 'Daten'},
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
  'appearance_title': {AppLanguage.fa: 'ظاهر برنامه', AppLanguage.en: 'Appearance', AppLanguage.de: 'Erscheinungsbild'},
  'calendar_title': {AppLanguage.fa: 'تقویم', AppLanguage.en: 'Calendar', AppLanguage.de: 'Kalender'},
  'gemini_key_guide_title': {AppLanguage.fa: 'راهنمای دریافت کلید هوش مصنوعی', AppLanguage.en: 'AI key setup guide', AppLanguage.de: 'Anleitung für den KI-Schlüssel'},
  'about_title': {AppLanguage.fa: 'درباره‌ی برنامه', AppLanguage.en: 'About', AppLanguage.de: 'Über die App'},
  'gemini_settings_title': {AppLanguage.fa: 'هوش مصنوعی (Gemini)', AppLanguage.en: 'AI (Gemini)', AppLanguage.de: 'KI (Gemini)'},
  'savings_suggestion_title': {
    AppLanguage.fa: 'پیشنهاد پس‌انداز و سرمایه‌گذاری',
    AppLanguage.en: 'Savings & investment suggestion',
    AppLanguage.de: 'Spar- und Anlagevorschlag',
  },
  'zero_based_budget_title': {AppLanguage.fa: 'بودجه‌بندی صفر-پایه', AppLanguage.en: 'Zero-based budget', AppLanguage.de: 'Zero-Based-Budget'},
  'csv_import_title': {AppLanguage.fa: 'بارگذاری صورتحساب بانکی', AppLanguage.en: 'Import bank statement', AppLanguage.de: 'Kontoauszug importieren'},
  'shopping_lists_title': {AppLanguage.fa: 'لیست‌های خرید', AppLanguage.en: 'Shopping lists', AppLanguage.de: 'Einkaufslisten'},
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
      navigatorKey: rootNavigatorKey,
      navigatorObservers: [appRouteObserver],
      home: const AppLockGate(child: HomeScreen()),
    );
  }
}

/// Lets the home screen notice when the person comes back to it, so its
/// numbers refresh without pulling the page down.
final RouteObserver<ModalRoute<void>> appRouteObserver = RouteObserver<ModalRoute<void>>();

/// Lets a tapped notification open a screen even though notification
/// callbacks have no BuildContext of their own.
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

/// Opens the detail screen for the transaction a notification was about
/// (e.g. a return-deadline reminder), once the app/navigator is ready.
Future<void> openTransactionFromNotification(String? payload) async {
  if (payload == null || payload.isEmpty) return;
  final nav = rootNavigatorKey.currentState;
  if (nav == null) return;
  final all = await Store.loadTransactions();
  final match = all.where((t) => t.id == payload).toList();
  if (match.isEmpty) return;
  final categories = await Store.loadCategories();
  final accounts = await Store.loadAccounts();
  nav.push(MaterialPageRoute(builder: (_) => TransactionDetailScreen(t: match.first, categories: categories, accounts: accounts)));
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
            sectionLabel(tr('section_accounts_categories')),
            item(1, Icons.category_outlined, tr('category_management'), () => const CategoryManagementScreen()),
            item(2, Icons.account_balance_wallet_outlined, tr('accounts'), () => const AccountManagementScreen()),
            item(13, Icons.swap_horiz, tr('transfer_between_accounts'), () => const TransferScreen()),
            const Divider(height: 1),
            sectionLabel(tr('section_transactions')),
            item(12, Icons.list_alt, tr('all_transactions'), () => const AllTransactionsScreen()),
            item(21, Icons.edit_note_outlined, 'تراکنش‌های پیش‌نویس', () => const DraftsScreen()),
            item(5, Icons.category_outlined, tr('affected_by_category_delete'), () => const AffectedTransactionsScreen()),
            item(19, Icons.upload_file_outlined, tr('csv_import_title'), () => const CsvImportScreen()),
            item(20, Icons.shopping_cart_outlined, tr('shopping_lists_title'), () => const ShoppingListsScreen()),
            const Divider(height: 1),
            sectionLabel(tr('section_budget_goals')),
            item(14, Icons.flag_outlined, tr('budget_goals'), () => const BudgetGoalsScreen()),
            item(18, Icons.pie_chart_outline, tr('zero_based_budget_title'), () => const ZeroBasedBudgetScreen()),
            item(15, Icons.savings_outlined, tr('savings_goals'), () => const SavingsGoalsScreen()),
            item(16, Icons.lightbulb_outline, tr('savings_suggestion_title'), () => const SavingsSuggestionScreen()),
            const Divider(height: 1),
            sectionLabel(tr('section_reports')),
            item(8, Icons.upcoming_outlined, tr('upcoming_payments'), () => const UpcomingPaymentsScreen()),
            item(7, Icons.bar_chart_outlined, tr('full_reporting'), () => const ReportsScreen()),
            item(9, Icons.trending_up, tr('expense_forecast'), () => const ForecastScreen()),
            item(10, Icons.calendar_month_outlined, tr('month_calendar'), () => const MonthCalendarScreen()),
            item(17, Icons.show_chart, tr('net_worth_title'), () => const NetWorthScreen()),
            const Divider(height: 1),
            sectionLabel(tr('section_data')),
            item(6, Icons.backup_outlined, tr('backup_restore_title'), () => const BackupRestoreScreen()),
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
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('درباره‌ی برنامه'),
            subtitle: Text(ltr('نسخه‌ی ${persianDigits(kAppVersion)} • حریم خصوصی و شرایط استفاده')),
            trailing: const Icon(Icons.chevron_left),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const AboutScreen())),
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
      appBar: AppBar(title: Text(tr('appearance_title'))),
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
      appBar: AppBar(title: Text(tr('calendar_title'))),
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
                subtitle: Text('مثلاً ۱۴۰۵/۰۷/۰۱'),
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

/// Shows a short dialog explaining that this AI feature needs a Gemini API
/// key, with a way to open the step-by-step guide - used everywhere an AI
/// action is attempted without a key configured yet.
Future<void> promptForGeminiKey(BuildContext context) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('نیاز به کلید هوش مصنوعی'),
      content: const Text(
        'برای استفاده از قابلیت‌های هوش مصنوعی (مثل خواندن خودکار رسید/فیش یا پیشنهاد پس‌انداز)، ابتدا باید یک کلید API رایگان از Gemini بگیری و در تنظیمات برنامه وارد کنی.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('cancel'))),
        FilledButton(
          onPressed: () {
            Navigator.pop(ctx);
            Navigator.push(context, MaterialPageRoute(builder: (_) => const GeminiKeyGuideScreen()));
          },
          child: const Text('راهنما'),
        ),
      ],
    ),
  );
}

class GeminiKeyGuideScreen extends StatelessWidget {
  const GeminiKeyGuideScreen({super.key});
  static const _keyUrl = 'https://aistudio.google.com/app/apikey';

  Widget _step(BuildContext context, int n, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 13,
            backgroundColor: Theme.of(context).colorScheme.primaryContainer,
            child: Text(ltr(persianDigits('$n')), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 14, height: 1.6))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('gemini_key_guide_title'))),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'کلید Gemini رایگانه و فقط چند دقیقه طول می‌کشه. این کلید فقط روی گوشی خودت ذخیره می‌شه و به جایی فرستاده نمی‌شه.',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 20),
          _step(context, 1, 'روی دکمه‌ی زیر بزن تا لینک صفحه‌ی دریافت کلید کپی بشه، و اون رو توی مرورگر گوشیت باز کن.'),
          Padding(
            padding: const EdgeInsets.only(right: 36, bottom: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SelectableText(_keyUrl, style: TextStyle(fontSize: 12, color: Colors.blue)),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(const ClipboardData(text: _keyUrl));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('لینک کپی شد.')));
                    }
                  },
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('کپی لینک'),
                ),
              ],
            ),
          ),
          _step(context, 2, 'با حساب گوگلت وارد شو (همون حسابی که جیمیل داری).'),
          _step(context, 3, 'روی دکمه‌ی «Create API key» بزن.'),
          _step(context, 4, 'کلیدی که ساخته می‌شه رو کپی کن (یه رشته‌ی طولانی که با AIza شروع می‌شه).'),
          _step(context, 5, 'برگرد به این برنامه، از منو برو به «تنظیمات › هوش مصنوعی (Gemini)»، کلید رو توی همون‌جا بچسبون و ذخیره کن.'),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const GeminiSettingsScreen())),
            icon: const Icon(Icons.settings_outlined),
            label: const Text('رفتن به تنظیمات هوش مصنوعی'),
          ),
        ],
      ),
    );
  }
}

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  Widget _sectionTitle(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(top: 20, bottom: 8),
        child: Text(text, style: Theme.of(context).textTheme.titleMedium),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('about_title'))),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Center(
            child: Column(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: Image.asset('assets/icon/icon.png', width: 84, height: 84, errorBuilder: (_, __, ___) => const Icon(Icons.savings, size: 84)),
                ),
                const SizedBox(height: 12),
                const Text('مدیریت مالی شخصی', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(ltr('نسخه‌ی ${persianDigits(kAppVersion)}'), style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
                const SizedBox(height: 2),
                Text('توسعه‌دهنده: $kDeveloperName', style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
              ],
            ),
          ),
          _sectionTitle(context, 'درباره'),
          const Text(
            'این برنامه برای مدیریت هزینه‌ها، درآمدها، حساب‌ها، اهداف پس‌انداز و بودجه‌بندی شخصی طراحی شده. '
            'همه‌ی اطلاعات مالی فقط روی همین گوشی ذخیره می‌شوند و به هیچ سروری فرستاده نمی‌شوند.',
            style: TextStyle(fontSize: 13, height: 1.7),
          ),
          _sectionTitle(context, 'حریم خصوصی'),
          const Text(
            '• تمام تراکنش‌ها، دسته‌بندی‌ها، حساب‌ها و تصاویر رسید/فیش فقط به‌صورت محلی روی گوشی شما ذخیره می‌شوند؛ '
            'این برنامه هیچ سرور یا پایگاه‌داده‌ی مرکزی ندارد و توسعه‌دهنده به اطلاعات شما دسترسی ندارد.\n\n'
            '• قابلیت خواندن هوشمند رسید/فیش (اختیاری) با استفاده از سرویس Gemini گوگل و با کلید API شخصیِ خودتان انجام می‌شود؛ '
            'در این حالت فقط تصویر همان رسید/فیش برای پردازش به سرویس Gemini ارسال می‌شود، طبق قوانین حریم خصوصی گوگل.\n\n'
            '• قفل برنامه (اثر انگشت/پین) به‌صورت محلی و رمزنگاری‌شده روی گوشی ذخیره می‌شود.\n\n'
            '• پشتیبان‌گیری فقط با اقدام شخص کاربر و به‌صورت فایل روی گوشی/فضای ابری شخصی او انجام می‌شود.\n\n'
            '• این برنامه هیچ داده‌ای را برای تبلیغات یا فروش به اشخاص ثالث جمع‌آوری نمی‌کند.',
            style: TextStyle(fontSize: 13, height: 1.8),
          ),
          _sectionTitle(context, 'شرایط استفاده'),
          const Text(
            '• این برنامه یک ابزار شخصی برای ثبت و پیگیری اطلاعات مالی است و جایگزین مشاوره‌ی مالی، حسابداری یا حقوقی رسمی نیست.\n\n'
            '• پیشنهادهای بخش «پیشنهاد پس‌انداز و سرمایه‌گذاری» جنبه‌ی آموزشی و کلی دارند و توصیه‌ی مالی شخصی‌سازی‌شده محسوب نمی‌شوند.\n\n'
            '• صحت اطلاعات خوانده‌شده توسط هوش مصنوعی (از روی تصویر رسید/فیش) باید توسط کاربر بررسی و تأیید شود.\n\n'
            '• مسئولیت نگهداری از نسخه‌ی پشتیبان اطلاعات بر عهده‌ی کاربر است.',
            style: TextStyle(fontSize: 13, height: 1.8),
          ),
          _sectionTitle(context, 'پشتیبانی'),
          const Text('برای گزارش مشکل یا پیشنهاد، می‌توانید از راه زیر با ما در ارتباط باشید:', style: TextStyle(fontSize: 13)),
          const SizedBox(height: 6),
          SelectableText(ltr(kSupportEmail), style: const TextStyle(fontSize: 13, color: Colors.blue)),
          const SizedBox(height: 20),
        ],
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
      appBar: AppBar(title: Text(tr('gemini_settings_title'))),
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
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.copy_outlined),
                    tooltip: 'کپی کلید',
                    onPressed: () async {
                      if (ctrl.text.trim().isEmpty) return;
                      await Clipboard.setData(ClipboardData(text: ctrl.text.trim()));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('کلید کپی شد.')));
                      }
                    },
                  ),
                  IconButton(
                    icon: Icon(obscure ? Icons.visibility_off : Icons.visibility),
                    onPressed: () => setState(() => obscure = !obscure),
                  ),
                ],
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

/// Asked when a draft that carries a scanned receipt/payslip photo becomes a
/// final transaction. Returns true to keep the photo, false to delete it and
/// null if the dialog was dismissed (the save should then be cancelled).
Future<bool?> askKeepReceiptImage(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('تصویر فیش'),
      content: const Text('تصویر فیش/رسید هم همراه این تراکنش ذخیره شود؟'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('خیر، حذف شود')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('بله، ذخیره شود')),
      ],
    ),
  );
}

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

const _maxPdfPages = 6;
// Tallest combined image we produce; taller bitmaps can fail to decode or
// display on some phones, so many pages get a narrower (smaller) width.
const _maxStitchedHeight = 8000.0;

/// Renders a PDF at [path] to one temporary image and returns its path.
/// Multi-page PDFs (e.g. payslips spanning several pages) get all their
/// pages - up to [_maxPdfPages] - stacked top to bottom in a single image,
/// so the AI reads every page and the preview/draft keeps them all.
Future<String> rasterizePdfPages(String path) async {
  final doc = await PdfDocument.openFile(path);
  try {
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final count = min(doc.pagesCount, _maxPdfPages);
    if (count <= 1) {
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
      final outPath = '${dir.path}/scan_$stamp.jpg';
      await File(outPath).writeAsBytes(rendered!.bytes);
      return outPath;
    }

    // One common width for every page; shrink it if the stack gets too tall.
    final ratios = <double>[];
    for (var i = 1; i <= count; i++) {
      final page = await doc.getPage(i);
      ratios.add(page.height / page.width);
      await page.close();
    }
    const gap = 12.0;
    final totalRatio = ratios.fold(0.0, (a, b) => a + b);
    var outW = 1400.0;
    if (outW * totalRatio + gap * (count - 1) > _maxStitchedHeight) {
      outW = (_maxStitchedHeight - gap * (count - 1)) / totalRatio;
    }
    final heights = ratios.map((r) => (outW * r).roundToDouble()).toList();
    final totalH = heights.fold(0.0, (a, b) => a + b) + gap * (count - 1);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(Rect.fromLTWH(0, 0, outW, totalH), Paint()..color = Colors.grey.shade400);
    var y = 0.0;
    for (var i = 0; i < count; i++) {
      final page = await doc.getPage(i + 1);
      final rendered = await page.render(width: outW, height: heights[i], format: PdfPageImageFormat.png);
      await page.close();
      final codec = await ui.instantiateImageCodec(rendered!.bytes);
      final frame = await codec.getNextFrame();
      final img = frame.image;
      canvas.drawRect(Rect.fromLTWH(0, y, outW, heights[i]), Paint()..color = Colors.white);
      canvas.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        Rect.fromLTWH(0, y, outW, heights[i]),
        Paint()..filterQuality = FilterQuality.high,
      );
      img.dispose();
      codec.dispose();
      y += heights[i] + gap;
    }
    final picture = recorder.endRecording();
    final stitched = await picture.toImage(outW.round(), totalH.round());
    picture.dispose();
    final data = await stitched.toByteData(format: ui.ImageByteFormat.png);
    stitched.dispose();
    final outPath = '${dir.path}/scan_$stamp.png';
    await File(outPath).writeAsBytes(data!.buffer.asUint8List());
    return outPath;
  } finally {
    await doc.close();
  }
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
  String? currency; // detected from the receipt text (EUR, USD, IRR, IRT...), if any
  ReceiptDraft({this.merchant = '', this.date, this.total, this.items = const [], this.categoryHint, this.currency});
}

/// Guesses the currency printed on a receipt/payslip from its text, using
/// the same codes as accounts. Returns null when nothing clear is found.
String? detectCurrencyInText(String text) {
  final t = text.toLowerCase();
  if (t.contains('تومان') || t.contains('toman')) return 'IRT';
  if (t.contains('ریال') || t.contains('rial') || t.contains('irr')) return 'IRR';
  if (t.contains('€') || RegExp(r'\beur\b').hasMatch(t) || t.contains('euro')) return 'EUR';
  if (t.contains('\$') || RegExp(r'\busd\b').hasMatch(t)) return 'USD';
  if (t.contains('£') || RegExp(r'\bgbp\b').hasMatch(t)) return 'GBP';
  if (RegExp(r'\bchf\b').hasMatch(t)) return 'CHF';
  return null;
}

/// Normalises a currency answer from the AI (code, symbol or name) to the
/// codes used for accounts.
String? normalizeCurrency(Object? raw) {
  if (raw == null) return null;
  final s = raw.toString().trim();
  if (s.isEmpty || s.toLowerCase() == 'null') return null;
  return detectCurrencyInText(s) ?? (RegExp(r'^[A-Za-z]{3}$').hasMatch(s) ? s.toUpperCase() : null);
}

/// Last day of the pay period written on a payslip ("09/2026", "2026-09",
/// "September 2026", "Sep. 2026"...), used as the payment date when the
/// payslip doesn't print one.
DateTime? payPeriodEnd(String? period) {
  if (period == null || period.trim().isEmpty) return null;
  final p = period.toLowerCase();
  int? y, m;
  final num = RegExp(r'(\d{1,2})\s*[./-]\s*(\d{4})').firstMatch(p);
  final iso = RegExp(r'(\d{4})\s*[./-]\s*(\d{1,2})').firstMatch(p);
  if (num != null) {
    m = int.tryParse(num.group(1)!);
    y = int.tryParse(num.group(2)!);
  } else if (iso != null) {
    y = int.tryParse(iso.group(1)!);
    m = int.tryParse(iso.group(2)!);
  } else {
    const names = [
      ['jan'], ['feb'], ['mär', 'mar'], ['apr'], ['mai', 'may'], ['jun'],
      ['jul'], ['aug'], ['sep'], ['okt', 'oct'], ['nov'], ['dez', 'dec'],
    ];
    for (var i = 0; i < 12 && m == null; i++) {
      if (names[i].any(p.contains)) m = i + 1;
    }
    final ym = RegExp(r'(\d{4})').firstMatch(p);
    y = ym == null ? null : int.tryParse(ym.group(1)!);
  }
  if (y == null || m == null || m < 1 || m > 12) return null;
  return DateTime(y, m + 1, 0);
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
  draft.currency = detectCurrencyInText(text);
  return draft;
}

const _payslipFieldKeywords = <String, List<String>>{
  'brutto': ['brutto', 'gesamtbrutto'],
  'netto': ['netto', 'auszahlungsbetrag'],
  'lohnsteuer': ['lohnsteuer'],
  'solidaritaetszuschlag': ['solidaritätszuschlag', 'soli'],
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
  final cur = detectCurrencyInText(text);
  if (cur != null) result['currency'] = cur;

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

/// What a Gemini 429 response is actually about: Google uses the same code
/// for the per-minute rate limit and for the daily quota, and only the
/// response body tells them apart.
({bool daily, Duration? retryAfter}) _parseGeminiQuota(String body) {
  final daily = body.contains('PerDay');
  final m = RegExp(r'"retryDelay"\s*:\s*"(\d+(?:\.\d+)?)s"').firstMatch(body);
  final secs = m == null ? null : double.tryParse(m.group(1)!);
  return (daily: daily, retryAfter: secs == null ? null : Duration(milliseconds: (secs * 1000).round()));
}

/// Sends [body] to Gemini, walking the model fallback list, and returns the
/// first successful response or throws a [GeminiException] whose message
/// names the real cause.
///
/// Each attempt counts against the free-tier limits, so retries are kept to
/// a minimum: an overloaded (503) or rate-limited (429) model gets at most
/// one more try after a pause and then the next model is used instead
/// (each model has its own separate quota), rather than hammering the same
/// model - which is what used to turn "servers busy" into a spurious
/// "daily quota exhausted".
Future<http.Response> _geminiPost(String apiKey, String body) async {
  http.Response? resp;
  Object? lastNetworkError;
  final attemptedModels = <String>[];
  var sawOverload = false;
  var sawPerMinuteLimit = false;
  var sawDailyLimit = false;
  for (final model in _geminiModels) {
    attemptedModels.add(model);
    final uri = Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey');
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        resp = await http
            .post(uri, headers: {'Content-Type': 'application/json'}, body: body)
            .timeout(const Duration(seconds: 45));
        lastNetworkError = null;
      } catch (e) {
        lastNetworkError = e;
        resp = null;
        if (attempt == 1) break;
        await Future.delayed(const Duration(seconds: 2));
        continue;
      }
      final code = resp.statusCode;
      if (code == 200) return resp;
      if (code == 503 || code == 500) {
        sawOverload = true;
        if (attempt == 0) {
          await Future.delayed(const Duration(seconds: 3));
          continue;
        }
        break;
      }
      if (code == 429) {
        final quota = _parseGeminiQuota(resp.body);
        if (quota.daily) {
          // This model's daily quota is gone; retrying it is pointless.
          sawDailyLimit = true;
          break;
        }
        sawPerMinuteLimit = true;
        final wait = quota.retryAfter ?? const Duration(seconds: 10);
        if (attempt == 0 && wait <= const Duration(seconds: 20)) {
          await Future.delayed(wait + const Duration(seconds: 1));
          continue;
        }
        break;
      }
      break;
    }
    // No connection at all - other models won't fare any better.
    if (resp == null) break;
    // Retired/renamed model, overloaded or out of quota: try the next one.
    // Anything else (bad key, bad request) won't be fixed by another model.
    if (![404, 429, 500, 503].contains(resp.statusCode)) break;
  }
  final raw = resp != null
      ? 'مدل‌های امتحان‌شده: ${attemptedModels.join(', ')}\nHTTP ${resp.statusCode}\n${resp.body}'
      : 'مدل‌های امتحان‌شده: ${attemptedModels.join(', ')}\nخطای شبکه: $lastNetworkError';
  if (resp == null) {
    throw GeminiException('اتصال به Gemini برقرار نشد. اتصال اینترنت را بررسی کنید و دوباره امتحان کنید.', raw);
  }
  if (sawPerMinuteLimit) {
    throw GeminiException(
        'تعداد درخواست‌ها به Gemini در یک دقیقه از حد مجاز رایگان گذشت. حدود یک دقیقه صبر کنید و دوباره امتحان کنید (سهمیه‌ی روزانه تمام نشده).',
        raw);
  }
  if (sawOverload) {
    throw GeminiException('سرورهای Gemini موقتاً شلوغ هستند. لطفاً چند دقیقه دیگر دوباره امتحان کنید.', raw);
  }
  if (sawDailyLimit) {
    throw GeminiException('سهمیه‌ی رایگان روزانه‌ی Gemini برای امروز تمام شده. فردا دوباره امتحان کنید.', raw);
  }
  final code = resp.statusCode;
  if (code == 400 && resp.body.contains('API_KEY_INVALID')) {
    throw GeminiException('کلید API جمنای نامعتبر است. آن را در تنظیمات بررسی کنید.', raw);
  }
  if (code == 403) {
    throw GeminiException('کلید API جمنای اجازه‌ی دسترسی ندارد (HTTP 403). آن را در تنظیمات بررسی کنید.', raw);
  }
  throw GeminiException('خطای Gemini API ($code)', raw);
}

Future<Map<String, dynamic>?> _geminiRequest(String apiKey, String imagePath, String prompt) async {
  final bytes = await File(imagePath).readAsBytes();
  final b64 = base64Encode(bytes);
  final body = jsonEncode({
    'contents': [
      {
        'parts': [
          {'text': prompt},
          {
            'inline_data': {'mime_type': imagePath.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg', 'data': b64}
          },
        ],
      },
    ],
    'generationConfig': {'response_mime_type': 'application/json'},
  });

  final resp = await _geminiPost(apiKey, body);
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
    'string or null}], "category": string or null, "keepReceipt": boolean, "keepReceiptItems": [string], '
    '"keepReceiptReason": string, "currency": string or null}. '
    '"currency" is the ISO 4217 code of the currency the amounts are printed in (e.g. "EUR", "USD"; for '
    'Iranian receipts use "IRR" for ریال and "IRT" for تومان), or null if it cannot be told. '
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
    '"keepReceiptItems" lists the exact names (from "items") of only the items that are clothing/shoes, '
    'home goods/housewares (furniture, cookware, dishware, textiles), or electrical/electronic appliances '
    '- do NOT include tools, toys, groceries, or anything else even if "isPhysicalGood" is true for it. '
    '"keepReceipt" is true only if "keepReceiptItems" is non-empty (those categories commonly need the '
    'receipt for warranty or returns) and false otherwise (e.g. a purely grocery/food receipt, or a '
    'receipt whose only physical items are tools or toys). "keepReceiptReason" is one short sentence in '
    'Persian (Farsi), regardless of what language the receipt itself is in: when true, explicitly name the '
    'item(s) from "keepReceiptItems" as the reason (e.g. "به‌خاطر [item names], بهتره فیش رو نگه داری"); '
    'when false, briefly say why not in Persian (e.g. all items are food/consumables). Keep merchant name '
    'in the receipt\'s own language/script. Numbers must be plain (no currency symbols). If a field is '
    'unreadable, use null.';

const _payslipPrompt = 'You are an expert payslip-reading assistant that understands payslips from any '
    'country (German Lohnabrechnung, Iranian فیش حقوقی, and others). Read the attached payslip image and '
    'extract structured data. Respond ONLY with compact JSON, no markdown, no explanation, in exactly this '
    'shape: {"brutto": number or null, "netto": number or null, "depositedAmount": number or null, '
    '"lohnsteuer": number or null, "solidaritaetszuschlag": number or null, "krankenversicherung": number '
    'or null, "pflegeversicherung": number or null, "rentenversicherung": number or null, '
    '"arbeitslosenversicherung": number or null, "vermoegenswirksameLeistungen": number or null, '
    '"betrieblicheAltersvorsorge": number or null, "vorschuss": number or null, "sonstigeAbzuege": number '
    'or null, "steuerklasse": string or null, "arbeitgeber": string or null, "abrechnungsmonat": string or '
    'null, "date": "YYYY-MM-DD" or null, "currency": string or null, "customFields": [{"label": string, "value": number}]}. The named '
    'fields above (brutto/netto/lohnsteuer/etc.) are German payroll terms - fill them ONLY when the '
    "payslip actually uses those German concepts. For a payslip in any other format (e.g. an Iranian "
    'فیش حقوقی with items like حقوق پایه، حق مسکن، حق اولاد، حق خواربار، بیمه‌ی تأمین اجتماعی، مالیات '
    'حقوق، اضافه‌کاری، پاداش، عیدی، کسورات), leave the German fields null and instead put EVERY line item '
    "printed on the payslip (its label exactly as printed, in the payslip's own language, and its amount) "
    'into "customFields" - this applies regardless of country, so nothing printed on the payslip is lost. '
    '"depositedAmount" is the actual amount transferred/paid out to the bank account if shown separately '
    'from "netto" (they can differ due to advances or other payroll deductions) - for a non-German '
    'payslip this is usually the final net/take-home amount. "vermoegenswirksameLeistungen" is '
    'VL/capital-formation benefits, "betrieblicheAltersvorsorge" is employer-sponsored supplementary '
    'pension deductions, "vorschuss" is any advance payment deducted, "sonstigeAbzuege" is any other '
    'German-payslip deduction not covered by the other fields. "date" is the date the pay is transferred '
    'to the bank account: look for a payout/value date (e.g. Auszahlung, Auszahlungsdatum, Überweisung, '
    'Valuta, Zahltag, Zahlungsdatum, تاریخ واریز, تاریخ پرداخت). It is NOT the date the payslip was '
    'printed/created and NOT the first day of the pay period. If no payout date is printed, use the last '
    'day of the pay period ("abrechnungsmonat"). "abrechnungsmonat" is the pay period as printed (e.g. '
    '"09/2026"). "currency" is the ISO 4217 code of the amounts (e.g. "EUR"; for Iranian payslips "IRR" '
    'for ریال, "IRT" for تومان), or null if it cannot be told. Numbers must be plain (no currency symbols). '
    'If a field is unreadable, use null.';

Future<Map<String, dynamic>?> geminiExtractReceipt(String apiKey, String imagePath) =>
    _geminiRequest(apiKey, imagePath, _receiptPrompt);

Future<Map<String, dynamic>?> geminiExtractPayslip(String apiKey, String imagePath) =>
    _geminiRequest(apiKey, imagePath, _payslipPrompt);

/// A text-only Gemini call (no image), used for the savings/investment
/// suggestion feature - returns plain prose, not JSON.
Future<String> geminiTextRequest(String apiKey, String prompt) async {
  final body = jsonEncode({
    'contents': [
      {
        'parts': [
          {'text': prompt},
        ],
      },
    ],
  });

  final resp = await _geminiPost(apiKey, body);
  final rawBody = utf8.decode(resp.bodyBytes);
  final decoded = jsonDecode(rawBody);
  final candidates = decoded['candidates'];
  if (candidates == null || candidates is! List || candidates.isEmpty) {
    final blockReason = decoded['promptFeedback']?['blockReason'];
    if (blockReason != null) {
      throw GeminiException('Gemini این درخواست را پردازش نکرد (دلیل: $blockReason).', rawBody);
    }
    throw GeminiException('پاسخ نامعتبر از Gemini دریافت شد (بدون نتیجه).', rawBody);
  }
  final text = candidates[0]?['content']?['parts']?[0]?['text'] as String?;
  if (text == null) {
    throw GeminiException('پاسخ Gemini قابل خواندن نبود.', rawBody);
  }
  return text.trim();
}

// ============================== Money formatting ==============================

/// Human-friendly currency name for display. Iranian money is shown as
/// "تومان" / "ریال" when the app language is Persian; every other currency
/// keeps its code. (IRT = Toman: a separate unit worth 10 Rial, offered
/// because Toman is what people in Iran normally use day to day.)
String currencyLabel(String code) {
  if (currentLanguage.value == AppLanguage.fa) {
    if (code == 'IRT') return 'تومان';
    if (code == 'IRR') return 'ریال';
  }
  return code;
}

/// Whether [currency] is written without decimals and in "millions" when
/// space is tight (Toman and Rial amounts are big whole numbers).
bool isWholeNumberCurrency(String currency) => currency == 'IRT' || currency == 'IRR';

String _groupThousands(String digits) => digits.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');

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
      return '\u2067${ltr(n)} د.إ\u2069';
    case 'IRR':
    case 'IRT':
      final grouped = _groupThousands(amount.round().abs().toString());
      final unit = currentLanguage.value == AppLanguage.fa ? (currency == 'IRT' ? 'تومان' : 'ریال') : currency;
      return '\u2067${ltr(persianDigits('${amount < 0 ? '-' : ''}$grouped'))} $unit\u2069';
    default:
      return ltr('$n $currency');
  }
}

/// Short amount for tight spaces (e.g. the pie-chart legend and chart
/// labels). Toman/Rial amounts are long, so they are shown in millions
/// ("۱۲۵.۴ م"); other currencies use the regular format.
String formatMoneyCompact(double amount, String currency) {
  if (!isWholeNumberCurrency(currency)) return formatMoney(amount, currency);
  final abs = amount.abs();
  String trim(double v) {
    final t = v.toStringAsFixed(1);
    return t.endsWith('.0') ? t.substring(0, t.length - 2) : t;
  }

  final sign = amount < 0 ? '-' : '';
  if (abs >= 1e6) return '\u2067${ltr(persianDigits('$sign${trim(abs / 1e6)}'))} م\u2069';
  return formatMoney(amount, currency);
}

// ---------------------------------------------------------------- amount input

/// Whole numbers typed by the person (day of month, number of installments...)
/// are shown with Persian digits while typing; [parseInt] reads them back.
class DigitsInputFormatter extends TextInputFormatter {
  const DigitsInputFormatter();
  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final ascii = StringBuffer();
    for (final ch in newValue.text.split('')) {
      final p = '۰۱۲۳۴۵۶۷۸۹'.indexOf(ch);
      final a = '٠١٢٣٤٥٦٧٨٩'.indexOf(ch);
      if (p >= 0) {
        ascii.write(p);
      } else if (a >= 0) {
        ascii.write(a);
      } else if (ch.codeUnitAt(0) >= 48 && ch.codeUnitAt(0) <= 57) {
        ascii.write(ch);
      } else if (ch == '.' || ch == '٫') {
        ascii.write('.');
      }
    }
    final text = persianDigits(ascii.toString());
    final cursor = newValue.selection.baseOffset.clamp(0, text.length);
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: cursor));
  }
}

int? parseInt(String input) => parseAmount(input)?.toInt();


/// Reads an amount typed into an [AmountInputFormatter] field (or pasted):
/// Persian/Arabic digits are accepted, "," / space / "٬" are thousands
/// separators and "." or "٫" is the decimal point.
double? parseAmount(String input) {
  const persian = '۰۱۲۳۴۵۶۷۸۹';
  const arabic = '٠١٢٣٤٥٦٧٨٩';
  final sb = StringBuffer();
  for (final ch in input.trim().split('')) {
    final p = persian.indexOf(ch);
    final a = arabic.indexOf(ch);
    if (p >= 0) {
      sb.write(p);
    } else if (a >= 0) {
      sb.write(a);
    } else if (ch == '٫') {
      sb.write('.');
    } else if (ch == ',' || ch == '٬' || ch == ' ') {
      continue;
    } else {
      sb.write(ch);
    }
  }
  final t = sb.toString();
  if (t.isEmpty) return null;
  return double.tryParse(t);
}

/// Text to pre-fill an amount field with: grouped in thousands, no
/// pointless ".00" (whole amounts show no decimals), Persian digits when the
/// app language is Persian.
String formatAmountInput(double v, {int maxDecimals = 2}) {
  var s = v.abs().toStringAsFixed(maxDecimals);
  if (s.contains('.')) {
    s = s.replaceFirst(RegExp(r'0+$'), '');
    if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  }
  final parts = s.split('.');
  final out = '${v < 0 ? '-' : ''}${_groupThousands(parts[0])}${parts.length > 1 ? '.${parts[1]}' : ''}';
  return persianDigits(out);
}

/// Live thousands separators while typing an amount ("1234567" -> "1,234,567").
/// A typed "," or "٫" acts as the decimal point; digits can be Persian.
class AmountInputFormatter extends TextInputFormatter {
  final bool allowNegative;
  final int maxDecimals;
  const AmountInputFormatter({this.allowNegative = false, this.maxDecimals = 6});

  static const _persian = '۰۱۲۳۴۵۶۷۸۹';
  static const _arabic = '٠١٢٣٤٥٦٧٨٩';

  static bool _isDigit(String ch) => (ch.codeUnitAt(0) >= 48 && ch.codeUnitAt(0) <= 57) || _persian.contains(ch) || _arabic.contains(ch);
  static String _ascii(String ch) {
    final p = _persian.indexOf(ch);
    if (p >= 0) return '$p';
    final a = _arabic.indexOf(ch);
    return a >= 0 ? '$a' : ch;
  }

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    var text = newValue.text;
    var cursor = newValue.selection.baseOffset;
    if (cursor < 0 || cursor > text.length) cursor = text.length;

    // Backspace right after a separator: remove the digit before it instead
    // of appearing to do nothing.
    final oldCommas = ','.allMatches(oldValue.text).length;
    final newCommas = ','.allMatches(text).length;
    if (text.length == oldValue.text.length - 1 && newCommas == oldCommas - 1 && cursor > 0 && _isDigit(text[cursor - 1])) {
      text = text.replaceRange(cursor - 1, cursor, '');
      cursor -= 1;
    }
    // A comma / Arabic decimal mark typed just now means "decimal point".
    if (text.length == oldValue.text.length + 1 && cursor > 0 && (text[cursor - 1] == ',' || text[cursor - 1] == '٫')) {
      text = text.replaceRange(cursor - 1, cursor, '.');
    }

    final digits = StringBuffer();
    var seenDot = false;
    var negative = false;
    var significantBeforeCursor = 0;
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      var kept = false;
      if (_isDigit(ch)) {
        digits.write(_ascii(ch));
        kept = true;
      } else if (ch == '.' && !seenDot) {
        digits.write('.');
        seenDot = true;
        kept = true;
      } else if (ch == '-' && allowNegative && i == 0) {
        negative = true;
        kept = true;
      }
      if (kept && i < cursor) significantBeforeCursor++;
    }

    var raw = digits.toString();
    var intPart = raw;
    var fracPart = '';
    final dot = raw.indexOf('.');
    if (dot >= 0) {
      intPart = raw.substring(0, dot);
      fracPart = raw.substring(dot + 1);
      if (fracPart.length > maxDecimals) fracPart = fracPart.substring(0, maxDecimals);
    }
    if (intPart.length > 1) intPart = intPart.replaceFirst(RegExp(r'^0+'), '');
    if (intPart.isEmpty && dot >= 0) intPart = '0';

    var formatted = '${negative ? '-' : ''}${_groupThousands(intPart)}${dot >= 0 ? '.$fracPart' : ''}';
    formatted = persianDigits(formatted);

    var pos = 0;
    var count = 0;
    while (pos < formatted.length && count < significantBeforeCursor) {
      final ch = formatted[pos];
      if (_isDigit(ch) || ch == '.' || ch == '-') count++;
      pos++;
    }
    return TextEditingValue(text: formatted, selection: TextSelection.collapsed(offset: pos));
  }
}

/// The main, memorable title for a transaction list row: the item name if
/// there's exactly one, "first item + N more" if there are several, the
/// transaction's own note if there are no items but a note was entered,
/// and the category name as a last resort so the line is never blank.
String txMainTitle(Transaction t, String categoryName) {
  if (t.merchant.trim().isNotEmpty) return t.merchant.trim();
  return txDetailTitle(t) ?? categoryName;
}

/// What the row title used to be before a shop name existed: the item name /
/// "first item +N", else the note. Null when there is neither.
String? txDetailTitle(Transaction t) {
  if (t.items.length == 1) return t.items.first.name;
  if (t.items.length > 1) return '${t.items.first.name} +${t.items.length - 1} قلم دیگر';
  if (t.note.trim().isNotEmpty) return t.note.trim();
  return null;
}

/// When a shop name takes the title's place, the item / note summary moves to
/// the small line above it so nothing that was shown before disappears.
String txExtraDetail(Transaction t) => ''; // merchant, when present, is shown alone as the title

// ============================== Home screen ==============================

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with RouteAware, SingleTickerProviderStateMixin, WidgetsBindingObserver {
  List<Transaction> tx = [];
  List<Category> categories = [];
  List<Account> accounts = [];
  bool loading = true;
  String? dashboardAccountFilter;
  final Map<String, bool> _monthShowNotDue = {}; // "y-m" -> true shows the not-yet-due list instead of the due one
  int shoppingPending = 0; // items not yet ticked off across all shopping lists
  late final AnimationController _draftHintController = AnimationController(vsync: this, duration: const Duration(milliseconds: 1300));
  bool _draftHintPlayed = false; // only nudge the person once per time the app is opened
  Timer? _draftHintStopTimer;
  DateTime? _pausedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  /// Makes the drafts icon pulse, glow and wiggle for several seconds so
  /// unconfirmed drafts can't go unnoticed when the app is opened.
  void _playDraftHint() {
    if (!mounted || draftCount == 0) return;
    _draftHintStopTimer?.cancel();
    _draftHintController.repeat();
    _draftHintStopTimer = Timer(const Duration(milliseconds: 1300 * 6), _stopDraftHint);
  }

  void _stopDraftHint() {
    _draftHintStopTimer?.cancel();
    if (!mounted || !_draftHintController.isAnimating) return;
    // Let the current cycle finish so the icon settles back smoothly.
    _draftHintController.animateTo(1.0).then((_) {
      if (mounted) _draftHintController.value = 0;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back to the app after a real stay in the background counts as
    // opening it again. Trips to the camera, gallery or file picker while
    // scanning also pause the app, sometimes for over a minute, so only a
    // longer absence (same grace period as the app lock) replays the hint.
    if (state == AppLifecycleState.paused) {
      _pausedAt = DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      // The date may have moved on (e.g. a new month) while the app sat in
      // the background - refresh so balances and month tabs follow.
      unawaited(_refresh());
      final pausedAt = _pausedAt;
      _pausedAt = null;
      if (pausedAt != null && DateTime.now().difference(pausedAt) >= const Duration(minutes: 5) && draftCount > 0) {
        Future.delayed(const Duration(milliseconds: 700), _playDraftHint);
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) appRouteObserver.subscribe(this, route);
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    _draftHintStopTimer?.cancel();
    _draftHintController.dispose();
    super.dispose();
  }

  /// Called when a screen pushed on top of Home is closed: refresh quietly
  /// (no spinner, no full reload) so the numbers are always current.
  @override
  void didPopNext() {
    _refresh();
  }

  DateTime _lastRefresh = DateTime.fromMillisecondsSinceEpoch(0);
  bool _refreshing = false;

  Future<void> _refresh() async {
    if (_refreshing || !mounted) return;
    // Skip if we've only just refreshed (e.g. an explicit reload right after closing a screen).
    if (DateTime.now().difference(_lastRefresh) < const Duration(milliseconds: 400)) return;
    _refreshing = true;
    try {
      await _reloadTx();
      categories = await Store.loadCategories();
      accounts = await Store.loadAccounts();
      _memo.clear();
      shoppingPending = await _loadShoppingPending();
      if (mounted) setState(() {});
    } finally {
      _lastRefresh = DateTime.now();
      _refreshing = false;
    }
  }

  Future<void> _load() async {
    await _reloadTx();
    categories = await Store.loadCategories();
    accounts = await Store.loadAccounts();
    _memo.clear();
    shoppingPending = await _loadShoppingPending();
    setState(() => loading = false);
    // Draw attention to the drafts icon the first time the app is opened
    // with unconfirmed drafts sitting around, so it's noticed - not on
    // every later silent refresh, just once per app visit. A short delay
    // lets the home screen settle first so the animation is actually seen.
    if (!_draftHintPlayed && draftCount > 0) {
      _draftHintPlayed = true;
      Future.delayed(const Duration(milliseconds: 700), _playDraftHint);
    }
    // Best-effort background retry for categories that only got a generic
    // icon last time (e.g. Gemini was unavailable); does nothing if none
    // are pending.
    unawaited(retryPendingCategoryIcons());
    unawaited(checkBudgetGoals());
    unawaited(checkSpendingAnomalies());
    unawaited(checkReturnDeadlines());
    unawaited(maybeRunAutoBackup());
  }

  String categoryName(String id) {
    final c = categories.where((c) => c.id == id).toList();
    return c.isEmpty ? 'بدون‌دسته' : c.first.name;
  }

  String currencyOf(String accountId) {
    final a = accounts.where((a) => a.id == accountId).toList();
    return a.isEmpty ? 'IRT' : a.first.currency;
  }

  Future<int> _loadShoppingPending() async {
    final lists = await Store.loadShoppingLists();
    return lists.fold<int>(0, (sum, l) => sum + l.items.where((i) => !i.checked).length);
  }

  int _draftCount = 0;
  int get draftCount => _draftCount;

  /// Loads transactions for the home screen: [tx] holds only confirmed ones
  /// (drafts must not affect any balance, total, chart or list here); the
  /// number of drafts is kept separately for the badge.
  // Results of the heavy per-build calculations (balances, period totals,
  // recurring projections), reused until the data or the day changes. Without
  // this every rebuild - e.g. expanding a month - recomputed them all.
  final Map<String, Object> _memo = {};
  T _memoized<T extends Object>(String key, T Function() compute) => (_memo[key] ??= compute()) as T;
  String get _dayKey {
    final n = DateTime.now();
    return '${n.year}-${n.month}-${n.day}';
  }

  int _reloadSeq = 0;
  Future<void> _reloadTx() async {
    final seq = ++_reloadSeq;
    final all = await Store.loadTransactions();
    if (seq != _reloadSeq) return; // a newer reload is already in flight; let it win
    _draftCount = all.where((t) => t.draft).length;
    tx = all.where((t) => !t.draft).toList()..sort((a, b) => b.date.compareTo(a.date));
    _memo.clear();
    _lastRefresh = DateTime.now();
  }

  String get _calKey => currentCalendarSystem.value.name;

  /// Occurrences of recurring transactions that have already fallen due
  /// (today included) besides their stored first one. They are real
  /// payments - rent paid each month - so they count in balances and
  /// totals and show up in their month's list on their own day.
  List<TxOccurrence> get _dueRecurring => _memoized('dueRec|$_dayKey|$_calKey', () {
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        final result = <TxOccurrence>[];
        for (final t in tx) {
          if (!t.isRecurring) continue;
          final anchor = DateTime(t.date.year, t.date.month, t.date.day);
          for (final d in computeRecurrenceOccurrences(t)) {
            final dd = DateTime(d.year, d.month, d.day);
            if (dd.isAfter(today)) break;
            if (dd == anchor) continue;
            result.add((date: dd, t: t, isReal: false));
          }
        }
        return result;
      });

  /// Confirmed transactions plus dated copies of the recurring occurrences
  /// that already fell due - what balances and period totals are made of.
  List<Transaction> get _effectiveTx =>
      _memoized('effTx|$_dayKey|$_calKey', () => [...tx, ..._dueRecurring.map((e) => e.t.copyWith(date: e.date))]);

  Map<String, double> get totalBalanceByCurrency => _memoized('balances|$_dayKey|$_calKey', _computeTotalBalance);
  Map<String, double> _computeTotalBalance() {
    final map = <String, double>{};
    for (final a in accounts) {
      if (a.initialBalance != 0) {
        map[a.currency] = (map[a.currency] ?? 0) + a.initialBalance;
      }
    }
    for (final t in _effectiveTx) {
      final cur = currencyOf(t.accountId);
      map[cur] = (map[cur] ?? 0) + (t.type == TxType.income ? t.amount : -t.amount);
    }
    return map;
  }

  /// Every account's balance converted into the main account's currency
  /// (using each account's own exchange rate), added into a single number -
  /// only meaningful when more than one currency is actually in use.
  double get _combinedBalanceInMainCurrency {
    final byAccount = <String, double>{};
    for (final a in accounts) {
      byAccount[a.id] = a.initialBalance;
    }
    for (final t in _effectiveTx) {
      byAccount[t.accountId] = (byAccount[t.accountId] ?? 0) + (t.type == TxType.income ? t.amount : -t.amount);
    }
    var total = 0.0;
    for (final a in accounts) {
      total += (byAccount[a.id] ?? 0) * a.exchangeRateToMain;
    }
    return total;
  }

  /// "Safe to spend" until the end of this month, per currency: current
  /// balance minus every not-yet-due expense (real future-dated
  /// transactions, plus projected recurring occurrences) still expected
  /// before the month ends - a PocketGuard/Simplifi-style guardrail so a
  /// healthy-looking balance doesn't hide bills that are already spoken for.
  Map<String, double> get safeToSpendByCurrency => _memoized('safe|$_dayKey', _computeSafeToSpend);
  Map<String, double> _computeSafeToSpend() {
    final balances = Map<String, double>.from(totalBalanceByCurrency);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final endOfMonth = DateTime(now.year, now.month + 1, 0);
    for (final e in occurrencesWithRecurringProjections(tx, horizonDays: 40)) {
      if (e.t.type != TxType.expense) continue;
      if (!e.date.isAfter(today) || e.date.isAfter(endOfMonth)) continue;
      final cur = currencyOf(e.t.accountId);
      balances[cur] = (balances[cur] ?? 0) - e.t.amount;
    }
    return balances;
  }

  Map<String, Map<String, double>> get periodStatsByCurrency =>
      _memoized('period|$dashboardAccountFilter|$_dayKey|$_calKey', _computePeriodStats);
  Map<String, Map<String, double>> _computePeriodStats() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final map = <String, Map<String, double>>{};
    // "This month" in the calendar chosen in settings (Jalali or Gregorian).
    final month = calendarMonthOf(today);
    for (final t in _effectiveTx) {
      // Not-yet-due (future-dated) transactions shouldn't count toward the
      // period's totals until their own date actually arrives.
      if (t.date.isAfter(today)) continue;
      if (t.date.isBefore(month.start)) continue;
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

  String get primaryCurrency =>
      dashboardAccountFilter != null ? currencyOf(dashboardAccountFilter!) : mainCurrencyOf(accounts);

  /// Top-level category (parent rolled up) expense totals for the current
  /// period (same period as [periodStatsByCurrency]), in [primaryCurrency].
  /// Expense transactions for the current period, in [primaryCurrency] -
  /// aggregation (including drill-down by category) happens inside
  /// [DashboardCharts] itself.
  List<Transaction> get expenseTransactionsForPeriod {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final month = calendarMonthOf(today);
    return _effectiveTx.where((t) {
      if (t.type != TxType.expense) return false;
      if (dashboardAccountFilter != null ? t.accountId != dashboardAccountFilter : currencyOf(t.accountId) != primaryCurrency) return false;
      if (t.date.isAfter(today)) return false;
      return !t.date.isBefore(month.start);
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
      for (final t in _effectiveTx) {
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
        builder: (_) => existing == null
            ? TransactionEditor(categories: categories, accounts: accounts, existing: existing)
            : TransactionDetailScreen(t: existing, categories: categories, accounts: accounts),
      ),
    );
    await _handleEditorResult(result);
  }

  /// Same post-processing as [_openEditor], but always opens the editor
  /// directly (skipping the read-only detail screen) - used for the
  /// swipe-to-edit shortcut, which already signals "edit" visually.
  Future<void> _openEditorDirect(Transaction existing) async {
    final result = await Navigator.push<Object>(
      context,
      MaterialPageRoute(builder: (_) => TransactionEditor(categories: categories, accounts: accounts, existing: existing)),
    );
    await _handleEditorResult(result);
  }

  Future<void> _handleEditorResult(Object? result) async {
    if (result == null) return;
    // A new category/subcategory may have been created inside the editor;
    // refresh so it's reflected immediately (otherwise the transaction
    // would look "uncategorized" until the next full reload).
    categories = await Store.loadCategories();
    accounts = await Store.loadAccounts();
    if (result is DeleteTransactionSignal) {
      final removed = await Store.deleteTransaction(result.id);
      _showUndoSnackbar(removed);
    } else if (result is Transaction) {
      await Store.upsertTransaction(result);
    } else {
      return;
    }
    // Always reload from storage after a write, rather than trusting this
    // screen's own (possibly stale) in-memory list - upsertTransaction /
    // deleteTransaction already operate on the freshest persisted data, so
    // this keeps the UI in sync with what was actually saved.
    await _reloadTx();
    if (mounted) setState(() {});
  }

  void _showUndoSnackbar(List<Transaction> removed) {
    if (removed.isEmpty || !mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(removed.length > 1 ? 'تراکنش‌ها حذف شدند' : 'تراکنش حذف شد'),
        persist: false,
        action: SnackBarAction(
          label: 'برگردون',
          onPressed: () async {
            for (final t in removed) {
              await Store.upsertTransaction(t);
            }
            await _reloadTx();
            if (mounted) setState(() {});
          },
        ),
        duration: const Duration(seconds: 5),
      ),
    );
  }

  Future<void> _openDrafts() async {
    _stopDraftHint();
    await Navigator.push(context, MaterialPageRoute(builder: (_) => const DraftsScreen()));
    await _load();
  }

  Future<void> _delete(Transaction t) async {
    await NotificationService.instance.cancelForTransaction(t.id);
    final removed = await Store.deleteTransaction(t.id);
    await _reloadTx();
    if (mounted) setState(() {});
    _showUndoSnackbar(removed);
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final balances = totalBalanceByCurrency;
    final safeToSpend = safeToSpendByCurrency;
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
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: AnimatedBuilder(
              animation: _draftHintController,
              builder: (context, child) {
                final t = _draftHintController.value;
                // Each cycle: a bounce up with a wiggle, plus a ring of light
                // spreading out behind the icon. At rest (t == 0) everything
                // is back to normal and the ring is invisible.
                final bump = sin(t * pi); // 0 -> 1 -> 0
                final scale = 1 + 0.35 * bump;
                final angle = 0.35 * (1 - t) * sin(t * 6 * pi);
                final ringAlpha = t == 0 ? 0.0 : 1 - t;
                return Stack(
                  alignment: Alignment.center,
                  clipBehavior: Clip.none,
                  children: [
                    IgnorePointer(
                      child: Transform.scale(
                        scale: 1 + 0.7 * t,
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.amber.withValues(alpha: 0.55 * ringAlpha),
                            border: Border.all(color: Colors.orange.withValues(alpha: 0.9 * ringAlpha), width: 3),
                          ),
                        ),
                      ),
                    ),
                    Transform.scale(scale: scale, child: Transform.rotate(angle: angle, child: child)),
                  ],
                );
              },
              child: Badge(
                label: Text(persianDigits('$draftCount')),
                backgroundColor: Colors.deepOrange,
                isLabelVisible: draftCount > 0,
                child: IconButton(icon: const Icon(Icons.edit_note_outlined), tooltip: 'پیش‌نویس‌ها', onPressed: _openDrafts),
              ),
            ),
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
                    if (balances.length > 1) ...[
                      const SizedBox(height: 2),
                      Text(
                        'جمع کل (به ${currencyLabel(primaryCurrency)}): ${formatMoney(_combinedBalanceInMainCurrency, primaryCurrency)}',
                        style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                      ),
                    ],
                    if (safeToSpend.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.shield_outlined, size: 14, color: Colors.grey.shade600),
                                const SizedBox(width: 6),
                                Text('امن برای خرج تا آخر ماه', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                              ],
                            ),
                            const SizedBox(height: 4),
                            ...safeToSpend.entries.map((e) => e.value >= 0
                                ? Text(
                                    formatMoney(e.value, e.key),
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: Theme.of(context).brightness == Brightness.dark ? Colors.indigo.shade200 : Colors.indigo,
                                    ),
                                  )
                                : Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Icon(Icons.warning_amber_rounded, size: 15, color: Colors.red.shade700),
                                        const SizedBox(width: 4),
                                        Expanded(
                                          child: Text(
                                            'پرداخت‌های پیش‌رو ${ltr(formatMoney(-e.value, e.key))} بیشتر از موجودی فعلیته',
                                            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.red.shade700),
                                          ),
                                        ),
                                      ],
                                    ),
                                  )),
                          ],
                        ),
                      ),
                    ],
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
            const SizedBox(height: 12),
            Material(
              color: Theme.of(context).colorScheme.secondaryContainer.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () async {
                  await Navigator.push(context, MaterialPageRoute(builder: (_) => const ShoppingListsScreen()));
                  final pending = await _loadShoppingPending();
                  if (mounted) setState(() => shoppingPending = pending);
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 20,
                        backgroundColor: Theme.of(context).colorScheme.secondary.withValues(alpha: 0.18),
                        child: Icon(Icons.shopping_cart_outlined, color: Theme.of(context).colorScheme.secondary),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(tr('shopping_lists_title'), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                            Text(
                              shoppingPending > 0 ? '$shoppingPending کالا هنوز خریداری نشده' : 'لیست خرید بساز و کالاها را تیک بزن',
                              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                            ),
                          ],
                        ),
                      ),
                      if (shoppingPending > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(color: Theme.of(context).colorScheme.secondary, borderRadius: BorderRadius.circular(12)),
                          child: Text(
                            '$shoppingPending',
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.onSecondary),
                          ),
                        ),
                      const SizedBox(width: 4),
                      Icon(Icons.chevron_left, color: Colors.grey.shade600),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
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
                      ...accounts.map((a) => DropdownMenuItem(value: a.id, child: Text('${a.name} (${currencyLabel(a.currency)})'))),
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
                // Months follow the calendar chosen in settings (Jalali or
                // Gregorian) and are worked out from today's date on every
                // build, so the tabs move on as soon as a new month starts.
                String keyOf(DateTime d) {
                  final start = calendarMonthOf(d).start;
                  return '${start.year}-${start.month}-${start.day}';
                }

                final prevMonth = calendarMonthOf(todayMidnight, -1);
                final thisMonth = calendarMonthOf(todayMidnight);
                final nextMonth = calendarMonthOf(todayMidnight, 1);

                // All not-yet-due entries (real future-dated transactions,
                // plus projected occurrences of recurring transactions),
                // grouped by the month they actually fall in.
                final futureByMonth = _memoized<Map<String, List<TxOccurrence>>>('future|$_dayKey|${currentCalendarSystem.value.name}', () {
                  final map = <String, List<TxOccurrence>>{};
                  for (final e in occurrencesWithRecurringProjections(tx, horizonDays: 75)) {
                    if (!e.date.isAfter(todayMidnight)) continue;
                    (map[keyOf(e.date)] ??= []).add(e);
                  }
                  for (final list in map.values) {
                    list.sort((a, b) => a.date.compareTo(b.date));
                  }
                  return map;
                });

                // Already-due transactions of this month and last month
                // (tx is sorted by date descending).
                final dueByMonth = <String, List<TxOccurrence>>{};
                for (final t in tx) {
                  if (t.date.isAfter(todayMidnight) || t.date.isBefore(prevMonth.start)) continue;
                  (dueByMonth[keyOf(t.date)] ??= []).add((date: t.date, t: t, isReal: true));
                }
                // Recurring payments that fell due (today included) show on
                // their own day like any other due transaction.
                for (final e in _dueRecurring) {
                  if (e.date.isBefore(prevMonth.start)) continue;
                  (dueByMonth[keyOf(e.date)] ??= []).add(e);
                }
                for (final list in dueByMonth.values) {
                  list.sort((a, b) => b.date.compareTo(a.date));
                }

                String title(CalendarMonth m) => '${m.name} ${m.yearText}';
                final nextKey = keyOf(nextMonth.start);
                final thisKey = keyOf(thisMonth.start);
                final prevKey = keyOf(prevMonth.start);

                return Column(
                  children: [
                    if ((futureByMonth[nextKey] ?? []).isNotEmpty)
                      _monthTabSection(
                        monthKey: nextKey,
                        title: title(nextMonth),
                        dimTitle: true,
                        initiallyExpanded: false,
                        dueTx: const [],
                        notDueEntries: futureByMonth[nextKey]!,
                      ),
                    _monthTabSection(
                      monthKey: thisKey,
                      title: title(thisMonth),
                      initiallyExpanded: true,
                      dueTx: dueByMonth[thisKey] ?? const [],
                      notDueEntries: futureByMonth[thisKey] ?? const [],
                    ),
                    if ((dueByMonth[prevKey] ?? []).isNotEmpty)
                      _monthTabSection(
                        monthKey: prevKey,
                        title: title(prevMonth),
                        initiallyExpanded: false,
                        dueTx: dueByMonth[prevKey]!,
                        notDueEntries: const [],
                      ),
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

  Widget _monthTabSection({
    required String monthKey,
    required String title,
    required List<TxOccurrence> dueTx,
    required List<TxOccurrence> notDueEntries,
    required bool initiallyExpanded,
    bool dimTitle = false,
  }) {
    final showingNotDue = _monthShowNotDue[monthKey] ?? false;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        // Keyed by month so a new month gets a fresh tile (its own
        // expanded state) instead of inheriting the previous one's.
        key: PageStorageKey('month-$monthKey'),
        initiallyExpanded: initiallyExpanded,
        tilePadding: EdgeInsets.zero,
        title: Text(
          title,
          style: dimTitle
              ? TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.w500)
              : Theme.of(context).textTheme.titleMedium,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      backgroundColor: !showingNotDue ? Theme.of(context).colorScheme.primaryContainer : null,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                    onPressed: () => setState(() => _monthShowNotDue[monthKey] = false),
                    child: Text(ltr(persianDigits('سررسید شده (${dueTx.length})')), style: const TextStyle(fontSize: 12)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      backgroundColor: showingNotDue ? Theme.of(context).colorScheme.primaryContainer : null,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                    onPressed: () => setState(() => _monthShowNotDue[monthKey] = true),
                    child: Text(ltr(persianDigits('سررسیدنشده (${notDueEntries.length})')), style: const TextStyle(fontSize: 12)),
                  ),
                ),
              ],
            ),
          ),
          if (!showingNotDue)
            if (dueTx.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('تراکنش سررسیدشده‌ای نیست.', style: TextStyle(color: Colors.grey, fontSize: 12)),
              )
            else
              ...dueTx.map((e) => e.isReal
                  ? _buildTxTile(e.t)
                  : _buildTxTile(e.t, projected: true, recurringDue: true, displayDate: e.date))
          else if (notDueEntries.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('تراکنش سررسیدنشده‌ای نیست.', style: TextStyle(color: Colors.grey, fontSize: 12)),
            )
          else
            ...notDueEntries.map((e) => _buildTxTile(e.t, dimmed: true, projected: !e.isReal, displayDate: e.date)),
        ],
      ),
    );
  }

  Widget _buildTxTile(Transaction t, {bool dimmed = false, bool projected = false, bool recurringDue = false, DateTime? displayDate}) {
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
              '${categoryName(t.categoryId)} • ${formatDate(displayDate ?? t.date)}${txExtraDetail(t)}'
              '${projected && !recurringDue ? ' • سررسیدنشده' : (t.isRecurring ? ' • تکرارشونده' : '')}'
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
            await _openEditorDirect(t);
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

  @override
  void didUpdateWidget(covariant DashboardCharts oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Categories can be renamed or deleted while this chart is on screen's
    // route stack; refresh the drilled-into category from the new list.
    final d = drilldown;
    if (d != null) {
      final match = widget.categories.where((c) => c.id == d.id).toList();
      drilldown = match.isEmpty ? null : match.first;
    }
  }

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
                'هزینه‌ی این ماه ${ltr(persianDigits('${change.abs().round()}%'))} ${up ? 'بیشتر' : 'کمتر'} از ماه قبل',
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
              height: 200,
              child: Row(
                children: [
                  SizedBox(
                    width: 150,
                    child: PieChart(
                      PieChartData(
                        sectionsSpace: 2,
                        centerSpaceRadius: 24,
                        sections: [
                          for (var i = 0; i < top.length; i++)
                            PieChartSectionData(
                              value: top[i].value,
                              color: _palette[i % _palette.length],
                              title: persianDigits('${(top[i].value / total * 100).round()}%'),
                              radius: 52,
                              titleStyle: const TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.w800, shadows: [Shadow(color: Colors.black54, blurRadius: 3)]),
                            ),
                          if (otherSum > 0)
                            PieChartSectionData(
                              value: otherSum,
                              color: Colors.grey,
                              title: persianDigits('${(otherSum / total * 100).round()}%'),
                              radius: 52,
                              titleStyle: const TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.w800, shadows: [Shadow(color: Colors.black54, blurRadius: 3)]),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: ListView(
                      padding: EdgeInsets.zero,
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
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Container(width: 14, height: 14, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                category.name,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, decoration: canDrill ? TextDecoration.underline : null),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              ltr(formatMoneyCompact(amount, widget.currency)),
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
            if (canDrill) const Icon(Icons.chevron_left, size: 18, color: Colors.grey),
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
      // Fit to the screen width and let tall images (all pages of a
      // multi-page PDF stacked together) be scrolled by dragging, with
      // pinch-to-zoom for details. Short images stay vertically centred.
      body: LayoutBuilder(
        builder: (context, c) => InteractiveViewer(
          constrained: false,
          minScale: 0.3,
          maxScale: 6,
          child: SizedBox(
            width: c.maxWidth,
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: c.maxHeight),
              child: Center(child: Image.file(File(imagePath), width: c.maxWidth, fit: BoxFit.fitWidth)),
            ),
          ),
        ),
      ),
    );
  }
}

enum ReceiptImageAction { reread, delete }

/// Shows a transaction's stored receipt/payslip image on its own, with
/// buttons below it to re-read it with AI or delete it. Pops with the
/// chosen [ReceiptImageAction] (null if the person just goes back).
class ReceiptImageScreen extends StatelessWidget {
  final String imagePath;
  const ReceiptImageScreen({required this.imagePath, super.key});

  Future<void> _confirmDelete(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف تصویر'),
        content: const Text('آیا از حذف تصویر رسید/فیش اطمینان دارید؟ خود تراکنش حذف نمی‌شود.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('delete')),
          ),
        ],
      ),
    );
    if (confirm == true && context.mounted) Navigator.pop(context, ReceiptImageAction.delete);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('تصویر رسید/فیش')),
      body: Column(
        children: [
          Expanded(
            child: Container(
              color: Colors.black,
              width: double.infinity,
              child: LayoutBuilder(
                builder: (context, c) => InteractiveViewer(
                  constrained: false,
                  minScale: 0.3,
                  maxScale: 6,
                  child: SizedBox(
                    width: c.maxWidth,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: c.maxHeight),
                      child: Center(child: Image.file(File(imagePath), width: c.maxWidth, fit: BoxFit.fitWidth)),
                    ),
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: () => Navigator.pop(context, ReceiptImageAction.reread),
                      icon: const Icon(Icons.auto_awesome),
                      label: const Text('خواندن اطلاعات با هوش مصنوعی', textAlign: TextAlign.center),
                      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _confirmDelete(context),
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('حذف تصویر'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red,
                        side: const BorderSide(color: Colors.red),
                        minimumSize: const Size.fromHeight(48),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class DraftsScreen extends StatefulWidget {
  /// 0 = scanned/manual drafts, 1 = drafts imported from a bank statement.
  final int initialTab;
  const DraftsScreen({this.initialTab = 0, super.key});
  @override
  State<DraftsScreen> createState() => _DraftsScreenState();
}

class _DraftsScreenState extends State<DraftsScreen> {
  List<Transaction> all = [];
  List<Transaction> tx = []; // drafts other than bank-statement ones
  List<Transaction> bankTx = []; // drafts imported from a bank statement
  List<Category> categories = [];
  List<Account> accounts = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    all = await Store.loadTransactions();
    final drafts = all.where((t) => t.draft).toList()..sort((a, b) => b.date.compareTo(a.date));
    tx = drafts.where((t) => !isBankImportId(t.id)).toList();
    bankTx = drafts.where((t) => isBankImportId(t.id)).toList();
    categories = await Store.loadCategories();
    accounts = await Store.loadAccounts();
    if (mounted) setState(() => loading = false);
  }

  /// Saved transactions (and other drafts) that may be the same booking as
  /// the bank-statement draft [t].
  List<Transaction> _duplicatesOf(Transaction t) =>
      possibleDuplicatesOf(t, all.where((x) => !(x.draft && isBankImportId(x.id) && x.id.compareTo(t.id) > 0)).toList());

  String categoryName(String id) {
    final c = categories.where((c) => c.id == id).toList();
    return c.isEmpty ? 'بدون‌دسته' : c.first.name;
  }

  String currencyOf(String accountId) {
    final a = accounts.where((a) => a.id == accountId).toList();
    return a.isEmpty ? 'IRT' : a.first.currency;
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

  Future<void> _compare(Transaction t, List<Transaction> candidates) async {
    final changed = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => DuplicateCompareScreen(draft: t, candidates: candidates, categories: categories, accounts: accounts),
      ),
    );
    if (changed == true) await _load();
  }

  Future<void> _delete(Transaction t) async {
    await NotificationService.instance.cancelForTransaction(t.id);
    await Store.deleteTransaction(t.id);
    await _load();
  }

  Widget _tile(Transaction t, {List<Transaction> duplicates = const []}) {
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
        child: Column(
          children: [
            ListTile(
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
              title: Text(t.merchant.isNotEmpty ? '${categoryName(t.categoryId)} • ${t.merchant}' : categoryName(t.categoryId)),
              subtitle: Text(
                isBankImportId(t.id) && t.note.isNotEmpty
                    ? '${formatDate(t.date)} • ${t.note.replaceFirst('از صورتحساب بانکی خوانده شده است.', '').trim()}'
                    : formatDate(t.date),
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
            if (duplicates.isNotEmpty)
              InkWell(
                onTap: () => _compare(t, duplicates),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.content_copy_outlined, size: 16, color: Colors.orange.shade800),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'احتمالاً تکراری است (${persianDigits('${duplicates.length}')} تراکنش مشابه)',
                          style: TextStyle(color: Colors.orange.shade900, fontSize: 12),
                        ),
                      ),
                      Text('مقایسه', style: TextStyle(color: Colors.orange.shade900, fontWeight: FontWeight.bold, fontSize: 12)),
                      Icon(Icons.chevron_left, size: 18, color: Colors.orange.shade900),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final bankWithDup = [for (final t in bankTx) (t: t, dups: _duplicatesOf(t))];
    final dupCount = bankWithDup.where((e) => e.dups.isNotEmpty).length;
    return DefaultTabController(
      length: 2,
      initialIndex: widget.initialTab,
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr('drafts')),
          bottom: TabBar(
            tabs: [
              Tab(text: 'اسکن و دستی (${persianDigits('${tx.length}')})'),
              Tab(text: 'صورتحساب بانک (${persianDigits('${bankTx.length}')})'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            tx.isEmpty
                ? const Center(child: Text('پیش‌نویسی وجود ندارد.'))
                : ListView(padding: const EdgeInsets.all(16), children: tx.map((t) => _tile(t)).toList()),
            bankTx.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'تراکنشی از صورتحساب بانک منتظر بررسی نیست.\nاز منوی «بارگذاری صورتحساب بانکی» فایل CSV یا PDF را وارد کن.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (dupCount > 0)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            '${persianDigits('$dupCount')} مورد احتمالاً قبلاً ثبت شده‌اند؛ روی «مقایسه» بزن تا کنار تراکنش ثبت‌شده ببینی و تصمیم بگیری.',
                            style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                          ),
                        ),
                      ...bankWithDup.map((e) => _tile(e.t, duplicates: e.dups)),
                    ],
                  ),
          ],
        ),
      ),
    );
  }
}

/// A bank-statement draft side by side with a saved transaction that may be
/// the same booking, with what to do about it: drop the draft as a
/// duplicate, keep it as a new transaction, or fill in what the saved one
/// is missing from it and drop the draft.
class DuplicateCompareScreen extends StatefulWidget {
  final Transaction draft;
  final List<Transaction> candidates;
  final List<Category> categories;
  final List<Account> accounts;
  const DuplicateCompareScreen({
    required this.draft,
    required this.candidates,
    required this.categories,
    required this.accounts,
    super.key,
  });
  @override
  State<DuplicateCompareScreen> createState() => _DuplicateCompareScreenState();
}

class _DuplicateCompareScreenState extends State<DuplicateCompareScreen> {
  int selected = 0;
  bool busy = false;

  Transaction get other => widget.candidates[selected];

  String _category(String id) => widget.categories.where((c) => c.id == id).firstOrNull?.name ?? 'بدون‌دسته';
  Account? _account(String id) => widget.accounts.where((a) => a.id == id).firstOrNull;
  String _money(Transaction t) => formatMoney(t.amount, _account(t.accountId)?.currency ?? 'IRT');
  String _note(Transaction t) => t.note.replaceFirst('از صورتحساب بانکی خوانده شده است.', '').trim();

  Future<void> _deleteDraft() async {
    setState(() => busy = true);
    await Store.deleteTransaction(widget.draft.id);
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _keepAsNew() async {
    setState(() => busy = true);
    await Store.upsertTransaction(widget.draft.copyWith(draft: false));
    if (mounted) Navigator.pop(context, true);
  }

  /// Copies what the saved transaction is missing (shop/payee, bank text)
  /// from the draft, then removes the draft.
  Future<void> _merge() async {
    setState(() => busy = true);
    final d = widget.draft;
    final o = other;
    final bankText = _note(d);
    final merged = o.copyWith(
      merchant: o.merchant.trim().isEmpty && d.merchant.trim().isNotEmpty ? d.merchant : null,
      note: bankText.isNotEmpty && !o.note.contains(bankText)
          ? (o.note.trim().isEmpty ? bankText : '${o.note}\n$bankText')
          : null,
    );
    await Store.upsertTransaction(merged);
    await Store.deleteTransaction(d.id);
    if (mounted) Navigator.pop(context, true);
  }

  Widget _row(String label, String a, String b) {
    final differs = a.trim() != b.trim();
    final style = TextStyle(fontSize: 13, color: differs ? Colors.orange.shade900 : null, fontWeight: differs ? FontWeight.w600 : null);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        color: differs ? Colors.orange.shade50 : null,
        border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 72, child: Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade700))),
          Expanded(child: Text(a.isEmpty ? '—' : a, style: style)),
          const SizedBox(width: 8),
          Expanded(child: Text(b.isEmpty ? '—' : b, style: style)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.draft;
    final o = other;
    return Scaffold(
      appBar: AppBar(title: const Text('مقایسه‌ی تراکنش مشابه')),
      bottomNavigationBar: pinnedBottomButtons(context, [
        OutlinedButton(
          onPressed: busy ? null : _keepAsNew,
          style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          child: const Text('تکراری نیست، ثبت شود', textAlign: TextAlign.center),
        ),
        FilledButton(
          onPressed: busy ? null : _deleteDraft,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48), backgroundColor: Colors.red.shade600),
          child: const Text('تکراری است، حذف شود', textAlign: TextAlign.center),
        ),
      ]),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.candidates.length > 1) ...[
            const Text('چند تراکنش مشابه پیدا شد؛ یکی را برای مقایسه انتخاب کن:', style: TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var i = 0; i < widget.candidates.length; i++)
                  ChoiceChip(
                    label: Text('${formatDate(widget.candidates[i].date)}${widget.candidates[i].draft ? ' (پیش‌نویس)' : ''}'),
                    selected: selected == i,
                    onSelected: (_) => setState(() => selected = i),
                  ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                Container(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                  child: Row(
                    children: [
                      const SizedBox(width: 72),
                      const Expanded(child: Text('از صورتحساب بانک', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13))),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          o.draft ? 'پیش‌نویس موجود' : 'ثبت‌شده‌ی قبلی',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
                _row('تاریخ', formatDate(d.date), formatDate(o.date)),
                _row('مبلغ', _money(d), _money(o)),
                _row('نوع', d.type == TxType.income ? 'درآمد' : 'هزینه', o.type == TxType.income ? 'درآمد' : 'هزینه'),
                _row('دسته‌بندی', _category(d.categoryId), _category(o.categoryId)),
                _row('حساب', _account(d.accountId)?.name ?? '', _account(o.accountId)?.name ?? ''),
                _row('فروشنده', d.merchant, o.merchant),
                _row('توضیح', _note(d), o.note),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'ردیف‌های نارنجی با هم فرق دارند.',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: busy ? null : _merge,
            icon: const Icon(Icons.merge_type),
            label: const Text('تکراری است؛ اطلاعات بانک به تراکنش ثبت‌شده اضافه شود'),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: busy
                ? null
                : () async {
                    final result = await Navigator.push<Object>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => TransactionEditor(categories: widget.categories, accounts: widget.accounts, existing: d),
                      ),
                    );
                    if (result is DeleteTransactionSignal) {
                      await Store.deleteTransaction(result.id);
                    } else if (result is Transaction) {
                      await Store.upsertTransaction(result);
                    } else {
                      return;
                    }
                    if (context.mounted) Navigator.pop(context, true);
                  },
            icon: const Icon(Icons.edit_outlined),
            label: const Text('ویرایش پیش‌نویس بانک'),
          ),
        ],
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
    final all = await Store.loadConfirmedTransactions();
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
    return a.isEmpty ? 'IRT' : a.first.currency;
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
        return 'سالانه (${formatDayMonth(t.date)})';
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

const _chartMonths = 4;

class _UpcomingPaymentsScreenState extends State<UpcomingPaymentsScreen> {
  bool loading = true;
  List<Transaction> tx = [];
  List<Category> categories = [];
  List<Account> accounts = [];
  _UpcomingRange range = _UpcomingRange.endOfThisMonth;
  DateTime customMonth = DateTime(DateTime.now().year, DateTime.now().month, 1);
  bool showChart = true;
  int chartMonthOffset = 0;
  String? accountFilter;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    tx = await Store.loadConfirmedTransactions();
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
    return m.isEmpty ? 'IRT' : m.first.currency;
  }

  String get primaryCurrency => accountFilter != null ? currencyOf(accountFilter!) : mainCurrencyOf(accounts);

  Future<void> _pickCustomMonth() async {
    final isJalali = currentCalendarSystem.value == CalendarSystem.jalali;
    final now = DateTime.now();
    int y, m, baseYear;
    if (isJalali) {
      final j = gregorianToJalali(customMonth.year, customMonth.month, customMonth.day);
      y = j[0];
      m = j[1];
      baseYear = gregorianToJalali(now.year, now.month, now.day)[0];
    } else {
      y = customMonth.year;
      m = customMonth.month;
      baseYear = now.year;
    }
    final monthNames = isJalali ? _jalaliMonthNames : _gregorianMonthNames;
    final years = {for (var i = 0; i < 4; i++) baseYear + i, y}.toList()..sort();
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
                  items: List.generate(12, (i) => i + 1).map((mo) => DropdownMenuItem(value: mo, child: Text(monthNames[mo - 1]))).toList(),
                  onChanged: (v) => setLocal(() => m = v ?? m),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<int>(
                  initialValue: y,
                  decoration: const InputDecoration(labelText: 'سال'),
                  items: years.map((yr) => DropdownMenuItem(value: yr, child: Text(ltr(persianDigits('$yr'))))).toList(),
                  onChanged: (v) => setLocal(() => y = v ?? y),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('cancel'))),
            FilledButton(
              onPressed: () {
                if (isJalali) {
                  final g = jalaliToGregorian(y, m, 1);
                  Navigator.pop(ctx, DateTime(g[0], g[1], g[2]));
                } else {
                  Navigator.pop(ctx, DateTime(y, m, 1));
                }
              },
              child: Text(tr('confirm')),
            ),
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
        return DateTimeRange(start: today, end: calendarMonthOf(today).end);
      case _UpcomingRange.nextMonth:
        final m = calendarMonthOf(today, 1);
        return DateTimeRange(start: m.start, end: m.end);
      case _UpcomingRange.custom:
        final m = calendarMonthOf(customMonth);
        return DateTimeRange(start: m.start, end: m.end);
    }
  }

  /// How far ahead recurring-occurrence projections need to reach to cover
  /// the 4-month chart, which can be paged forward/back with
  /// [chartMonthOffset] - without this, recurring transactions silently
  /// stopped showing up once the chart was paged past a fixed horizon.
  int _neededHorizonDays(DateTime today) {
    final lastChartMonthEnd = calendarMonthOf(today, _chartMonths - 1 + chartMonthOffset).end;
    final needed = lastChartMonthEnd.difference(today).inDays + 5;
    return needed > 220 ? needed : 220;
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final selectedRange = _rangeFor(range, today);
    final currency = primaryCurrency;

    final allOccurrences = occurrencesWithRecurringProjections(tx, horizonDays: _neededHorizonDays(today));
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

    // Lookahead chart: projected expense per calendar month. Whole months
    // are counted - including recurring payments that already fell due
    // earlier in the current month - not just what's still to come.
    final firstChartMonth = calendarMonthOf(today, chartMonthOffset);
    final chartOccurrences = occurrencesWithRecurringProjections(
      tx,
      horizonDays: _neededHorizonDays(today),
      from: firstChartMonth.start,
    );
    final chartMonths = <({CalendarMonth month, double expense})>[];
    for (var i = 0; i < _chartMonths; i++) {
      final cm = calendarMonthOf(today, i + chartMonthOffset);
      final total = chartOccurrences
          .where((e) =>
              e.t.type == TxType.expense &&
              (accountFilter != null ? e.t.accountId == accountFilter : currencyOf(e.t.accountId) == currency) &&
              !e.date.isBefore(cm.start) &&
              !e.date.isAfter(cm.end))
          .fold(0.0, (s, e) => s + e.t.amount);
      chartMonths.add((month: cm, expense: total));
    }
    final maxChart = chartMonths.fold(0.0, (m, c) => c.expense > m ? c.expense : m);

    final customLabel = range == _UpcomingRange.custom
        ? '${calendarMonthOf(customMonth).name} ${calendarMonthOf(customMonth).yearText}'
        : 'ماه دلخواه';

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('upcoming_payments')),
        actions: [
          IconButton(
            icon: Icon(showChart ? Icons.bar_chart : Icons.bar_chart_outlined),
            tooltip: showChart ? 'پنهان کردن نمودار' : 'نمایش نمودار',
            isSelected: showChart,
            onPressed: () => setState(() => showChart = !showChart),
          ),
        ],
      ),
      // Everything scrolls together, so the list isn't squeezed under a
      // fixed chart.
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('بازه‌ی زمانی', style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 8),
                  SegmentedButton<_UpcomingRange>(
                    showSelectedIcon: false,
                    style: const ButtonStyle(visualDensity: VisualDensity.compact),
                    segments: [
                      const ButtonSegment(value: _UpcomingRange.endOfThisMonth, label: Text('تا آخر این ماه')),
                      const ButtonSegment(value: _UpcomingRange.nextMonth, label: Text('ماه بعد')),
                      ButtonSegment(
                        value: _UpcomingRange.custom,
                        icon: const Icon(Icons.calendar_month_outlined, size: 16),
                        label: Text(customLabel, maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                    ],
                    selected: {range},
                    onSelectionChanged: (sel) {
                      final r = sel.first;
                      if (r == _UpcomingRange.custom) {
                        _pickCustomMonth();
                      } else {
                        setState(() => range = r);
                      }
                    },
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String?>(
                    initialValue: accountFilter,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'حساب',
                      prefixIcon: Icon(Icons.account_balance_wallet_outlined),
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: [
                      DropdownMenuItem(value: null, child: Text(tr('all_accounts'))),
                      ...accounts.map((a) => DropdownMenuItem(value: a.id, child: Text('${a.name} (${currencyLabel(a.currency)})'))),
                    ],
                    onChanged: (v) => setState(() => accountFilter = v),
                  ),
                ],
              ),
            ),
          ),
          if (showChart) ...[
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.chevron_left, size: 20),
                          tooltip: 'یک ماه بعد',
                          onPressed: () => setState(() => chartMonthOffset++),
                          visualDensity: VisualDensity.compact,
                        ),
                        Expanded(
                          child: Text(
                            'هزینه‌ی پیش‌بینی‌شده‌ی ماهانه',
                            style: Theme.of(context).textTheme.titleSmall,
                            textAlign: TextAlign.center,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.chevron_right, size: 20),
                          tooltip: 'یک ماه قبل',
                          onPressed: () => setState(() => chartMonthOffset--),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 200,
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
                                        FittedBox(
                                          fit: BoxFit.scaleDown,
                                          child: Text(
                                            chartMonths[i].expense > 0 ? ltr(formatMoneyCompact(chartMonths[i].expense, currency)) : '',
                                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                                            textAlign: TextAlign.center,
                                            maxLines: 1,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Container(
                                          height: 115 * (chartMonths[i].expense / maxChart).clamp(0.02, 1.0),
                                          margin: const EdgeInsets.symmetric(horizontal: 10),
                                          decoration: BoxDecoration(
                                            color: chartMonths[i].month.start == calendarMonthOf(today).start
                                                ? Colors.red.shade600
                                                : Colors.red.shade300,
                                            borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        Text(chartMonths[i].month.name, style: const TextStyle(fontSize: 12)),
                                        Text(
                                          ltr(chartMonths[i].month.yearText),
                                          style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
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
          ],
          if (totalsByCurrency.isNotEmpty) ...[
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: const Icon(Icons.summarize_outlined),
                title: const Text('جمع هزینه‌های پیش‌رو در این بازه', style: TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: totalsByCurrency.entries
                      .map((e) => Text(ltr(formatMoney(e.value, e.key)), style: const TextStyle(color: Colors.red, fontSize: 15)))
                      .toList(),
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          if (entries.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: Text('در این بازه هزینه‌ی پیش‌رویی وجود ندارد.')),
            )
          else
            ...entries.map((e) => _entryCard(e, today)),
        ],
      ),
    );
  }

  Widget _entryCard(TxOccurrence e, DateTime today) {
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
          daysLeft == 0 ? 'امروز' : '${formatDate(e.date)} • ${ltr(persianDigits('$daysLeft'))} روز دیگر',
        ),
        trailing: Text(
          ltr(e.t.type == TxType.income ? '+' : '-') + formatMoney(e.t.amount, currencyOf(e.t.accountId)),
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: e.t.type == TxType.income ? Colors.green.shade700 : Colors.red.shade700,
          ),
        ),
        onTap: () async {
          final result = await Navigator.push<Object>(
            context,
            MaterialPageRoute(builder: (_) => TransactionDetailScreen(t: e.t, categories: categories, accounts: accounts)),
          );
          if (result is DeleteTransactionSignal) {
            await Store.deleteTransaction(result.id);
          } else if (result is Transaction) {
            await Store.upsertTransaction(result);
          }
          await _load();
        },
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
    return a.isEmpty ? 'IRT' : a.first.currency;
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

enum AutoBackupFrequency { off, weekly, monthly, quarterly }

extension AutoBackupFrequencyX on AutoBackupFrequency {
  String get label => switch (this) {
        AutoBackupFrequency.off => 'خاموش',
        AutoBackupFrequency.weekly => 'هفتگی',
        AutoBackupFrequency.monthly => 'ماهانه',
        AutoBackupFrequency.quarterly => 'فصلی (هر ۳ ماه)',
      };
  int get days => switch (this) {
        AutoBackupFrequency.off => 0,
        AutoBackupFrequency.weekly => 7,
        AutoBackupFrequency.monthly => 30,
        AutoBackupFrequency.quarterly => 90,
      };
}

/// Silently writes a backup file to the app's own storage (no share sheet)
/// when the interval the person chose in Settings has passed, keeping only
/// the most recent few so this can't quietly fill up the device.
Future<void> maybeRunAutoBackup() async {
  final freq = await Store.loadAutoBackupFrequency();
  if (freq == AutoBackupFrequency.off) return;
  final last = await Store.loadLastAutoBackupAt();
  final now = DateTime.now();
  if (last != null && now.difference(last).inDays < freq.days) return;
  try {
    final data = await Store.exportBackupData();
    final json = const JsonEncoder.withIndent('  ').convert(data);
    final dir = await getApplicationDocumentsDirectory();
    final backupsDir = Directory('${dir.path}/auto_backups');
    if (!await backupsDir.exists()) await backupsDir.create(recursive: true);
    final path = '${backupsDir.path}/backup_${now.millisecondsSinceEpoch}.json';
    await File(path).writeAsString(json);
    // Keep only the 5 most recent auto-backups.
    final files = backupsDir.listSync().whereType<File>().toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    for (final f in files.skip(5)) {
      try {
        await f.delete();
      } catch (_) {}
    }
    await Store.saveLastAutoBackupAt(now);
  } catch (_) {
    // Best-effort only - a failed silent backup shouldn't interrupt the person.
  }
}

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

// ============================== Savings/investment suggestion ==============================

class SavingsSuggestionScreen extends StatefulWidget {
  const SavingsSuggestionScreen({super.key});
  @override
  State<SavingsSuggestionScreen> createState() => _SavingsSuggestionScreenState();
}

class _SavingsSuggestionScreenState extends State<SavingsSuggestionScreen> {
  bool loading = true;
  bool hasGeminiKey = false;
  bool requesting = false;
  String? aiSuggestion;
  String? errorMessage;
  List<Transaction> tx = [];
  List<Account> accounts = [];
  List<SavingsGoal> goals = [];
  List<SavingsContribution> contributions = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    tx = await Store.loadConfirmedTransactions();
    accounts = await Store.loadAccounts();
    goals = await Store.loadSavingsGoals();
    contributions = await Store.loadSavingsContributions();
    final key = await Store.loadGeminiKey();
    hasGeminiKey = key != null && key.trim().isNotEmpty;
    setState(() => loading = false);
  }

  String get primaryCurrency => mainCurrencyOf(accounts);

  String currencyOf(String accountId) {
    final m = accounts.where((a) => a.id == accountId).toList();
    return m.isEmpty ? 'IRT' : m.first.currency;
  }

  /// Average monthly income/expense (in the primary currency, transfers
  /// excluded since they're not real income/expense) over the last
  /// [months] full months, not counting the current, still-in-progress
  /// month.
  ({double income, double expense}) _averages(int months) {
    final now = DateTime.now();
    double income = 0, expense = 0;
    for (var i = 1; i <= months; i++) {
      var y = now.year;
      var m = now.month - i;
      while (m < 1) {
        m += 12;
        y--;
      }
      for (final t in tx) {
        if (currencyOf(t.accountId) != primaryCurrency) continue;
        if (t.categoryId == '_transfer_out_' || t.categoryId == '_transfer_in_') continue;
        if (t.date.year != y || t.date.month != m) continue;
        if (t.type == TxType.income) {
          income += t.amount;
        } else {
          expense += t.amount;
        }
      }
    }
    return (income: income / months, expense: expense / months);
  }

  Future<void> _requestAiSuggestion() async {
    setState(() {
      requesting = true;
      errorMessage = null;
    });
    try {
      final key = await Store.loadGeminiKey();
      final avg = _averages(3);
      final surplus = avg.income - avg.expense;
      final goalLines = goals.map((g) {
        final progress = contributions.where((c) => c.goalId == g.id).fold(0.0, (s, c) => s + c.amount);
        return '- ${g.name}: ${progress.toStringAsFixed(0)}/${g.targetAmount.toStringAsFixed(0)} $primaryCurrency';
      }).join('\n');
      final prompt =
          'You are a friendly, general personal-finance educator (NOT a licensed financial advisor - never claim '
          'to be one, never give confident predictions, never recommend specific stocks, funds, or ISINs). Given '
          'this person\'s recent monthly averages (in $primaryCurrency): income ${avg.income.toStringAsFixed(0)}, '
          'expenses ${avg.expense.toStringAsFixed(0)}, monthly surplus ${surplus.toStringAsFixed(0)}, and their '
          'savings goals with current progress:\n$goalLines\n\n'
          'Write a short (120-180 words), warm, practical note in Persian. Cover, at a general/educational level '
          'only: (1) a rough split for the surplus between an emergency buffer, their stated goals, and general '
          'long-term investing (e.g. broad index funds) - as a starting point to think about, not a directive; '
          '(2) one habit suggestion (like automating a monthly transfer); (3) a closing reminder that this is '
          'general educational information, not personalized financial advice, and that they should do their own '
          'research or consult a licensed advisor for actual decisions. Do not mention specific companies, tickers, '
          'or make return/performance predictions. Plain prose, no markdown, no headers.';
      final result = await geminiTextRequest(key!.trim(), prompt);
      setState(() => aiSuggestion = result);
    } on GeminiException catch (e) {
      setState(() => errorMessage = e.friendlyMessage);
    } catch (e) {
      setState(() => errorMessage = 'خطای غیرمنتظره: $e');
    } finally {
      if (mounted) setState(() => requesting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final avg = _averages(3);
    final surplus = avg.income - avg.expense;
    final currency = primaryCurrency;
    return Scaffold(
      appBar: AppBar(title: Text(tr('savings_suggestion_title'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('میانگین ۳ ماه اخیر', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('میانگین درآمد'),
                      Text(ltr(formatMoney(avg.income, currency)), style: const TextStyle(color: Colors.green, fontWeight: FontWeight.w600)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('میانگین هزینه'),
                      Text(ltr(formatMoney(avg.expense, currency)), style: const TextStyle(color: Colors.red, fontWeight: FontWeight.w600)),
                    ],
                  ),
                  const Divider(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('مازاد قابل پس‌انداز', style: TextStyle(fontWeight: FontWeight.bold)),
                      Text(
                        ltr(formatMoney(surplus, currency)),
                        style: TextStyle(fontWeight: FontWeight.bold, color: surplus >= 0 ? Colors.indigo : Colors.red),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (surplus > 0)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('یک نقطه‌ی شروع ساده', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text(
                      'با مازاد ماهانه‌ی حدود ${ltr(formatMoney(surplus, currency))}، یک شروع رایج اینه: '
                      'حدود نیمی رو برای اهداف نزدیک‌مدت (مثل چیزهایی که توی «اهداف پس‌انداز» تعریف کردی) '
                      'کنار بذاری، و باقی رو به‌صورت ماهانه و خودکار وارد یه حساب سرمایه‌گذاری بلندمدت کنی. '
                      'این فقط یه نقطه‌ی شروعه، نه یه قانون ثابت.',
                      style: const TextStyle(fontSize: 13, height: 1.6),
                    ),
                  ],
                ),
              ),
            )
          else
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'در ۳ ماه اخیر، میانگین هزینه‌هات از درآمدت بیشتر بوده. قبل از فکر به پس‌انداز/سرمایه‌گذاری، شاید بهتر باشه اول روی کم‌کردن هزینه‌ها یا افزایش درآمد تمرکز کنی.',
                  style: TextStyle(fontSize: 13, height: 1.6),
                ),
              ),
            ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: requesting ? null : () => hasGeminiKey ? _requestAiSuggestion() : promptForGeminiKey(context),
            icon: requesting
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.auto_awesome),
            label: Text(requesting ? 'در حال دریافت...' : 'پیشنهاد هوشمند‌تر (با هوش مصنوعی)'),
          ),
          if (errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(errorMessage!, style: const TextStyle(color: Colors.red, fontSize: 12)),
            ),
          if (aiSuggestion != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Card(
                color: Colors.indigo.shade50,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(aiSuggestion!, style: const TextStyle(fontSize: 13, height: 1.7)),
                ),
              ),
            ),
          const SizedBox(height: 8),
          Text(
            'این صفحه اطلاعات آموزشی و کلی ارائه می‌دهد و جایگزین مشاوره‌ی مالی رسمی نیست.',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
          ),
        ],
      ),
    );
  }
}

// ============================== Net worth trend ==============================

class NetWorthScreen extends StatefulWidget {
  const NetWorthScreen({super.key});
  @override
  State<NetWorthScreen> createState() => _NetWorthScreenState();
}

class _NetWorthScreenState extends State<NetWorthScreen> {
  bool loading = true;
  List<Account> accounts = [];
  List<Transaction> tx = [];
  String baseCurrency = 'IRT';
  Map<String, double> rates = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    accounts = await Store.loadAccounts();
    tx = await Store.loadConfirmedTransactions();
    final storedBase = await Store.loadBaseCurrency();
    baseCurrency = storedBase ?? (accounts.isNotEmpty ? accounts.first.currency : 'IRT');
    rates = await Store.loadExchangeRates();
    setState(() => loading = false);
  }

  double _rateFor(String currency) {
    if (currency == baseCurrency) return 1.0;
    final stored = rates[currency];
    if (stored != null) return stored;
    // 1 Toman = 10 Rial, so no manual rate is needed between the two.
    if (baseCurrency == 'IRR' && currency == 'IRT') return 10.0;
    if (baseCurrency == 'IRT' && currency == 'IRR') return 0.1;
    return 1.0;
  }

  double _netWorthAt(DateTime endOfMonth) {
    var total = 0.0;
    for (final a in accounts) {
      var balance = a.initialBalance;
      for (final t in tx) {
        if (t.accountId != a.id) continue;
        if (t.date.isAfter(endOfMonth)) continue;
        balance += t.type == TxType.income ? t.amount : -t.amount;
      }
      total += balance * _rateFor(a.currency);
    }
    return total;
  }

  Set<String> get _nonBaseCurrencies => accounts.map((a) => a.currency).where((c) => c != baseCurrency).toSet();

  Future<void> _editSettings() async {
    String localBase = baseCurrency;
    final ctrls = <String, TextEditingController>{
      for (final c in accounts.map((a) => a.currency).toSet())
        if (c != localBase) c: TextEditingController(text: rates[c]?.toString() ?? '1'),
    };
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        // rebuild controllers if base currency changes inside the dialog
        for (final c in accounts.map((a) => a.currency).toSet()) {
          if (c != localBase && !ctrls.containsKey(c)) {
            ctrls[c] = TextEditingController(text: rates[c]?.toString() ?? '1');
          }
        }
        return AlertDialog(
          title: const Text('ارز مرجع و نرخ تبدیل'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: localBase,
                  decoration: const InputDecoration(labelText: 'ارز مرجع'),
                  items: kCurrencies.map((c) => DropdownMenuItem(value: c, child: Text(currencyLabel(c)))).toList(),
                  onChanged: (v) => setLocal(() => localBase = v ?? localBase),
                ),
                const SizedBox(height: 12),
                if (ctrls.isEmpty)
                  const Text('حساب دیگری با ارز متفاوت نداری.', style: TextStyle(fontSize: 12, color: Colors.grey))
                else ...[
                  const Text('نرخ تبدیل هر واحد به ارز مرجع:', style: TextStyle(fontSize: 12, color: Colors.grey)),
                  const SizedBox(height: 8),
                  ...ctrls.entries
                      .where((e) => e.key != localBase)
                      .map((e) => Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: TextField(
                              controller: e.value,
                              keyboardType: const TextInputType.numberWithOptions(decimal: true), inputFormatters: const [AmountInputFormatter()],
                              decoration: InputDecoration(labelText: '۱ ${currencyLabel(e.key)} = ? ${currencyLabel(localBase)}', isDense: true),
                            ),
                          )),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('save'))),
          ],
        );
      }),
    );
    if (result != true) return;
    final newRates = <String, double>{};
    for (final entry in ctrls.entries) {
      if (entry.key == localBase) continue;
      final v = parseAmount(entry.value.text);
      if (v != null && v > 0) newRates[entry.key] = v;
    }
    baseCurrency = localBase;
    rates = newRates;
    await Store.saveBaseCurrency(baseCurrency);
    await Store.saveExchangeRates(rates);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final now = DateTime.now();
    final months = <({DateTime month, double value})>[];
    for (var i = 11; i >= 0; i--) {
      var y = now.year;
      var m = now.month - i;
      while (m < 1) {
        m += 12;
        y--;
      }
      final endOfMonth = DateTime(y, m + 1, 0);
      months.add((month: DateTime(y, m), value: _netWorthAt(endOfMonth)));
    }
    final maxVal = months.fold(0.0, (mx, e) => e.value.abs() > mx ? e.value.abs() : mx);
    final current = months.isEmpty ? 0.0 : months.last.value;
    final missingRates = _nonBaseCurrencies.where((c) => !rates.containsKey(c)).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('روند ارزش خالص دارایی'),
        actions: [
          infoButton(
            context,
            'روند ارزش خالص دارایی',
            'ارزش خالص دارایی یعنی مجموع موجودی همه‌ی حساب‌هات با هم. این نمودار این عدد رو برای ۱۲ ماه اخیر نشون می‌ده تا ببینی کل دارایی‌ت در طول زمان داره بیشتر می شه یا کمتر.\n\n'
            'اگه چند حساب با ارزهای مختلف داری، می‌تونی نرخ تبدیل دستی تنظیم کنی (دکمه‌ی تنظیمات) تا همه با هم جمع بسته بشن.',
          ),
          IconButton(icon: const Icon(Icons.settings_outlined), onPressed: _editSettings),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('ارزش خالص فعلی (تقریبی، بر اساس ${currencyLabel(baseCurrency)})', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                  const SizedBox(height: 4),
                  Text(
                    ltr(formatMoney(current, baseCurrency)),
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: current >= 0 ? Colors.green.shade700 : Colors.red.shade700),
                  ),
                ],
              ),
            ),
          ),
          if (missingRates.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: InkWell(
                onTap: _editSettings,
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, size: 14, color: Colors.grey),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'برای ${missingRates.join('، ')} نرخ تبدیل تنظیم نشده (فعلاً ۱:۱ حساب شده). برای تنظیم بزن.',
                        style: const TextStyle(fontSize: 11, color: Colors.grey, decoration: TextDecoration.underline),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SizedBox(
                height: 220,
                child: maxVal <= 0
                    ? const Center(child: Text('داده‌ای برای نمایش نیست.', style: TextStyle(color: Colors.grey)))
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          for (final m in months)
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  // Grouped in threes (e.g. ۱۲,۵۰۰,۰۰۰) and shrunk to
                                  // fit the bar instead of being cut off.
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      m.value.abs() >= 1
                                          ? ltr(persianDigits('${m.value < 0 ? '-' : ''}${_groupThousands(m.value.abs().round().toString())}'))
                                          : '',
                                      style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold),
                                      maxLines: 1,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Container(
                                    height: maxVal > 0 ? 140 * (m.value.abs() / maxVal).clamp(0.02, 1.0) : 2,
                                    margin: const EdgeInsets.symmetric(horizontal: 2),
                                    decoration: BoxDecoration(
                                      color: m.value >= 0 ? Colors.indigo.shade300 : Colors.red.shade300,
                                      borderRadius: const BorderRadius.vertical(top: Radius.circular(3)),
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(() { final n = _gregorianMonthNames[m.month.month - 1]; return n.length > 3 ? n.substring(0, 3) : n; }(), style: const TextStyle(fontSize: 8)),
                                ],
                              ),
                            ),
                        ],
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================== Zero-based (YNAB-style) monthly budget ==============================

class ZeroBasedBudgetScreen extends StatefulWidget {
  const ZeroBasedBudgetScreen({super.key});
  @override
  State<ZeroBasedBudgetScreen> createState() => _ZeroBasedBudgetScreenState();
}

class _ZeroBasedBudgetScreenState extends State<ZeroBasedBudgetScreen> {
  bool loading = true;
  List<Category> categories = [];
  List<Transaction> tx = [];
  List<BudgetGoal> goals = [];
  List<Account> accounts = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    categories = await Store.loadCategories();
    tx = await Store.loadConfirmedTransactions();
    goals = await Store.loadBudgetGoals();
    accounts = await Store.loadAccounts();
    setState(() => loading = false);
  }

  String currencyOf(String accountId) {
    final m = accounts.where((a) => a.id == accountId).toList();
    return m.isEmpty ? 'IRT' : m.first.currency;
  }

  String get primaryCurrency => mainCurrencyOf(accounts);

  /// This month's actual income so far; if nothing has come in yet this
  /// month, falls back to the average of the last 3 months so the screen
  /// still has something meaningful to allocate against early in the month.
  double get _monthIncome {
    final now = DateTime.now();
    var income = 0.0;
    for (final t in tx) {
      if (t.type != TxType.income || t.categoryId == '_transfer_in_') continue;
      if (currencyOf(t.accountId) != primaryCurrency) continue;
      if (t.date.year == now.year && t.date.month == now.month) income += t.amount;
    }
    if (income > 0) return income;
    var sum = 0.0;
    for (var i = 1; i <= 3; i++) {
      var y = now.year, m = now.month - i;
      while (m < 1) {
        m += 12;
        y--;
      }
      for (final t in tx) {
        if (t.type != TxType.income || t.categoryId == '_transfer_in_') continue;
        if (currencyOf(t.accountId) != primaryCurrency) continue;
        if (t.date.year == y && t.date.month == m) sum += t.amount;
      }
    }
    return sum / 3;
  }

  double get _totalAllocated => goals.fold(0.0, (s, g) => s + g.monthlyAmount);

  double _allocationFor(String categoryId) {
    final m = goals.where((g) => g.categoryId == categoryId).toList();
    return m.isEmpty ? 0 : m.first.monthlyAmount;
  }

  double _spendFor(String categoryId) {
    final now = DateTime.now();
    var spend = 0.0;
    for (final t in tx) {
      if (t.type != TxType.expense || t.categoryId == '_transfer_out_') continue;
      if (currencyOf(t.accountId) != primaryCurrency) continue;
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

  Future<void> _editAllocation(Category c) async {
    final ctrl = TextEditingController(text: _allocationFor(c.id) > 0 ? formatAmountInput(_allocationFor(c.id)) : '');
    final result = await showDialog<double?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('تخصیص ${c.name}'),
        content: TextField(
          controller: ctrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true), inputFormatters: const [AmountInputFormatter()],
          decoration: InputDecoration(labelText: 'مبلغ تخصیص‌یافته در ماه (${currencyLabel(primaryCurrency)})'),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, 0.0), child: const Text('صفر کن')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, parseAmount(ctrl.text)), child: Text(tr('save'))),
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
    final income = _monthIncome;
    final allocated = _totalAllocated;
    final unallocated = income - allocated;
    final unallocatedColor = unallocated.abs() < 0.01 ? Colors.green : (unallocated > 0 ? Colors.amber.shade800 : Colors.red);
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('zero_based_budget_title')),
        actions: [
          infoButton(
            context,
            tr('zero_based_budget_title'),
            'روش بودجه‌بندی صفر-پایه یعنی هر تومان/ریالی که درآمد داری، از قبل به یه دسته‌بندی یا هدف مشخص اختصاص بدی، طوری که چیزی بدون برنامه نمونه.\n\n'
            'این صفحه درآمد این ماه رو با مجموع تخصیص‌هایی که برای دسته‌بندی‌های هزینه گذاشتی مقایسه می‌کنه؛ اگه چیزی «تخصیص‌نیافته» بمونه یعنی هنوز مشخص نکردی اون بخش از پول قراره کجا بره.',
          ),
        ],
      ),
      body: Column(
        children: [
          Card(
            margin: const EdgeInsets.all(16),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('درآمد این ماه'),
                      Text(ltr(formatMoney(income, primaryCurrency)), style: const TextStyle(fontWeight: FontWeight.w600)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('تخصیص‌یافته'),
                      Text(ltr(formatMoney(allocated, primaryCurrency)), style: const TextStyle(fontWeight: FontWeight.w600)),
                    ],
                  ),
                  const Divider(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        unallocated.abs() < 0.01 ? 'همه‌چیز تخصیص یافته' : (unallocated > 0 ? 'هنوز تخصیص‌نیافته' : 'بیش از درآمد تخصیص یافته'),
                        style: TextStyle(fontWeight: FontWeight.bold, color: unallocatedColor),
                      ),
                      Text(
                        ltr(formatMoney(unallocated, primaryCurrency)),
                        style: TextStyle(fontWeight: FontWeight.bold, color: unallocatedColor, fontSize: 16),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              itemCount: topCategories.length,
              itemBuilder: (context, i) {
                final c = topCategories[i];
                final alloc = _allocationFor(c.id);
                final spend = _spendFor(c.id);
                final ratio = alloc > 0 ? (spend / alloc).clamp(0.0, 1.0) : 0.0;
                return Card(
                  child: ListTile(
                    leading: Icon(iconForCategory(c, categories)),
                    title: Text(c.name),
                    subtitle: alloc > 0
                        ? Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: LinearProgressIndicator(
                                    value: ratio,
                                    minHeight: 6,
                                    backgroundColor: Colors.grey.withValues(alpha: 0.2),
                                    color: ratio >= 1.0 ? Colors.red : Colors.indigo.shade300,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  '${formatMoney(spend, primaryCurrency)} از ${formatMoney(alloc, primaryCurrency)} خرج شده',
                                  style: const TextStyle(fontSize: 11),
                                ),
                              ],
                            ),
                          )
                        : const Text('تخصیصی داده نشده', style: TextStyle(color: Colors.grey, fontSize: 12)),
                    trailing: const Icon(Icons.edit_outlined, size: 18),
                    onTap: () => _editAllocation(c),
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
  List<Account> accounts = [];

  String get mainCurrency => mainCurrencyOf(accounts);
  bool get hasOtherCurrencies => accounts.any((a) => a.currency != mainCurrency);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    categories = await Store.loadCategories();
    tx = await Store.loadConfirmedTransactions();
    goals = await Store.loadBudgetGoals();
    accounts = await Store.loadAccounts();
    setState(() => loading = false);
  }

  double _spendFor(String categoryId) {
    final now = DateTime.now();
    var spend = 0.0;
    final curById = {for (final a in accounts) a.id: a.currency};
    for (final t in tx) {
      if (t.type != TxType.expense) continue;
      if ((curById[t.accountId] ?? mainCurrency) != mainCurrency) continue; // other units can't be added up
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
    final ctrl = TextEditingController(text: existing.isEmpty ? '' : formatAmountInput(existing.first.monthlyAmount));
    final result = await showDialog<double?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('هدف هزینه‌ی ${c.name}'),
        content: TextField(
          controller: ctrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true), inputFormatters: const [AmountInputFormatter()],
          decoration: InputDecoration(labelText: 'مبلغ هدف در ماه (${currencyLabel(mainCurrency)})', hintText: 'مثلاً ۲۰۰,۰۰۰'),
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
            onPressed: () => Navigator.pop(ctx, parseAmount(ctrl.text)),
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
      appBar: AppBar(
        title: Text(tr('budget_goals')),
        actions: [
          infoButton(
            context,
            tr('budget_goals'),
            'برای هر دسته‌بندی هزینه یه سقف ماهانه تعیین می‌کنی. برنامه خرج این ماه رو با اون سقف مقایسه می‌کنه و وقتی نزدیک یا رد شده باشی، هشدار می‌ده.\n\n'
            'این ابزار مناسبه اگه می‌خوای جلوی خرج زیاد توی یه دسته‌بندی خاص (مثلاً خوراک یا خرید) رو بگیری.',
          ),
        ],
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: topCategories.length + (hasOtherCurrencies ? 1 : 0),
        itemBuilder: (context, i) {
          if (hasOtherCurrencies && i == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                'هدف‌ها به واحد حساب اصلی (${currencyLabel(mainCurrency)}) هستند؛ تراکنش‌های حساب‌هایی با واحد دیگر در این محاسبه نمی‌آیند.',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
              ),
            );
          }
          final c = topCategories[hasOtherCurrencies ? i - 1 : i];
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
                            '${formatMoney(spend, mainCurrency)} از ${formatMoney(goal.monthlyAmount, mainCurrency)} (${ltr(persianDigits('${(ratio * 100).round()}%'))})',
                            style: TextStyle(fontSize: 12, color: color),
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
  List<Account> accounts = [];

  /// Savings goals have no account of their own: they are always in the
  /// currency of the main account.
  String get mainCurrency => mainCurrencyOf(accounts);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    goals = await Store.loadSavingsGoals();
    contributions = await Store.loadSavingsContributions();
    accounts = await Store.loadAccounts();
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
    final amountCtrl = TextEditingController(text: (existing == null ? '' : formatAmountInput(existing.targetAmount)));
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
                TextField(
                  controller: amountCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: const [AmountInputFormatter()],
                  decoration: InputDecoration(labelText: 'مبلغ هدف (${currencyLabel(mainCurrency)})'),
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(targetDate == null ? 'تاریخ هدف (اختیاری)' : formatDate(targetDate!)),
                  trailing: const Icon(Icons.calendar_today, size: 18),
                  onTap: () async {
                    final picked = await showAppDatePicker(
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
    final amount = parseAmount(amountCtrl.text);
    if (nameCtrl.text.trim().isEmpty || amount == null || amount <= 0) return;
    final goal = SavingsGoal(
      id: existing?.id ?? 'sg_${DateTime.now().microsecondsSinceEpoch}',
      name: nameCtrl.text.trim(),
      targetAmount: amount,
      targetDate: targetDate,
      currency: mainCurrency,
    );
    goals = [...goals.where((g) => g.id != goal.id), goal];
    await Store.saveSavingsGoals(goals);
    setState(() {});
  }

  Future<void> _addContribution(SavingsGoal g) async {
    final amountCtrl = TextEditingController();
    DateTime date = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
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
                keyboardType: const TextInputType.numberWithOptions(decimal: true), inputFormatters: const [AmountInputFormatter()],
                decoration: InputDecoration(labelText: 'مبلغ واریزی (${currencyLabel(mainCurrency)})'),
                autofocus: true,
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(formatDate(date)),
                trailing: const Icon(Icons.calendar_today, size: 18),
                onTap: () async {
                  final picked =
                      await showAppDatePicker(
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
    final amount = parseAmount(amountCtrl.text);
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
                            title: Text(ltr(formatMoney(c.amount, mainCurrency))),
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
      appBar: AppBar(
        title: Text(tr('savings_goals')),
        actions: [
          infoButton(
            context,
            tr('savings_goals'),
            'برای یه هدف مشخص (مثلاً خرید ماشین یا سفر) یه مبلغ هدف تعیین می‌کنی و هر بار که پس‌انداز می‌کنی، یه واریزی ثبت می‌کنی.\n\n'
            'این هدف مستقل از حساب‌هاته - فقط پیشرفتت به سمت اون مبلغ رو پیگیری می‌کنه، بدون اینکه به تراکنش‌های روزمره‌ربط داشته باشه.',
          ),
        ],
      ),
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
                  projection = 'با روند فعلی، حدود ${persianDigits('$monthsLeft')} ماه دیگر به هدف می\u200cرسی.';
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
                          '${ltr(formatMoney(current, mainCurrency))} از ${ltr(formatMoney(g.targetAmount, mainCurrency))} (${ltr(persianDigits('${(ratio * 100).round()}%'))})',
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

// ============================== CSV / bank statement import ==============================

List<List<String>> _parseCsv(String content, String delimiter) {
  final lines = content.split(RegExp(r'\r\n|\r|\n')).where((l) => l.trim().isNotEmpty).toList();
  return lines.map((line) => _parseCsvLine(line, delimiter)).toList();
}

List<String> _parseCsvLine(String line, String delimiter) {
  final result = <String>[];
  final buffer = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (ch == '"') {
      if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
        buffer.write('"');
        i++;
      } else {
        inQuotes = !inQuotes;
      }
    } else if (ch == delimiter && !inQuotes) {
      result.add(buffer.toString().trim());
      buffer.clear();
    } else {
      buffer.write(ch);
    }
  }
  result.add(buffer.toString().trim());
  return result;
}

String _detectDelimiter(String firstLine) {
  final commaCount = ','.allMatches(firstLine).length;
  final semiCount = ';'.allMatches(firstLine).length;
  final tabCount = '\t'.allMatches(firstLine).length;
  if (tabCount > commaCount && tabCount > semiCount) return '\t';
  return semiCount > commaCount ? ';' : ',';
}

const _csvDateFormats = ['dd.MM.yyyy', 'yyyy-MM-dd', 'dd/MM/yyyy', 'MM/dd/yyyy', 'dd-MM-yyyy'];

/// One booking read from a bank statement (CSV or PDF). [amount] is
/// negative for money leaving the account.
typedef StatementRow = ({DateTime date, double amount, String desc, String? merchant, String? categoryHint});

/// Transactions imported from a bank statement get ids with one of these
/// prefixes, which is how the drafts screen keeps them in their own tab.
bool isBankImportId(String id) => id.startsWith('csv_') || id.startsWith('bank_');

/// Already saved transactions that look like the same booking as [t]: same
/// account, type and amount, dated within 3 days of it.
List<Transaction> possibleDuplicatesOf(Transaction t, List<Transaction> all) {
  return all
      .where((x) =>
          x.id != t.id &&
          x.accountId == t.accountId &&
          x.type == t.type &&
          (x.amount - t.amount).abs() < 0.01 &&
          x.date.difference(t.date).inDays.abs() <= 3)
      .toList()
    ..sort((a, b) => a.date.difference(t.date).inDays.abs().compareTo(b.date.difference(t.date).inDays.abs()));
}

/// Best guess of a category for a booking text: a known shop name first,
/// then any of the person's category names that appears in the text.
Category? guessCategoryForText(String text, TxType type, List<Category> categories) {
  final lower = text.toLowerCase();
  for (final e in _knownMerchants.entries) {
    if (lower.contains(e.key.toLowerCase())) {
      final c = categories.where((c) => c.id == e.value && c.type == type).firstOrNull;
      if (c != null) return c;
    }
  }
  final candidates = categories.where((c) => c.type == type && c.name.trim().length >= 3).toList()
    ..sort((a, b) => b.name.length.compareTo(a.name.length));
  for (final c in candidates) {
    if (lower.contains(c.name.toLowerCase())) return c;
  }
  return null;
}

/// Known shop name found in a booking text, used as the merchant.
String? merchantInText(String text) {
  final lower = text.toLowerCase();
  for (final k in _knownMerchants.keys) {
    if (lower.contains(k.toLowerCase())) return k;
  }
  return null;
}

String _bankStatementPrompt(List<Category> categories) =>
    'You are reading one page of a bank account statement (any country or language). Extract every booked '
    'transaction on this page. Respond ONLY with compact JSON, no markdown, in exactly this shape: '
    '{"currency": string or null, "transactions": [{"date": "YYYY-MM-DD", "amount": number, "description": '
    'string, "counterparty": string or null, "category": string or null}]}. "amount" is negative for money '
    'leaving the account (payments, card purchases, debits, Soll, برداشت) and positive for money coming in '
    '(salary, refunds, credits, Haben, واریز). Use the booking date; if dates are in the Persian (Jalali/Shamsi) '
    'calendar, convert them to Gregorian. Ignore opening/closing balances, page totals and summaries. '
    '"description" is the booking text as printed, at most 120 characters. "counterparty" is the merchant, payee '
    'or payer name if shown. "currency" is the ISO 4217 code of the amounts ("IRR" for ریال, "IRT" for تومان). '
    '"category" is the best fitting one of these categories of the person, copied exactly, or null if none fits: '
    '${categories.where((c) => !c.id.startsWith('_')).map((c) => c.name).toSet().join(', ')}. '
    'Numbers must be plain (no currency symbols, no thousands separators). If the page has no transactions, '
    'return an empty list.';

List<StatementRow> _statementRowsFromJson(Map<String, dynamic> json) {
  final list = json['transactions'];
  if (list is! List) return [];
  final result = <StatementRow>[];
  for (final e in list.whereType<Map>()) {
    final date = DateTime.tryParse((e['date'] ?? '').toString());
    final amount = (e['amount'] is num) ? (e['amount'] as num).toDouble() : double.tryParse('${e['amount']}');
    if (date == null || amount == null || amount == 0) continue;
    final counterparty = e['counterparty']?.toString().trim();
    result.add((
      date: DateTime(date.year, date.month, date.day),
      amount: amount,
      desc: (e['description'] ?? '').toString().trim(),
      merchant: (counterparty == null || counterparty.isEmpty || counterparty == 'null') ? null : counterparty,
      categoryHint: e['category']?.toString(),
    ));
  }
  return result;
}

/// Offline fallback for a statement page read by on-device OCR: every line
/// with a date and an amount becomes a booking. Amounts marked with a minus
/// sign (before or after), "S"/"Soll" or "-" are outgoing; "+"/"H" incoming;
/// unmarked amounts are treated as outgoing.
List<StatementRow> parseStatementText(String text) {
  final dateRe = RegExp(r'(\d{1,2})[./](\d{1,2})[./](\d{2,4})|(\d{4})-(\d{1,2})-(\d{1,2})');
  final amountRe = RegExp(r'([+-]?)\s?(\d{1,3}(?:[.,\s]\d{3})*[.,]\d{2})\s?([+-]|S\b|H\b)?');
  final result = <StatementRow>[];
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    final dm = dateRe.firstMatch(line);
    if (dm == null) continue;
    final rest = line.substring(dm.end);
    final amounts = amountRe.allMatches(rest).toList();
    if (amounts.isEmpty) continue;
    final am = amounts.first;
    final value = _parseAmountToken(am.group(2)!.replaceAll(' ', ''));
    if (value == null || value == 0) continue;
    int y, m, d;
    if (dm.group(4) != null) {
      y = int.parse(dm.group(4)!);
      m = int.parse(dm.group(5)!);
      d = int.parse(dm.group(6)!);
    } else {
      d = int.parse(dm.group(1)!);
      m = int.parse(dm.group(2)!);
      y = int.parse(dm.group(3)!);
      if (y < 100) y += 2000;
    }
    if (m < 1 || m > 12 || d < 1 || d > 31) continue;
    final incoming = am.group(1) == '+' || am.group(3) == '+' || am.group(3) == 'H';
    final desc = rest.replaceRange(am.start, am.end, ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    result.add((
      date: DateTime(y, m, d),
      amount: incoming ? value : -value,
      desc: desc,
      merchant: merchantInText(desc),
      categoryHint: null,
    ));
  }
  return result;
}

/// Renders each page of a PDF (up to [maxPages]) to its own temporary JPEG,
/// for reading bank statements page by page.
Future<List<String>> renderPdfPagesToImages(String path, {int maxPages = 24}) async {
  final doc = await PdfDocument.openFile(path);
  try {
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final out = <String>[];
    final count = min(doc.pagesCount, maxPages);
    for (var i = 1; i <= count; i++) {
      final page = await doc.getPage(i);
      const maxDim = 1800.0;
      var scale = 2.0;
      final longest = page.width > page.height ? page.width : page.height;
      if (longest * scale > maxDim) scale = maxDim / longest;
      final rendered = await page.render(width: page.width * scale, height: page.height * scale, format: PdfPageImageFormat.jpeg);
      await page.close();
      final outPath = '${dir.path}/statement_${stamp}_$i.jpg';
      await File(outPath).writeAsBytes(rendered!.bytes);
      out.add(outPath);
    }
    return out;
  } finally {
    await doc.close();
  }
}

class CsvImportScreen extends StatefulWidget {
  const CsvImportScreen({super.key});
  @override
  State<CsvImportScreen> createState() => _CsvImportScreenState();
}

class _CsvImportScreenState extends State<CsvImportScreen> {
  bool loading = true;
  List<Account> accounts = [];
  List<Category> categories = [];
  List<Transaction> existingTx = [];

  List<List<String>>? rows; // includes header row at index 0
  String delimiter = ',';
  int? dateCol, amountCol, debitCol, creditCol, descCol;
  bool useSeparateDebitCredit = false;
  String dateFormat = 'dd.MM.yyyy';
  Account? targetAccount;
  Category? defaultExpenseCategory;
  Category? defaultIncomeCategory;

  List<StatementRow>? preview;
  bool importing = false;
  bool readingPdf = false;
  String pdfProgress = '';
  String? detectedCurrency;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    accounts = await Store.loadAccounts();
    categories = await Store.loadCategories();
    existingTx = await Store.loadTransactions();
    if (accounts.isNotEmpty) targetAccount = accounts.first;
    setState(() => loading = false);
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['csv', 'pdf']);
    if (result == null || result.files.single.path == null) return;
    if (result.files.single.path!.toLowerCase().endsWith('.pdf')) {
      await _readPdf(result.files.single.path!);
      return;
    }
    final content = await File(result.files.single.path!).readAsString();
    final detectedDelimiter = _detectDelimiter(content.split('\n').first);
    final parsed = _parseCsv(content, detectedDelimiter);
    if (parsed.isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('فایل خالی یا نامعتبر است.')));
      return;
    }
    setState(() {
      rows = parsed;
      delimiter = detectedDelimiter;
      preview = null;
      dateCol = null;
      amountCol = null;
      debitCol = null;
      creditCol = null;
      descCol = null;
    });
  }

  /// Reads a PDF statement page by page - with the AI when a Gemini key is
  /// set (it also suggests a category and the shop/payee), otherwise with
  /// on-device text recognition and a simpler line-by-line reading.
  Future<void> _readPdf(String path) async {
    setState(() {
      readingPdf = true;
      pdfProgress = 'در حال آماده‌سازی صفحات...';
      rows = null;
      preview = null;
      detectedCurrency = null;
    });
    try {
      final pages = await renderPdfPagesToImages(path);
      final key = (await Store.loadGeminiKey())?.trim();
      final result = <StatementRow>[];
      String? currency;
      Object? aiError;
      for (var i = 0; i < pages.length; i++) {
        if (!mounted) return;
        setState(() => pdfProgress = 'در حال خواندن صفحه‌ی ${persianDigits('${i + 1}')} از ${persianDigits('${pages.length}')}...');
        List<StatementRow>? pageRows;
        if (key != null && key.isNotEmpty && aiError == null) {
          try {
            final json = await _geminiRequest(key, pages[i], _bankStatementPrompt(categories));
            if (json != null) {
              currency ??= normalizeCurrency(json['currency']);
              pageRows = _statementRowsFromJson(json);
            }
          } catch (e) {
            aiError = e;
          }
        }
        pageRows ??= parseStatementText(await extractTextFromImage(pages[i]));
        result.addAll(pageRows);
      }
      if (!mounted) return;
      result.sort((a, b) => a.date.compareTo(b.date));
      setState(() {
        readingPdf = false;
        preview = result;
        detectedCurrency = currency;
      });
      if (aiError != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${aiError is GeminiException ? aiError.friendlyMessage : 'خواندن هوشمند ممکن نشد.'} '
              'بقیه‌ی صفحات با خواندن خودکار ساده خوانده شد؛ نتیجه را با دقت بررسی کنید.'),
          duration: const Duration(seconds: 6),
        ));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => readingPdf = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('خواندن فایل PDF ممکن نشد.')));
    }
  }

  void _buildPreview() {
    if (rows == null || dateCol == null || descCol == null) return;
    if (!useSeparateDebitCredit && amountCol == null) return;
    if (useSeparateDebitCredit && (debitCol == null || creditCol == null)) return;
    final format = DateFormat(dateFormat);
    final result = <StatementRow>[];
    for (var i = 1; i < rows!.length; i++) {
      final row = rows![i];
      if (row.length <= dateCol!) continue;
      DateTime? date;
      try {
        date = format.parseStrict(row[dateCol!].trim());
      } catch (_) {
        continue;
      }
      double? amount;
      if (useSeparateDebitCredit) {
        final debitStr = debitCol! < row.length ? row[debitCol!].trim() : '';
        final creditStr = creditCol! < row.length ? row[creditCol!].trim() : '';
        final debit = double.tryParse(debitStr.replaceAll('.', '').replaceAll(',', '.').replaceAll(RegExp(r'[^0-9.\-]'), ''));
        final credit = double.tryParse(creditStr.replaceAll('.', '').replaceAll(',', '.').replaceAll(RegExp(r'[^0-9.\-]'), ''));
        if (credit != null && credit != 0) {
          amount = credit.abs();
        } else if (debit != null && debit != 0) {
          amount = -debit.abs();
        }
      } else {
        final raw = amountCol! < row.length ? row[amountCol!].trim() : '';
        // Handle European-style "1.234,56" as well as plain "1234.56"
        var cleaned = raw.replaceAll(RegExp(r'[^\d,.\-]'), '');
        if (cleaned.contains(',') && cleaned.contains('.')) {
          cleaned = cleaned.replaceAll('.', '').replaceAll(',', '.');
        } else if (cleaned.contains(',')) {
          cleaned = cleaned.replaceAll(',', '.');
        }
        amount = double.tryParse(cleaned);
      }
      if (amount == null || amount == 0) continue;
      final desc = descCol! < row.length ? row[descCol!].trim() : '';
      result.add((date: date, amount: amount, desc: desc, merchant: merchantInText(desc), categoryHint: null));
    }
    setState(() => preview = result);
  }

  /// The very same booking was already imported earlier (same statement
  /// read twice) - skipped instead of piling up copies.
  bool _alreadyImported(StatementRow p, String accountId) {
    return existingTx.any((t) =>
        isBankImportId(t.id) &&
        t.accountId == accountId &&
        t.date.year == p.date.year &&
        t.date.month == p.date.month &&
        t.date.day == p.date.day &&
        (t.amount - p.amount.abs()).abs() < 0.01 &&
        (p.desc.isEmpty || t.note.contains(p.desc)));
  }

  Transaction _toDraft(StatementRow p, int index) {
    final type = p.amount >= 0 ? TxType.income : TxType.expense;
    final cat = _matchCategoryHint(p.categoryHint, categories, type) ??
        guessCategoryForText('${p.merchant ?? ''} ${p.desc}', type, categories) ??
        (type == TxType.income ? defaultIncomeCategory : defaultExpenseCategory);
    return Transaction(
      id: 'bank_${DateTime.now().microsecondsSinceEpoch}_$index',
      type: type,
      amount: p.amount.abs(),
      categoryId: cat?.id ?? (type == TxType.income ? 'i_misc' : 'e_misc'),
      accountId: targetAccount!.id,
      date: p.date,
      merchant: type == TxType.expense ? (p.merchant ?? '') : '',
      note: 'از صورتحساب بانکی خوانده شده است.${p.desc.isNotEmpty ? ' ${p.desc}' : ''}',
      // Bank-statement rows aren't registered directly - they land in their
      // own drafts tab so each one can be reviewed (and compared with a
      // possible duplicate) before it counts toward any totals.
      draft: true,
    );
  }

  int _possibleDuplicateCount() {
    if (preview == null || targetAccount == null) return 0;
    final confirmed = existingTx.where((t) => !isBankImportId(t.id) || !t.draft).toList();
    var n = 0;
    for (var i = 0; i < preview!.length; i++) {
      if (possibleDuplicatesOf(_toDraft(preview![i], i), confirmed).isNotEmpty) n++;
    }
    return n;
  }

  Future<void> _import() async {
    if (preview == null || targetAccount == null) return;
    setState(() => importing = true);
    var imported = 0, skipped = 0, possibleDup = 0;
    final drafts = <Transaction>[];
    for (var i = 0; i < preview!.length; i++) {
      final p = preview![i];
      if (_alreadyImported(p, targetAccount!.id)) {
        skipped++;
        continue;
      }
      final d = _toDraft(p, i);
      if (possibleDuplicatesOf(d, existingTx).isNotEmpty) possibleDup++;
      drafts.add(d);
    }
    for (final d in drafts) {
      await Store.upsertTransaction(d);
      imported++;
    }
    if (!mounted) return;
    setState(() => importing = false);
    final open = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('نتیجه‌ی بارگذاری'),
        content: Text(
          '${persianDigits('$imported')} تراکنش به‌صورت پیش‌نویس در بخش «صورتحساب بانک» پیش‌نویس‌ها ذخیره شد.'
          '${possibleDup > 0 ? '\n${persianDigits('$possibleDup')} مورد احتمالاً تکراری است؛ آن‌جا می‌توانی با تراکنش ثبت‌شده مقایسه‌اش کنی.' : ''}'
          '${skipped > 0 ? '\n${persianDigits('$skipped')} مورد قبلاً از صورتحساب بارگذاری شده بود و دوباره اضافه نشد.' : ''}',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('confirm'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('مشاهده‌ی پیش‌نویس‌ها')),
        ],
      ),
    );
    if (!mounted) return;
    if (open == true) {
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const DraftsScreen(initialTab: 1)));
    } else {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final header = rows?.first ?? [];
    return Scaffold(
      appBar: AppBar(title: Text(tr('csv_import_title'))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (readingPdf)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 48),
              child: Column(
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(pdfProgress, textAlign: TextAlign.center),
                ],
              ),
            )
          else if (rows == null && preview == null)
            Column(
              children: [
                const Text(
                  'فایل صورتحساب بانک را انتخاب کن: CSV (اکثر بانک‌ها امکان دانلودش را دارند) یا PDF. '
                  'PDF با هوش مصنوعی خوانده می‌شود (اگر کلید Gemini وارد شده باشد) و دسته‌بندی و طرف حساب هم حدس زده می‌شود.',
                  style: TextStyle(fontSize: 13),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(onPressed: _pickFile, icon: const Icon(Icons.upload_file), label: const Text('انتخاب فایل CSV یا PDF')),
              ],
            )
          else ...[
            if (rows != null) ...[
            Text('${rows!.length - 1} ردیف پیدا شد. ستون‌های مربوطه رو مشخص کن:', style: const TextStyle(fontSize: 13)),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: dateCol,
              decoration: const InputDecoration(labelText: 'ستون تاریخ', border: OutlineInputBorder(), isDense: true),
              items: header.asMap().entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
              onChanged: (v) => setState(() {
                dateCol = v;
                preview = null;
              }),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: dateFormat,
              decoration: const InputDecoration(labelText: 'فرمت تاریخ', border: OutlineInputBorder(), isDense: true),
              items: _csvDateFormats.map((f) => DropdownMenuItem(value: f, child: Text(f))).toList(),
              onChanged: (v) => setState(() {
                dateFormat = v ?? dateFormat;
                preview = null;
              }),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<int>(
              initialValue: descCol,
              decoration: const InputDecoration(labelText: 'ستون توضیحات', border: OutlineInputBorder(), isDense: true),
              items: header.asMap().entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
              onChanged: (v) => setState(() {
                descCol = v;
                preview = null;
              }),
            ),
            const SizedBox(height: 10),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('بدهکار/بستانکار در دو ستون جدا هستند', style: TextStyle(fontSize: 13)),
              value: useSeparateDebitCredit,
              onChanged: (v) => setState(() {
                useSeparateDebitCredit = v;
                preview = null;
              }),
            ),
            if (!useSeparateDebitCredit)
              DropdownButtonFormField<int>(
                initialValue: amountCol,
                decoration: const InputDecoration(labelText: 'ستون مبلغ (منفی=هزینه، مثبت=درآمد)', border: OutlineInputBorder(), isDense: true),
                items: header.asMap().entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
                onChanged: (v) => setState(() {
                  amountCol = v;
                  preview = null;
                }),
              )
            else ...[
              DropdownButtonFormField<int>(
                initialValue: debitCol,
                decoration: const InputDecoration(labelText: 'ستون بدهکار (خروج پول)', border: OutlineInputBorder(), isDense: true),
                items: header.asMap().entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
                onChanged: (v) => setState(() {
                  debitCol = v;
                  preview = null;
                }),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<int>(
                initialValue: creditCol,
                decoration: const InputDecoration(labelText: 'ستون بستانکار (ورود پول)', border: OutlineInputBorder(), isDense: true),
                items: header.asMap().entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
                onChanged: (v) => setState(() {
                  creditCol = v;
                  preview = null;
                }),
              ),
            ],
            const SizedBox(height: 16),
            OutlinedButton(onPressed: _buildPreview, child: const Text('پیش‌نمایش')),
            ],
            if (preview != null) ...[
              const SizedBox(height: 16),
              Text('${persianDigits('${preview!.length}')} تراکنش قابل‌بارگذاری پیدا شد.', style: const TextStyle(fontWeight: FontWeight.bold)),
              if (_possibleDuplicateCount() > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    '${persianDigits('${_possibleDuplicateCount()}')} مورد احتمالاً قبلاً ثبت شده؛ بعد از ذخیره می‌توانی مقایسه‌شان کنی.',
                    style: TextStyle(fontSize: 12, color: Colors.orange.shade800),
                  ),
                ),
              if (detectedCurrency != null && targetAccount != null && detectedCurrency != targetAccount!.currency)
                currencyMismatchWarning(detectedCurrency!, targetAccount!.currency),
              const SizedBox(height: 12),
              DropdownButtonFormField<Account>(
                initialValue: targetAccount,
                decoration: const InputDecoration(labelText: 'حساب مقصد', border: OutlineInputBorder(), isDense: true),
                items: accounts.map((a) => DropdownMenuItem(value: a, child: Text('${a.name} (${currencyLabel(a.currency)})'))).toList(),
                onChanged: (v) => setState(() => targetAccount = v),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<Category>(
                initialValue: defaultExpenseCategory,
                decoration: const InputDecoration(labelText: 'دسته‌بندی پیش‌فرض هزینه‌ها', border: OutlineInputBorder(), isDense: true),
                items: categoriesInHierarchicalOrder(categories, TxType.expense)
                    .map((c) => DropdownMenuItem(value: c, child: Text(c.parentId == null ? c.name : '　　${c.name}')))
                    .toList(),
                onChanged: (v) => setState(() => defaultExpenseCategory = v),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<Category>(
                initialValue: defaultIncomeCategory,
                decoration: const InputDecoration(labelText: 'دسته‌بندی پیش‌فرض درآمدها', border: OutlineInputBorder(), isDense: true),
                items: categoriesInHierarchicalOrder(categories, TxType.income)
                    .map((c) => DropdownMenuItem(value: c, child: Text(c.parentId == null ? c.name : '　　${c.name}')))
                    .toList(),
                onChanged: (v) => setState(() => defaultIncomeCategory = v),
              ),
              const SizedBox(height: 8),
              const Text(
                'هر تراکنش در صورت امکان دسته‌بندی حدس‌زده‌ی خودش را می‌گیرد؛ این‌ها فقط برای بقیه است. بعداً هم می‌توانی هرکدام را اصلاح کنی.',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              ...preview!.take(5).map((p) => Card(
                    child: ListTile(
                      dense: true,
                      title: Text(
                        p.merchant ?? (p.desc.isEmpty ? '(بدون توضیح)' : p.desc),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text('${formatDate(p.date)}${p.categoryHint != null ? ' • ${p.categoryHint}' : ''}'),
                      trailing: Text(
                        ltr(persianDigits(p.amount.toStringAsFixed(2))),
                        style: TextStyle(color: p.amount >= 0 ? Colors.green : Colors.red, fontWeight: FontWeight.w600),
                      ),
                    ),
                  )),
              if (preview!.length > 5)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('و ${preview!.length - 5} مورد دیگر...', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: (targetAccount == null || importing) ? null : _import,
                icon: importing
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.download_done),
                label: Text(importing ? 'در حال ذخیره...' : 'ذخیره ${preview!.length} تراکنش به‌صورت پیش‌نویس'),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

// ============================== Shopping lists ==============================

class ShoppingListsScreen extends StatefulWidget {
  const ShoppingListsScreen({super.key});
  @override
  State<ShoppingListsScreen> createState() => _ShoppingListsScreenState();
}

class _ShoppingListsScreenState extends State<ShoppingListsScreen> {
  bool loading = true;
  List<ShoppingList> lists = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    lists = await Store.loadShoppingLists();
    setState(() => loading = false);
  }

  Future<void> _addList() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('لیست خرید جدید'),
        content: TextField(controller: ctrl, decoration: const InputDecoration(labelText: 'نام لیست (مثلاً خرید هفتگی)'), autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: Text(tr('save'))),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final list = ShoppingList(id: 'sl_${DateTime.now().microsecondsSinceEpoch}', name: name);
    lists = [...lists, list];
    await Store.saveShoppingLists(lists);
    setState(() {});
  }

  Future<void> _renameList(ShoppingList l) async {
    final ctrl = TextEditingController(text: l.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ویرایش نام لیست'),
        content: TextField(controller: ctrl, decoration: const InputDecoration(labelText: 'نام لیست'), autofocus: true),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: Text(tr('save'))),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == l.name) return;
    lists = lists.map((x) => x.id == l.id ? x.copyWith(name: name) : x).toList();
    await Store.saveShoppingLists(lists);
    setState(() {});
  }

  Future<void> _deleteList(ShoppingList l) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف لیست'),
        content: Text('لیست «${l.name}» حذف شود؟'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('delete'))),
        ],
      ),
    );
    if (confirm != true) return;
    lists = lists.where((x) => x.id != l.id).toList();
    await Store.saveShoppingLists(lists);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(title: Text(tr('shopping_lists_title'))),
      floatingActionButton: FloatingActionButton.extended(onPressed: _addList, icon: const Icon(Icons.add), label: const Text('لیست جدید')),
      body: lists.isEmpty
          ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('هنوز لیست خریدی نساختی.')))
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 88),
              itemCount: lists.length,
              itemBuilder: (context, i) {
                final l = lists[i];
                final done = l.items.where((it) => it.checked).length;
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.shopping_cart_outlined),
                    title: Text(l.name),
                    subtitle: Text('$done/${l.items.length} خریداری‌شده'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(icon: const Icon(Icons.edit_outlined, size: 20), onPressed: () => _renameList(l)),
                        IconButton(icon: const Icon(Icons.delete_outline, size: 20), onPressed: () => _deleteList(l)),
                      ],
                    ),
                    onTap: () async {
                      await Navigator.push(context, MaterialPageRoute(builder: (_) => ShoppingListDetailScreen(listId: l.id)));
                      await _load();
                    },
                  ),
                );
              },
            ),
    );
  }
}

class ShoppingListDetailScreen extends StatefulWidget {
  final String listId;
  const ShoppingListDetailScreen({required this.listId, super.key});
  @override
  State<ShoppingListDetailScreen> createState() => _ShoppingListDetailScreenState();
}

class _ShoppingListDetailScreenState extends State<ShoppingListDetailScreen> {
  bool loading = true;
  List<ShoppingList> allLists = [];
  List<Category> categories = [];
  List<Account> accounts = [];
  ShoppingList get list => allLists.firstWhere((l) => l.id == widget.listId);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    allLists = await Store.loadShoppingLists();
    categories = await Store.loadCategories();
    accounts = await Store.loadAccounts();
    setState(() => loading = false);
  }

  Future<void> _persist() async {
    await Store.saveShoppingLists(allLists);
    setState(() {});
  }

  void _updateList(ShoppingList updated) {
    allLists = allLists.map((l) => l.id == updated.id ? updated : l).toList();
  }

  Future<void> _addOrEditItem({ShoppingListItem? existing}) async {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final qtyCtrl = TextEditingController(text: persianDigits(existing?.quantity?.toString() ?? ''));
    final priceCtrl = TextEditingController(text: existing?.estimatedPrice == null ? '' : formatAmountInput(existing!.estimatedPrice!));
    final added = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? 'افزودن کالا' : 'ویرایش کالا'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, decoration: InputDecoration(labelText: tr('item_name')), autofocus: true),
            const SizedBox(height: 8),
            TextField(controller: qtyCtrl, keyboardType: TextInputType.number, inputFormatters: const [DigitsInputFormatter()], decoration: InputDecoration(labelText: '${tr('quantity')} (اختیاری)')),
            const SizedBox(height: 8),
            TextField(
              controller: priceCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true), inputFormatters: const [AmountInputFormatter()],
              decoration: const InputDecoration(labelText: 'قیمت تقریبی (اختیاری)'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(existing == null ? tr('add') : tr('save'))),
        ],
      ),
    );
    if (added != true || nameCtrl.text.trim().isEmpty) return;
    final item = ShoppingListItem(
      id: existing?.id ?? 'sli_${DateTime.now().microsecondsSinceEpoch}',
      name: nameCtrl.text.trim(),
      quantity: parseAmount(qtyCtrl.text),
      estimatedPrice: parseAmount(priceCtrl.text),
      checked: existing?.checked ?? false,
    );
    final items = [...list.items.where((i) => i.id != item.id), item];
    _updateList(list.copyWith(items: items));
    await _persist();
  }

  Future<void> _toggleItem(ShoppingListItem item) async {
    final items = list.items.map((i) => i.id == item.id ? i.copyWith(checked: !i.checked) : i).toList();
    _updateList(list.copyWith(items: items));
    await _persist();
  }

  Future<void> _deleteItem(ShoppingListItem item) async {
    final items = list.items.where((i) => i.id != item.id).toList();
    _updateList(list.copyWith(items: items));
    await _persist();
  }

  Future<void> _convertCheckedToTransaction() async {
    final checked = list.items.where((i) => i.checked).toList();
    if (checked.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('اول کالاهایی که خریدی رو تیک بزن.')));
      return;
    }
    final receiptItems = checked.map((i) => ReceiptItemEntry(name: i.name, quantity: i.quantity, price: i.estimatedPrice)).toList();
    final total = checked.fold(0.0, (s, i) => s + (i.estimatedPrice ?? 0));
    final draftTx = Transaction(
      id: 'shoplist_${DateTime.now().microsecondsSinceEpoch}',
      type: TxType.expense,
      amount: total > 0 ? total : 0.01,
      categoryId: '_uncategorized_',
      accountId: accounts.isNotEmpty ? accounts.first.id : 'default',
      date: DateTime.now(),
      note: 'از لیست خرید «${list.name}»',
      items: receiptItems,
      draft: true,
    );
    final result = await Navigator.push<Object>(
      context,
      MaterialPageRoute(builder: (_) => TransactionEditor(categories: categories, accounts: accounts, existing: draftTx)),
    );
    if (result is Transaction) {
      await Store.upsertTransaction(result);
      // Remove the checked items from the list now that they're logged.
      final remaining = list.items.where((i) => !i.checked).toList();
      _updateList(list.copyWith(items: remaining));
      await _persist();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تراکنش ثبت شد.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final currentList = list;
    final estimatedTotal = currentList.items.fold(0.0, (s, i) => s + (i.estimatedPrice ?? 0));
    final checkedCount = currentList.items.where((i) => i.checked).length;
    return Scaffold(
      appBar: AppBar(
        title: Text(currentList.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: 'ویرایش نام لیست',
            onPressed: () async {
              final ctrl = TextEditingController(text: currentList.name);
              final name = await showDialog<String>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('ویرایش نام لیست'),
                  content: TextField(controller: ctrl, decoration: const InputDecoration(labelText: 'نام لیست'), autofocus: true),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('cancel'))),
                    FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: Text(tr('save'))),
                  ],
                ),
              );
              if (name == null || name.isEmpty || name == currentList.name) return;
              _updateList(currentList.copyWith(name: name));
              await _persist();
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(onPressed: () => _addOrEditItem(), child: const Icon(Icons.add)),
      body: Column(
        children: [
          if (currentList.items.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('$checkedCount از ${currentList.items.length} خریداری‌شده'),
                          if (estimatedTotal > 0) Text('جمع تقریبی: ${formatAmountInput(estimatedTotal)}'),
                        ],
                      ),
                      if (checkedCount > 0) ...[
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          onPressed: _convertCheckedToTransaction,
                          icon: const Icon(Icons.receipt_long_outlined, size: 18),
                          label: const Text('ثبت خریداری‌شده‌ها به‌عنوان تراکنش'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          Expanded(
            child: currentList.items.isEmpty
                ? const Center(child: Text('این لیست خالیه. با دکمه‌ی + کالا اضافه کن.'))
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 88),
                    itemCount: currentList.items.length,
                    itemBuilder: (context, i) {
                      final item = currentList.items[i];
                      return Card(
                        child: ListTile(
                          leading: Checkbox(value: item.checked, onChanged: (_) => _toggleItem(item)),
                          title: Text(
                            item.name,
                            style: item.checked ? const TextStyle(decoration: TextDecoration.lineThrough, color: Colors.grey) : null,
                          ),
                          subtitle: (item.quantity != null || item.estimatedPrice != null)
                              ? Text(
                                  '${item.quantity != null ? 'تعداد: ${item.quantity!.toStringAsFixed(item.quantity! % 1 == 0 ? 0 : 2)}' : ''}'
                                  '${item.quantity != null && item.estimatedPrice != null ? ' • ' : ''}'
                                  '${item.estimatedPrice != null ? '~${formatAmountInput(item.estimatedPrice!)}' : ''}',
                                )
                              : null,
                          trailing: IconButton(icon: const Icon(Icons.delete_outline, size: 20), onPressed: () => _deleteItem(item)),
                          onTap: () => _addOrEditItem(existing: item),
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
  DateTime date = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
  bool saving = false;
  RecurrenceFrequency recurrence = RecurrenceFrequency.none;
  final dayCtrl = TextEditingController();
  int weekday = 1;
  final intervalCtrl = TextEditingController(text: persianDigits('30'));
  final installmentsCtrl = TextEditingController();
  DateTime? endDate;
  String endMode = 'unlimited'; // 'unlimited' | 'installments' | 'date'
  final exchangeRateCtrl = TextEditingController();

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
    final picked = await showAppDatePicker(
      context: context,
      initialDate: date,
      firstDate: DateTime(2015),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      builder: (ctx, child) => Directionality(textDirection: TextDirection.ltr, child: child!),
    );
    if (picked != null) setState(() => date = picked);
  }

  Future<void> _save() async {
    final amount = parseAmount(amountCtrl.text);
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
    var convertedAmount = amount;
    if (fromAccount!.currency != toAccount!.currency) {
      final rate = parseAmount(exchangeRateCtrl.text);
      if (rate == null || rate <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('برای انتقال بین ${currencyLabel(fromAccount!.currency)} و ${currencyLabel(toAccount!.currency)}، نرخ تبدیل را وارد کنید.'),
        ));
        return;
      }
      convertedAmount = amount * rate;
    }
    int? recDay;
    int? recWeekday;
    int? recInterval;
    int? recInstallments;
    DateTime? recEndDate;
    if (recurrence == RecurrenceFrequency.monthly || recurrence == RecurrenceFrequency.quarterly) {
      recDay = parseInt(dayCtrl.text);
      if (recDay == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('روز سررسید در ماه را وارد کنید.')));
        return;
      }
      if (recDay < 1) recDay = 1;
      if (recDay > 31) recDay = 31;
    } else if (recurrence == RecurrenceFrequency.weekly) {
      recWeekday = weekday;
    } else if (recurrence == RecurrenceFrequency.custom) {
      recInterval = parseInt(intervalCtrl.text);
      if (recInterval == null || recInterval <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعداد روز بازه را درست وارد کنید.')));
        return;
      }
    }
    if (recurrence != RecurrenceFrequency.none) {
      if (endMode == 'installments') {
        recInstallments = parseInt(installmentsCtrl.text);
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
      amount: convertedAmount,
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
            items: accounts.map((a) => DropdownMenuItem(value: a, child: Text('${a.name} (${currencyLabel(a.currency)})'))).toList(),
            onChanged: (v) => setState(() => fromAccount = v),
          ),
          const SizedBox(height: 12),
          Center(child: Icon(Icons.arrow_downward, color: Colors.grey.shade500)),
          const SizedBox(height: 12),
          DropdownButtonFormField<Account>(
            initialValue: toAccount,
            decoration: InputDecoration(labelText: tr('to_account'), border: const OutlineInputBorder()),
            items: accounts.map((a) => DropdownMenuItem(value: a, child: Text('${a.name} (${currencyLabel(a.currency)})'))).toList(),
            onChanged: (v) => setState(() => toAccount = v),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: amountCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true), inputFormatters: const [AmountInputFormatter()],
            decoration: InputDecoration(labelText: tr('amount'), hintText: 'مثلاً 100.00', border: const OutlineInputBorder()),
            onChanged: (_) => setState(() {}),
          ),
          if (fromAccount != null && toAccount != null && fromAccount!.currency != toAccount!.currency) ...[
            const SizedBox(height: 16),
            TextField(
              controller: exchangeRateCtrl,
              keyboardType: const TextInputType.numberWithOptions(decimal: true), inputFormatters: const [AmountInputFormatter()],
              decoration: InputDecoration(
                labelText: '۱ ${currencyLabel(fromAccount!.currency)} = ? ${currencyLabel(toAccount!.currency)}',
                hintText: 'نرخ تبدیل',
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            Builder(builder: (context) {
              final amt = parseAmount(amountCtrl.text);
              final rate = parseAmount(exchangeRateCtrl.text);
              if (amt == null || rate == null || rate <= 0) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'معادل: ${ltr(formatMoney(amt * rate, toAccount!.currency))}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              );
            }),
          ],
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
              keyboardType: TextInputType.number, inputFormatters: const [DigitsInputFormatter()],
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
              keyboardType: TextInputType.number, inputFormatters: const [DigitsInputFormatter()],
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
                keyboardType: TextInputType.number, inputFormatters: const [DigitsInputFormatter()],
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
                  final picked = await showAppDatePicker(
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
  String draftFilter = 'exclude'; // 'exclude' (default) | 'only' | 'all'
  bool? returnableFilter; // null = all, true = has an item with a return deadline, false = no such item
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
    return m.isEmpty ? 'IRT' : m.first.currency;
  }

  Future<void> _openEditor(Transaction t) async {
    final result = await Navigator.push<Object>(
      context,
      MaterialPageRoute(builder: (_) => TransactionDetailScreen(t: t, categories: categories, accounts: accounts)),
    );
    if (result == null) return;
    if (result is DeleteTransactionSignal) {
      final removed = await Store.deleteTransaction(result.id);
      await _load();
      if (removed.isNotEmpty && mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(removed.length > 1 ? 'تراکنش\u200cها حذف شدند' : 'تراکنش حذف شد'),
            persist: false,
            action: SnackBarAction(
              label: 'برگردون',
              onPressed: () async {
                for (final t in removed) {
                  await Store.upsertTransaction(t);
                }
                await _load();
              },
            ),
            duration: const Duration(seconds: 5),
          ),
        );
      }
      return;
    } else if (result is Transaction) {
      await Store.upsertTransaction(result);
    }
    await _load();
  }

  String _sortLabel(_TxSortMode m) => switch (m) {
        _TxSortMode.dateDesc => 'تاریخ تراکنش (جدیدترین)',
        _TxSortMode.dateAsc => 'تاریخ تراکنش (قدیمی‌ترین)',
        _TxSortMode.createdDesc => 'زمان ثبت (جدیدترین)',
        _TxSortMode.createdAsc => 'زمان ثبت (قدیمی‌ترین)',
        _TxSortMode.amountDesc => 'مبلغ (بیشترین)',
        _TxSortMode.amountAsc => 'مبلغ (کمترین)',
      };

  int get _activeFilterCount =>
      (typeFilter != null ? 1 : 0) +
      (categoryFilter != null ? 1 : 0) +
      (accountFilter != null ? 1 : 0) +
      (recurringFilter != null ? 1 : 0) +
      (draftFilter != 'exclude' ? 1 : 0) +
      (returnableFilter != null ? 1 : 0);

  Future<void> _openFilterSheet() async {
    TxType? localType = typeFilter;
    String? localCategory = categoryFilter;
    String? localAccount = accountFilter;
    bool? localRecurring = recurringFilter;
    String localDraft = draftFilter;
    bool? localReturnable = returnableFilter;
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
                        localDraft = 'exclude';
                        localReturnable = null;
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
                Text('وضعیت تراکنش', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  initialValue: localDraft,
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12)),
                  items: const [
                    DropdownMenuItem(value: 'exclude', child: Text('تراکنش‌های تأیید شده')),
                    DropdownMenuItem(value: 'only', child: Text('تراکنش‌های پیش‌نویس')),
                    DropdownMenuItem(value: 'all', child: Text('همه‌ی تراکنش‌ها')),
                  ],
                  onChanged: (v) => setLocal(() => localDraft = v ?? localDraft),
                ),
                const SizedBox(height: 16),
                Text('مهلت مرجوعی کالا', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                const SizedBox(height: 6),
                DropdownButtonFormField<bool?>(
                  initialValue: localReturnable,
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12)),
                  items: const [
                    DropdownMenuItem(value: null, child: Text('همه')),
                    DropdownMenuItem(value: true, child: Text('دارای مهلت مرجوعی')),
                    DropdownMenuItem(value: false, child: Text('بدون مهلت مرجوعی')),
                  ],
                  onChanged: (v) => setLocal(() => localReturnable = v),
                ),
                const SizedBox(height: 16),
                Text('دسته‌بندی', style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                const SizedBox(height: 6),
                DropdownButtonFormField<String?>(
                  initialValue: localCategory,
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12)),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('همه‌ی دسته‌بندی‌ها')),
                    ...categoriesInHierarchicalOrder(categories, TxType.expense).map((c) => DropdownMenuItem(
                          value: c.id,
                          child: Text(c.parentId == null ? c.name : '　　${c.name}'),
                        )),
                    ...categoriesInHierarchicalOrder(categories, TxType.income).map((c) => DropdownMenuItem(
                          value: c.id,
                          child: Text(c.parentId == null ? c.name : '　　${c.name}'),
                        )),
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
                      draftFilter = localDraft;
                      returnableFilter = localReturnable;
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
      if (categoryFilter != null && !categoryMatchesFilter(t.categoryId, categoryFilter!, categories)) return false;
      if (accountFilter != null && t.accountId != accountFilter) return false;
      if (recurringFilter != null && t.isRecurring != recurringFilter) return false;
      if (draftFilter == 'exclude' && t.draft) return false;
      if (draftFilter == 'only' && !t.draft) return false;
      if (returnableFilter != null) {
        final hasReturnable = t.items.any((it) => it.returnUntil != null);
        if (hasReturnable != returnableFilter) return false;
      }
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
                  if (draftFilter != 'exclude')
                    _appliedFilterChip(
                      draftFilter == 'only' ? 'تراکنش‌های پیش‌نویس' : 'همه‌ی تراکنش‌ها',
                      () => setState(() => draftFilter = 'exclude'),
                    ),
                  if (returnableFilter != null)
                    _appliedFilterChip(
                      returnableFilter! ? 'دارای مهلت مرجوعی' : 'بدون مهلت مرجوعی',
                      () => setState(() => returnableFilter = null),
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
                                '${categoryName(t.categoryId)} • ${formatDate(t.date)}${txExtraDetail(t)}'
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
    return m.isEmpty ? 'IRT' : m.first.currency;
  }

  Future<void> _openEditor(Transaction t) async {
    final result = await Navigator.push<Object>(
      context,
      MaterialPageRoute(builder: (_) => TransactionDetailScreen(t: t, categories: categories, accounts: accounts)),
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
                                      label: Text('گارانتی تا ${formatDate(m.item.warrantyUntil!)}',
                                          style: const TextStyle(fontSize: 11)),
                                      visualDensity: VisualDensity.compact,
                                      backgroundColor: Colors.blue.shade50,
                                    ),
                                  if (m.item.returnUntil != null)
                                    Chip(
                                      label: Text('مرجوعی تا ${formatDate(m.item.returnUntil!)}',
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
  bool groupByMerchant = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    tx = await Store.loadConfirmedTransactions();
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
    final picked = await showAppDateRangePicker(
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
    if (categoryFilter != null && !categoryMatchesFilter(t.categoryId, categoryFilter!, categories)) return false;
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
    return m.isEmpty ? 'IRT' : m.first.currency;
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

  /// Expense total per shop name (transactions with no shop name filled in
  /// are grouped together under "بدون‌نام").
  Map<String, double> _expenseByMerchant(List<Transaction> list, String currency) {
    final map = <String, double>{};
    for (final t in list) {
      if (t.type != TxType.expense) continue;
      if (currencyOf(t.accountId) != currency) continue;
      final key = t.merchant.trim().isEmpty ? 'بدون‌نام' : t.merchant.trim();
      map[key] = (map[key] ?? 0) + t.amount;
    }
    return map;
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
      primaryCurrency = mainCurrencyOf(accounts);
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
    final byMerchant = _expenseByMerchant(currentTx, primaryCurrency).entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final maxMerchantAmount = byMerchant.isEmpty ? 0.0 : byMerchant.first.value;

    Widget comparisonRow(String label, double cur, double prev, {required bool higherIsBad}) {
      String changeText = '';
      Color changeColor = Colors.grey;
      if (prev > 0) {
        final change = (cur - prev) / prev * 100;
        final up = change >= 0;
        final bad = higherIsBad ? up : !up;
        changeColor = bad ? Colors.red.shade700 : Colors.green.shade700;
        changeText = '${ltr(persianDigits('${up ? '+' : ''}${change.round()}%'))} نسبت به دوره‌ی قبل';
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
                    ? '${formatDate(rangeStart)} - ${formatDate(rangeEnd)}'
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
          if ((byCategory.isNotEmpty || byMerchant.isNotEmpty) && typeFilter != TxType.income) ...[
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(groupByMerchant ? 'هزینه بر اساس فروشگاه' : 'هزینه بر اساس دسته‌بندی', style: Theme.of(context).textTheme.titleMedium),
                TextButton.icon(
                  onPressed: () => setState(() => groupByMerchant = !groupByMerchant),
                  icon: const Icon(Icons.swap_horiz, size: 16),
                  label: Text(groupByMerchant ? 'نمایش بر اساس دسته‌بندی' : 'نمایش بر اساس فروشگاه', style: const TextStyle(fontSize: 12)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (!groupByMerchant)
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
                  ))
            else if (byMerchant.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('هیچ فروشگاهی برای این تراکنش‌ها ثبت نشده.', style: TextStyle(color: Colors.grey, fontSize: 12)),
              )
            else
              ...byMerchant.map((e) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(e.key),
                            Text(ltr(formatMoney(e.value, primaryCurrency)), style: const TextStyle(fontWeight: FontWeight.w600)),
                          ],
                        ),
                        const SizedBox(height: 4),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: maxMerchantAmount > 0 ? e.value / maxMerchantAmount : 0,
                            minHeight: 6,
                            backgroundColor: Colors.grey.withValues(alpha: 0.2),
                            color: Colors.teal.shade300,
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
    tx = await Store.loadConfirmedTransactions();
    categories = await Store.loadCategories();
    accounts = await Store.loadAccounts();
    setState(() => loading = false);
  }

  String currencyOf(String accountId) {
    final m = accounts.where((a) => a.id == accountId).toList();
    return m.isEmpty ? 'IRT' : m.first.currency;
  }

  String get primaryCurrency => mainCurrencyOf(accounts);

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
    tx = await Store.loadConfirmedTransactions();
    accounts = await Store.loadAccounts();
    categories = await Store.loadCategories();
    setState(() => loading = false);
  }

  String currencyOf(String accountId) {
    final m = accounts.where((a) => a.id == accountId).toList();
    return m.isEmpty ? 'IRT' : m.first.currency;
  }

  String categoryName(String id) {
    final m = categories.where((c) => c.id == id).toList();
    return m.isEmpty ? 'بدون‌دسته' : m.first.name;
  }

  Future<void> _showDayTransactions(DateTime date) async {
    final dayEntries = occurrencesWithRecurringProjections(tx, horizonDays: 400, from: date)
        .where((e) =>
            e.date.year == date.year &&
            e.date.month == date.month &&
            e.date.day == date.day &&
            (accountFilter == null || e.t.accountId == accountFilter))
        .toList();
    if (dayEntries.isEmpty) return;
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
                  itemCount: dayEntries.length,
                  itemBuilder: (context, i) {
                    final e = dayEntries[i];
                    final t = e.t;
                    return Opacity(
                      opacity: e.isReal ? 1.0 : 0.6,
                      child: Card(
                        child: ListTile(
                          title: Text(categoryName(t.categoryId)),
                          subtitle: Text(
                            e.isReal
                                ? (t.note.isNotEmpty ? t.note : '')
                                : 'سررسیدنشده${t.isRecurring ? ' • تکرارشونده' : ''}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
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
                              MaterialPageRoute(builder: (_) => TransactionDetailScreen(t: t, categories: categories, accounts: accounts)),
                            );
                            await _load();
                          },
                        ),
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

  String get primaryCurrency => accountFilter != null ? currencyOf(accountFilter!) : mainCurrencyOf(accounts);

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
    // From the start of the shown month, so recurring payments that already
    // fell due this month are shown on their days too.
    for (final e in occurrencesWithRecurringProjections(tx, horizonDays: 400, from: DateTime(month.year, month.month, 1))) {
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

    // DateTime.weekday: Monday=1 .. Sunday=7. Weeks start on Saturday with
    // the Jalali calendar setting and on Monday with the Gregorian one.
    final saturdayFirst = currentCalendarSystem.value == CalendarSystem.jalali;
    final firstWeekday = DateTime(month.year, month.month, 1).weekday; // 1..7, Mon..Sun
    final leadingBlanks = saturdayFirst ? (firstWeekday + 1) % 7 : firstWeekday - 1;

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
                Text(
                  currentCalendarSystem.value == CalendarSystem.jalali
                      ? () {
                          final j = gregorianToJalali(month.year, month.month, 1);
                          return '${_jalaliMonthNames[j[1] - 1]} ${persianDigits('${j[0]}')}';
                        }()
                      : '${_gregorianMonthNames[month.month - 1]} ${month.year}',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
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
                ...accounts.map((a) => DropdownMenuItem(value: a.id, child: Text('${a.name} (${currencyLabel(a.currency)})'))),
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
              children: (currentCalendarSystem.value == CalendarSystem.jalali
                      ? const ['ش', 'ی', 'د', 'س', 'چ', 'پ', 'ج']
                      : currentLanguage.value == AppLanguage.fa
                          ? const ['د', 'س', 'چ', 'پ', 'ج', 'ش', 'ی']
                          : const ['M', 'T', 'W', 'T', 'F', 'S', 'S'])
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
                  final todayBg = Theme.of(context).colorScheme.primaryContainer;
                  final todayFg = Theme.of(context).colorScheme.onPrimaryContainer;
                  return InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => _showDayTransactions(date),
                    child: Container(
                    margin: const EdgeInsets.all(2),
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    decoration: BoxDecoration(
                      color: isToday ? todayBg : null,
                      border: Border.all(color: isToday ? todayFg.withValues(alpha: 0.4) : Colors.grey.shade200),
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
                            color: isToday ? todayFg : (future ? Colors.grey.shade400 : null),
                          ),
                        ),
                        if (exp > 0)
                          Text(
                            ltr('-${formatAmountInput(exp)}'),
                            style: TextStyle(fontSize: 9, color: future ? Colors.red.shade200 : Colors.red.shade700),
                          ),
                        if (inc > 0)
                          Text(
                            ltr('+${formatAmountInput(inc)}'),
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
  AutoBackupFrequency autoFreq = AutoBackupFrequency.off;

  @override
  void initState() {
    super.initState();
    Store.loadAutoBackupFrequency().then((f) {
      if (mounted) setState(() => autoFreq = f);
    });
  }

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
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.schedule_outlined, size: 20),
                      SizedBox(width: 10),
                      Expanded(child: Text('پشتیبان‌گیری خودکار', style: TextStyle(fontWeight: FontWeight.w600))),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'در بازه‌ی انتخابی، یه نسخه‌ی پشتیبان به‌طور خودکار روی حافظه‌ی گوشی ذخیره می‌شه (بدون نیاز به کار دستی). فقط ۵ نسخه‌ی آخر نگه داشته می‌شه.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<AutoBackupFrequency>(
                    initialValue: autoFreq,
                    decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
                    items: AutoBackupFrequency.values.map((f) => DropdownMenuItem(value: f, child: Text(f.label))).toList(),
                    onChanged: (v) async {
                      if (v == null) return;
                      setState(() => autoFreq = v);
                      await Store.saveAutoBackupFrequency(v);
                      if (v != AutoBackupFrequency.off) unawaited(maybeRunAutoBackup());
                    },
                  ),
                ],
              ),
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
        imagePath = await rasterizePdfPages(res.files.single.path!);
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
              _section('فیش حقوقی جدید', 'استخراج درآمد ناخالص و خالص، مالیات، بیمه و کلاس مالیاتی', Icons.badge_outlined, true),
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
  // Set when re-reviewing an already saved transaction (e.g. a draft): saving
  // then updates that same transaction instead of creating a new one.
  final Transaction? existing;
  const ReceiptReviewScreen({required this.imagePath, required this.initial, this.existing, super.key});
  @override
  State<ReceiptReviewScreen> createState() => _ReceiptReviewScreenState();
}

class _ReceiptReviewScreenState extends State<ReceiptReviewScreen> {
  final merchantCtrl = TextEditingController();
  final totalCtrl = TextEditingController();
  DateTime date = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
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
  bool dateConfirmed = false; // true once read successfully by AI or picked manually
  bool? keepReceipt;
  String? keepReceiptReason;
  late String? detectedCurrency = widget.initial.currency;
  late List<ReceiptItemEntry> items;

  // Snapshot of the form taken once it's loaded (before the AI fills
  // anything in), used to tell whether anything was changed since.
  String? _initialSignature;
  List<Listenable> get _watchedControllers => [merchantCtrl, totalCtrl];
  String _signature() => jsonEncode([
        merchantCtrl.text,
        totalCtrl.text,
        date.toIso8601String(),
        selectedCategory?.id,
        selectedAccount?.id,
        items.map((e) => e.toJson()).toList(),
      ]);

  @override
  void initState() {
    super.initState();
    merchantCtrl.text = widget.initial.merchant;
    totalCtrl.text = widget.initial.total == null ? '' : formatAmountInput(widget.initial.total!);
    date = widget.initial.date ?? DateTime.now();
    items = List.of(widget.initial.items);
    // A final transaction's date was already confirmed when it was saved; a
    // draft's may not have been (drafts skip that question).
    if (widget.existing != null && !widget.existing!.draft) dateConfirmed = true;
    _load();
  }

  Future<void> _load() async {
    categories = await Store.loadCategories();
    accounts = await Store.loadAccounts();
    existingTx = await Store.loadTransactions();
    selectedAccount = _initialAccount();
    selectedCategory = categories.where((c) => c.id == widget.existing?.categoryId).firstOrNull ??
        _matchCategoryHint(widget.initial.categoryHint, categories, TxType.expense);
    _initialSignature = _signature();
    final key = await Store.loadGeminiKey();
    hasGeminiKey = key != null && key.trim().isNotEmpty;
    setState(() => loading = false);
    if (hasGeminiKey) unawaited(_improveWithGemini());
  }

  Account? _initialAccount() {
    if (accounts.isEmpty) return null;
    return accounts.where((a) => a.id == widget.existing?.accountId).firstOrNull ?? accounts.first;
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
        if (result['total'] != null) {
          final t = (result['total'] as num).toDouble();
          totalCtrl.text = formatAmountInput(t);
        }
        if (result['date'] != null) {
          final parsed = DateTime.tryParse(result['date']);
          if (parsed != null) {
            date = parsed;
            dateConfirmed = true;
          }
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
        detectedCurrency = normalizeCurrency(result['currency']) ?? detectedCurrency;
        if (result['keepReceiptReason'] != null) keepReceiptReason = result['keepReceiptReason'].toString();
        final matched = _matchCategoryHint(result['category']?.toString(), categories, TxType.expense);
        if (matched != null) selectedCategory = matched;
      }
    } catch (e) {
      geminiFailed = true;
      lastGeminiErrorDetail = e is GeminiException ? e.rawDetail : e.toString();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e is GeminiException
              ? e.friendlyMessage
              : 'خواندن هوشمند ممکن نشد. دوباره امتحان کنید یا دستی تکمیل کنید.'),
          duration: const Duration(seconds: 5),
          // A snackbar with an action stays until dismissed by default;
          // let this one disappear by itself.
          persist: false,
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
    final qtyCtrl = TextEditingController(text: persianDigits(existing?.quantity?.toString() ?? '1'));
    final priceCtrl = TextEditingController(text: existing?.price == null ? '' : formatAmountInput(existing!.price!));
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
              TextField(controller: qtyCtrl, keyboardType: TextInputType.number, inputFormatters: const [DigitsInputFormatter()], decoration: InputDecoration(labelText: tr('quantity'))),
              const SizedBox(height: 8),
              TextField(controller: priceCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), inputFormatters: const [AmountInputFormatter()], decoration: InputDecoration(labelText: tr('price'))),
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
      quantity: parseAmount(qtyCtrl.text),
      price: parseAmount(priceCtrl.text),
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
    // Saving a draft is never blocked by checks or questions - those only
    // matter for the final save.
    final parsedTotal = parseAmount(totalCtrl.text);
    if (!draft && (parsedTotal == null || parsedTotal <= 0)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('مبلغ کل معتبر وارد کنید.')));
      return;
    }
    final total = parsedTotal ?? 0;
    if (!draft && selectedCategory == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('برای ثبت نهایی، دسته‌بندی را انتخاب کنید.')));
      return;
    }
    if (!draft && selectedAccount == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('برای ثبت نهایی، حساب را انتخاب کنید.')));
      return;
    }
    if (!draft && !dateConfirmed) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('تاریخ خوانده نشد'),
          content: Text('از درست بودن تاریخ ${formatDate(date)} اطمینان حاصل کنید.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('درست است')),
          ],
        ),
      );
      if (proceed != true) return;
    }
    final duplicate = existingTx.any((t) =>
        t.id != widget.existing?.id &&
        t.type == TxType.expense &&
        (t.amount - total).abs() < 0.01 &&
        t.date.year == date.year &&
        t.date.month == date.month &&
        t.date.day == date.day);
    if (!draft && duplicate) {
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
    final id = widget.existing?.id ?? DateTime.now().microsecondsSinceEpoch.toString();
    // A re-reviewed transaction already has its image stored permanently.
    String? persistedImage = widget.existing != null ? widget.imagePath : null;
    // Drafts always keep their scan; on the final save ask whether the
    // receipt/payslip photo should be kept with the transaction.
    var keepNewImage = draft;
    if (!draft && (widget.existing == null || widget.existing!.draft)) {
      final keep = await askKeepReceiptImage(context);
      if (keep == null) return;
      if (widget.existing == null) {
        keepNewImage = keep;
      } else if (!keep && persistedImage != null) {
        try {
          await File(persistedImage).delete();
        } catch (_) {
          // the file may already be gone - nothing else to do
        }
        persistedImage = null;
      }
      if (!context.mounted) return;
    }
    if (keepNewImage && widget.existing == null) {
      try {
        persistedImage = await persistDraftImage(widget.imagePath, id);
      } catch (_) {
        // best-effort only - saving the transaction matters more than the image copy
      }
    }
    final result = Transaction(
      id: id,
      type: TxType.expense,
      amount: total,
      categoryId: selectedCategory?.id ?? '_uncategorized_',
      accountId: selectedAccount?.id ?? 'default',
      date: date,
      merchant: merchantCtrl.text.trim(),
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
        final existing = widget.existing;
        if (existing != null) {
          // Re-reviewing a saved transaction: only ask when something changed.
          if (_signature() == _initialSignature) {
            Navigator.pop(context);
            return;
          }
          final choice = await askSaveChanges(context);
          if (!context.mounted) return;
          if (choice == 'discard') {
            Navigator.pop(context);
          } else if (choice == 'save') {
            await _save(draft: existing.draft);
          }
          return;
        }
        final shouldPop = await confirmDiscardChanges(context);
        if (!context.mounted) return;
        if (shouldPop) Navigator.pop(context);
      },
      child: Scaffold(
      appBar: AppBar(title: Text(tr('review_receipt'))),
      bottomNavigationBar: ListenableBuilder(
        // Rebuild as fields are typed in, so "save changes" lights up as
        // soon as something differs from what was saved.
        listenable: Listenable.merge(_watchedControllers),
        builder: (context, _) {
          final changed = _signature() != _initialSignature;
          return pinnedBottomButtons(context, [
            // For an already saved transaction this keeps it as it was (draft
            // or final) and just saves the edits - enabled once changed.
            if (widget.existing == null)
              OutlinedButton(
                onPressed: () => _save(draft: true),
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                child: const Text('ذخیره پیش‌نویس'),
              )
            else if (widget.existing!.draft)
              OutlinedButton(
                onPressed: changed ? () => _save(draft: true) : null,
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                child: const Text('ذخیره تغییرات'),
              )
            else
              FilledButton(
                onPressed: changed ? () => _save(draft: false) : null,
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                child: const Text('ذخیره تغییرات'),
              ),
            if (widget.existing == null || widget.existing!.draft)
              FilledButton(
                onPressed: () => _save(draft: false),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                child: const Text('ثبت نهایی'),
              ),
          ]);
        },
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          GestureDetector(
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => FullImageViewer(imagePath: widget.imagePath))),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                children: [
                  Image.file(
                    File(widget.imagePath),
                    height: 180,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    alignment: Alignment.topCenter,
                  ),
                  PositionedDirectional(
                    bottom: 8,
                    start: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                      child: const Icon(Icons.zoom_out_map, size: 16, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (detectedCurrency != null && selectedAccount != null && detectedCurrency != selectedAccount!.currency)
            currencyMismatchWarning(detectedCurrency!, selectedAccount!.currency),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: improving ? null : () => hasGeminiKey ? _improveWithGemini() : promptForGeminiKey(context),
            icon: improving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(geminiFailed ? Icons.refresh : Icons.auto_awesome),
            label: Text(improving ? 'در حال بهبود...' : (geminiFailed ? 'تلاش مجدد با هوش مصنوعی' : 'بهبود با هوش مصنوعی')),
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
            keyboardType: const TextInputType.numberWithOptions(decimal: true), inputFormatters: const [AmountInputFormatter()],
            decoration: const InputDecoration(labelText: 'مبلغ کل', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          ListTile(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: Colors.grey.shade400)),
            title: Text('تاریخ: ${formatDate(date)}'),
            trailing: const Icon(Icons.calendar_month),
            onTap: () async {
              final d = await showAppDatePicker(
                context: context,
                firstDate: DateTime(2000),
                lastDate: DateTime(2100),
                initialDate: date,
                builder: (ctx, child) => Directionality(textDirection: TextDirection.ltr, child: child!),
              );
              if (d != null) setState(() { date = d; dateConfirmed = true; });
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
            items: accounts.map((a) => DropdownMenuItem(value: a, child: Text('${a.name} (${currencyLabel(a.currency)})'))).toList(),
            onChanged: (v) => setState(() => selectedAccount = v),
          ),
          const SizedBox(height: 16),
          if (keepReceipt != null)
            Container(
              margin: const EdgeInsets.only(bottom: 16),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: (keepReceipt! ? Colors.amber : Colors.green).withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.14 : 0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: (keepReceipt! ? Colors.amber : Colors.green).withValues(alpha: 0.45)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    keepReceipt! ? Icons.receipt_long : Icons.check_circle_outline,
                    color: keepReceipt! ? (Theme.of(context).brightness == Brightness.dark ? Colors.amber.shade300 : Colors.amber.shade800) : (Theme.of(context).brightness == Brightness.dark ? Colors.green.shade300 : Colors.green.shade800),
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
                            color: keepReceipt! ? (Theme.of(context).brightness == Brightness.dark ? Colors.amber.shade200 : Colors.amber.shade900) : (Theme.of(context).brightness == Brightness.dark ? Colors.green.shade200 : Colors.green.shade900),
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
                      '${it.quantity != null ? 'تعداد: ${ltr(persianDigits(it.quantity!.toStringAsFixed(it.quantity! % 1 == 0 ? 0 : 2)))}' : ''}'
                      '${it.quantity != null && it.price != null ? ' • ' : ''}'
                      '${it.price != null ? formatMoney(it.price!, selectedAccount?.currency ?? 'IRT') : ''}',
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
                              label: Text('گارانتی تا ${formatDate(it.warrantyUntil!)}', style: const TextStyle(fontSize: 11)),
                              visualDensity: VisualDensity.compact,
                              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              backgroundColor: Colors.blue.shade50,
                            ),
                          if (it.returnUntil != null)
                            Chip(
                              avatar: const Icon(Icons.assignment_return_outlined, size: 14),
                              label: Text('مرجوعی تا ${formatDate(it.returnUntil!)}', style: const TextStyle(fontSize: 11)),
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
          const SizedBox(height: 16),
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
  // Set when re-reviewing an already saved transaction (e.g. a draft): saving
  // then updates that same transaction instead of creating a new one.
  final Transaction? existing;
  const PayslipReviewScreen({required this.imagePath, required this.initial, this.existing, super.key});
  @override
  State<PayslipReviewScreen> createState() => _PayslipReviewScreenState();
}

class _PayslipReviewScreenState extends State<PayslipReviewScreen> {
  final Map<String, TextEditingController> numCtrls = {};
  final steuerklasseCtrl = TextEditingController();
  final arbeitgeberCtrl = TextEditingController();
  final monatCtrl = TextEditingController();
  DateTime date = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
  List<Category> categories = [];
  List<Account> accounts = [];
  Category? selectedCategory;
  Account? selectedAccount;
  bool loading = true;
  bool improving = false;
  bool geminiFailed = false;
  String? lastGeminiErrorDetail;
  bool hasGeminiKey = false;
  bool dateConfirmed = false; // true once read successfully by AI or picked manually
  List<Transaction> existingTx = [];
  List<PayslipCustomField> customFields = [];
  late String? detectedCurrency = normalizeCurrency(widget.initial['currency']);

  // Snapshot of the form taken once it's loaded (before the AI fills
  // anything in), used to tell whether anything was changed since.
  String? _initialSignature;
  List<Listenable> get _watchedControllers => [...numCtrls.values, steuerklasseCtrl, arbeitgeberCtrl, monatCtrl];
  String _signature() => jsonEncode([
        for (final k in _payslipLabels.keys) numCtrls[k]!.text,
        steuerklasseCtrl.text,
        arbeitgeberCtrl.text,
        monatCtrl.text,
        date.toIso8601String(),
        selectedCategory?.id,
        selectedAccount?.id,
        customFields.map((f) => f.toJson()).toList(),
      ]);

  @override
  void initState() {
    super.initState();
    for (final key in _payslipLabels.keys) {
      numCtrls[key] = TextEditingController(text: widget.initial[key] != null ? formatAmountInput((widget.initial[key] as num).toDouble()) : '');
    }
    steuerklasseCtrl.text = widget.initial['steuerklasse']?.toString() ?? '';
    arbeitgeberCtrl.text = widget.initial['arbeitgeber']?.toString() ?? '';
    monatCtrl.text = widget.initial['abrechnungsmonat']?.toString() ?? '';
    final initialDate = (widget.initial['date'] != null ? DateTime.tryParse(widget.initial['date'].toString()) : null) ??
        payPeriodEnd(widget.initial['abrechnungsmonat']?.toString());
    if (initialDate != null) date = initialDate;
    if (widget.initial['customFields'] is List) {
      customFields = (widget.initial['customFields'] as List)
          .whereType<Map>()
          .map((e) => PayslipCustomField(label: (e['label'] ?? '').toString(), value: (e['value'] as num? ?? 0).toDouble()))
          .where((f) => f.label.trim().isNotEmpty)
          .toList();
    }
    if (widget.existing != null) {
      date = widget.existing!.date;
      // A final transaction's date was already confirmed; a draft's may not have been.
      dateConfirmed = !widget.existing!.draft;
    }
    _load();
  }

  Future<void> _load() async {
    categories = await Store.loadCategories();
    accounts = await Store.loadAccounts();
    existingTx = await Store.loadTransactions();
    selectedAccount = _initialAccount();
    final match = categories.where((c) => c.id == (widget.existing?.categoryId ?? 'i_salary')).toList();
    selectedCategory = match.isEmpty ? categories.where((c) => c.id == 'i_salary').firstOrNull : match.first;
    _initialSignature = _signature();
    final key = await Store.loadGeminiKey();
    hasGeminiKey = key != null && key.trim().isNotEmpty;
    setState(() => loading = false);
    if (hasGeminiKey) unawaited(_improveWithGemini());
  }

  Account? _initialAccount() {
    if (accounts.isEmpty) return null;
    return accounts.where((a) => a.id == widget.existing?.accountId).firstOrNull ?? accounts.first;
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
        detectedCurrency = normalizeCurrency(result['currency']) ?? detectedCurrency;
        for (final k in _payslipLabels.keys) {
          if (result[k] != null) numCtrls[k]!.text = formatAmountInput((result[k] as num).toDouble());
        }
        if (result['steuerklasse'] != null) steuerklasseCtrl.text = result['steuerklasse'].toString();
        if (result['arbeitgeber'] != null) arbeitgeberCtrl.text = result['arbeitgeber'].toString();
        if (result['abrechnungsmonat'] != null) monatCtrl.text = result['abrechnungsmonat'].toString();
        // The payout date; when the payslip doesn't print one, the end of
        // its pay period is a far better guess than today's date.
        final parsedDate = (result['date'] != null ? DateTime.tryParse(result['date'].toString()) : null) ??
            payPeriodEnd(result['abrechnungsmonat']?.toString());
        if (parsedDate != null) {
          setState(() {
            date = parsedDate;
            dateConfirmed = true;
          });
        }
        if (result['customFields'] is List) {
          final parsed = (result['customFields'] as List)
              .whereType<Map>()
              .map((e) => PayslipCustomField(label: (e['label'] ?? '').toString(), value: (e['value'] as num? ?? 0).toDouble()))
              .where((f) => f.label.trim().isNotEmpty)
              .toList();
          if (parsed.isNotEmpty) setState(() => customFields = parsed);
        }
      }
    } catch (e) {
      geminiFailed = true;
      lastGeminiErrorDetail = e is GeminiException ? e.rawDetail : e.toString();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e is GeminiException
              ? e.friendlyMessage
              : 'خواندن هوشمند ممکن نشد. دوباره امتحان کنید یا دستی تکمیل کنید.'),
          duration: const Duration(seconds: 5),
          // A snackbar with an action stays until dismissed by default;
          // let this one disappear by itself.
          persist: false,
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
    // Saving a draft is never blocked by checks or questions - those only
    // matter for the final save.
    final netto = parseAmount(numCtrls['netto']!.text);
    if (!draft && (netto == null || netto <= 0)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('مبلغ Netto معتبر وارد کنید.')));
      return;
    }
    final depositedAmount = parseAmount(numCtrls['depositedAmount']!.text);
    // The actual amount credited to the account can differ from netto (e.g.
    // advances or other payroll-side deductions) - prefer it when present.
    final transactionAmount = (depositedAmount != null && depositedAmount > 0) ? depositedAmount : (netto ?? 0);
    if (!draft && selectedCategory == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('برای ثبت نهایی، دسته‌بندی را انتخاب کنید.')));
      return;
    }
    if (!draft && selectedAccount == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('برای ثبت نهایی، حساب را انتخاب کنید.')));
      return;
    }
    if (!draft && !dateConfirmed) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('تاریخ خوانده نشد'),
          content: Text('از درست بودن تاریخ ${formatDate(date)} اطمینان حاصل کنید.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('درست است')),
          ],
        ),
      );
      if (proceed != true) return;
    }
    double? num_(String k) => parseAmount(numCtrls[k]!.text.trim());
    final details = PayslipDetails(
      brutto: num_('brutto'),
      netto: num_('netto'),
      depositedAmount: num_('depositedAmount'),
      lohnsteuer: num_('lohnsteuer'),
      solidaritaetszuschlag: num_('solidaritaetszuschlag'),
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
      customFields: customFields,
    );
    final duplicate = existingTx.any((t) =>
        t.id != widget.existing?.id &&
        t.type == TxType.income &&
        (t.amount - transactionAmount).abs() < 0.01 &&
        t.date.year == date.year &&
        t.date.month == date.month &&
        t.date.day == date.day);
    if (!draft && duplicate) {
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
    final id = widget.existing?.id ?? DateTime.now().microsecondsSinceEpoch.toString();
    // A re-reviewed transaction already has its image stored permanently.
    String? persistedImage = widget.existing != null ? widget.imagePath : null;
    // Drafts always keep their scan; on the final save ask whether the
    // receipt/payslip photo should be kept with the transaction.
    var keepNewImage = draft;
    if (!draft && (widget.existing == null || widget.existing!.draft)) {
      final keep = await askKeepReceiptImage(context);
      if (keep == null) return;
      if (widget.existing == null) {
        keepNewImage = keep;
      } else if (!keep && persistedImage != null) {
        try {
          await File(persistedImage).delete();
        } catch (_) {
          // the file may already be gone - nothing else to do
        }
        persistedImage = null;
      }
      if (!context.mounted) return;
    }
    if (keepNewImage && widget.existing == null) {
      try {
        persistedImage = await persistDraftImage(widget.imagePath, id);
      } catch (_) {
        // best-effort only - saving the transaction matters more than the image copy
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
        final existing = widget.existing;
        if (existing != null) {
          // Re-reviewing a saved transaction: only ask when something changed.
          if (_signature() == _initialSignature) {
            Navigator.pop(context);
            return;
          }
          final choice = await askSaveChanges(context);
          if (!context.mounted) return;
          if (choice == 'discard') {
            Navigator.pop(context);
          } else if (choice == 'save') {
            await _save(draft: existing.draft);
          }
          return;
        }
        final shouldPop = await confirmDiscardChanges(context);
        if (!context.mounted) return;
        if (shouldPop) Navigator.pop(context);
      },
      child: Scaffold(
      appBar: AppBar(title: Text(tr('review_payslip'))),
      bottomNavigationBar: ListenableBuilder(
        // Rebuild as fields are typed in, so "save changes" lights up as
        // soon as something differs from what was saved.
        listenable: Listenable.merge(_watchedControllers),
        builder: (context, _) {
          final changed = _signature() != _initialSignature;
          return pinnedBottomButtons(context, [
            // For an already saved transaction this keeps it as it was (draft
            // or final) and just saves the edits - enabled once changed.
            if (widget.existing == null)
              OutlinedButton(
                onPressed: () => _save(draft: true),
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                child: const Text('ذخیره پیش‌نویس'),
              )
            else if (widget.existing!.draft)
              OutlinedButton(
                onPressed: changed ? () => _save(draft: true) : null,
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                child: const Text('ذخیره تغییرات'),
              )
            else
              FilledButton(
                onPressed: changed ? () => _save(draft: false) : null,
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                child: const Text('ذخیره تغییرات'),
              ),
            if (widget.existing == null || widget.existing!.draft)
              FilledButton(
                onPressed: () => _save(draft: false),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                child: const Text('ثبت نهایی'),
              ),
          ]);
        },
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          GestureDetector(
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => FullImageViewer(imagePath: widget.imagePath))),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                children: [
                  Image.file(
                    File(widget.imagePath),
                    height: 180,
                    width: double.infinity,
                    fit: BoxFit.cover,
                    alignment: Alignment.topCenter,
                  ),
                  PositionedDirectional(
                    bottom: 8,
                    start: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                      child: const Icon(Icons.zoom_out_map, size: 16, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (detectedCurrency != null && selectedAccount != null && detectedCurrency != selectedAccount!.currency)
            currencyMismatchWarning(detectedCurrency!, selectedAccount!.currency),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: improving ? null : () => hasGeminiKey ? _improveWithGemini() : promptForGeminiKey(context),
            icon: improving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(geminiFailed ? Icons.refresh : Icons.auto_awesome),
            label: Text(improving ? 'در حال بهبود...' : (geminiFailed ? 'تلاش مجدد با هوش مصنوعی' : 'بهبود با هوش مصنوعی')),
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
          PayslipFieldsEditor(
            controllers: numCtrls,
            customFields: customFields,
            onCustomChanged: (list) => setState(() => customFields = list),
            onLayoutChanged: () => setState(() {}),
          ),
          const SizedBox(height: 12),
          ListTile(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: Colors.grey.shade400)),
            title: Text('تاریخ: ${formatDate(date)}'),
            trailing: const Icon(Icons.calendar_month),
            onTap: () async {
              final d = await showAppDatePicker(
                context: context,
                firstDate: DateTime(2000),
                lastDate: DateTime(2100),
                initialDate: date,
                builder: (ctx, child) => Directionality(textDirection: TextDirection.ltr, child: child!),
              );
              if (d != null) setState(() { date = d; dateConfirmed = true; });
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
            items: accounts.map((a) => DropdownMenuItem(value: a, child: Text('${a.name} (${currencyLabel(a.currency)})'))).toList(),
            onChanged: (v) => setState(() => selectedAccount = v),
          ),
          const SizedBox(height: 16),
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

// ============================== Transaction detail (read-only) ==============================

class TransactionDetailScreen extends StatelessWidget {
  final Transaction t;
  final List<Category> categories;
  final List<Account> accounts;
  const TransactionDetailScreen({required this.t, required this.categories, required this.accounts, super.key});

  String get _categoryName {
    final m = categories.where((c) => c.id == t.categoryId).toList();
    return m.isEmpty ? 'بدون‌دسته' : m.first.name;
  }

  String get _accountName {
    final m = accounts.where((a) => a.id == t.accountId).toList();
    return m.isEmpty ? '' : m.first.name;
  }

  String get _currency {
    final m = accounts.where((a) => a.id == t.accountId).toList();
    return m.isEmpty ? 'IRT' : m.first.currency;
  }

  Widget _row(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
          const SizedBox(width: 12),
          Flexible(child: Text(value, style: const TextStyle(fontSize: 13), textAlign: TextAlign.left)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('جزئیات تراکنش'),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit_outlined),
            tooltip: tr('edit'),
            onPressed: () async {
              final result = await Navigator.push<Object>(
                context,
                MaterialPageRoute(builder: (_) => TransactionEditor(categories: categories, accounts: accounts, existing: t)),
              );
              if (result != null && context.mounted) Navigator.pop(context, result);
            },
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: tr('delete'),
            onPressed: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: Text(tr('delete_transaction_confirm')),
                  content: const Text('این کار قابل بازگشت نیست (مگر با برگردون).'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
                    FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('delete'))),
                  ],
                ),
              );
              if (confirm == true && context.mounted) Navigator.pop(context, DeleteTransactionSignal(t.id));
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: Column(
              children: [
                Text(
                  ltr(t.type == TxType.income ? '+' : '-') + formatMoney(t.amount, _currency),
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: t.type == TxType.income ? Colors.green.shade700 : Colors.red.shade700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(txMainTitle(t, _categoryName), style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Column(
                children: [
                  if (t.merchant.trim().isNotEmpty) ...[
                    _row(context, 'فروشگاه', t.merchant.trim()),
                    const Divider(height: 1),
                  ],
                  _row(context, 'دسته‌بندی', _categoryName),
                  const Divider(height: 1),
                  _row(context, 'حساب', _accountName),
                  const Divider(height: 1),
                  _row(context, 'تاریخ', formatDate(t.date)),
                  if (t.note.trim().isNotEmpty) ...[
                    const Divider(height: 1),
                    _row(context, 'توضیحات', t.note.trim()),
                  ],
                  if (t.isRecurring) ...[
                    const Divider(height: 1),
                    _row(context, 'تکرار', switch (t.recurrence) {
                      RecurrenceFrequency.weekly => 'هفتگی',
                      RecurrenceFrequency.monthly => 'ماهانه',
                      RecurrenceFrequency.quarterly => 'فصلی',
                      RecurrenceFrequency.yearly => 'سالانه',
                      RecurrenceFrequency.custom => 'هر ${t.recurrenceIntervalDays ?? '?'} روز',
                      RecurrenceFrequency.none => '—',
                    }),
                  ],
                  if (t.draft) ...[
                    const Divider(height: 1),
                    _row(context, 'وضعیت', 'پیش‌نویس'),
                  ],
                ],
              ),
            ),
          ),
          if (t.items.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text('اقلام', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            ...t.items.map((it) => Card(
                  child: ListTile(
                    dense: true,
                    title: Text(it.name),
                    subtitle: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${it.quantity != null ? 'تعداد: ${ltr(persianDigits(it.quantity!.toStringAsFixed(it.quantity! % 1 == 0 ? 0 : 2)))}' : ''}'
                          '${it.quantity != null && it.price != null ? ' • ' : ''}'
                          '${it.price != null ? ltr(formatMoney(it.price!, _currency)) : ''}',
                        ),
                        if (it.warrantyNote != null) Text(it.warrantyNote!, style: const TextStyle(fontSize: 11)),
                      ],
                    ),
                  ),
                )),
          ],
          if (t.payslipDetails != null) ...[
            const SizedBox(height: 16),
            Text('جزئیات فیش حقوقی', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Column(
                  children: [
                    if (t.payslipDetails!.brutto != null) _row(context, 'Brutto', ltr(formatMoney(t.payslipDetails!.brutto!, _currency))),
                    if (t.payslipDetails!.netto != null) ...[
                      const Divider(height: 1),
                      _row(context, 'Netto', ltr(formatMoney(t.payslipDetails!.netto!, _currency))),
                    ],
                    ...t.payslipDetails!.customFields.map((f) => Column(
                          children: [
                            const Divider(height: 1),
                            _row(context, f.label, ltr(formatMoney(f.value, _currency))),
                          ],
                        )),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Lets the person add, view and remove their own payslip lines (e.g. حق مسکن،
/// حق اولاد، بیمه‌ی تأمین اجتماعی) - works for a payslip from any country.
/// Which built-in payslip fields are hidden and what they are called, as
/// the person set it up (shared by every payslip, stored on the device).
class PayslipFieldPrefs {
  final Set<String> hidden;
  final Map<String, String> labels;
  const PayslipFieldPrefs({required this.hidden, required this.labels});

  // Rarely used on most payslips, so not shown unless the person adds them
  // back (or a payslip actually has a value for them).
  static const defaults = PayslipFieldPrefs(
    hidden: {'solidaritaetszuschlag', 'vermoegenswirksameLeistungen', 'vorschuss'},
    labels: {},
  );

  String labelOf(String key) => labels[key] ?? _payslipLabels[key] ?? key;

  static const _prefsKey = 'payslip_field_prefs';
  static PayslipFieldPrefs? _cache;

  static Future<PayslipFieldPrefs> load() async {
    if (_cache != null) return _cache!;
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString(_prefsKey);
    if (raw == null) return _cache = defaults;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return _cache = PayslipFieldPrefs(
        hidden: {...(j['hidden'] as List? ?? const []).map((e) => e.toString())},
        labels: {...((j['labels'] as Map?) ?? const {}).map((k, v) => MapEntry(k.toString(), v.toString()))},
      );
    } catch (_) {
      return _cache = defaults;
    }
  }

  static Future<void> save(PayslipFieldPrefs p) async {
    _cache = p;
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_prefsKey, jsonEncode({'hidden': p.hidden.toList(), 'labels': p.labels}));
  }
}

/// All payslip amount fields - the built-in ones and those the person added -
/// shown the same way, as text fields. Each one's name can be changed and the
/// field removed from its menu; "add field" adds a new one or brings back a
/// removed built-in field.
class PayslipFieldsEditor extends StatefulWidget {
  final Map<String, TextEditingController> controllers; // built-in fields, by key
  final Set<String> exclude; // built-in keys shown elsewhere on the screen
  final List<PayslipCustomField> customFields;
  final ValueChanged<List<PayslipCustomField>> onCustomChanged;
  final VoidCallback? onLayoutChanged;
  const PayslipFieldsEditor({
    required this.controllers,
    required this.customFields,
    required this.onCustomChanged,
    this.exclude = const {},
    this.onLayoutChanged,
    super.key,
  });
  @override
  State<PayslipFieldsEditor> createState() => _PayslipFieldsEditorState();
}

class _PayslipFieldsEditorState extends State<PayslipFieldsEditor> {
  PayslipFieldPrefs prefs = PayslipFieldPrefs.defaults;
  final List<TextEditingController> _customCtrls = [];

  @override
  void initState() {
    super.initState();
    PayslipFieldPrefs.load().then((p) {
      if (mounted) setState(() => prefs = p);
    });
    _syncCustomCtrls();
  }

  @override
  void didUpdateWidget(covariant PayslipFieldsEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncCustomCtrls();
  }

  @override
  void dispose() {
    for (final c in _customCtrls) {
      c.dispose();
    }
    super.dispose();
  }

  /// Keeps one text controller per custom field, updating their text only
  /// when the value really changed (e.g. filled in by the AI), so typing
  /// isn't disturbed.
  void _syncCustomCtrls() {
    final fields = widget.customFields;
    while (_customCtrls.length > fields.length) {
      _customCtrls.removeLast().dispose();
    }
    for (var i = 0; i < fields.length; i++) {
      final text = fields[i].value == 0 ? '' : formatAmountInput(fields[i].value);
      if (i >= _customCtrls.length) {
        _customCtrls.add(TextEditingController(text: text));
      } else if ((parseAmount(_customCtrls[i].text) ?? 0) != fields[i].value) {
        _customCtrls[i].text = text;
      }
    }
  }

  void _updateCustom(int i, PayslipCustomField f) {
    final list = [...widget.customFields];
    list[i] = f;
    widget.onCustomChanged(list);
  }

  Future<String?> _askName(String title, String initial) async {
    final ctrl = TextEditingController(text: initial);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(labelText: 'نام فیلد')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('confirm'))),
        ],
      ),
    );
    final name = ctrl.text.trim();
    return ok == true && name.isNotEmpty ? name : null;
  }

  Future<bool> _confirmRemove(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('حذف فیلد'),
        content: Text('فیلد «$name» حذف شود؟'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('delete'))),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _renameBuiltIn(String key) async {
    final name = await _askName('تغییر نام فیلد', prefs.labelOf(key));
    if (name == null) return;
    final p = PayslipFieldPrefs(hidden: prefs.hidden, labels: {...prefs.labels, key: name});
    await PayslipFieldPrefs.save(p);
    if (mounted) setState(() => prefs = p);
  }

  Future<void> _removeBuiltIn(String key) async {
    if (!await _confirmRemove(prefs.labelOf(key))) return;
    widget.controllers[key]?.clear();
    final p = PayslipFieldPrefs(hidden: {...prefs.hidden, key}, labels: prefs.labels);
    await PayslipFieldPrefs.save(p);
    if (mounted) setState(() => prefs = p);
    widget.onLayoutChanged?.call();
  }

  Future<void> _add() async {
    final hiddenKeys = _payslipLabels.keys
        .where((k) => !widget.exclude.contains(k) && prefs.hidden.contains(k) && (widget.controllers[k]?.text.isEmpty ?? true))
        .toList();
    final nameCtrl = TextEditingController();
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('افزودن فیلد'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: hiddenKeys.isEmpty,
                decoration: const InputDecoration(labelText: 'نام فیلد جدید (مثلاً حق مسکن)'),
              ),
              if (hiddenKeys.isNotEmpty) ...[
                const SizedBox(height: 16),
                const Text('یا برگرداندن فیلدهای حذف‌شده:', style: TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: hiddenKeys
                      .map((k) => ActionChip(label: Text(prefs.labelOf(k)), onPressed: () => Navigator.pop(ctx, 'builtin:$k')))
                      .toList(),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'new'), child: Text(tr('add'))),
        ],
      ),
    );
    if (picked == null) return;
    if (picked.startsWith('builtin:')) {
      final key = picked.substring(8);
      final p = PayslipFieldPrefs(hidden: {...prefs.hidden}..remove(key), labels: prefs.labels);
      await PayslipFieldPrefs.save(p);
      if (mounted) setState(() => prefs = p);
      widget.onLayoutChanged?.call();
      return;
    }
    final name = nameCtrl.text.trim();
    if (name.isEmpty) return;
    widget.onCustomChanged([...widget.customFields, PayslipCustomField(label: name, value: 0)]);
  }

  Widget _fieldRow({
    required TextEditingController controller,
    required String label,
    required VoidCallback onRename,
    required VoidCallback onRemove,
    ValueChanged<String>? onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: const [AmountInputFormatter()],
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          suffixIcon: PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, size: 20),
            tooltip: 'گزینه‌های فیلد',
            onSelected: (v) => v == 'rename' ? onRename() : onRemove(),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: Text('تغییر نام')),
              PopupMenuItem(value: 'remove', child: Text('حذف فیلد')),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final builtIn = _payslipLabels.keys.where((k) =>
        !widget.exclude.contains(k) &&
        widget.controllers[k] != null &&
        (!prefs.hidden.contains(k) || widget.controllers[k]!.text.isNotEmpty));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final k in builtIn)
          _fieldRow(
            controller: widget.controllers[k]!,
            label: prefs.labelOf(k),
            onRename: () => _renameBuiltIn(k),
            onRemove: () => _removeBuiltIn(k),
          ),
        for (var i = 0; i < widget.customFields.length && i < _customCtrls.length; i++)
          _fieldRow(
            controller: _customCtrls[i],
            label: widget.customFields[i].label,
            onChanged: (v) => _updateCustom(i, PayslipCustomField(label: widget.customFields[i].label, value: parseAmount(v) ?? 0)),
            onRename: () async {
              final name = await _askName('تغییر نام فیلد', widget.customFields[i].label);
              if (name != null) _updateCustom(i, PayslipCustomField(label: name, value: widget.customFields[i].value));
            },
            onRemove: () async {
              if (!await _confirmRemove(widget.customFields[i].label)) return;
              widget.onCustomChanged([...widget.customFields]..removeAt(i));
            },
          ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(onPressed: _add, icon: const Icon(Icons.add, size: 18), label: const Text('افزودن فیلد')),
        ),
      ],
    );
  }
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
  final merchantCtrl = TextEditingController();
  final dayCtrl = TextEditingController();
  final intervalCtrl = TextEditingController();
  final installmentsCtrl = TextEditingController();
  late String? _currentImagePath = widget.existing?.imagePath;
  Category? selectedCategory;
  Account? selectedAccount;
  DateTime date = DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day);
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
  List<PayslipCustomField> payslipCustomFields = [];

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
      amountCtrl.text = formatAmountInput(e.amount);
      noteCtrl.text = e.note;
      merchantCtrl.text = e.merchant;
      date = e.date;
      recurrence = e.recurrence;
      dayCtrl.text = persianDigits(e.recurrenceDay?.toString() ?? dayOfMonthInCalendar(date).toString());
      weekday = e.recurrenceWeekday ?? date.weekday;
      intervalCtrl.text = persianDigits(e.recurrenceIntervalDays?.toString() ?? '');
      installmentsCtrl.text = persianDigits(e.installments?.toString() ?? '');
      endDate = e.recurrenceEndDate;
      endMode = e.recurrenceEndDate != null ? 'date' : (e.installments != null ? 'count' : 'unlimited');
      notifyEnabled = e.notifyEnabled;
      notifyLastTwoEnabled = e.notifyLastTwoEnabled;
      notifyMessageCtrl.text = e.notifyMessage;
      notifyEachEnabled = e.notifyDaysBeforeEach != null;
      notifyDaysCtrl.text = persianDigits(e.notifyDaysBeforeEach?.toString() ?? '');
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
          payslipNumCtrls[k]!.text = map[k] != null ? formatAmountInput(map[k]!) : '';
        }
        payslipSteuerklasseCtrl.text = pd.steuerklasse ?? '';
        payslipArbeitgeberCtrl.text = pd.arbeitgeber ?? '';
        payslipMonatCtrl.text = pd.abrechnungsmonat ?? '';
        payslipCustomFields = List.of(pd.customFields);
      }
      final match = categories.where((c) => c.id == e.categoryId).toList();
      selectedCategory = match.isEmpty ? null : match.first;
    }
    for (final c in [
      amountCtrl,
      noteCtrl,
      merchantCtrl,
      dayCtrl,
      intervalCtrl,
      installmentsCtrl,
      notifyMessageCtrl,
      notifyDaysCtrl,
      ...payslipNumCtrls.values,
      payslipSteuerklasseCtrl,
      payslipArbeitgeberCtrl,
      payslipMonatCtrl,
    ]) {
      _watchText(c);
    }
  }

  /// Marks the form as changed when [c]'s text changes (controller listeners
  /// also fire for cursor/selection moves, which aren't changes), and
  /// rebuilds so the save button and back-button behaviour follow along.
  void _watchText(TextEditingController c) {
    var last = c.text;
    c.addListener(() {
      if (c.text == last) return;
      last = c.text;
      if (!_dirty && mounted) setState(() => _dirty = true);
    });
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

  Future<bool> _save({bool? asDraft}) async {
    if (asDraft != null) draft = asDraft;
    // Saving a draft is never blocked by checks or questions - those only
    // matter for the final save.
    final parsedAmount = parseAmount(amountCtrl.text);
    if (!draft && (parsedAmount == null || parsedAmount <= 0)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('مبلغ معتبر وارد کنید.')));
      return false;
    }
    final amount = parsedAmount ?? 0;
    if (!draft && selectedCategory == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('یک دسته‌بندی انتخاب کنید.')));
      return false;
    }
    if (!draft && selectedAccount == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('یک حساب انتخاب کنید.')));
      return false;
    }
    final existingList = draft ? const <Transaction>[] : await Store.loadTransactions();
    final duplicate = existingList.any((t) =>
        t.id != widget.existing?.id &&
        t.type == type &&
        (t.amount - amount).abs() < 0.01 &&
        t.date.year == date.year &&
        t.date.month == date.month &&
        t.date.day == date.day &&
        t.categoryId == selectedCategory?.id);
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
      recDay = parseInt(dayCtrl.text);
      if (recDay == null && !draft) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('روز سررسید در ماه را وارد کنید.')));
        return false;
      }
      if (recDay != null && recDay < 1) recDay = 1;
      if (recDay != null && recDay > 31) recDay = 31;
    } else if (recurrence == RecurrenceFrequency.weekly) {
      recWeekday = weekday;
    } else if (recurrence == RecurrenceFrequency.custom) {
      recInterval = parseInt(intervalCtrl.text);
      if (!draft && (recInterval == null || recInterval <= 0)) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعداد روز بازه را درست وارد کنید.')));
        return false;
      }
    }
    if (recurrence != RecurrenceFrequency.none) {
      if (endMode == 'date') {
        recEndDate = endDate;
      } else if (endMode == 'count') {
        recInstallments = parseInt(installmentsCtrl.text);
      }
      // endMode == 'unlimited': leave both recEndDate and recInstallments null
    }
    final id = widget.existing?.id ?? DateTime.now().microsecondsSinceEpoch.toString();
    PayslipDetails? payslipDetails;
    if (type == TxType.income) {
      double? num_(String k) {
        final t = payslipNumCtrls[k]!.text.trim();
        return t.isEmpty ? null : parseAmount(t);
      }

      final hasAny = payslipNumCtrls.values.any((c) => c.text.trim().isNotEmpty) ||
          payslipSteuerklasseCtrl.text.trim().isNotEmpty ||
          payslipArbeitgeberCtrl.text.trim().isNotEmpty ||
          payslipMonatCtrl.text.trim().isNotEmpty ||
          payslipCustomFields.isNotEmpty;
      if (hasAny) {
        payslipDetails = PayslipDetails(
          brutto: num_('brutto'),
          netto: num_('netto'),
          // The deposited amount is the main amount field of an income.
          depositedAmount: amount,
          lohnsteuer: num_('lohnsteuer'),
          solidaritaetszuschlag: num_('solidaritaetszuschlag'),
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
          customFields: payslipCustomFields,
        );
      }
    }
    // A draft made from a scan keeps a copy of the receipt/payslip photo. When
    // it becomes a final transaction, ask whether that photo should be kept.
    String? keptImage = _currentImagePath;
    if (keptImage != null && !draft && (widget.existing?.draft ?? false)) {
      if (!context.mounted) return false;
      final keep = await askKeepReceiptImage(context);
      if (keep == null) return false;
      if (!keep) {
        try {
          await File(keptImage).delete();
        } catch (_) {
          // the file may already be gone - nothing else to do
        }
        keptImage = null;
      }
    }
    final result = Transaction(
      id: id,
      type: type,
      amount: amount,
      categoryId: selectedCategory?.id ?? '_uncategorized_',
      accountId: selectedAccount?.id ?? 'default',
      date: date,
      note: noteCtrl.text.trim(),
      imagePath: keptImage,
      merchant: type == TxType.expense ? merchantCtrl.text.trim() : '',
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
      notifyDaysBeforeEach: notifyEnabled && notifyEachEnabled ? parseInt(notifyDaysCtrl.text) : null,
      payslipDetails: payslipDetails,
    );
    // Scheduling/cancelling reminders doesn't need to block the save flow -
    // let it run in the background so the screen closes immediately.
    if (notifyEnabled && !result.draft) {
      unawaited(NotificationService.instance.scheduleForTransaction(result, selectedCategory!.name));
    } else {
      unawaited(NotificationService.instance.cancelForTransaction(result.id));
    }
    if (!context.mounted) return true;
    Navigator.pop(context, result);
    return true;
  }

  /// Re-runs the AI review on this transaction's stored receipt/payslip image.
  Future<void> _reReviewWithAi() async {
    final existing = widget.existing!;
    Transaction? result;
    if (existing.type == TxType.expense) {
      final draftInit = ReceiptDraft(
        merchant: existing.merchant.isNotEmpty ? existing.merchant : existing.note,
        date: existing.date,
        total: existing.amount,
        items: existing.items,
        categoryHint: selectedCategory?.name,
      );
      result = await Navigator.push<Transaction>(
        context,
        MaterialPageRoute(
          builder: (_) => ReceiptReviewScreen(imagePath: _currentImagePath!, initial: draftInit, existing: existing),
        ),
      );
    } else {
      result = await Navigator.push<Transaction>(
        context,
        MaterialPageRoute(
          builder: (_) => PayslipReviewScreen(
            imagePath: _currentImagePath!,
            initial: {...?existing.payslipDetails?.toJson(), 'date': existing.date.toIso8601String()},
            existing: existing,
          ),
        ),
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
        note: existing.merchant.isNotEmpty ? existing.note : result.note,
        merchant: result.merchant,
        draft: result.draft,
        items: result.items,
        payslipDetails: result.payslipDetails,
        imagePath: result.imagePath,
      ),
    );
  }

  Future<void> _addItemRow({int? editIndex}) async {
    final existing = editIndex != null ? items[editIndex] : null;
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final qtyCtrl = TextEditingController(text: persianDigits(existing?.quantity?.toString() ?? '1'));
    final priceCtrl = TextEditingController(text: existing?.price == null ? '' : formatAmountInput(existing!.price!));
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
              TextField(controller: qtyCtrl, keyboardType: TextInputType.number, inputFormatters: const [DigitsInputFormatter()], decoration: InputDecoration(labelText: tr('quantity'))),
              const SizedBox(height: 8),
              TextField(controller: priceCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), inputFormatters: const [AmountInputFormatter()], decoration: InputDecoration(labelText: tr('price'))),
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
      quantity: parseAmount(qtyCtrl.text),
      price: parseAmount(priceCtrl.text),
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
            recurrenceDay: parseInt(dayCtrl.text),
            recurrenceWeekday: weekday,
            recurrenceIntervalDays: parseInt(intervalCtrl.text),
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
            keyboardType: TextInputType.number, inputFormatters: const [DigitsInputFormatter()],
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
            keyboardType: TextInputType.number, inputFormatters: const [DigitsInputFormatter()],
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
                final d = await showAppDatePicker(
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
              keyboardType: TextInputType.number, inputFormatters: const [DigitsInputFormatter()],
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
                      keyboardType: TextInputType.number, inputFormatters: const [DigitsInputFormatter()],
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
        if (widget.existing != null) {
          // Only reached when something was changed (canPop is false then).
          final choice = await askSaveChanges(context);
          if (!context.mounted) return;
          if (choice == 'discard') {
            Navigator.pop(context);
          } else if (choice == 'save') {
            await _save();
          }
          return;
        }
        final shouldPop = await confirmDiscardChanges(context, onSave: () async => _save());
        if (didPop || !context.mounted) return;
        if (shouldPop) {
          // _save() already pops with the saved Transaction when it succeeds;
          // if the user chose to discard instead, pop with no result here.
          if (Navigator.canPop(context)) Navigator.pop(context);
        }
      },
      child: Scaffold(
      bottomNavigationBar: pinnedBottomButtons(context, [
        // A confirmed transaction only needs "save changes", enabled once
        // something was changed. A draft keeps "save changes" (into the same
        // draft, also enabled once changed) next to "final save"; a new
        // transaction gets "save as draft" and "final save".
        if (widget.existing == null)
          OutlinedButton(
            onPressed: () => _save(asDraft: true),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: Text(tr('save_as_draft'), textAlign: TextAlign.center),
          )
        else if (widget.existing!.draft)
          OutlinedButton(
            onPressed: _dirty ? () => _save(asDraft: true) : null,
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: const Text('ذخیره تغییرات', textAlign: TextAlign.center),
          ),
        if (widget.existing != null && !widget.existing!.draft)
          FilledButton(
            onPressed: _dirty ? () => _save(asDraft: false) : null,
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: const Text('ذخیره تغییرات', textAlign: TextAlign.center),
          )
        else
          FilledButton(
            onPressed: () => _save(asDraft: false),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
            child: const Text('ثبت نهایی', textAlign: TextAlign.center),
          ),
      ], trailing: [
        if (_currentImagePath != null)
          IconButton(
            icon: const Icon(Icons.receipt_long_outlined),
            tooltip: 'تصویر رسید/فیش',
            onPressed: () async {
              final action = await Navigator.push<ReceiptImageAction>(
                context,
                MaterialPageRoute(builder: (_) => ReceiptImageScreen(imagePath: _currentImagePath!)),
              );
              if (!context.mounted || action == null) return;
              if (action == ReceiptImageAction.reread) {
                await _reReviewWithAi();
              } else {
                final path = _currentImagePath;
                if (path != null) {
                  try {
                    await File(path).delete();
                  } catch (_) {
                    // already gone - fine
                  }
                }
                setState(() {
                  _currentImagePath = null;
                  _dirty = true;
                });
              }
            },
          ),
        if (widget.existing != null)
          IconButton(
            icon: Icon(Icons.delete_outline, color: Colors.red.shade400),
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
      ]),
      appBar: AppBar(
        title: Text(widget.existing == null ? 'تراکنش جدید' : 'ویرایش تراکنش'),
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
            keyboardType: const TextInputType.numberWithOptions(decimal: true), inputFormatters: const [AmountInputFormatter()],
            decoration: InputDecoration(labelText: type == TxType.income ? 'مبلغ واریز شده به حساب' : tr('amount'), hintText: 'مثلاً 250,000', border: const OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<Account>(
            initialValue: selectedAccount,
            decoration: InputDecoration(labelText: tr('account'), border: const OutlineInputBorder()),
            items: widget.accounts
                .map((a) => DropdownMenuItem(value: a, child: Text('${a.name} (${currencyLabel(a.currency)})')))
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
              final d = await showAppDatePicker(
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
          if (type == TxType.expense) ...[
            TextField(
              controller: merchantCtrl,
              decoration: const InputDecoration(labelText: 'نام فروشگاه', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 16),
          ],
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
                        '${it.quantity != null ? 'تعداد: ${ltr(persianDigits(it.quantity!.toStringAsFixed(it.quantity! % 1 == 0 ? 0 : 2)))}' : ''}'
                        '${it.quantity != null && it.price != null ? ' • ' : ''}'
                        '${it.price != null ? formatMoney(it.price!, selectedAccount?.currency ?? 'IRT') : ''}',
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
                                label: Text('گارانتی تا ${formatDate(it.warrantyUntil!)}', style: const TextStyle(fontSize: 11)),
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                backgroundColor: Colors.blue.shade50,
                              ),
                            if (it.returnUntil != null)
                              Chip(
                                avatar: const Icon(Icons.assignment_return_outlined, size: 14),
                                label: Text('مرجوعی تا ${formatDate(it.returnUntil!)}', style: const TextStyle(fontSize: 11)),
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
            PayslipFieldsEditor(
              controllers: payslipNumCtrls,
              // The deposited amount is this income's main amount field.
              exclude: const {'depositedAmount'},
              customFields: payslipCustomFields,
              onCustomChanged: (list) => setState(() {
                payslipCustomFields = list;
                _dirty = true;
              }),
              onLayoutChanged: () => setState(() {}),
            ),
          ],
          const SizedBox(height: 16),
          _recurrenceSection(),
          const SizedBox(height: 8),
          Text(
            'پیش‌نویس‌ها در هیچ محاسبه‌ای لحاظ نمی‌شوند تا زمانی که ثبت نهایی شوند.',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 8),
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
        ? formatAmountInput(existing.initialBalance)
        : '');
    AccountType type = existing?.type ?? AccountType.bank;
    final mainCur = mainCurrencyOf(accounts);
    String currency = existing?.currency ?? mainCur;
    // Once an account exists, its currency is locked - except Rial/Toman,
    // which can be freely toggled between each other (a fixed x10 / x0.1
    // relationship, so no rate needs to be typed in for that swap).
    final currencyLocked = existing != null && !(existing.currency == 'IRR' || existing.currency == 'IRT');
    final rateCtrl = TextEditingController(text: existing != null && existing.exchangeRateToMain != 1.0 ? formatAmountInput(existing.exchangeRateToMain, maxDecimals: 6) : '');
    final result = await showDialog<Account>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        // A rate is asked for only once, when a NEW account is first given a
        // currency that differs from the main account's - after that its
        // currency can't change (other than the fixed Rial/Toman swap), so
        // there's nothing left to ask a rate for at this dialog.
        final needsRate = existing == null && accounts.isNotEmpty && currency != mainCur;
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
                if (currencyLocked)
                  InputDecorator(
                    decoration: const InputDecoration(labelText: 'واحد پول', helperText: 'واحد پول یک حساب بعد از ساختنش قابل تغییر نیست.', helperMaxLines: 2),
                    child: Text(currencyLabel(currency)),
                  )
                else
                  DropdownButtonFormField<String>(
                    initialValue: currency,
                    decoration: const InputDecoration(labelText: 'واحد پول'),
                    items: (existing == null ? kCurrencies : const ['IRR', 'IRT'])
                        .map((c) => DropdownMenuItem(value: c, child: Text(currencyLabel(c))))
                        .toList(),
                    onChanged: (v) => setLocal(() => currency = v ?? currency),
                  ),
                if (needsRate) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: Colors.amber.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
                    child: const Text(
                      'در انتخاب واحد پول این حساب دقت کن - بعد از ساختن حساب، واحدش دیگه قابل تغییر نیست (به‌جز جابه‌جایی ریال/تومان).',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: rateCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: const [AmountInputFormatter()],
                    decoration: InputDecoration(
                      labelText: '۱ ${currencyLabel(currency)} = ? ${currencyLabel(mainCur)}',
                      helperText: 'برای نمایش موجودی کل به واحد حساب اصلی در صفحه‌ی اصلی لازمه.',
                      helperMaxLines: 2,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: balanceCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                  inputFormatters: const [AmountInputFormatter(allowNegative: true)],
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
                  initialBalance: parseAmount(balanceCtrl.text) ?? 0,
                  exchangeRateToMain: needsRate
                      ? (parseAmount(rateCtrl.text) ?? 1.0)
                      : (existing?.exchangeRateToMain ?? 1.0),
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
    if (existing != null && result.currency != existing.currency) {
      // Only the fixed Rial/Toman swap can reach here (the dropdown allows
      // nothing else once an account exists) - apply its fixed factor
      // directly, no rate entry needed.
      await _swapRialToman(existing, result);
      return;
    }
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

  /// Edits just the exchange rate to the main account's currency - the only
  /// thing about a non-main account's currency that can change after it's
  /// created.
  Future<void> _editExchangeRate(Account a) async {
    final mainCur = mainCurrencyOf(accounts);
    final rateCtrl = TextEditingController(text: formatAmountInput(a.exchangeRateToMain, maxDecimals: 6));
    final rate = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('ویرایش ضریب تبدیل'),
        content: TextField(
          controller: rateCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: const [AmountInputFormatter()],
          decoration: InputDecoration(labelText: '۱ ${currencyLabel(a.currency)} = ? ${currencyLabel(mainCur)}', border: const OutlineInputBorder()),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, parseAmount(rateCtrl.text)), child: Text(tr('save'))),
        ],
      ),
    );
    if (rate == null || rate <= 0) return;
    setState(() {
      final idx = accounts.indexWhere((x) => x.id == a.id);
      if (idx >= 0) accounts[idx] = accounts[idx].copyWith(exchangeRateToMain: rate);
    });
    await Store.saveAccounts(accounts);
  }

  /// Rial <-> Toman is the only currency swap allowed on an existing
  /// account, and its factor is always exactly 10 (1 Toman = 10 Rial), so
  /// unlike a real currency change there's nothing to ask the person - just
  /// confirm and apply it, optionally to every other account in the old unit
  /// too.
  Future<void> _swapRialToman(Account old, Account edited) async {
    final factor = old.currency == 'IRR' ? 0.1 : 10.0; // IRR->IRT or IRT->IRR
    final others = accounts.where((a) => a.id != old.id && a.currency == old.currency).toList();
    final hasMixedCurrencies = accounts.any((a) => a.currency != old.currency && a.currency != edited.currency);
    if (hasMixedCurrencies) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('پیشنهاد پشتیبان‌گیری'),
          content: const Text(
            'چون حساب‌هایی با واحدهای پول مختلف داری، پیشنهاد می‌شه قبل از ادامه، از «تنظیمات › پشتیبان‌گیری و بازیابی» یه نسخه‌ی پشتیبان بگیری.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('متوجه‌ام، ادامه بده')),
          ],
        ),
      );
      if (proceed != true) return;
    }
    var convertOthers = others.isNotEmpty;
    if (!context.mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('تبدیل ریال/تومان'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'واحد این حساب از «${currencyLabel(old.currency)}» به «${currencyLabel(edited.currency)}» تغییر می‌کند '
                '(با ضریب ثابت ${old.currency == 'IRR' ? '۰٫۱' : '۱۰'}). همه‌ی مبلغ‌های این حساب متناسب با آن تبدیل می‌شوند.',
                style: const TextStyle(fontSize: 13, height: 1.6),
              ),
              if (others.isNotEmpty) ...[
                const SizedBox(height: 8),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: convertOthers,
                  onChanged: (v) => setLocal(() => convertOthers = v ?? false),
                  title: Text(
                    'حساب‌های دیگری با همین واحد (${others.map((a) => a.name).join('، ')}) هم تبدیل شوند',
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('cancel'))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('تبدیل')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final isMainAccount = accounts.isNotEmpty && accounts.first.id == old.id;
    final accs = await Store.loadAccounts();
    await Store.saveAccounts([for (final a in accs) a.id == old.id ? edited.copyWith(currency: old.currency) : a]);
    final convertedIds = {old.id, if (convertOthers) ...others.map((a) => a.id)};
    await Store.convertAccountsCurrency(
      accountIds: convertedIds,
      newCurrency: edited.currency,
      factor: factor,
    );
    if (isMainAccount) {
      // The main account's currency itself just changed - every OTHER
      // account's exchangeRateToMain is "1 of its currency = ? of the main
      // currency", so it needs the same x10 / x0.1 factor applied to stay
      // correct against the new main currency (accounts already converted
      // above, i.e. still in Rial/Toman, don't need this - their rate to
      // the main currency is always 1).
      final afterSwap = await Store.loadAccounts();
      final rescaled = [
        for (final a in afterSwap)
          convertedIds.contains(a.id) ? a : a.copyWith(exchangeRateToMain: roundMoney(a.exchangeRateToMain * factor)),
      ];
      await Store.saveAccounts(rescaled);
    }
    final fresh = await Store.loadAccounts();
    if (!mounted) return;
    setState(() => accounts = fresh);
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
    final mainCur = mainCurrencyOf(accounts);
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
                      a.currency != mainCur
                          ? '${a.type.label} • ${currencyLabel(a.currency)} • نرخ به ${currencyLabel(mainCur)}: ${formatAmountInput(a.exchangeRateToMain, maxDecimals: 6)}'
                          : (a.initialBalance != 0
                              ? '${a.type.label} • ${currencyLabel(a.currency)} • موجودی اولیه: ${ltr(formatMoney(a.initialBalance, a.currency))}'
                              : '${a.type.label} • ${currencyLabel(a.currency)}'),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (a.currency != mainCur)
                          IconButton(
                            icon: const Icon(Icons.currency_exchange, size: 20),
                            tooltip: 'ویرایش ضریب تبدیل',
                            onPressed: () => _editExchangeRate(a),
                          ),
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
