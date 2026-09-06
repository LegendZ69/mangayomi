import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/services/translation/translation_settings.dart';

void main() {
  group('TranslationSettings', () {
    test('requested defaults remain explicit and are not provider claims', () {
      const settings = TranslationSettings();
      expect(settings.vertexMode, VertexMode.full);
      expect(settings.executionMode, ExecutionMode.hybrid);
      expect(settings.detectionEngine, DetectionEngine.ai);
      expect(settings.ocrEngine, OcrEngine.ai);
      expect(settings.inpaintEngine, InpaintEngine.overlay);
      expect(settings.ppocrDetectionModel, 'PP-OCRv6_small_det');
      expect(settings.ppocrRecognitionModel, 'PP-OCRv6_small_rec');
      expect(settings.yoloModel, 'yolo26n');
      expect(settings.model, 'gemini-3.8-flash');
      expect(settings.location, 'global');
      expect(settings.projectId, isEmpty);
      expect(settings.targetLanguage, 'English');
      expect(settings.thinkingLevel, 'MEDIUM');
      expect(settings.maxOutputTokens, isNull);
      expect(settings.rawGenerationConfig, isEmpty);
      expect(settings.captureRawBodies, isFalse);
      expect(settings.priorityPaygo, isFalse);
      expect(settings.provisionedThroughput, isFalse);
      expect(settings.timeoutSeconds, 60);
      expect(settings.maxRetries, 2);
      expect(settings.maxLogEntries, 500);
      expect(settings.fontFamily, isNull);
      expect(settings.fontSize, isNull);
      expect(settings.fontWeight, isNull);
      expect(settings.backgroundColor, isNull);
      expect(settings.textColor, isNull);
      expect(settings.validate(), isEmpty);
      expect(settings.validateRuntimeSupport(), isEmpty);
      expect(settings.validateForExecution(), contains(contains('project ID')));
    });

    test('round trips all fields through JSON', () {
      const settings = TranslationSettings(
        executionMode: ExecutionMode.localOnly,
        detectionEngine: DetectionEngine.ppocrAi,
        ocrEngine: OcrEngine.ppocrAi,
        inpaintEngine: InpaintEngine.lama,
        ppocrDetectionModel: 'PP-OCRv5_mobile_det',
        ppocrRecognitionModel: 'korean_PP-OCRv5_mobile_rec',
        yoloModel: 'yolo26x',
        vertexMode: VertexMode.express,
        projectId: 'project-example',
        location: 'us-central1',
        model: 'custom-requested-model',
        targetLanguage: 'Japanese',
        thinkingLevel: 'LOW',
        maxOutputTokens: 2048,
        rawGenerationConfig: {
          'temperature': 0.5,
          'responseSchema': {
            'type': 'OBJECT',
            'required': ['regions'],
          },
        },
        captureRawBodies: true,
        timeoutSeconds: 90,
        maxRetries: 0,
        maxLogEntries: 100,
        fontFamily: 'Custom Font',
        fontSize: 18,
        fontWeight: 500,
        backgroundColor: 0xffffffff,
        textColor: 0xff000000,
        priorityPaygo: true,
        provisionedThroughput: true,
      );
      final restored = TranslationSettings.fromJson(
        jsonDecode(jsonEncode(settings.toJson())) as Map<String, dynamic>,
      );
      expect(restored.toJson(), settings.toJson());
      expect(restored.validateRuntimeSupport(), hasLength(3));
    });

    test('missing fields receive defaults', () {
      expect(
        TranslationSettings.fromJson({}).toJson(),
        const TranslationSettings().toJson(),
      );
    });

    test('artifact preferences are saveable, but do not enable adapters', () {
      final settings = const TranslationSettings().copyWith(
        ppocrDetectionModel: 'PP-OCRv6_tiny_det',
        ppocrRecognitionModel: 'PP-OCRv6_tiny_rec',
        yoloModel: 'yolo26m',
        detectionEngine: DetectionEngine.ppocr,
      );
      expect(settings.validate(), isEmpty);
      expect(settings.ppocrDetectionModel, 'PP-OCRv6_tiny_det');
      expect(settings.ppocrRecognitionModel, 'PP-OCRv6_tiny_rec');
      expect(settings.yoloModel, 'yolo26m');
      expect(settings.validateRuntimeSupport(), contains(contains('unavailable')));
      for (final field in [
        'ppocrDetectionModel', 'ppocrRecognitionModel', 'yoloModel',
      ]) {
        for (final value in ['', ' ', '../model', 'https://example.test/model',
          r'C:\models\model', 'model\nsecret', null, 3]) {
          expect(
            () => TranslationSettings.fromJson({field: value}),
            throwsFormatException,
            reason: '$field must be a model identifier only',
          );
        }
      }
    });

    test('unknown enum values never reset execution or engine preferences', () {
      for (final field in [
        'executionMode', 'detectionEngine', 'ocrEngine', 'inpaintEngine',
        'vertexMode',
      ]) {
        for (final value in ['unrecognized', null, 1]) {
          expect(
            () => TranslationSettings.fromJson({field: value}),
            throwsFormatException,
            reason: '$field=$value must not silently become an app default',
          );
        }
      }
    });

    test('rejects incorrect types instead of coercing privacy settings', () {
      for (final entry in <String, dynamic>{
        'captureRawBodies': 'false',
        'priorityPaygo': 1,
        'provisionedThroughput': null,
        'timeoutSeconds': 1.5,
        'maxRetries': '2',
        'model': 42,
        'fontSize': '18',
        'fontWeight': 400.5,
        'rawGenerationConfig': [],
      }.entries) {
        expect(
          () => TranslationSettings.fromJson({entry.key: entry.value}),
          throwsFormatException,
          reason: entry.key,
        );
      }
    });

    test('rejects invalid finite numeric and JSON values', () {
      for (final entry in <String, dynamic>{
        'timeoutSeconds': 0,
        'maxRetries': -1,
        'maxLogEntries': 0,
        'maxOutputTokens': 0,
        'fontSize': double.infinity,
        'fontWeight': 450,
        'backgroundColor': -1,
        'textColor': 0x100000000,
        'thinkingLevel': 'unrecognized',
        'location': ' ',
        'model': '',
        'targetLanguage': '',
        'rawGenerationConfig': {'temperature': double.nan},
      }.entries) {
        expect(
          () => TranslationSettings.fromJson({entry.key: entry.value}),
          throwsFormatException,
          reason: entry.key,
        );
      }
      expect(
        () => TranslationSettings.fromJson({
          'rawGenerationConfig': {1: 'non-string key'},
        }),
        throwsFormatException,
      );
      expect(
        () => TranslationSettings.fromJson({'maxLogEntries': 10001}),
        throwsFormatException,
      );
    });

    test('copyWith retains untouched fields and explicitly clears defaults', () {
      const initial = TranslationSettings(
        projectId: 'project-example',
        maxOutputTokens: 1000,
        fontFamily: 'Custom Font',
        fontSize: 20,
        fontWeight: 700,
        backgroundColor: 0xffffffff,
        textColor: 0xff000000,
      );
      expect(initial.copyWith().toJson(), initial.toJson());
      final reset = initial.copyWith(
        maxOutputTokens: null,
        fontFamily: null,
        fontSize: null,
        fontWeight: null,
        backgroundColor: null,
        textColor: null,
        captureRawBodies: true,
      );
      expect(reset.projectId, initial.projectId);
      expect(reset.maxOutputTokens, isNull);
      expect(reset.fontFamily, isNull);
      expect(reset.fontSize, isNull);
      expect(reset.fontWeight, isNull);
      expect(reset.backgroundColor, isNull);
      expect(reset.textColor, isNull);
      expect(reset.captureRawBodies, isTrue);
      expect(initial.captureRawBodies, isFalse);
    });

    test('JSON snapshots do not share nested generation configuration', () {
      final raw = <String, dynamic>{
        'responseSchema': <String, dynamic>{'type': 'OBJECT'},
      };
      final settings = TranslationSettings.fromJson({
        'rawGenerationConfig': raw,
      });
      (raw['responseSchema'] as Map)['type'] = 'STRING';
      final exported = settings.toJson();
      final exportedRaw = exported['rawGenerationConfig'] as Map;
      (exportedRaw['responseSchema'] as Map)['type'] = 'ARRAY';
      expect(
        (settings.rawGenerationConfig['responseSchema'] as Map)['type'],
        'OBJECT',
      );
    });

    test('credentials in raw configuration are rejected before persistence', () {
      for (final key in [
        'Authorization', 'api_key', 'X-Goog-Api-Key', 'access_token',
        'refreshToken', 'id_token', 'client-secret', 'PRIVATE_KEY',
        'password', 'Cookie', 'Set-Cookie', 'service_account', 'credentials',
      ]) {
        final settings = TranslationSettings(rawGenerationConfig: {
          'thinkingConfig': {
            'nested': [
              {key: 'never-persist-this-secret'},
            ],
          },
        });
        expect(settings.validate(), contains(contains('secure credential')));
        expect(settings.toJson, throwsFormatException);
        expect(
          () => TranslationSettings.fromJson({
            'rawGenerationConfig': settings.rawGenerationConfig,
          }),
          throwsFormatException,
        );
        expect(
          settings.validate().join(' '),
          isNot(contains('never-persist-this-secret')),
        );
      }
    });

    test('incomplete full mode setup is saveable, but not execution ready', () {
      final settings = TranslationSettings.fromJson({});
      expect(settings.validate(), isEmpty);
      expect(settings.validateForExecution(), hasLength(1));
      expect(
        settings.copyWith(projectId: 'project-example').validateForExecution(),
        isEmpty,
      );
      expect(
        settings.copyWith(vertexMode: VertexMode.express).validateForExecution(),
        isEmpty,
      );
    });

    test('all unavailable selections fail runtime support explicitly', () {
      for (final engine in DetectionEngine.values) {
        final errors = const TranslationSettings()
            .copyWith(detectionEngine: engine).validateRuntimeSupport();
        expect(errors, engine == DetectionEngine.ai ? isEmpty : isNotEmpty);
      }
      for (final engine in OcrEngine.values) {
        final errors = const TranslationSettings()
            .copyWith(ocrEngine: engine).validateRuntimeSupport();
        expect(errors, engine == OcrEngine.ai ? isEmpty : isNotEmpty);
      }
      expect(
        const TranslationSettings(inpaintEngine: InpaintEngine.lama)
            .validateRuntimeSupport(),
        contains(contains('unavailable')),
      );
    });
  });

  group('execution policy', () {
    const both = EngineCapabilities(local: true, cloud: true);
    const neither = EngineCapabilities(local: false, cloud: false);

    test('hybrid preferences use the requested concrete engine', () {
      for (final engine in [
        TranslationEngine.ppocr, TranslationEngine.yolo26,
        TranslationEngine.lama,
      ]) {
        final decision = resolveExecution(
          engine: engine, mode: ExecutionMode.hybrid, capabilities: both,
        );
        expect(
          decision.location,
          engine == TranslationEngine.ppocr
              ? ExecutionLocation.local
              : ExecutionLocation.cloud,
        );
        expect(decision.isAvailable, isTrue);
        expect(decision.isFallback, isFalse);
      }
    });

    test('hybrid can fall back only to the same engine at another location', () {
      for (final engine in [
        TranslationEngine.ppocr, TranslationEngine.yolo26,
        TranslationEngine.lama,
      ]) {
        final isPpocr = engine == TranslationEngine.ppocr;
        final decision = resolveExecution(
          engine: engine,
          mode: ExecutionMode.hybrid,
          capabilities: EngineCapabilities(local: !isPpocr, cloud: isPpocr),
        );
        expect(decision.isFallback, isTrue);
        expect(decision.reason, contains('same engine'));
        expect(
          decision.location,
          isPpocr ? ExecutionLocation.cloud : ExecutionLocation.local,
        );
      }
    });

    test('local only never falls back to a cloud vision adapter', () {
      for (final engine in [
        TranslationEngine.ppocr, TranslationEngine.yolo26,
        TranslationEngine.lama,
      ]) {
        final unavailable = resolveExecution(
          engine: engine,
          mode: ExecutionMode.localOnly,
          capabilities: const EngineCapabilities(local: false, cloud: true),
        );
        expect(unavailable.location, isNull);
        expect(unavailable.isAvailable, isFalse);
        expect(unavailable.isFallback, isFalse);
        expect(unavailable.reason, contains('No other engine was substituted'));
        expect(
          resolveExecution(
            engine: engine, mode: ExecutionMode.localOnly, capabilities: both,
          ).location,
          ExecutionLocation.local,
        );
      }
    });

    test('cloud only never falls back to a local vision adapter', () {
      for (final engine in [
        TranslationEngine.ppocr, TranslationEngine.yolo26,
        TranslationEngine.lama,
      ]) {
        final unavailable = resolveExecution(
          engine: engine,
          mode: ExecutionMode.cloudOnly,
          capabilities: const EngineCapabilities(local: true, cloud: false),
        );
        expect(unavailable.location, isNull);
        expect(unavailable.isAvailable, isFalse);
        expect(unavailable.isFallback, isFalse);
        expect(
          resolveExecution(
            engine: engine, mode: ExecutionMode.cloudOnly, capabilities: both,
          ).location,
          ExecutionLocation.cloud,
        );
      }
    });

    test('AI stays cloud and overlays stay local in every execution mode', () {
      for (final mode in ExecutionMode.values) {
        expect(
          resolveExecution(
            engine: TranslationEngine.ai, mode: mode, capabilities: both,
          ).location,
          ExecutionLocation.cloud,
        );
        expect(
          resolveExecution(
            engine: TranslationEngine.overlay, mode: mode, capabilities: both,
          ).location,
          ExecutionLocation.local,
        );
        expect(
          resolveExecution(
            engine: TranslationEngine.ai,
            mode: mode,
            capabilities: const EngineCapabilities(local: true, cloud: false),
          ).isAvailable,
          isFalse,
        );
        expect(
          resolveExecution(
            engine: TranslationEngine.overlay,
            mode: mode,
            capabilities: const EngineCapabilities(local: false, cloud: true),
          ).isAvailable,
          isFalse,
        );
      }
    });

    test('missing adapters are unavailable for every engine and mode', () {
      for (final mode in ExecutionMode.values) {
        for (final engine in TranslationEngine.values) {
          final decision = resolveExecution(
            engine: engine, mode: mode, capabilities: neither,
          );
          expect(decision.isAvailable, isFalse);
          expect(decision.location, isNull);
          expect(decision.reason, contains('unavailable'));
          expect(decision.isFallback, isFalse);
        }
      }
    });
  });
}
