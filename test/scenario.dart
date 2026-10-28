// Test data: two years of household finances, and an independent reference
// calculation to check the app's numbers against.
import 'dart:math';

import 'package:personal_finance/main.dart';

DateTime d(int y, int m, int day) => DateTime(y, m, day);
DateTime dayOnly(DateTime x) => DateTime(x.year, x.month, x.day);

class Scenario {
  final String currency;
  final List<Account> accounts;
  final List<Transaction> tx;
  final List<BudgetGoal> budgetGoals;
  final List<SavingsGoal> savingsGoals;
  final List<SavingsContribution> contributions;
  Scenario(this.currency, this.accounts, this.tx, this.budgetGoals, this.savingsGoals, this.contributions);
}

/// Amount scale per currency (Toman amounts are big whole numbers).
double scale(String cur) => switch (cur) { 'IRT' => 50000, _ => 1 };
double money(String cur, double v) => cur == 'IRT' ? (v * scale(cur)).roundToDouble() : (v * 100).roundToDouble() / 100;

Scenario buildScenario(String cur, {int seed = 7}) {
  final rnd = Random(seed);
  final now = DateTime.now();
  final today = dayOnly(now);
  final start = DateTime(today.year - 2, today.month, 1);
  double m(double v) => money(cur, v);
  final accounts = [
    Account(id: 'giro', name: 'Giro', type: AccountType.bank, currency: cur, initialBalance: m(2500)),
    Account(id: 'save', name: 'Savings', type: AccountType.savings, currency: cur, initialBalance: m(2000)),
    Account(id: 'cash', name: 'Cash', type: AccountType.cash, currency: cur, initialBalance: m(150)),
    Account(id: 'card', name: 'Credit card', type: AccountType.creditCard, currency: cur, initialBalance: 0),
    Account(id: 'biz', name: 'Business', type: AccountType.bank, currency: cur, initialBalance: m(1000)),
  ];
  final tx = <Transaction>[];
  var n = 0;
  String id() => 't${n++}';
  // --- recurring, every kind
  tx.add(Transaction(id: 'rent', type: TxType.expense, amount: m(950), categoryId: 'e_housing_rent', accountId: 'giro',
      date: d(start.year, start.month, 1), recurrence: RecurrenceFrequency.monthly, recurrenceDay: 1, merchant: 'Landlord',
      notifyEnabled: true, notifyDaysBeforeEach: 2));
  tx.add(Transaction(id: 'salary', type: TxType.income, amount: m(3200), categoryId: 'i_salary', accountId: 'giro',
      date: d(start.year, start.month, 28), recurrence: RecurrenceFrequency.monthly, recurrenceDay: 28));
  tx.add(Transaction(id: 'phone', type: TxType.expense, amount: m(39.99), categoryId: 'e_bills_phone', accountId: 'giro',
      date: d(start.year, start.month + 2, 15), recurrence: RecurrenceFrequency.monthly, recurrenceDay: 15, installments: 24,
      notifyEnabled: true, notifyLastTwoEnabled: true, merchant: 'Telekom'));
  tx.add(Transaction(id: 'insurance', type: TxType.expense, amount: m(180), categoryId: 'e_insurance', accountId: 'giro',
      date: d(start.year, start.month + 1, 10), recurrence: RecurrenceFrequency.quarterly, recurrenceDay: 10));
  tx.add(Transaction(id: 'gym', type: TxType.expense, amount: m(9.99), categoryId: 'e_leisure', accountId: 'card',
      date: d(start.year, start.month + 4, 3), recurrence: RecurrenceFrequency.weekly, recurrenceWeekday: d(start.year, start.month + 4, 3).weekday,
      recurrenceEndDate: DateTime(today.year, today.month + 2, 28), merchant: 'FitX'));
  tx.add(Transaction(id: 'fuel', type: TxType.expense, amount: m(45), categoryId: 'e_car_fuel', accountId: 'card',
      date: d(start.year, start.month + 7, 1), recurrence: RecurrenceFrequency.custom, recurrenceIntervalDays: 14, installments: 40,
      merchant: 'Aral'));
  tx.add(Transaction(id: 'software', type: TxType.expense, amount: m(89), categoryId: 'e_subscription_software', accountId: 'biz',
      date: d(start.year, start.month + 3, 20), recurrence: RecurrenceFrequency.yearly));
  tx.add(Transaction(id: 'carloan', type: TxType.expense, amount: m(300), categoryId: 'e_loans_car', accountId: 'giro',
      date: d(start.year + 1, 8, 31), recurrence: RecurrenceFrequency.monthly, recurrenceDay: 31, installments: 18,
      notifyEnabled: true, notifyLastTwoEnabled: true));
  // a recurring transfer (both legs recurring)
  tx.add(Transaction(id: 'tr1_out', type: TxType.expense, amount: m(200), categoryId: '_transfer_out_', accountId: 'giro',
      date: d(start.year, start.month, 5), recurrence: RecurrenceFrequency.monthly, recurrenceDay: 5, note: 'to savings'));
  tx.add(Transaction(id: 'tr1_in', type: TxType.income, amount: m(200), categoryId: '_transfer_in_', accountId: 'save',
      date: d(start.year, start.month, 5), recurrence: RecurrenceFrequency.monthly, recurrenceDay: 5, note: 'from giro'));
  // --- one-off expenses
  const shops = {
    'e_food_market': ['REWE', 'Lidl', 'Aldi', 'Edeka'],
    'e_food_restaurant': ['Pizzeria Roma', 'Sushi Bar', 'Cafe Central'],
    'e_food_produce': ['Market stall'],
    'e_clothing': ['H&M', 'Zara'],
    'e_health': ['Pharmacy'],
    'e_leisure': ['Cinema', 'Bookshop'],
    'e_transport_public': ['DB'],
    'e_housing_repair': ['Bauhaus'],
    'e_misc': ['Amazon'],
  };
  final cats = shops.keys.toList();
  final days = today.difference(start).inDays;
  for (var i = 0; i < 900; i++) {
    final c = cats[rnd.nextInt(cats.length)];
    final shop = shops[c]![rnd.nextInt(shops[c]!.length)];
    final date = start.add(Duration(days: rnd.nextInt(days + 1)));
    final acc = ['giro', 'cash', 'card', 'card', 'giro'][rnd.nextInt(5)];
    final amount = m(2 + rnd.nextDouble() * 120);
    final items = c == 'e_clothing'
        ? [ReceiptItemEntry(name: 'Jacket ${i % 7}', price: amount, returnUntil: date.add(const Duration(days: 30)))]
        : (c == 'e_food_market' && rnd.nextBool() ? [ReceiptItemEntry(name: 'Milk', price: m(1.2)), ReceiptItemEntry(name: 'Bread', price: m(2.5))] : <ReceiptItemEntry>[]);
    tx.add(Transaction(id: id(), type: TxType.expense, amount: amount, categoryId: c, accountId: acc, date: dayOnly(date), merchant: shop, items: items));
  }
  // --- one-off incomes
  for (var i = 0; i < 24; i++) {
    final date = start.add(Duration(days: rnd.nextInt(days + 1)));
    tx.add(Transaction(id: id(), type: TxType.income, amount: m(100 + rnd.nextDouble() * 900), categoryId: i.isEven ? 'i_freelance' : 'i_gift',
        accountId: i.isEven ? 'biz' : 'cash', date: dayOnly(date)));
  }
  // --- one-off transfers
  for (var i = 0; i < 15; i++) {
    final date = dayOnly(start.add(Duration(days: rnd.nextInt(days + 1))));
    final a = m(50 + rnd.nextDouble() * 300);
    tx.add(Transaction(id: 'x${i}_out', type: TxType.expense, amount: a, categoryId: '_transfer_out_', accountId: 'giro', date: date));
    tx.add(Transaction(id: 'x${i}_in', type: TxType.income, amount: a, categoryId: '_transfer_in_', accountId: 'cash', date: date));
  }
  // --- future-dated (planned) and drafts (must count nowhere)
  for (var i = 0; i < 5; i++) {
    tx.add(Transaction(id: id(), type: TxType.expense, amount: m(20 + i * 10), categoryId: 'e_misc', accountId: 'giro',
        date: today.add(Duration(days: 3 + i * 9)), merchant: 'Planned $i'));
  }
  for (var i = 0; i < 10; i++) {
    tx.add(Transaction(id: 'bank_draft_$i', type: TxType.expense, amount: m(500), categoryId: 'e_misc', accountId: 'giro',
        date: today.subtract(Duration(days: i)), draft: true, merchant: 'Draft $i'));
  }
  final budgetGoals = [BudgetGoal(categoryId: 'e_food', monthlyAmount: m(400)), BudgetGoal(categoryId: 'e_leisure', monthlyAmount: m(100))];
  final savingsGoals = [
    SavingsGoal(id: 'g1', name: 'Car', targetAmount: m(8000), targetDate: DateTime(today.year + 1, today.month, 1), currency: cur),
    SavingsGoal(id: 'g2', name: 'Trip', targetAmount: m(1500), currency: cur),
  ];
  final contributions = [
    for (var i = 0; i < 12; i++) SavingsContribution(id: 'c$i', goalId: i.isEven ? 'g1' : 'g2', amount: m(150), date: start.add(Duration(days: 30 * i))),
  ];
  return Scenario(cur, accounts, tx, budgetGoals, savingsGoals, contributions);
}

// ---------------------------------------------------------------------------
// Reference calculation (Gregorian calendar), written independently of the app.

int daysIn(int y, int m) => DateTime(y, m + 1, 0).day;
DateTime monthDay(int y, int m, int day) {
  final t = y * 12 + (m - 1);
  final yy = t ~/ 12, mm = t % 12 + 1;
  return DateTime(yy, mm, min(day, daysIn(yy, mm)));
}

/// Jalali month [addMonths] after the Jalali month of [ref], on [day]
/// (clamped to that month's length: 31 days in months 1-6, 30 in 7-11,
/// 29 or 30 in Esfand).
DateTime jalaliMonthDay(DateTime ref, int addMonths, int day) {
  final j = gregorianToJalali(ref.year, ref.month, ref.day);
  final t = j[0] * 12 + (j[1] - 1) + addMonths;
  final y = t ~/ 12, m = t % 12 + 1;
  final firstOfMonth = jalaliToGregorian(y, m, 1);
  final firstOfNext = m == 12 ? jalaliToGregorian(y + 1, 1, 1) : jalaliToGregorian(y, m + 1, 1);
  final len = DateTime.utc(firstOfNext[0], firstOfNext[1], firstOfNext[2])
      .difference(DateTime.utc(firstOfMonth[0], firstOfMonth[1], firstOfMonth[2]))
      .inDays;
  final g = jalaliToGregorian(y, m, min(day, len));
  return DateTime(g[0], g[1], g[2]);
}

/// All payment dates of a recurring transaction (up to [until]).
List<DateTime> refOccurrences(Transaction t, DateTime until, {bool jalali = false}) {
  final s = dayOnly(t.date);
  final ownDay = jalali ? gregorianToJalali(s.year, s.month, s.day)[2] : s.day;
  DateTime monthly(int add, int day) => jalali ? jalaliMonthDay(s, add, day) : monthDay(s.year, s.month + add, day);
  final out = <DateTime>[];
  for (var i = 0; i < 100000; i++) {
    DateTime c;
    switch (t.recurrence) {
      case RecurrenceFrequency.monthly:
        c = i == 0 ? s : monthly(i, t.recurrenceDay ?? ownDay);
      case RecurrenceFrequency.quarterly:
        c = i == 0 ? s : monthly(3 * i, t.recurrenceDay ?? ownDay);
      case RecurrenceFrequency.weekly:
        c = DateTime(s.year, s.month, s.day + 7 * i);
      case RecurrenceFrequency.custom:
        c = DateTime(s.year, s.month, s.day + (t.recurrenceIntervalDays ?? 30) * i);
      case RecurrenceFrequency.yearly:
        c = i == 0 ? s : monthly(12 * i, ownDay);
      case RecurrenceFrequency.none:
        return [s];
    }
    if (c.isAfter(until)) break;
    if (t.recurrenceEndDate != null && c.isAfter(dayOnly(t.recurrenceEndDate!))) break;
    out.add(c);
    if (t.installments != null && out.length >= t.installments!) break;
  }
  return out;
}

class Booking {
  final DateTime date;
  final Transaction t;
  Booking(this.date, this.t);
  double get signed => t.type == TxType.income ? t.amount : -t.amount;
  bool get isTransfer => t.categoryId.startsWith('_transfer');
}

/// Every booking (real or a recurring payment) up to [until], drafts left out.
List<Booking> refBookings(List<Transaction> tx, DateTime until, {bool jalali = false}) => [
      for (final t in tx)
        if (!t.draft)
          for (final dd in refOccurrences(t, until, jalali: jalali)) Booking(dd, t),
    ];

/// Start and end of the calendar month [offset] months from [d].
({DateTime start, DateTime end}) refMonth(DateTime d, int offset, {bool jalali = false}) {
  if (!jalali) {
    return (start: DateTime(d.year, d.month + offset, 1), end: DateTime(d.year, d.month + offset + 1, 0));
  }
  final start = jalaliMonthDay(d, offset, 1);
  final next = jalaliMonthDay(d, offset + 1, 1);
  return (start: start, end: DateTime(next.year, next.month, next.day - 1));
}
