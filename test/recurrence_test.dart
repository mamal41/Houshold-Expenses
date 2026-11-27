// A recurring series' own date is its first payment. When that date was not
// on the series' due day (saved on the 27th, due on the 15th), the first
// payment silently landed on the 27th and the 15th of that month had none.
// These check that it is noticed, asked about and fixed.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:personal_finance/main.dart';

Transaction series(DateTime date, {RecurrenceFrequency f = RecurrenceFrequency.monthly, int? day, int? weekday, int? installments, DateTime? end}) =>
    Transaction(
      id: 'loan',
      type: TxType.expense,
      amount: 100,
      categoryId: 'e_misc',
      accountId: 'default',
      date: date,
      recurrence: f,
      recurrenceDay: day,
      recurrenceWeekday: weekday,
      installments: installments,
      recurrenceEndDate: end,
    );

Future<void> pumpFor(WidgetTester tester, [int steps = 8]) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

void main() {
  setUp(() {
    currentLanguage.value = AppLanguage.fa;
    currentCalendarSystem.value = CalendarSystem.gregorian;
  });

  test('a first payment off the due day is found, with the due days around it', () {
    const f = RecurrenceFrequency.monthly;
    expect(offRulePaymentDays(f, DateTime(2026, 11, 27), day: 15), (before: DateTime(2026, 11, 15), after: DateTime(2026, 12, 15)));
    expect(offRulePaymentDays(f, DateTime(2026, 11, 5), day: 15), (before: DateTime(2026, 10, 15), after: DateTime(2026, 11, 15)));
    expect(offRulePaymentDays(f, DateTime(2026, 11, 15), day: 15), isNull);
    // Day 31 is the last day of a shorter month.
    expect(offRulePaymentDays(f, DateTime(2026, 11, 30), day: 31), isNull);
    expect(offRulePaymentDays(f, DateTime(2027, 2, 28), day: 30), isNull);
    expect(offRulePaymentDays(RecurrenceFrequency.quarterly, DateTime(2026, 11, 27), day: 1),
        (before: DateTime(2026, 11, 1), after: DateTime(2026, 12, 1)));
    // Patterns without a due day are never off it.
    expect(offRulePaymentDays(RecurrenceFrequency.yearly, DateTime(2026, 11, 27), day: 15), isNull);
    expect(offRulePaymentDays(RecurrenceFrequency.custom, DateTime(2026, 11, 27), day: 15), isNull);
  });

  test('weekly: the chosen weekday just before and after the date', () {
    final thursday = DateTime(2026, 11, 26);
    expect(thursday.weekday, DateTime.thursday);
    expect(offRulePaymentDays(RecurrenceFrequency.weekly, thursday, weekday: DateTime.monday),
        (before: DateTime(2026, 11, 23), after: DateTime(2026, 11, 30)));
    expect(offRulePaymentDays(RecurrenceFrequency.weekly, thursday, weekday: DateTime.thursday), isNull);
    // A saved weekly series pays every 7 days from its date - and says so,
    // whatever weekday was stored with it.
    final w = series(thursday, f: RecurrenceFrequency.weekly, weekday: DateTime.monday, installments: 3);
    expect(computeRecurrenceOccurrences(w), [thursday, DateTime(2026, 12, 3), DateTime(2026, 12, 10)]);
    expect(offRuleOf(w), isNull);
    expect(recurrenceLabelOf(w), contains('پنجشنبه'));
  });

  test('Jalali: the due day counts in Jalali months', () {
    currentCalendarSystem.value = CalendarSystem.jalali;
    // 6 Azar 1405, due on the 15th of each Jalali month.
    final d = DateTime(2026, 11, 27);
    expect(gregorianToJalali(2026, 11, 27), [1405, 9, 6]);
    final j15Azar = jalaliToGregorian(1405, 9, 15);
    final j15Aban = jalaliToGregorian(1405, 8, 15);
    expect(offRulePaymentDays(RecurrenceFrequency.monthly, d, day: 15),
        (before: DateTime(j15Aban[0], j15Aban[1], j15Aban[2]), after: DateTime(j15Azar[0], j15Azar[1], j15Azar[2])));
    expect(offRulePaymentDays(RecurrenceFrequency.monthly, d, day: 6), isNull);
  });

  testWidgets('the question lists each choice with its payments and returns the one picked', (tester) async {
    tester.view.physicalSize = const Size(1000, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // Saved on 27 Nov, due on the 15th, the last payment on 15 Apr.
    final s = series(DateTime(2026, 11, 27), day: 15, end: DateTime(2027, 4, 15));
    FirstPaymentFix? picked;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(child: ElevatedButton(onPressed: () async => picked = await askFirstPayment(context, s), child: const Text('ask'))),
        ),
      ),
    ));
    await tester.tap(find.text('ask'));
    await pumpFor(tester);
    expect(find.text('اولین پرداخت کدام روز است؟'), findsOneWidget);
    String outline(DateTime first, int? day) => recurrenceOutline(s.copyWith(date: first, recurrenceDay: day));
    // The due day before the date: 15 Nov - 15 Apr, 6 payments; after it:
    // 15 Dec - 15 Apr, 5; every payment on the 27th: 27 Nov - 27 Mar, 5; as
    // saved: 27 Nov, then the 15th, 6.
    expect(find.text(outline(DateTime(2026, 11, 15), 15)), findsOneWidget);
    expect(find.text(outline(DateTime(2026, 12, 15), 15)), findsOneWidget);
    expect(find.text(outline(DateTime(2026, 11, 27), 27)), findsOneWidget);
    expect(find.text(outline(DateTime(2026, 11, 27), 15)), findsOneWidget);
    expect(computeRecurrenceOccurrences(s.copyWith(date: DateTime(2026, 12, 15))).length, 5);
    expect(computeRecurrenceOccurrences(s.copyWith(date: DateTime(2026, 11, 15))).length, 6);
    await tester.tap(find.text(locf('اولین پرداخت: {0}', [formatDate(DateTime(2026, 12, 15))])));
    await pumpFor(tester);
    expect(picked, (date: DateTime(2026, 12, 15), day: 15, weekday: null));
  });

  testWidgets('the editor starts the due day at the date, and asks when it is set apart', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1000, 5000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final categories = await Store.loadCategories();
    final accounts = await Store.loadAccounts();
    final expenseCat = categories.firstWhere((c) => c.type == TxType.expense && !c.id.startsWith('_'));
    final start = Transaction(id: 'x', type: TxType.expense, amount: 100, categoryId: expenseCat.id, accountId: accounts.first.id, date: DateTime(2026, 11, 27));
    Object? saved;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () async => saved = await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => TransactionEditor(categories: categories, accounts: accounts, existing: start)),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await pumpFor(tester, 12);
    // Monthly: the due day starts as the date's own day (27).
    await tester.tap(find.byType(DropdownButtonFormField<RecurrenceFrequency>));
    await pumpFor(tester);
    await tester.tap(find.text('ماهانه (روز مشخصی از ماه)').last);
    await pumpFor(tester);
    final dayField = find.widgetWithText(TextField, persianDigits('27'));
    expect(dayField, findsOneWidget);
    // Set apart: due on the 15th, 5 payments.
    await tester.enterText(dayField, '15');
    await tester.tap(find.text('تعداد قسط'));
    await pumpFor(tester);
    await tester.enterText(find.widgetWithText(TextField, tr('total_installments')), '5');
    await pumpFor(tester);
    // The form already says the first payment is off the due day.
    expect(find.textContaining(locf('تاریخ تراکنش ({0}) روز {1} ماه نیست', [formatDate(DateTime(2026, 11, 27)), persianDigits('15')])), findsOneWidget);
    await tester.tap(find.text('ذخیره تغییرات').first);
    await pumpFor(tester, 12);
    expect(find.text('اولین پرداخت کدام روز است؟'), findsOneWidget);
    await tester.tap(find.descendant(
      of: find.byType(SimpleDialog),
      matching: find.text(locf('اولین پرداخت: {0}', [formatDate(DateTime(2026, 12, 15))])),
    ));
    await pumpFor(tester, 12);
    expect(saved, isA<Transaction>());
    final t = saved as Transaction;
    expect(t.date, DateTime(2026, 12, 15));
    expect(t.recurrenceDay, 15);
    expect(t.installments, 5);
    expect(computeRecurrenceOccurrences(t), [
      DateTime(2026, 12, 15),
      DateTime(2027, 1, 15),
      DateTime(2027, 2, 15),
      DateTime(2027, 3, 15),
      DateTime(2027, 4, 15),
    ]);
  });

  testWidgets('a series saved off its due day is flagged in the recurring list and can be fixed there', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1000, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final now = DateTime.now();
    // Saved with the 27th of next month, due on the 15th, 6 payments.
    final first = DateTime(now.year, now.month + 1, 27);
    await Store.saveTransactions([series(first, day: 15, installments: 6)]);
    await tester.pumpWidget(const MaterialApp(home: RecurringTransactionsScreen()));
    await pumpFor(tester, 10);
    final flag = locf('اولین پرداخت ({0}) روز {1} ماه نیست', [formatDate(first), persianDigits('15')]);
    expect(find.text(flag), findsOneWidget);
    await tester.tap(find.text('بررسی'));
    await pumpFor(tester);
    final due = DateTime(now.year, now.month + 2, 15);
    await tester.tap(find.text(locf('اولین پرداخت: {0}', [formatDate(due)])));
    await pumpFor(tester, 10);
    final stored = (await Store.loadTransactions()).single;
    expect(stored.date, due);
    expect(stored.recurrenceDay, 15);
    expect(find.text(flag), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
