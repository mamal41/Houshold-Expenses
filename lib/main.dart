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

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Full-screen: hide the status bar and Android's gesture/nav bar; either
  // can be revealed temporarily by swiping from that edge, then auto-hides
  // again, so on-screen content never sits underneath the system bars.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
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
        TextButton(onPressed: () => Navigator.pop(ctx, 'cancel'), child: const Text('انصراف')),
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

enum RecurrenceFrequency { none, monthly, weekly, custom }

enum AccountType { cash, bank, creditCard, savings, other }

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

class Category {
  final String id;
  final String name;
  final String? parentId;
  final TxType type;
  const Category({required this.id, required this.name, this.parentId, required this.type});

  Category copyWith({String? name, String? parentId}) => Category(
        id: id,
        name: name ?? this.name,
        parentId: parentId ?? this.parentId,
        type: type,
      );

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'parentId': parentId, 'type': type.name};
  factory Category.fromJson(Map<String, dynamic> j) => Category(
        id: j['id'],
        name: j['name'],
        parentId: j['parentId'],
        type: TxType.values.byName(j['type']),
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
    case RecurrenceFrequency.none:
      return null;
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
  Category(id: 'e_misc', name: 'متفرقه', type: TxType.expense),
  Category(id: 'i_salary', name: 'حقوق', type: TxType.income),
  Category(id: 'i_freelance', name: 'فریلنسری', type: TxType.income),
  Category(id: 'i_investment', name: 'سرمایه‌گذاری', type: TxType.income),
  Category(id: 'i_gift', name: 'هدیه', type: TxType.income),
  Category(id: 'i_misc', name: 'متفرقه', type: TxType.income),
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
  'e_misc': Icons.more_horiz,
  'i_salary': Icons.payments_outlined,
  'i_freelance': Icons.laptop_mac_outlined,
  'i_investment': Icons.trending_up,
  'i_gift': Icons.card_giftcard_outlined,
  'i_misc': Icons.more_horiz,
};

IconData iconForCategory(Category? c, List<Category> all) {
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
    if (!list.any((c) => c.id == 'e_car_parking')) {
      list = [...list, ...defaultCategories.where((c) => c.id == 'e_car_parking')];
      changed = true;
    }
    if (changed) await saveCategories(list);
    return list;
  }

  static Future<void> saveCategories(List<Category> list) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(_catKey, list.map((c) => jsonEncode(c.toJson())).toList());
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
      title: 'مدیریت مالی شخصی',
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
                child: Text('مدیریت مالی شخصی', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
              ),
            ),
            item(0, Icons.home_outlined, 'خانه', () => const HomeScreen()),
            item(1, Icons.category_outlined, 'مدیریت دسته‌بندی‌ها', () => const CategoryManagementScreen()),
            item(2, Icons.account_balance_wallet_outlined, 'حساب‌ها', () => const AccountManagementScreen()),
            item(3, Icons.settings_outlined, 'تنظیمات', () => const SettingsScreen()),
            item(4, Icons.repeat, 'تراکنش‌های تکرارشونده', () => const RecurringTransactionsScreen()),
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
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('ذخیره شد.')));
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(title: const Text('تنظیمات')),
      drawer: const AppDrawer(currentIndex: 3),
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
          FilledButton(onPressed: _save, child: const Text('ذخیره')),
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
  final rendered = await page.render(
    width: page.width * 2,
    height: page.height * 2,
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
    resp = await http.post(uri, headers: {'Content-Type': 'application/json'}, body: body);
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
      throw Exception('سرورهای Gemini موقتاً شلوغ هستند. لطفاً چند لحظه دیگر دوباره امتحان کنید.');
    }
    throw Exception('خطای Gemini API (${code ?? '—'}): ${resp?.body ?? ''}');
  }
  final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
  final text = decoded['candidates']?[0]?['content']?['parts']?[0]?['text'];
  if (text == null) return null;
  return jsonDecode(text) as Map<String, dynamic>;
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
    "two-word general shopping category for this receipt (e.g. \"خوراک\", \"پوشاک\", \"دارو\") in the "
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
    return c.isEmpty ? 'بدون‌دسته' : c.first.name;
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
        ? 'این ماه'
        : 'از ${ltr(DateFormat('dd.MM').format(start))} تا امروز (بعد از آخرین حقوق)';
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final exit = await confirmExitApp(context);
        if (exit) SystemNavigator.pop();
      },
      child: Scaffold(
      appBar: AppBar(
        title: const Text('مدیریت مالی شخصی'),
        actions: [
          Badge(
            label: Text('$draftCount'),
            isLabelVisible: draftCount > 0,
            child: IconButton(icon: const Icon(Icons.drafts_outlined), tooltip: 'پیش‌نویس‌ها', onPressed: _openDrafts),
          ),
          IconButton(icon: const Icon(Icons.document_scanner_outlined), tooltip: 'اسکن رسید/فیش حقوقی', onPressed: _openScan),
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
            Text('تراکنش‌ها', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            if (tx.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: Text('هنوز تراکنشی ثبت نشده. با دکمه + شروع کنید.')),
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
                        title: const Text('حذف تراکنش'),
                        content: const Text('این تراکنش حذف شود؟'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
                          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('حذف')),
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
                        '${t.isRecurring ? ' • تکرارشونده' : ''}'
                        '${t.draft ? ' • پیش‌نویس' : ''}',
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
        label: const Text('تراکنش جدید'),
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

// ============================== Drafts ==============================

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
    final all = await Store.loadTransactions();
    all.removeWhere((x) => x.id == t.id);
    await Store.saveTransactions(all);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(title: const Text('پیش‌نویس‌ها')),
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
                          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
                          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('حذف')),
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
    final all = await Store.loadTransactions();
    all.removeWhere((x) => x.id == t.id);
    await Store.saveTransactions(all);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(title: const Text('تراکنش‌های تکرارشونده')),
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
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
                        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('حذف')),
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
                        '${next != null ? ' • سررسید بعدی: ${ltr(DateFormat('dd.MM.yyyy').format(next))}' : ''}',
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
              label: const Text('دوربین', softWrap: false, overflow: TextOverflow.visible),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: OutlinedButton.icon(
              style: style,
              onPressed: busy ? null : () => _process(isPayslip, ScanSource.gallery),
              icon: const Icon(Icons.photo_library, size: 18),
              label: const Text('گالری', softWrap: false, overflow: TextOverflow.visible),
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
      appBar: AppBar(title: const Text('اسکن رسید یا فیش حقوقی')),
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
          content: Text('خواندن هوشمند این‌بار ممکن نشد (سرور شلوغ است یا خطای موقتی رخ داد). می‌توانید دوباره امتحان کنید یا فیلدها را دستی تکمیل و ثبت کنید.'),
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

  Future<void> _addItemRow() async {
    final nameCtrl = TextEditingController();
    final qtyCtrl = TextEditingController(text: '1');
    final priceCtrl = TextEditingController();
    final added = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('افزودن کالا'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'نام کالا'), autofocus: true),
            const SizedBox(height: 8),
            TextField(controller: qtyCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'تعداد')),
            const SizedBox(height: 8),
            TextField(controller: priceCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'قیمت')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('افزودن')),
        ],
      ),
    );
    if (added != true || nameCtrl.text.trim().isEmpty) return;
    setState(() {
      items.add(ReceiptItemEntry(
        name: nameCtrl.text.trim(),
        quantity: double.tryParse(qtyCtrl.text.replaceAll(',', '.')),
        price: double.tryParse(priceCtrl.text.replaceAll(',', '.')),
      ));
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
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('بله، ثبت شود')),
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
      appBar: AppBar(title: const Text('بررسی رسید')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.file(File(widget.imagePath), height: 180, width: double.infinity, fit: BoxFit.cover),
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
            const Text(
              'برای بهبود دقت با هوش مصنوعی، کلید Gemini را از منوی «تنظیمات» وارد کنید.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          if (geminiFailed)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'خواندن هوشمند ممکن نشد. فیلدهای زیر را بررسی و در صورت نیاز دستی اصلاح کنید.',
                style: TextStyle(color: Colors.orange, fontSize: 12),
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
            title: Text('تاریخ: ${ltr(DateFormat('dd.MM.yyyy').format(date))}'),
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
            title: Text(selectedCategory?.name ?? 'انتخاب دسته‌بندی'),
            trailing: const Icon(Icons.chevron_left),
            onTap: _pickCategory,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<Account>(
            initialValue: selectedAccount,
            decoration: const InputDecoration(labelText: 'حساب', border: OutlineInputBorder()),
            items: accounts.map((a) => DropdownMenuItem(value: a, child: Text('${a.name} (${a.currency})'))).toList(),
            onChanged: (v) => setState(() => selectedAccount = v),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('اقلام خرید', style: Theme.of(context).textTheme.titleMedium),
              TextButton.icon(onPressed: _addItemRow, icon: const Icon(Icons.add), label: const Text('افزودن')),
            ],
          ),
          if (items.isEmpty)
            const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('کالایی ثبت نشده.', style: TextStyle(color: Colors.grey))),
          ...items.asMap().entries.map((e) {
            final i = e.key;
            final it = e.value;
            return Card(
              child: ListTile(
                dense: true,
                title: Text(it.name),
                subtitle: Text(
                  '${it.quantity != null ? 'تعداد: ${ltr(it.quantity!.toStringAsFixed(it.quantity! % 1 == 0 ? 0 : 2))}' : ''}'
                  '${it.quantity != null && it.price != null ? ' • ' : ''}'
                  '${it.price != null ? ltr('€${it.price!.toStringAsFixed(2)}') : ''}',
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: () => setState(() => items.removeAt(i)),
                ),
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
  'brutto': 'Brutto',
  'netto': 'Netto',
  'lohnsteuer': 'Lohnsteuer',
  'solidaritaetszuschlag': 'Solidaritätszuschlag',
  'kirchensteuer': 'Kirchensteuer',
  'krankenversicherung': 'Krankenversicherung',
  'pflegeversicherung': 'Pflegeversicherung',
  'rentenversicherung': 'Rentenversicherung',
  'arbeitslosenversicherung': 'Arbeitslosenversicherung',
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
          content: Text('خواندن هوشمند این‌بار ممکن نشد (سرور شلوغ است یا خطای موقتی رخ داد). می‌توانید دوباره امتحان کنید یا فیلدها را دستی تکمیل و ثبت کنید.'),
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
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('مبلغ Netto معتبر وارد کنید.')));
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
    final lines = <String>[];
    if (arbeitgeberCtrl.text.trim().isNotEmpty) lines.add(arbeitgeberCtrl.text.trim());
    if (monatCtrl.text.trim().isNotEmpty) lines.add('ماه: ${monatCtrl.text.trim()}');
    if (steuerklasseCtrl.text.trim().isNotEmpty) lines.add('Steuerklasse: ${steuerklasseCtrl.text.trim()}');
    for (final k in _payslipLabels.keys) {
      final v = numCtrls[k]!.text.trim();
      if (v.isNotEmpty) lines.add('${_payslipLabels[k]}: $v');
    }
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
          title: const Text('تراکنش مشابه'),
          content: const Text('یک تراکنش با همین مبلغ و تاریخ قبلاً ثبت شده. این ممکن است اسکن تکراری همین فیش باشد. باز هم ثبت شود؟'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('بله، ثبت شود')),
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
      note: lines.join('\n'),
      draft: draft,
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
      appBar: AppBar(title: const Text('بررسی فیش حقوقی')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.file(File(widget.imagePath), height: 180, width: double.infinity, fit: BoxFit.cover),
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
            const Text(
              'برای بهبود دقت با هوش مصنوعی، کلید Gemini را از منوی «تنظیمات» وارد کنید.',
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
          if (geminiFailed)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'خواندن هوشمند ممکن نشد. فیلدهای زیر را بررسی و در صورت نیاز دستی اصلاح کنید.',
                style: TextStyle(color: Colors.orange, fontSize: 12),
              ),
            ),
          const SizedBox(height: 16),
          TextField(controller: arbeitgeberCtrl, decoration: const InputDecoration(labelText: 'کارفرما (Arbeitgeber)', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(controller: monatCtrl, decoration: const InputDecoration(labelText: 'ماه (Abrechnungsmonat)', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          TextField(controller: steuerklasseCtrl, decoration: const InputDecoration(labelText: 'کلاس مالیاتی (Steuerklasse)', border: OutlineInputBorder())),
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
            title: Text('تاریخ: ${ltr(DateFormat('dd.MM.yyyy').format(date))}'),
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
            title: Text(selectedCategory?.name ?? 'انتخاب دسته‌بندی'),
            trailing: const Icon(Icons.chevron_left),
            onTap: _pickCategory,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<Account>(
            initialValue: selectedAccount,
            decoration: const InputDecoration(labelText: 'حساب', border: OutlineInputBorder()),
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
  bool draft = false;
  bool _dirty = false;
  List<Category> categories = [];
  List<ReceiptItemEntry> items = [];

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
      draft = e.draft;
      items = List.of(e.items);
      final match = categories.where((c) => c.id == e.categoryId).toList();
      selectedCategory = match.isEmpty ? null : match.first;
    } else {
      dayCtrl.text = date.day.toString();
    }
    amountCtrl.addListener(() => _dirty = true);
    noteCtrl.addListener(() => _dirty = true);
    dayCtrl.addListener(() => _dirty = true);
    intervalCtrl.addListener(() => _dirty = true);
    installmentsCtrl.addListener(() => _dirty = true);
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

  bool _save() {
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
    int? recDay;
    int? recWeekday;
    int? recInterval;
    int? recInstallments;
    DateTime? recEndDate;
    if (recurrence == RecurrenceFrequency.monthly) {
      recDay = int.tryParse(dayCtrl.text) ?? date.day;
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
    );
    Navigator.pop(context, result);
    return true;
  }

  Future<void> _addItemRow() async {
    final nameCtrl = TextEditingController();
    final qtyCtrl = TextEditingController(text: '1');
    final priceCtrl = TextEditingController();
    final added = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('افزودن کالا'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'نام کالا'), autofocus: true),
            const SizedBox(height: 8),
            TextField(controller: qtyCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'تعداد')),
            const SizedBox(height: 8),
            TextField(controller: priceCtrl, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'قیمت')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('افزودن')),
        ],
      ),
    );
    if (added != true || nameCtrl.text.trim().isEmpty) return;
    setState(() {
      items.add(ReceiptItemEntry(
        name: nameCtrl.text.trim(),
        quantity: double.tryParse(qtyCtrl.text.replaceAll(',', '.')),
        price: double.tryParse(priceCtrl.text.replaceAll(',', '.')),
      ));
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
          decoration: const InputDecoration(labelText: 'نوع تکرار', border: OutlineInputBorder()),
          items: const [
            DropdownMenuItem(value: RecurrenceFrequency.none, child: Text('بدون تکرار')),
            DropdownMenuItem(value: RecurrenceFrequency.monthly, child: Text('ماهانه (روز مشخصی از ماه)')),
            DropdownMenuItem(value: RecurrenceFrequency.weekly, child: Text('هفتگی (روز مشخصی از هفته)')),
            DropdownMenuItem(value: RecurrenceFrequency.custom, child: Text('بازه‌ی دلخواه (هر N روز)')),
          ],
          onChanged: (v) => setState(() {
            recurrence = v ?? RecurrenceFrequency.none;
            _dirty = true;
          }),
        ),
        if (recurrence == RecurrenceFrequency.monthly) ...[
          const SizedBox(height: 12),
          TextField(
            controller: dayCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'روز سررسید در ماه (۱ تا ۳۱)',
              helperText: 'برای ماه‌های کوتاه‌تر، به‌صورت خودکار آخرین روز همان ماه در نظر گرفته می‌شود.',
              border: OutlineInputBorder(),
            ),
          ),
        ],
        if (recurrence == RecurrenceFrequency.weekly) ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            initialValue: weekday,
            decoration: const InputDecoration(labelText: 'روز هفته', border: OutlineInputBorder()),
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
              title: Text(endDate == null ? 'انتخاب تاریخ آخرین پرداخت' : 'تا: ${ltr(DateFormat('dd.MM.yyyy').format(endDate!))}'),
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
              decoration: const InputDecoration(labelText: 'تعداد کل اقساط', border: OutlineInputBorder()),
            ),
          ],
          if (preview != null) ...[
            const SizedBox(height: 8),
            Text(
              'سررسید بعدی: ${ltr(DateFormat('dd.MM.yyyy').format(preview))}',
              style: TextStyle(color: Colors.indigo.shade700, fontWeight: FontWeight.w600),
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
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
                      FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('حذف')),
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
            decoration: const InputDecoration(labelText: 'مبلغ', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<Account>(
            initialValue: selectedAccount,
            decoration: const InputDecoration(labelText: 'حساب', border: OutlineInputBorder()),
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
            title: Text(selectedCategory?.name ?? 'انتخاب دسته‌بندی'),
            trailing: const Icon(Icons.chevron_left),
            onTap: _pickCategory,
          ),
          const SizedBox(height: 16),
          ListTile(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: Colors.grey.shade400)),
            title: Text('تاریخ: ${ltr(DateFormat('dd.MM.yyyy').format(date))}'),
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
            decoration: const InputDecoration(labelText: 'توضیحات (اختیاری)', border: OutlineInputBorder()),
          ),
          if (type == TxType.expense) ...[
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('اقلام خرید', style: Theme.of(context).textTheme.titleMedium),
                TextButton.icon(onPressed: _addItemRow, icon: const Icon(Icons.add), label: const Text('افزودن')),
              ],
            ),
            if (items.isEmpty)
              const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('کالایی ثبت نشده.', style: TextStyle(color: Colors.grey))),
            ...items.asMap().entries.map((e) {
              final i = e.key;
              final it = e.value;
              return Card(
                child: ListTile(
                  dense: true,
                  title: Text(it.name),
                  subtitle: Text(
                    '${it.quantity != null ? 'تعداد: ${ltr(it.quantity!.toStringAsFixed(it.quantity! % 1 == 0 ? 0 : 2))}' : ''}'
                    '${it.quantity != null && it.price != null ? ' • ' : ''}'
                    '${it.price != null ? ltr('€${it.price!.toStringAsFixed(2)}') : ''}',
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 20),
                    onPressed: () => setState(() {
                      items.removeAt(i);
                      _dirty = true;
                    }),
                  ),
                ),
              );
            }),
          ],
          const SizedBox(height: 16),
          _recurrenceSection(),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('ذخیره به‌صورت پیش‌نویس'),
            subtitle: const Text('پیش‌نویس‌ها بعداً قابل بررسی و تأیید نهایی هستند.'),
            value: draft,
            onChanged: (v) => setState(() {
              draft = v;
              _dirty = true;
            }),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: _save, child: const Text('ذخیره')),
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
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('افزودن')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final newCat = Category(
      id: 'c_${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      parentId: parentId,
      type: widget.type,
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
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('افزودن')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final newCat = Category(
      id: 'c_${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      parentId: parentId,
      type: selectedType,
    );
    setState(() => categories = [...categories, newCat]);
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
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('ذخیره')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    setState(() {
      categories = categories.map((x) => x.id == c.id ? x.copyWith(name: name) : x).toList();
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
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('حذف')),
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
      appBar: AppBar(title: const Text('مدیریت دسته‌بندی‌ها')),
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
                : ListView(children: tree),
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
    AccountType type = existing?.type ?? AccountType.bank;
    String currency = existing?.currency ?? 'EUR';
    final result = await showDialog<Account>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        return AlertDialog(
          title: Text(existing == null ? 'حساب جدید' : 'ویرایش حساب'),
          content: Column(
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
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('انصراف')),
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
              child: const Text('ذخیره'),
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
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('حذف')),
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
      appBar: AppBar(title: const Text('حساب‌ها')),
      drawer: const AppDrawer(currentIndex: 2),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: accounts
            .map((a) => Card(
                  child: ListTile(
                    leading: const Icon(Icons.account_balance_wallet_outlined),
                    title: Text(a.name),
                    subtitle: Text('${a.type.label} • ${a.currency}'),
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
