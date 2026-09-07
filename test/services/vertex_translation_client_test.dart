import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mangayomi/services/translation/translation_settings.dart';
import 'package:mangayomi/services/translation/vertex_translation_client.dart';

const _settings = TranslationSettings(projectId: 'translation-project');
const _credential = 'never-print-this-credential';
final _image = Uint8List.fromList([1, 2, 3]);

Map<String, dynamic> _region({String id = 'r1', List<num>? box}) => {
  'id': id,
  'box_2d': box ?? [10, 20, 300, 400],
  'sourceText': 'こんにちは',
  'translatedText': 'Hello',
};

Map<String, dynamic> _response({
  List<Map<String, dynamic>>? regions,
  String finishReason = 'STOP',
}) => {
  'candidates': [
    {
      'finishReason': finishReason,
      'content': {
        'parts': [
          {
            'text': jsonEncode({
              'regions': regions ?? [_region()],
            }),
          },
        ],
      },
    },
  ],
  'usageMetadata': {
    'promptTokenCount': 100,
    'candidatesTokenCount': 30,
    'thoughtsTokenCount': 20,
    'totalTokenCount': 150,
    'trafficType': 'ON_DEMAND',
  },
};

http.Response _jsonResponse(Object body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Future<TranslationResult> _translate(
  VertexTranslationClient client, {
  TranslationSettings settings = _settings,
  void Function(TranslationApiEvent)? onEvent,
}) => client.translate(
  imageBytes: _image,
  mimeType: 'image/png',
  settings: settings,
  credential: _credential,
  onEvent: onEvent,
);

Matcher _apiError(String code) =>
    isA<TranslationApiException>().having((error) => error.code, 'code', code);

void main() {
  group('Vertex wire contract', () {
    test(
      'full global uses bearer, shared routing and protected JSON schema',
      () async {
        final events = <TranslationApiEvent>[];
        final client = VertexTranslationClient(
          client: MockClient((request) async {
            expect(
              request.url.toString(),
              'https://aiplatform.googleapis.com/v1/projects/translation-project/locations/global/publishers/google/models/gemini-3.8-flash:generateContent',
            );
            expect(request.headers['Authorization'], 'Bearer $_credential');
            expect(request.headers['X-Vertex-AI-LLM-Request-Type'], 'shared');
            expect(
              request.headers.containsKey(
                'X-Vertex-AI-LLM-Shared-Request-Type',
              ),
              isFalse,
            );
            expect(request.followRedirects, isFalse);
            final body = jsonDecode(request.body) as Map;
            final config = body['generationConfig'] as Map;
            expect(config['thinkingConfig'], {'thinkingLevel': 'MEDIUM'});
            expect(config['responseMimeType'], 'application/json');
            expect(config['responseSchema'], isA<Map>());
            for (final key in [
              'temperature',
              'topP',
              'topK',
              'frequencyPenalty',
              'presencePenalty',
              'candidateCount',
              'maxOutputTokens',
            ]) {
              expect(config.containsKey(key), isFalse, reason: key);
            }
            expect(body['contents'][0]['parts'][1]['inlineData'], {
              'mimeType': 'image/png',
              'data': base64Encode(_image),
            });
            return _jsonResponse(_response());
          }),
        );
        addTearDown(client.close);
        final result = await _translate(client, onEvent: events.add);
        expect(result.regions.single.translatedText, 'Hello');
        expect(result.regions.single.top, 10);
        expect(result.usageMetadata['totalTokenCount'], 150);
        expect(events.last.phase, 'complete');
        final log = jsonEncode(events.map((e) => e.toJson()).toList());
        expect(log, isNot(contains(_credential)));
        expect(log, isNot(contains('こんにちは')));
        expect(log, isNot(contains(base64Encode(_image))));
      },
    );

    test(
      'express omits project and location and warns without model fallback',
      () async {
        final events = <TranslationApiEvent>[];
        final client = VertexTranslationClient(
          client: MockClient((request) async {
            expect(request.url.host, 'aiplatform.googleapis.com');
            expect(
              request.url.path,
              '/v1/publishers/google/models/gemini-3.8-flash:generateContent',
            );
            expect(request.url.queryParameters, {'key': _credential});
            expect(request.headers.containsKey('Authorization'), isFalse);
            return _jsonResponse(_response(regions: []));
          }),
        );
        addTearDown(client.close);
        final result = await _translate(
          client,
          settings: _settings.copyWith(vertexMode: VertexMode.express),
          onEvent: events.add,
        );
        expect(result.regions, isEmpty);
        expect(
          events.any(
            (e) => e.phase == 'warning' && e.message.contains('unverified'),
          ),
          isTrue,
        );
        expect(
          jsonEncode(events.map((e) => e.toJson()).toList()),
          isNot(contains(_credential)),
        );
      },
    );

    test(
      'priority is opt-in; provisioned throughput opt-in stops bypass header',
      () async {
        final client = VertexTranslationClient(
          client: MockClient((request) async {
            expect(
              request.headers['X-Vertex-AI-LLM-Shared-Request-Type'],
              'priority',
            );
            expect(
              request.headers.containsKey('X-Vertex-AI-LLM-Request-Type'),
              isFalse,
            );
            return _jsonResponse(_response());
          }),
        );
        addTearDown(client.close);
        await _translate(
          client,
          settings: _settings.copyWith(
            priorityPaygo: true,
            provisionedThroughput: true,
          ),
        );
      },
    );

    test('accepts supported raw overrides while retaining schema', () async {
      final client = VertexTranslationClient(
        client: MockClient((request) async {
          final config = jsonDecode(request.body)['generationConfig'] as Map;
          expect(config['maxOutputTokens'], 2048);
          expect(config['thinkingConfig'], {'thinkingLevel': 'LOW'});
          expect(config['seed'], -1);
          expect(config['responseMimeType'], 'application/json');
          return _jsonResponse(_response());
        }),
      );
      addTearDown(client.close);
      await _translate(
        client,
        settings: _settings.copyWith(
          rawGenerationConfig: {
            'maxOutputTokens': 2048,
            'thinkingConfig': {'thinkingLevel': 'LOW'},
            'stopSequences': ['END'],
            'seed': -1,
            'mediaResolution': 'MEDIA_RESOLUTION_HIGH',
          },
        ),
      );
    });

    for (final field in [
      'frequencyPenalty',
      'presencePenalty',
      'candidateCount',
      'temperature',
      'topP',
      'topK',
      'responseMimeType',
      'responseSchema',
      'responseJsonSchema',
      'responseFormat',
      'unknown',
    ]) {
      test('rejects unsupported or protected raw $field before HTTP', () async {
        final client = VertexTranslationClient(
          client: MockClient((_) async {
            fail('Invalid settings must not send HTTP requests.');
          }),
        );
        addTearDown(client.close);
        await expectLater(
          _translate(
            client,
            settings: _settings.copyWith(rawGenerationConfig: {field: 0}),
          ),
          throwsA(_apiError('unsupported_generation_config')),
        );
      });
    }

    test('rejects MINIMAL for 3.8', () async {
      final client = VertexTranslationClient(
        client: MockClient((_) async => _jsonResponse(_response())),
      );
      addTearDown(client.close);
      await expectLater(
        _translate(
          client,
          settings: _settings.copyWith(thinkingLevel: 'MINIMAL'),
        ),
        throwsA(_apiError('invalid_thinking')),
      );
    });

    test('rejects simultaneous thinking budget and level', () async {
      final client = VertexTranslationClient(
        client: MockClient((_) async => _jsonResponse(_response())),
      );
      addTearDown(client.close);
      await expectLater(
        _translate(
          client,
          settings: _settings.copyWith(
            rawGenerationConfig: {
              'thinkingConfig': {
                'thinkingLevel': 'LOW',
                'thinkingBudget': 1024,
              },
            },
          ),
        ),
        throwsA(_apiError('invalid_thinking')),
      );
    });

    for (final output in [0, 65537, 10.5, '2048', null]) {
      test('rejects invalid maximum output value $output', () async {
        final client = VertexTranslationClient(
          client: MockClient((_) async => _jsonResponse(_response())),
        );
        addTearDown(client.close);
        await expectLater(
          _translate(
            client,
            settings: _settings.copyWith(
              rawGenerationConfig: {'maxOutputTokens': output},
            ),
          ),
          throwsA(_apiError('invalid_output_limit')),
        );
      });
    }

    for (final location in ['global', 'us', 'eu']) {
      test('accepts the dotted default model ID in $location', () async {
        var calls = 0;
        final client = VertexTranslationClient(
          client: MockClient((request) async {
            calls++;
            expect(request.url.scheme, 'https');
            expect(
              request.url.host,
              location == 'global'
                  ? 'aiplatform.googleapis.com'
                  : '$location-aiplatform.googleapis.com',
            );
            expect(
              request.url.pathSegments.last,
              'gemini-3.8-flash:generateContent',
            );
            expect(request.url.query, isEmpty);
            return _jsonResponse(_response());
          }),
        );
        addTearDown(client.close);
        await _translate(
          client,
          settings: _settings.copyWith(location: location),
        );
        expect(calls, 1);
      });
    }

    test('a well-formed dotted model still requires adapter support', () async {
      final client = VertexTranslationClient(
        client: MockClient((_) async {
          fail('An unsupported model must never send a request.');
        }),
      );
      addTearDown(client.close);
      await expectLater(
        _translate(
          client,
          settings: _settings.copyWith(model: 'gemini-3.8-pro'),
        ),
        throwsA(_apiError('unsupported_model')),
      );
    });

    for (final field in ['model', 'projectId', 'location']) {
      for (final value in [
        '../other',
        'global.evil.example/path',
        'https://evil.example',
        'model%2Fother',
        'model?key=secret',
        'model#fragment',
        'model\r\nInjected: value',
      ]) {
        test(
          'rejects endpoint injection in $field: ${jsonEncode(value)}',
          () async {
            final client = VertexTranslationClient(
              client: MockClient((_) async {
                fail('Invalid endpoint must never send a request.');
              }),
            );
            addTearDown(client.close);
            final settings = switch (field) {
              'model' => _settings.copyWith(model: value),
              'projectId' => _settings.copyWith(projectId: value),
              _ => _settings.copyWith(location: value),
            };
            await expectLater(
              _translate(client, settings: settings),
              throwsA(_apiError('invalid_endpoint')),
            );
          },
        );
      }
    }

    test('model dots do not permit dots in project or location', () async {
      for (final settings in [
        _settings.copyWith(projectId: 'translation.project'),
        _settings.copyWith(location: 'global.evil'),
      ]) {
        final client = VertexTranslationClient(
          client: MockClient((_) async {
            fail('Invalid endpoint must never send a request.');
          }),
        );
        addTearDown(client.close);
        await expectLater(
          _translate(client, settings: settings),
          throwsA(_apiError('invalid_endpoint')),
        );
      }
    });

    test('rejects empty image before HTTP', () async {
      final client = VertexTranslationClient(
        client: MockClient((_) async {
          fail('Empty images must not send a request.');
        }),
      );
      addTearDown(client.close);
      await expectLater(
        client.translate(
          imageBytes: Uint8List(0),
          mimeType: 'image/png',
          settings: _settings,
          credential: _credential,
        ),
        throwsA(_apiError('invalid_image')),
      );
    });
  });

  group('strict structured response validation', () {
    Future<void> rejects(Object payload, String code) async {
      final client = VertexTranslationClient(
        client: MockClient((_) async => _jsonResponse(payload)),
      );
      addTearDown(client.close);
      await expectLater(_translate(client), throwsA(_apiError(code)));
    }

    test(
      'rejects duplicate IDs',
      () => rejects(
        _response(regions: [_region(), _region()]),
        'duplicate_region',
      ),
    );

    for (final box in <List<num>>[
      [-1, 20, 300, 400],
      [10, 20, 1001, 400],
      [300, 20, 10, 400],
      [10, 400, 300, 20],
      [10, 20, 10, 400],
      [10, 20, 300],
    ]) {
      test(
        'rejects invalid box $box',
        () =>
            rejects(_response(regions: [_region(box: box)]), 'invalid_region'),
      );
    }

    test('fromJson rejects non-finite coordinates', () {
      expect(
        () =>
            TranslationRegion.fromJson(_region(box: [double.nan, 20, 30, 40])),
        throwsA(_apiError('invalid_region')),
      );
      expect(
        () => TranslationRegion.fromJson(
          _region(box: [0, 20, double.infinity, 40]),
        ),
        throwsA(_apiError('invalid_region')),
      );
    });

    test('enforces local text and region-count safety bounds', () {
      final longRegion = _region();
      longRegion['translatedText'] = List.filled(
        TranslationRegion.maxTextCharacters + 1,
        'x',
      ).join();
      expect(
        () => TranslationRegion.fromJson(longRegion),
        throwsA(_apiError('invalid_region')),
      );
      expect(
        () => TranslationResult.fromJson({
          'regions': List.generate(
            TranslationResult.maxRegionCount + 1,
            (i) => _region(id: 'r$i'),
          ),
        }),
        throwsA(_apiError('invalid_result')),
      );
    });

    test('rejects oversized transport responses', () async {
      final client = VertexTranslationClient(
        client: MockClient(
          (_) async => http.Response.bytes(
            Uint8List(VertexTranslationClient.maxResponseBytes + 1),
            200,
          ),
        ),
      );
      addTearDown(client.close);
      await expectLater(
        _translate(client),
        throwsA(_apiError('response_too_large')),
      );
    });

    test(
      'rejects max-token truncated response even if its JSON parses',
      () =>
          rejects(_response(finishReason: 'MAX_TOKENS'), 'incomplete_response'),
    );
    test(
      'rejects safety finish',
      () => rejects(_response(finishReason: 'SAFETY'), 'incomplete_response'),
    );
    test(
      'rejects prompt safety block',
      () => rejects({
        'promptFeedback': {'blockReason': 'SAFETY'},
      }, 'safety_blocked'),
    );
    test('rejects blocked safety rating with otherwise valid text', () async {
      final payload = _response();
      (payload['candidates'] as List).single['safetyRatings'] = [
        {'blocked': true},
      ];
      await rejects(payload, 'safety_blocked');
    });
    test('rejects missing candidates', () => rejects({}, 'missing_candidate'));
    test('rejects string box coordinate', () async {
      final region = _region();
      region['box_2d'] = ['10', 20, 300, 400];
      await rejects(_response(regions: [region]), 'invalid_region');
    });
    test('rejects malformed structured JSON', () async {
      final payload = _response();
      (payload['candidates'] as List).single['content'] = {
        'parts': [
          {'text': '```json\n{}\n```'},
        ],
      };
      await rejects(payload, 'invalid_translation_json');
    });
    test('result and event persist through JSON', () {
      final result = TranslationResult.fromJson({
        'regions': [_region()],
        'usageMetadata': {'totalTokenCount': 8},
      });
      final decoded = TranslationResult.fromJson(
        jsonDecode(jsonEncode(result.toJson())) as Map<String, dynamic>,
      );
      expect(decoded.regions.single.sourceText, 'こんにちは');
      expect(decoded.regions.single.right, 400);
      final event = TranslationApiEvent(
        timestamp: DateTime.utc(2026),
        phase: 'complete',
        message: 'Done',
        data: {'regionCount': 1},
      );
      expect(
        TranslationApiEvent.fromJson(event.toJson()).toJson(),
        event.toJson(),
      );
    });
  });

  group('retry, cancellation and credential protection', () {
    test('retries a 429 with bounded backoff', () async {
      var calls = 0;
      final waits = <Duration>[];
      final client = VertexTranslationClient(
        client: MockClient((_) async {
          calls++;
          return calls <= 2
              ? _jsonResponse({'error': 'busy'}, status: 429)
              : _jsonResponse(_response());
        }),
        delay: (duration) async {
          waits.add(duration);
        },
      );
      addTearDown(client.close);
      await _translate(client);
      expect(calls, 3);
      expect(waits, [const Duration(seconds: 1), const Duration(seconds: 2)]);
    });

    test(
      'does not retry permanent errors or expose raw error bodies',
      () async {
        var calls = 0;
        final events = <TranslationApiEvent>[];
        final client = VertexTranslationClient(
          client: MockClient((_) async {
            calls++;
            return _jsonResponse({
              'error': {'message': 'Bearer $_credential secret=other-secret'},
            }, status: 401);
          }),
        );
        addTearDown(client.close);
        await expectLater(
          _translate(client, onEvent: events.add),
          throwsA(_apiError('http_401')),
        );
        expect(calls, 1);
        expect(
          jsonEncode(events.map((e) => e.toJson()).toList()),
          isNot(contains('other-secret')),
        );
      },
    );

    test('never exposes an exception URL', () async {
      final events = <TranslationApiEvent>[];
      final client = VertexTranslationClient(
        client: MockClient((_) async {
          throw http.ClientException(
            'transport leaked $_credential',
            Uri.parse(
              'https://aiplatform.googleapis.com/path?key=$_credential',
            ),
          );
        }),
      );
      addTearDown(client.close);
      try {
        await _translate(
          client,
          settings: _settings.copyWith(maxRetries: 0),
          onEvent: events.add,
        );
        fail('Expected a network error.');
      } on TranslationApiException catch (error) {
        expect(error.code, 'network');
        expect(error.toString(), isNot(contains(_credential)));
      }
      expect(
        jsonEncode(events.map((e) => e.toJson()).toList()),
        isNot(contains(_credential)),
      );
    });

    test('refuses redirects', () async {
      final client = VertexTranslationClient(
        client: MockClient((request) async {
          expect(request.followRedirects, isFalse);
          return http.Response(
            '',
            302,
            headers: {'location': 'https://evil.example'},
          );
        }),
      );
      addTearDown(client.close);
      await expectLater(_translate(client), throwsA(_apiError('http_302')));
    });

    test(
      'cancel closes actual transport and wakes an in-flight request',
      () async {
        final requested = Completer<void>();
        final response = Completer<http.Response>();
        final transport = _TrackingClient((_) {
          requested.complete();
          return response.future;
        });
        final client = VertexTranslationClient(client: transport);
        addTearDown(client.close);
        final pending = _translate(client);
        final assertion = expectLater(pending, throwsA(_apiError('cancelled')));
        await requested.future;
        client.cancel();
        await assertion;
        expect(transport.closed, isTrue);
        response.complete(_jsonResponse(_response()));
      },
    );

    test('cancel wakes retry backoff immediately', () async {
      final waiting = Completer<void>();
      final continueWait = Completer<void>();
      var calls = 0;
      final transport = _TrackingClient((_) async {
        calls++;
        return _jsonResponse({}, status: 503);
      });
      final client = VertexTranslationClient(
        client: transport,
        delay: (_) {
          waiting.complete();
          return continueWait.future;
        },
      );
      addTearDown(client.close);
      final pending = _translate(client);
      final assertion = expectLater(pending, throwsA(_apiError('cancelled')));
      await waiting.future;
      client.cancel();
      await assertion;
      expect(calls, 1);
      expect(transport.closed, isTrue);
      continueWait.complete();
    });

    test('raw capture is opt-in, redacted, bounded and omits images', () async {
      final events = <TranslationApiEvent>[];
      final payload = _response();
      payload['debug'] = {
        'authorization': 'Bearer $_credential',
        'nested': {'access_token': 'unknown-access-token'},
        'url': 'https://files.example/image?X-Goog-Signature=signed-secret&other=private-query',
        'inlineData': {'mimeType': 'image/png', 'data': base64Encode(_image)},
        'large': List.filled(20000, 'x ').join(),
      };
      final client = VertexTranslationClient(
        client: MockClient((_) async => _jsonResponse(payload)),
      );
      addTearDown(client.close);
      await _translate(
        client,
        settings: _settings.copyWith(captureRawBodies: true),
        onEvent: events.add,
      );
      final serialized = jsonEncode(events.map((e) => e.toJson()).toList());
      for (final secret in [
        _credential,
        'unknown-access-token',
        'signed-secret',
        'private-query',
        base64Encode(_image),
      ]) {
        expect(serialized, isNot(contains(secret)), reason: secret);
      }
      final raw =
          events.firstWhere((e) => e.phase == 'response').data['rawResponse']
              as String;
      expect(
        raw.length,
        lessThan(VertexTranslationClient.maxRawLogCharacters + 100),
      );
      expect(raw, contains('TRUNCATED'));
      expect(serialized, contains('こんにちは'));
    });

    test('recursive redaction preserves useful token counters', () {
      final redacted = redactTranslationData({
        'generationConfig': {'maxOutputTokens': 2048},
        'usageMetadata': {
          'promptTokenCount': 10,
          'totalTokenCount': 15,
          'thoughtsTokenCount': 5,
          'promptTokensDetails': [
            {'modality': 'IMAGE', 'tokenCount': 10},
          ],
          'candidatesTokensDetails': [
            {'modality': 'TEXT', 'tokenCount': 5},
          ],
          'cacheTokensDetails': [
            {'modality': 'TEXT', 'tokenCount': 2},
          ],
          'toolUsePromptTokensDetails': [
            {'modality': 'TEXT', 'tokenCount': 1},
          ],
        },
        'headers': {
          'Authorization': 'Bearer unknown',
          'X-Goog-Api-Key': 'unknown-key',
        },
        'nested': [
          {'refresh_token': 'unknown-refresh'},
        ],
        'accessTokenCount': 12345,
        'text': 'credential=not-for-logs Bearer bearer-value',
      }) as Map;
      final encoded = jsonEncode(redacted);
      for (final secret in [
        'unknown',
        'unknown-key',
        'unknown-refresh',
        'not-for-logs',
        'bearer-value',
      ]) {
        expect(encoded, isNot(contains(secret)));
      }
      expect(redacted['usageMetadata']['totalTokenCount'], 15);
      expect(redacted['generationConfig']['maxOutputTokens'], 2048);
      expect(redacted['accessTokenCount'], '[REDACTED]');
      for (final field in [
        'promptTokensDetails',
        'candidatesTokensDetails',
        'cacheTokensDetails',
        'toolUsePromptTokensDetails',
      ]) {
        expect(redacted['usageMetadata'][field], isA<List>());
        expect(redacted['usageMetadata'][field][0]['tokenCount'], isA<num>());
      }
    });

    test('wrapped event data survives recursive export redaction', () {
      final event = TranslationApiEvent(
        timestamp: DateTime.utc(2026),
        phase: 'response',
        message: 'Received',
        data: {
          'statusCode': 200,
          'nested': {'data': 'image-base64'},
          'usageMetadata': {'promptTokenCount': 10},
        },
      );
      final safe = redactTranslationData(event.toJson()) as Map;
      expect(safe['data']['statusCode'], 200);
      expect(safe['data']['nested']['data'], '[REDACTED]');
      expect(safe['data']['usageMetadata']['promptTokenCount'], 10);
    });

    test('raw validation is available without credentials or a client', () {
      expect(
        VertexTranslationClient.validateGenerationConfig(_settings),
        isEmpty,
      );
      expect(
        VertexTranslationClient.validateGenerationConfig(
          _settings.copyWith(rawGenerationConfig: {'candidateCount': 1}),
        ),
        isNotEmpty,
      );
    });
  });
}

class _TrackingClient extends MockClient {
  _TrackingClient(super.fn);
  bool closed = false;

  @override
  void close() {
    closed = true;
    super.close();
  }
}
