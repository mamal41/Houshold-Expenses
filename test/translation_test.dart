// Every text of the app must also exist in English and German: Persian left
// on the screen after choosing another language is a bug.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:personal_finance/main.dart';
import 'package:personal_finance/ui_translations.dart';

/// The string literals of the first argument of each loc(...) / locf(...)
/// call in [src] (both sides of a `cond ? '..' : '..'`, adjacent literals
/// joined), decoded.
List<String> locTexts(String src) {
  final out = <String>[];
  for (final m in RegExp(r'(?<![A-Za-z0-9_])locf?\(').allMatches(src)) {
    var i = m.end;
    var depth = 0;
    String? current;
    var lastEnd = -1;
    while (i < src.length) {
      final c = src[i];
      if (c == "'" || c == '"') {
        final buf = StringBuffer();
        var j = i + 1;
        var interpolated = false;
        while (src[j] != c) {
          if (src[j] == r'\') {
            final n = src[j + 1];
            if (n == 'n') {
              buf.write('\n');
            } else if (n == 'u') {
              buf.writeCharCode(int.parse(src.substring(j + 2, j + 6), radix: 16));
              j += 4;
            } else {
              buf.write(n);
            }
            j += 2;
            continue;
          }
          if (src[j] == r'$') interpolated = true;
          buf.write(src[j]);
          j++;
        }
        final text = buf.toString();
        if (current != null && src.substring(lastEnd, i).trim().isEmpty) {
          current = current + text;
          out[out.length - 1] = current;
        } else if (!interpolated) {
          current = text;
          out.add(text);
        }
        lastEnd = j + 1;
        i = j + 1;
        continue;
      }
      if ('([{'.contains(c)) depth++;
      if (')]}'.contains(c)) {
        if (depth == 0) break;
        depth--;
      }
      if (c == ',' && depth == 0) break;
      i++;
    }
  }
  return out.where((t) => RegExp(r'[؀-ۿ]').hasMatch(t)).toList();
}

void main() {
  test('every Persian UI text has an English and a German translation', () {
    final missing = <String>{};
    final seen = <String>{};
    for (final f in Directory('lib').listSync().whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      if (f.path.endsWith('ui_translations.dart')) continue;
      for (final t in locTexts(f.readAsStringSync())) {
        seen.add(t);
        final row = uiTranslations[t];
        if (row == null || row.length < 2 || row.any((x) => x.trim().isEmpty)) missing.add(t);
      }
    }
    // (The texts were really found.)
    expect(seen.length, greaterThan(800));
    expect(missing, isEmpty, reason: 'Texts without English/German:\n${missing.join('\n')}');
  });

  test('notes the app wrote itself follow the app language', () {
    currentLanguage.value = AppLanguage.en;
    expect(shownNote('انتقال به Sparkonto'), 'Transfer to Sparkonto');
    expect(shownNote('Übertrag von Girokonto'), 'Transfer from Girokonto');
    expect(shownNote('از لیست خرید «هفتگی»'), 'From shopping list “هفتگی”');
    expect(shownNote('کرایه (دسته‌بندی قبلی: خانه)'), 'کرایه (previous category: خانه)');
    // The person's own words are left alone.
    expect(shownNote('  pizza with friends  '), 'pizza with friends');
    currentLanguage.value = AppLanguage.de;
    expect(shownNote('Transfer to Savings'), 'Übertrag an Savings');
    currentLanguage.value = AppLanguage.fa;
    expect(shownNote('Transfer to Savings'), 'انتقال به Savings');
  });

  test('short Toman amounts say "million" in the app language', () {
    currentLanguage.value = AppLanguage.en;
    expect(formatMoneyCompact(12500000, 'IRT'), contains('12.5M IRT'));
    currentLanguage.value = AppLanguage.de;
    expect(formatMoneyCompact(12500000, 'IRT'), contains('12.5 Mio. IRT'));
    currentLanguage.value = AppLanguage.fa;
    expect(formatMoneyCompact(12500000, 'IRT'), contains('م'));
  });

  test('default category and account names follow the app language, chosen names do not', () {
    currentLanguage.value = AppLanguage.de;
    expect(localizedDefaultCategory(const Category(id: 'i_salary', name: 'حقوق', type: TxType.income)).name, 'Gehalt');
    expect(localizedDefaultCategory(const Category(id: 'i_salary', name: 'Salary', type: TxType.income)).name, 'Gehalt');
    expect(localizedDefaultCategory(const Category(id: 'i_salary', name: 'Mein Lohn', type: TxType.income)).name, 'Mein Lohn');
    expect(localizedDefaultCategory(const Category(id: 'x_own', name: 'حقوق', type: TxType.income)).name, 'حقوق');
    expect(localizedDefaultAccount(defaultAccount).name, 'Hauptkonto');
    currentLanguage.value = AppLanguage.fa;
    expect(localizedDefaultCategory(const Category(id: 'e_misc', name: 'Sonstiges', type: TxType.expense)).name, 'متفرقه');
  });
}
