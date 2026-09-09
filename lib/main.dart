import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const MoneyApp());

// Isolates an LTR chunk (numbers, dates, currency) inside RTL Persian text
// so it always renders left-to-right in the right place, instead of the
// Unicode bidi algorithm re-ordering symbols/signs relative to the digits.
String ltr(String s) => '\u2066$s\u2069';

// ============================== Models ==============================

enum TxType { expense, income }

class Category {
  final String id;
  final String name;
  final String? parentId;
  final TxType type;
  const Category({required this.id, required this.name, this.parentId, required this.type});

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'parentId': parentId, 'type': type.name};
  factory Category.fromJson(Map<String, dynamic> j) => Category(
        id: j['id'],
        name: j['name'],
        parentId: j['parentId'],
        type: TxType.values.byName(j['type']),
      );
}

class Transaction {
  final String id;
  final TxType type;
  final double amount;
  final String categoryId;
  final DateTime date;
  final String note;
  final bool recurring;
  final int? recurrenceDay;

  const Transaction({
    required this.id,
    required this.type,
    required this.amount,
    required this.categoryId,
    required this.date,
    this.note = '',
    this.recurring = false,
    this.recurrenceDay,
  });

  Transaction copyWith({
    TxType? type,
    double? amount,
    String? categoryId,
    DateTime? date,
    String? note,
    bool? recurring,
    int? recurrenceDay,
  }) =>
      Transaction(
        id: id,
        type: type ?? this.type,
        amount: amount ?? this.amount,
        categoryId: categoryId ?? this.categoryId,
        date: date ?? this.date,
        note: note ?? this.note,
        recurring: recurring ?? this.recurring,
        recurrenceDay: recurrenceDay ?? this.recurrenceDay,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.name,
        'amount': amount,
        'categoryId': categoryId,
        'date': date.toIso8601String(),
        'note': note,
        'recurring': recurring,
        'recurrenceDay': recurrenceDay,
      };

  factory Transaction.fromJson(Map<String, dynamic> j) => Transaction(
        id: j['id'],
        type: TxType.values.byName(j['type']),
        amount: (j['amount'] as num).toDouble(),
        categoryId: j['categoryId'],
        date: DateTime.parse(j['date']),
        note: j['note'] ?? '',
        recurring: j['recurring'] ?? false,
        recurrenceDay: j['recurrenceDay'],
      );
}

// ============================== Default categories ==============================

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

// ============================== Storage ==============================

class Store {
  static const _txKey = 'transactions';
  static const _catKey = 'custom_categories';

  static Future<List<Transaction>> loadTransactions() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getStringList(_txKey) ?? [];
    return raw.map((s) => Transaction.fromJson(jsonDecode(s))).toList();
  }

  static Future<void> saveTransactions(List<Transaction> list) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(_txKey, list.map((t) => jsonEncode(t.toJson())).toList());
  }

  static Future<List<Category>> loadCustomCategories() async {
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getStringList(_catKey) ?? [];
    return raw.map((s) => Category.fromJson(jsonDecode(s))).toList();
  }

  static Future<void> saveCustomCategories(List<Category> list) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setStringList(_catKey, list.map((c) => jsonEncode(c.toJson())).toList());
  }
}

// ============================== App ==============================

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

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Transaction> tx = [];
  List<Category> customCats = [];
  bool loading = true;

  List<Category> get allCategories => [...defaultCategories, ...customCats];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    tx = await Store.loadTransactions();
    customCats = await Store.loadCustomCategories();
    tx.sort((a, b) => b.date.compareTo(a.date));
    setState(() => loading = false);
  }

  Future<void> _save() async {
    await Store.saveTransactions(tx);
    await Store.saveCustomCategories(customCats);
  }

  String categoryName(String id) {
    final c = allCategories.where((c) => c.id == id).toList();
    return c.isEmpty ? 'بدون‌دسته' : c.first.name;
  }

  double get totalBalance {
    double s = 0;
    for (final t in tx) {
      s += t.type == TxType.income ? t.amount : -t.amount;
    }
    return s;
  }

  Map<String, double> get thisMonth {
    final now = DateTime.now();
    double income = 0, expense = 0;
    for (final t in tx) {
      if (t.date.year == now.year && t.date.month == now.month) {
        if (t.type == TxType.income) {
          income += t.amount;
        } else {
          expense += t.amount;
        }
      }
    }
    return {'income': income, 'expense': expense};
  }

  Future<void> _openEditor({Transaction? existing}) async {
    final result = await Navigator.push<Transaction>(
      context,
      MaterialPageRoute(
        builder: (_) => TransactionEditor(
          categories: allCategories,
          existing: existing,
          onCategoryAdded: (c) async {
            setState(() => customCats.add(c));
            await Store.saveCustomCategories(customCats);
          },
        ),
      ),
    );
    if (result == null) return;
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

  Future<void> _delete(Transaction t) async {
    setState(() => tx.removeWhere((x) => x.id == t.id));
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final m = thisMonth;
    return Scaffold(
      appBar: AppBar(title: const Text('مدیریت مالی شخصی')),
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
                    Text('موجودی کل', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(
                      ltr('€${totalBalance.toStringAsFixed(2)}'),
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                            color: totalBalance >= 0 ? Colors.green.shade700 : Colors.red.shade700,
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                    const Divider(height: 24),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _MonthStat(label: 'درآمد این ماه', value: m['income']!, color: Colors.green),
                        _MonthStat(label: 'هزینه این ماه', value: m['expense']!, color: Colors.red),
                      ],
                    ),
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
                      title: const Text('حذف تراکنش'),
                      content: const Text('این تراکنش حذف شود؟'),
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
                          t.type == TxType.income ? Icons.arrow_downward : Icons.arrow_upward,
                          color: t.type == TxType.income ? Colors.green.shade800 : Colors.red.shade800,
                        ),
                      ),
                      title: Text(categoryName(t.categoryId)),
                      subtitle: Text(
                        '${ltr(DateFormat('dd.MM.yyyy').format(t.date))}'
                        '${t.note.isNotEmpty ? ' • ${t.note}' : ''}'
                        '${t.recurring ? ' • تکرارشونده' : ''}',
                      ),
                      trailing: Text(
                        ltr('${t.type == TxType.income ? '+' : '-'}€${t.amount.toStringAsFixed(2)}'),
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
    );
  }
}

class _MonthStat extends StatelessWidget {
  final String label;
  final double value;
  final MaterialColor color;
  const _MonthStat({required this.label, required this.value, required this.color});
  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: Colors.grey.shade600, fontSize: 12)),
        Text(ltr('€${value.toStringAsFixed(2)}'),
            style: TextStyle(color: color.shade700, fontWeight: FontWeight.bold, fontSize: 16)),
      ],
    );
  }
}

// ============================== Transaction editor ==============================

class TransactionEditor extends StatefulWidget {
  final List<Category> categories;
  final Transaction? existing;
  final void Function(Category) onCategoryAdded;
  const TransactionEditor({required this.categories, required this.onCategoryAdded, this.existing, super.key});
  @override
  State<TransactionEditor> createState() => _TransactionEditorState();
}

class _TransactionEditorState extends State<TransactionEditor> {
  late TxType type;
  final amountCtrl = TextEditingController();
  final noteCtrl = TextEditingController();
  final dayCtrl = TextEditingController();
  Category? selectedCategory;
  DateTime date = DateTime.now();
  bool recurring = false;
  List<Category> categories = [];

  @override
  void initState() {
    super.initState();
    categories = widget.categories;
    final e = widget.existing;
    type = e?.type ?? TxType.expense;
    if (e != null) {
      amountCtrl.text = e.amount.toStringAsFixed(2);
      noteCtrl.text = e.note;
      date = e.date;
      recurring = e.recurring;
      dayCtrl.text = e.recurrenceDay?.toString() ?? '';
      final match = categories.where((c) => c.id == e.categoryId).toList();
      selectedCategory = match.isEmpty ? null : match.first;
    }
  }

  Future<void> _pickCategory() async {
    final picked = await showModalBottomSheet<Category>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => CategoryPicker(
        type: type,
        categories: categories,
        onCategoryAdded: (c) {
          setState(() => categories = [...categories, c]);
          widget.onCategoryAdded(c);
        },
      ),
    );
    if (picked != null) setState(() => selectedCategory = picked);
  }

  void _save() {
    final amount = double.tryParse(amountCtrl.text.replaceAll(',', '.'));
    if (amount == null || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('مبلغ معتبر وارد کنید.')));
      return;
    }
    if (selectedCategory == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('یک دسته‌بندی انتخاب کنید.')));
      return;
    }
    final id = widget.existing?.id ?? DateTime.now().microsecondsSinceEpoch.toString();
    final result = Transaction(
      id: id,
      type: type,
      amount: amount,
      categoryId: selectedCategory!.id,
      date: date,
      note: noteCtrl.text.trim(),
      recurring: recurring,
      recurrenceDay: recurring ? int.tryParse(dayCtrl.text) : null,
    );
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.existing == null ? 'تراکنش جدید' : 'ویرایش تراکنش')),
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
            }),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: amountCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'مبلغ (€)', border: OutlineInputBorder()),
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
              );
              if (d != null) setState(() => date = d);
            },
          ),
          const SizedBox(height: 16),
          TextField(
            controller: noteCtrl,
            decoration: const InputDecoration(labelText: 'توضیحات (اختیاری)', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            title: const Text('تراکنش تکرارشونده (قسط / هزینه ثابت ماهانه)'),
            value: recurring,
            onChanged: (v) => setState(() => recurring = v),
          ),
          if (recurring)
            TextField(
              controller: dayCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'روز سررسید در ماه (۱ تا ۲۸)', border: OutlineInputBorder()),
            ),
          const SizedBox(height: 24),
          FilledButton(onPressed: _save, child: const Text('ذخیره')),
        ],
      ),
    );
  }
}

// ============================== Category picker ==============================

class CategoryPicker extends StatefulWidget {
  final TxType type;
  final List<Category> categories;
  final void Function(Category) onCategoryAdded;
  const CategoryPicker({required this.type, required this.categories, required this.onCategoryAdded, super.key});
  @override
  State<CategoryPicker> createState() => _CategoryPickerState();
}

class _CategoryPickerState extends State<CategoryPicker> {
  List<Category> stack = [];
  late List<Category> categories;

  @override
  void initState() {
    super.initState();
    categories = widget.categories;
  }

  Future<void> _addCategory() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('دسته‌بندی جدید'),
        content: TextField(controller: ctrl, decoration: const InputDecoration(labelText: 'نام دسته‌بندی')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('انصراف')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('افزودن')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final parentId = stack.isEmpty ? null : stack.last.id;
    final newCat = Category(
      id: 'custom_${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      parentId: parentId,
      type: widget.type,
    );
    setState(() => categories = [...categories, newCat]);
    widget.onCategoryAdded(newCat);
  }

  @override
  Widget build(BuildContext context) {
    final parentId = stack.isEmpty ? null : stack.last.id;
    final items = categories.where((c) => c.type == widget.type && c.parentId == parentId).toList();
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
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
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: items.map((c) {
                  final hasChildren = categories.any((x) => x.parentId == c.id);
                  return ListTile(
                    title: Text(c.name),
                    trailing: hasChildren ? const Icon(Icons.chevron_left) : null,
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
              title: const Text('افزودن دسته‌بندی جدید'),
              onTap: _addCategory,
            ),
          ],
        ),
      ),
    );
  }
}
