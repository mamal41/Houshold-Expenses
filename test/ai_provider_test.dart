// The AI services other than Gemini: request shapes, reading the answers,
// error messages, and the settings screen that picks the service.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:personal_finance/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    currentLanguage.value = AppLanguage.fa;
    SharedPreferences.setMockInitialValues({});
  });

  test('OpenAI-compatible address', () {
    expect(const AiConfig(openAiBaseUrl: 'https://api.openai.com/v1/').openAiChatUrl, 'https://api.openai.com/v1/chat/completions');
    expect(const AiConfig(openAiBaseUrl: 'https://gw.example/v1/chat/completions').openAiChatUrl, 'https://gw.example/v1/chat/completions');
  });

  test('request bodies carry the image', () {
    final o = openAiRequestBody('m', 'p', imageB64: 'AAA');
    final parts = (o['messages'] as List).first['content'] as List;
    expect(parts[1]['image_url']['url'], 'data:image/jpeg;base64,AAA');
    expect((openAiRequestBody('m', 'p')['messages'] as List).first['content'], 'p');
    final c = claudeRequestBody('claude-opus-5-5', 'p', imageB64: 'BBB', mime: 'image/png');
    final blocks = (c['messages'] as List).first['content'] as List;
    expect(blocks.first['type'], 'image');
    expect(blocks.first['source']['media_type'], 'image/png');
    expect(blocks.last, {'type': 'text', 'text': 'p'});
    expect(c.containsKey('temperature'), isFalse);
  });

  test('JSON is found inside fences and prose', () {
    expect(parseAiJson('```json\n{"total": 5}\n```', 'x'), {'total': 5});
    expect(parseAiJson('Here it is: {"a": {"b": 1}} done', 'x'), {
      'a': {'b': 1}
    });
    expect(() => parseAiJson('no json', 'x'), throwsA(isA<GeminiException>()));
  });

  test('answers are read', () {
    expect(
        openAiResponseText({
          'choices': [
            {
              'message': {'content': 'hi'}
            }
          ]
        }, ''),
        'hi');
    expect(
        claudeResponseText({
          'content': [
            {'type': 'thinking', 'thinking': '...'},
            {'type': 'text', 'text': 'hello'}
          ],
          'stop_reason': 'end_turn'
        }, ''),
        'hello');
    expect(() => claudeResponseText({'content': [], 'stop_reason': 'refusal'}, ''), throwsA(isA<GeminiException>()));
  });

  test('chosen service is used and errors are explained', () async {
    final img = File('${Directory.systemTemp.createTempSync().path}/r.jpg')..writeAsBytesSync([1, 2, 3]);
    late http.Request seen;
    await Store.saveAiConfig(const AiConfig(provider: AiProvider.claude, claudeKey: 'k1'));
    expect(await Store.loadAiKey(), 'k1');
    await http.runWithClient(() async {
      final json = await geminiExtractReceipt('k1', img.path);
      expect(json!['total'], 12.5);
    }, () => MockClient((r) async {
          seen = r;
          return http.Response(
              jsonEncode({
                'content': [
                  {'type': 'text', 'text': '{"total": 12.5}'}
                ],
                'stop_reason': 'end_turn'
              }),
              200);
        }));
    expect(seen.url.toString(), 'https://api.anthropic.com/v1/messages');
    expect(seen.headers['x-api-key'], 'k1');
    expect(seen.headers['anthropic-version'], '2026-10-21');

    await Store.saveAiConfig(const AiConfig(provider: AiProvider.openai, openAiKey: 'k2', openAiBaseUrl: 'https://gw.example/v1', openAiModel: 'gpt-4o'));
    await http.runWithClient(() async {
      expect(await geminiTextRequest('k2', 'hello'), 'ok');
    }, () => MockClient((r) async {
          seen = r;
          return http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': ' ok '}
                  }
                ]
              }),
              200);
        }));
    expect(seen.url.toString(), 'https://gw.example/v1/chat/completions');
    expect(seen.headers['Authorization'], 'Bearer k2');
    expect(jsonDecode(seen.body)['model'], 'gpt-4o');

    await http.runWithClient(() async {
      await expectLater(
        geminiTextRequest('k2', 'hello'),
        throwsA(isA<GeminiException>().having((e) => e.friendlyMessage, 'message', contains('HTTP 401'))),
      );
    }, () => MockClient((r) async => http.Response('{"error":"bad key"}', 401)));
  });

  test('Gemini gets the key in a header, not in the address', () async {
    await Store.saveAiConfig(const AiConfig(geminiKey: ' AIza-test\n'));
    late http.Request seen;
    await http.runWithClient(() async {
      expect(await geminiTextRequest((await Store.loadAiKey())!, 'hi'), 'ok');
    }, () => MockClient((r) async {
          seen = r;
          return http.Response(
              jsonEncode({
                'candidates': [
                  {
                    'content': {
                      'parts': [
                        {'text': 'ok'}
                      ]
                    }
                  }
                ]
              }),
              200);
        }));
    expect(seen.url.queryParameters.containsKey('key'), isFalse);
    expect(seen.headers['x-goog-api-key'], 'AIza-test');
  });

  testWidgets('settings screen switches and saves the service', (tester) async {
    tester.view.physicalSize = const Size(500, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: Directionality(textDirection: TextDirection.rtl, child: GeminiSettingsScreen())));
    await tester.pumpAndSettle();
    expect(find.text('Gemini API Key'), findsOneWidget);
    await tester.tap(find.text('OpenAI و سازگار'));
    await tester.pumpAndSettle();
    expect(find.text('Gemini API Key'), findsNothing);
    await tester.enterText(find.widgetWithText(TextField, 'API Key'), ' sk-test ');
    await tester.tap(find.text(tr('save')));
    await tester.pumpAndSettle();
    final c = await Store.loadAiConfig();
    expect(c.provider, AiProvider.openai);
    expect(c.activeKey, 'sk-test');
    expect(c.openAiChatUrl, 'https://api.openai.com/v1/chat/completions');
    await tester.tap(find.text('Claude'));
    await tester.pumpAndSettle();
    expect(find.text('Claude API Key'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
