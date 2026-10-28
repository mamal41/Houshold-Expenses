// End-to-end check of the app's calculations with two years of data:
// the numbers shown on the screens are compared with an independent
// reference calculation (test/scenario.dart). Run per currency: Euro and
// Dollar with the Gregorian calendar in English, Toman with the Jalali
// calendar in Persian.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:personal_finance/main.dart';

import 'scenario.dart';

class Config {
  final String currency;
  final bool jalali;
  final AppLanguage language;
  const Config(this.currency, this.jalali, this.language);
}

const configs = [
  Config('EUR', false, AppLanguage.en),
  Config('IRT', true, AppLanguage.fa),
  Config('USD', false, AppLanguage.en),
];

Future<void> seed(Scenario s, Config c) async {
  SharedPreferences.setMockInitialValues({});
  await Store.saveLanguage(c.language);
  final cal = c.jalali ? CalendarSystem.jalali : CalendarSystem.gregorian;
  await Store.saveCalendarSystem(cal);
  currentLanguage.value = c.language;
  currentCalendarSystem.value = cal;
  await Store.saveAccounts(s.accounts);
  await Store.saveTransactions(s.tx);
  await Store.saveBudgetGoals(s.budgetGoals);
  await Store.saveSavingsGoals(s.savingsGoals);
  await Store.saveSavingsContributions(s.contributions);
}

List<String> textsOf(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
    .toList();

Future<void> show(WidgetTester tester, Widget screen) async {
  tester.view.physicalSize = const Size(1200, 40000);
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(MaterialApp(home: screen));
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

Future<void> close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 3));
}

double sum(Iterable<Booking> b) => b.fold(0.0, (a, x) => a + x.t.amount);

void main() {
  for (final c in configs) {
    final cur = c.currency;
    group('$cur (${c.jalali ? 'Jalali' : 'Gregorian'})', () {
      final s = buildScenario(cur);
      final today = dayOnly(DateTime.now());
      final m0 = refMonth(today, 0, jalali: c.jalali);
      final all = refBookings(s.tx, DateTime(today.year + 3, 12, 31), jalali: c.jalali);
      final past = all.where((b) => !b.date.isAfter(today)).toList();
      final initial = s.accounts.fold(0.0, (a, x) => a + x.initialBalance);
      final balance = initial + past.fold(0.0, (a, b) => a + b.signed);
      bool inRange(DateTime d, DateTime from, DateTime to) => !d.isBefore(from) && !d.isAfter(to);
      final thisMonth = past.where((b) => !b.date.isBefore(m0.start) && !b.isTransfer).toList();
      final monthIncome = sum(thisMonth.where((b) => b.t.type == TxType.income));
      final monthExpense = sum(thisMonth.where((b) => b.t.type == TxType.expense));
      final notDueThisMonth = all.where((b) => b.date.isAfter(today) && !b.date.isAfter(m0.end) && !b.isTransfer).toList();
      late List<Category> categories;
      String topOf(String id) {
        var cat = categories.firstWhere((x) => x.id == id);
        while (cat.parentId != null) {
          cat = categories.firstWhere((x) => x.id == cat.parentId);
        }
        return cat.id;
      }

      String nameOf(String id) => categories.firstWhere((x) => x.id == id).name;
      String money(double v) => formatMoney(v, cur);

      // Matches the shown amount, allowing for a cent of rounding.
      bool showsMoney(WidgetTester tester, double v) {
        final texts = textsOf(tester);
        final step = cur == 'IRT' ? 1.0 : 0.01;
        return [v, v - step, v + step].any((x) => texts.any((t) => t.contains(money(x))));
      }

      // Text right after the first text equal to [label].
      String? after(WidgetTester tester, String label) {
        final texts = textsOf(tester);
        final i = texts.indexOf(label);
        return i < 0 || i + 1 >= texts.length ? null : texts[i + 1];
      }

      void expectMoney(WidgetTester tester, String what, double v) {
        expect(showsMoney(tester, v), isTrue, reason: '$cur $what: expected ${money(v)}');
      }

      setUp(() async {
        await seed(s, c);
        categories = await Store.loadCategories();
      });

      test('recurring dates (every kind)', () {
        currentCalendarSystem.value = c.jalali ? CalendarSystem.jalali : CalendarSystem.gregorian;
        final horizon = DateTime(today.year + 3, today.month, today.day);
        for (final t in s.tx.where((t) => t.isRecurring)) {
          expect(computeRecurrenceOccurrences(t), refOccurrences(t, horizon, jalali: c.jalali), reason: '${t.id} ${t.recurrence}');
        }
      });

      testWidgets('home', (tester) async {
        await show(tester, const HomeScreen());
        expectMoney(tester, 'balance as of today', balance);
        expectMoney(tester, 'month income (no transfers)', monthIncome);
        expectMoney(tester, 'month expense (no transfers)', monthExpense);
        final upcoming = all.where((b) => b.date.isAfter(today) && !b.date.isAfter(m0.end));
        final safe = balance +
            upcoming.fold(0.0, (a, b) => a + (b.t.type == TxType.expense ? -b.t.amount : (b.t.categoryId == '_transfer_in_' ? b.t.amount : 0)));
        expectMoney(tester, 'safe to spend', safe.abs());
        await close(tester);
      });

      testWidgets('month calendar', (tester) async {
        await show(tester, const MonthCalendarScreen());
        expectMoney(tester, 'calendar income so far', monthIncome);
        expectMoney(tester, 'calendar expense so far', monthExpense);
        expectMoney(tester, 'calendar not yet due expense', sum(notDueThisMonth.where((b) => b.t.type == TxType.expense)));
        await close(tester);
      });

      testWidgets('reports (this month)', (tester) async {
        await show(tester, const ReportsScreen());
        expectMoney(tester, 'report income', monthIncome);
        expectMoney(tester, 'report expense', monthExpense);
        expectMoney(tester, 'report net', monthIncome - monthExpense);
        final byTop = <String, double>{};
        for (final b in thisMonth.where((b) => b.t.type == TxType.expense)) {
          byTop[topOf(b.t.categoryId)] = (byTop[topOf(b.t.categoryId)] ?? 0) + b.t.amount;
        }
        for (final e in byTop.entries) {
          final shown = after(tester, nameOf(e.key));
          expect(shown != null && [e.value - 0.01, e.value, e.value + 0.01].any((v) => shown.contains(money(v))), isTrue,
              reason: '$cur report category ${e.key}: expected ${money(e.value)}, shown $shown');
        }
        expect(textsOf(tester).contains(nameOf('_transfer_out_')), isFalse, reason: 'transfers listed as an expense category');
        await close(tester);
      });

      testWidgets('budget goals and zero-based budget', (tester) async {
        double spent(String top) => sum(thisMonth.where((b) => b.t.type == TxType.expense && topOf(b.t.categoryId) == top));
        await show(tester, const BudgetGoalsScreen());
        expectMoney(tester, 'budget food spent', spent('e_food'));
        expectMoney(tester, 'budget leisure spent', spent('e_leisure'));
        expect(textsOf(tester).contains(nameOf('_transfer_out_')), isFalse, reason: 'transfer category offered as a budget');
        await close(tester);
        await show(tester, const ZeroBasedBudgetScreen());
        // Nothing earned yet this month: the average of the last 3 months
        // that had income stands in.
        var income = monthIncome;
        if (income <= 0) {
          final past3 = [
            for (var i = 1; i <= 3; i++)
              () {
                final m = refMonth(today, -i, jalali: c.jalali);
                return sum(past.where((b) => b.t.type == TxType.income && !b.isTransfer && inRange(b.date, m.start, m.end)));
              }(),
          ].where((v) => v > 0).toList();
          income = past3.isEmpty ? 0 : past3.reduce((a, b) => a + b) / past3.length;
        }
        expectMoney(tester, 'zero-based income', income);
        expectMoney(tester, 'zero-based allocated', s.budgetGoals.fold(0.0, (a, g) => a + g.monthlyAmount));
        expect(textsOf(tester).contains(nameOf('_transfer_out_')), isFalse, reason: 'transfer category in zero-based budget');
        await close(tester);
      });

      testWidgets('accounts and net worth', (tester) async {
        await show(tester, const AccountManagementScreen());
        for (final a in s.accounts) {
          final v = a.initialBalance + past.where((b) => b.t.accountId == a.id).fold(0.0, (x, b) => x + b.signed);
          expectMoney(tester, 'account ${a.id} balance', v);
        }
        await close(tester);
        await show(tester, const NetWorthScreen());
        expectMoney(tester, 'net worth today', balance);
        await close(tester);
      });

      testWidgets('savings goals', (tester) async {
        await show(tester, const SavingsGoalsScreen());
        for (final g in s.savingsGoals) {
          expectMoney(tester, 'savings ${g.name}', s.contributions.where((x) => x.goalId == g.id).fold(0.0, (a, x) => a + x.amount));
        }
        await close(tester);
      });

      testWidgets('recurring list: next due', (tester) async {
        await show(tester, const RecurringTransactionsScreen());
        final texts = textsOf(tester);
        for (final t in s.tx.where((t) => t.isRecurring)) {
          final next = refOccurrences(t, DateTime(today.year + 3, 12, 31), jalali: c.jalali).where((d) => !d.isBefore(today));
          if (next.isEmpty) continue;
          expect(texts.any((x) => x.contains(formatDate(next.first))), isTrue, reason: '${t.id}: next due ${formatDate(next.first)}');
        }
        await close(tester);
      });

      testWidgets('upcoming payments', (tester) async {
        await show(tester, const UpcomingPaymentsScreen());
        bool upcomingExpense(Booking b) => b.t.type == TxType.expense && !b.isTransfer;
        // Until the end of this month: recurring payments from today on,
        // one-off transactions only when dated after today.
        final listed = all.where((b) =>
            upcomingExpense(b) &&
            !b.date.isAfter(m0.end) &&
            (b.t.isRecurring ? !b.date.isBefore(today) : b.date.isAfter(today)));
        expectMoney(tester, 'upcoming total this month', sum(listed));
        for (var i = 0; i < 4; i++) {
          final m = refMonth(today, i, jalali: c.jalali);
          final v = sum(all.where((b) =>
              upcomingExpense(b) && inRange(b.date, m.start, m.end) && (b.t.isRecurring || b.date.isAfter(today))));
          // Big amounts are shown shortened (e.g. "82.2 M").
          final compact = formatMoneyCompact(v, cur);
          expect(showsMoney(tester, v) || textsOf(tester).any((t) => t.contains(compact)), isTrue,
              reason: '$cur upcoming chart month +$i: expected ${money(v)}');
        }
        await close(tester);
      });

      testWidgets('forecast', (tester) async {
        await show(tester, const ForecastScreen());
        final monthNo = c.jalali ? gregorianToJalali(today.year, today.month, today.day)[1] : today.month;
        // The same calendar month in earlier years, when it's fully over.
        final spending = past.where((b) => b.t.type == TxType.expense && !b.isTransfer);
        var total = 0.0, years = 0;
        for (var k = 1; k <= 5; k++) {
          final m = refMonth(today, -12 * k, jalali: c.jalali);
          final inMonth = spending.where((b) => inRange(b.date, m.start, m.end));
          if (inMonth.isEmpty) continue;
          years++;
          total += sum(inMonth);
        }
        expect(monthNo, greaterThan(0));
        expectMoney(tester, 'forecast average ($years years)', years == 0 ? 0 : total / years);
        expectMoney(tester, 'forecast spent so far', monthExpense);
        expect(textsOf(tester).contains(nameOf('_transfer_out_')), isFalse, reason: 'transfers in forecast');
        await close(tester);
      });

      testWidgets('savings suggestion (last 3 months)', (tester) async {
        await show(tester, const SavingsSuggestionScreen());
        var inc = 0.0, exp = 0.0;
        for (var i = 1; i <= 3; i++) {
          final m = refMonth(today, -i, jalali: c.jalali);
          final b = past.where((b) => !b.isTransfer && inRange(b.date, m.start, m.end));
          inc += sum(b.where((b) => b.t.type == TxType.income));
          exp += sum(b.where((b) => b.t.type == TxType.expense));
        }
        expectMoney(tester, 'average income', inc / 3);
        expectMoney(tester, 'average expense', exp / 3);
        await close(tester);
      });

      testWidgets('all transactions', (tester) async {
        await show(tester, const AllTransactionsScreen());
        final stored = s.tx.where((t) => !t.draft).length;
        final dueRepeats = past.where((b) => b.t.isRecurring && b.date != dayOnly(b.t.date)).length;
        final texts = textsOf(tester);
        expect(texts.any((x) => x.contains(persianDigits('${stored + dueRepeats}'))), isTrue,
            reason: 'count: expected ${stored + dueRepeats}, shown ${texts.take(5).join(' | ')}');
        await close(tester);
      });
    });
  }

  test('Jalali calendar months match known dates', () {
    currentCalendarSystem.value = CalendarSystem.jalali;
    expect(jalaliToGregorian(1405, 1, 1), [2026, 3, 21]);
    expect(jalaliToGregorian(1405, 7, 1), [2026, 9, 23]);
    expect(jalaliToGregorian(1405, 8, 1), [2026, 10, 23]);
    expect(jalaliToGregorian(1403, 12, 30), [2025, 3, 20]); // 1403 is a leap year
    final m = calendarMonthOf(DateTime(2026, 10, 28));
    expect([m.start, m.end], [DateTime(2026, 10, 23), DateTime(2026, 11, 21)]);
    // A monthly payment on day 31 (from 31 Shahrivar) falls on the last day
    // of the 30-day months and of Esfand.
    final t = Transaction(id: 'x', type: TxType.expense, amount: 1, categoryId: 'e_misc', accountId: 'a',
        date: DateTime(2026, 9, 22), recurrence: RecurrenceFrequency.monthly, recurrenceDay: 31, installments: 7);
    expect(computeRecurrenceOccurrences(t), [
      DateTime(2026, 9, 22), // 31 Shahrivar
      DateTime(2026, 10, 22), // 30 Mehr
      DateTime(2026, 11, 21), // 30 Aban
      DateTime(2026, 12, 21), // 30 Azar
      DateTime(2027, 1, 20), // 30 Dey
      DateTime(2027, 2, 19), // 30 Bahman
      DateTime(2027, 3, 20), // 29 Esfand 1405
    ]);
    currentCalendarSystem.value = CalendarSystem.gregorian;
    final g = Transaction(id: 'y', type: TxType.expense, amount: 1, categoryId: 'e_misc', accountId: 'a',
        date: DateTime(2027, 1, 31), recurrence: RecurrenceFrequency.monthly, recurrenceDay: 31, installments: 4);
    expect(computeRecurrenceOccurrences(g), [DateTime(2027, 1, 31), DateTime(2027, 2, 28), DateTime(2027, 3, 31), DateTime(2027, 4, 30)]);
  });
}
