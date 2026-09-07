/// Execution preferences apply to non-AI vision engines. Gemini is always a
/// cloud service; drawing an overlay is always local.
enum ExecutionMode { hybrid, cloudOnly, localOnly }

enum DetectionEngine { ai, ppocr, ppocrAi, yolo26 }

enum OcrEngine { ai, ppocr, ppocrAi }

enum InpaintEngine { overlay, lama }

enum VertexMode { full, express }

const _unchanged = Object();

/// Serializable, non-secret translation preferences.
///
/// Queue limits, retry limits, target language and visual defaults are app
/// preferences, not provider limits. Null font/color values inherit the system
/// theme. API keys and access tokens must be stored separately in secure storage.
/// The requested model is preserved verbatim; settings do not assert that it is
/// available in the provider's model catalog.
/// PP-OCR/YOLO artifact preferences describe upstream model identities, not
/// installed adapters. See docs/translation/engine-support.md for provenance;
/// defaults are application preferences and make no device-performance claim.
class TranslationSettings {
  const TranslationSettings({
    this.executionMode = ExecutionMode.hybrid,
    this.detectionEngine = DetectionEngine.ai,
    this.ocrEngine = OcrEngine.ai,
    this.inpaintEngine = InpaintEngine.overlay,
    this.ppocrDetectionModel = 'PP-OCRv6_small_det',
    this.ppocrRecognitionModel = 'PP-OCRv6_small_rec',
    this.yoloModel = 'yolo26n',
    this.vertexMode = VertexMode.full,
    this.projectId = '',
    this.location = 'global',
    this.model = 'gemini-3.8-flash',
    this.targetLanguage = 'English',
    this.thinkingLevel = 'MEDIUM',
    this.maxOutputTokens,
    this.rawGenerationConfig = const {},
    this.captureRawBodies = false,
    this.timeoutSeconds = 60,
    this.maxRetries = 2,
    this.maxLogEntries = 500,
    this.fontFamily,
    this.fontSize,
    this.fontWeight,
    this.backgroundColor,
    this.textColor,
    this.priorityPaygo = false,
    this.provisionedThroughput = false,
  });

  final ExecutionMode executionMode;
  final DetectionEngine detectionEngine;
  final OcrEngine ocrEngine;
  final InpaintEngine inpaintEngine;
  final String ppocrDetectionModel;
  final String ppocrRecognitionModel;
  final String yoloModel;
  final VertexMode vertexMode;
  final String projectId;
  final String location;
  final String model;
  final String targetLanguage;
  final String thinkingLevel;
  final int? maxOutputTokens;
  final Map<String, dynamic> rawGenerationConfig;
  final bool captureRawBodies;
  final int timeoutSeconds;
  final int maxRetries;
  final int maxLogEntries;
  final String? fontFamily;
  final double? fontSize;
  final int? fontWeight;

  /// ARGB color values. Null means inherit the theme default.
  final int? backgroundColor;
  final int? textColor;
  final bool priorityPaygo;
  final bool provisionedThroughput;

  TranslationSettings copyWith({
    ExecutionMode? executionMode,
    DetectionEngine? detectionEngine,
    OcrEngine? ocrEngine,
    InpaintEngine? inpaintEngine,
    String? ppocrDetectionModel,
    String? ppocrRecognitionModel,
    String? yoloModel,
    VertexMode? vertexMode,
    String? projectId,
    String? location,
    String? model,
    String? targetLanguage,
    String? thinkingLevel,
    Object? maxOutputTokens = _unchanged,
    Map<String, dynamic>? rawGenerationConfig,
    bool? captureRawBodies,
    int? timeoutSeconds,
    int? maxRetries,
    int? maxLogEntries,
    Object? fontFamily = _unchanged,
    Object? fontSize = _unchanged,
    Object? fontWeight = _unchanged,
    Object? backgroundColor = _unchanged,
    Object? textColor = _unchanged,
    bool? priorityPaygo,
    bool? provisionedThroughput,
  }) => TranslationSettings(
    executionMode: executionMode ?? this.executionMode,
    detectionEngine: detectionEngine ?? this.detectionEngine,
    ocrEngine: ocrEngine ?? this.ocrEngine,
    inpaintEngine: inpaintEngine ?? this.inpaintEngine,
    ppocrDetectionModel: ppocrDetectionModel ?? this.ppocrDetectionModel,
    ppocrRecognitionModel: ppocrRecognitionModel ?? this.ppocrRecognitionModel,
    yoloModel: yoloModel ?? this.yoloModel,
    vertexMode: vertexMode ?? this.vertexMode,
    projectId: projectId ?? this.projectId,
    location: location ?? this.location,
    model: model ?? this.model,
    targetLanguage: targetLanguage ?? this.targetLanguage,
    thinkingLevel: thinkingLevel ?? this.thinkingLevel,
    maxOutputTokens: identical(maxOutputTokens, _unchanged)
        ? this.maxOutputTokens
        : maxOutputTokens as int?,
    rawGenerationConfig: rawGenerationConfig ?? this.rawGenerationConfig,
    captureRawBodies: captureRawBodies ?? this.captureRawBodies,
    timeoutSeconds: timeoutSeconds ?? this.timeoutSeconds,
    maxRetries: maxRetries ?? this.maxRetries,
    maxLogEntries: maxLogEntries ?? this.maxLogEntries,
    fontFamily: identical(fontFamily, _unchanged)
        ? this.fontFamily
        : fontFamily as String?,
    fontSize: identical(fontSize, _unchanged)
        ? this.fontSize
        : (fontSize as num?)?.toDouble(),
    fontWeight: identical(fontWeight, _unchanged)
        ? this.fontWeight
        : fontWeight as int?,
    backgroundColor: identical(backgroundColor, _unchanged)
        ? this.backgroundColor
        : backgroundColor as int?,
    textColor: identical(textColor, _unchanged)
        ? this.textColor
        : textColor as int?,
    priorityPaygo: priorityPaygo ?? this.priorityPaygo,
    provisionedThroughput: provisionedThroughput ?? this.provisionedThroughput,
  );

  Map<String, dynamic> toJson() => {
    'executionMode': executionMode.name,
    'detectionEngine': detectionEngine.name,
    'ocrEngine': ocrEngine.name,
    'inpaintEngine': inpaintEngine.name,
    'ppocrDetectionModel': ppocrDetectionModel,
    'ppocrRecognitionModel': ppocrRecognitionModel,
    'yoloModel': yoloModel,
    'vertexMode': vertexMode.name,
    'projectId': projectId,
    'location': location,
    'model': model,
    'targetLanguage': targetLanguage,
    'thinkingLevel': thinkingLevel,
    'maxOutputTokens': maxOutputTokens,
    'rawGenerationConfig': _copyJsonObject(
      rawGenerationConfig,
      'rawGenerationConfig',
    ),
    'captureRawBodies': captureRawBodies,
    'timeoutSeconds': timeoutSeconds,
    'maxRetries': maxRetries,
    'maxLogEntries': maxLogEntries,
    'fontFamily': fontFamily,
    'fontSize': fontSize,
    'fontWeight': fontWeight,
    'backgroundColor': backgroundColor,
    'textColor': textColor,
    'priorityPaygo': priorityPaygo,
    'provisionedThroughput': provisionedThroughput,
  };

  /// Missing fields use app defaults. Present-but-invalid fields throw instead
  /// of silently changing an execution or data-capture preference.
  factory TranslationSettings.fromJson(Map<String, dynamic> json) {
    const defaults = TranslationSettings();
    final settings = TranslationSettings(
      executionMode: _readEnum(
        json,
        'executionMode',
        ExecutionMode.values,
        defaults.executionMode,
      ),
      detectionEngine: _readEnum(
        json,
        'detectionEngine',
        DetectionEngine.values,
        defaults.detectionEngine,
      ),
      ocrEngine: _readEnum(
        json,
        'ocrEngine',
        OcrEngine.values,
        defaults.ocrEngine,
      ),
      inpaintEngine: _readEnum(
        json,
        'inpaintEngine',
        InpaintEngine.values,
        defaults.inpaintEngine,
      ),
      ppocrDetectionModel: _read<String>(
        json,
        'ppocrDetectionModel',
        defaults.ppocrDetectionModel,
      ),
      ppocrRecognitionModel: _read<String>(
        json,
        'ppocrRecognitionModel',
        defaults.ppocrRecognitionModel,
      ),
      yoloModel: _read<String>(json, 'yoloModel', defaults.yoloModel),
      vertexMode: _readEnum(
        json,
        'vertexMode',
        VertexMode.values,
        defaults.vertexMode,
      ),
      projectId: _read<String>(json, 'projectId', defaults.projectId),
      location: _read<String>(json, 'location', defaults.location),
      model: _read<String>(json, 'model', defaults.model),
      targetLanguage: _read<String>(
        json,
        'targetLanguage',
        defaults.targetLanguage,
      ),
      thinkingLevel: _read<String>(
        json,
        'thinkingLevel',
        defaults.thinkingLevel,
      ),
      maxOutputTokens: _readNullable<int>(json, 'maxOutputTokens'),
      rawGenerationConfig: Map.unmodifiable(
        _copyJsonObject(
          json.containsKey('rawGenerationConfig')
              ? json['rawGenerationConfig']
              : const <String, dynamic>{},
          'rawGenerationConfig',
        ),
      ),
      captureRawBodies: _read<bool>(
        json,
        'captureRawBodies',
        defaults.captureRawBodies,
      ),
      timeoutSeconds: _read<int>(
        json,
        'timeoutSeconds',
        defaults.timeoutSeconds,
      ),
      maxRetries: _read<int>(json, 'maxRetries', defaults.maxRetries),
      maxLogEntries: _read<int>(json, 'maxLogEntries', defaults.maxLogEntries),
      fontFamily: _readNullable<String>(json, 'fontFamily'),
      fontSize: _readNullable<num>(json, 'fontSize')?.toDouble(),
      fontWeight: _readNullable<int>(json, 'fontWeight'),
      backgroundColor: _readNullable<int>(json, 'backgroundColor'),
      textColor: _readNullable<int>(json, 'textColor'),
      priorityPaygo: _read<bool>(json, 'priorityPaygo', defaults.priorityPaygo),
      provisionedThroughput: _read<bool>(
        json,
        'provisionedThroughput',
        defaults.provisionedThroughput,
      ),
    );
    final errors = settings.validate();
    if (errors.isNotEmpty) throw FormatException(errors.join(' '));
    return settings;
  }

  /// Validates configuration shape, not model availability or credentials.
  /// Incomplete setup and unavailable engine choices can still be saved.
  List<String> validate() {
    final errors = <String>[];
    if (location.trim().isEmpty) errors.add('Location must not be empty.');
    if (model.trim().isEmpty) errors.add('Model must not be empty.');
    if (targetLanguage.trim().isEmpty) {
      errors.add('Target language must not be empty.');
    }
    final artifactIdentifier = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$');
    for (final entry in {
      'PP-OCR detection model': ppocrDetectionModel,
      'PP-OCR recognition model': ppocrRecognitionModel,
      'YOLO model': yoloModel,
    }.entries) {
      if (!artifactIdentifier.hasMatch(entry.value)) {
        errors.add(
          '${entry.key} must be a non-empty artifact identifier, '
          'not a path, URL, or credential.',
        );
      }
    }
    if (!const ['MINIMAL', 'LOW', 'MEDIUM', 'HIGH'].contains(thinkingLevel)) {
      errors.add('Thinking level must be MINIMAL, LOW, MEDIUM, or HIGH.');
    }
    if (maxOutputTokens != null && maxOutputTokens! <= 0) {
      errors.add('Maximum output tokens must be positive when specified.');
    }
    if (timeoutSeconds <= 0) errors.add('Timeout must be positive.');
    if (maxRetries < 0) errors.add('Maximum retries cannot be negative.');
    if (maxLogEntries <= 0 || maxLogEntries > 10000) {
      errors.add('Maximum log entries must be 1 to 10000 (app safety limit).');
    }
    if (fontSize != null && (!fontSize!.isFinite || fontSize! <= 0)) {
      errors.add('Font size must be finite and positive, or system default.');
    }
    if (fontWeight != null &&
        (fontWeight! < 100 || fontWeight! > 900 || fontWeight! % 100 != 0)) {
      errors.add('Font weight must be 100 to 900 in steps of 100, or default.');
    }
    for (final entry in {
      'Background color': backgroundColor,
      'Text color': textColor,
    }.entries) {
      final value = entry.value;
      if (value != null && (value < 0 || value > 0xffffffff)) {
        errors.add('${entry.key} must be a 32-bit ARGB value, or default.');
      }
    }
    try {
      _copyJsonObject(rawGenerationConfig, 'rawGenerationConfig');
    } on FormatException catch (error) {
      errors.add(error.message.toString());
    }
    return errors;
  }

  /// This initial executable slice implements AI detection, AI OCR and local
  /// overlays only. A stored engine selection must never become mocked work or
  /// silently substitute another engine when its adapter has not been shipped.
  List<String> validateRuntimeSupport() => [
    if (detectionEngine != DetectionEngine.ai)
      '${detectionEngine.name} detection is unavailable: its engine adapter '
          'is not installed. Select AI detection explicitly to run.',
    if (ocrEngine != OcrEngine.ai)
      '${ocrEngine.name} OCR is unavailable: its engine adapter is not '
          'installed. Select AI OCR explicitly to run.',
    if (inpaintEngine != InpaintEngine.overlay)
      'LaMa inpainting is unavailable: its engine adapter is not installed. '
          'Select overlay explicitly to run.',
  ];

  /// Execution readiness excluding secret credentials and server-side checks.
  List<String> validateForExecution() => [
    ...validate(),
    ...validateRuntimeSupport(),
    if (vertexMode == VertexMode.full && projectId.trim().isEmpty)
      'A Google Cloud project ID is required for full Vertex AI mode.',
  ];
}

/// A concrete engine. Compound PP-OCR + AI pipelines resolve their PP-OCR and
/// AI steps separately, so the non-AI privacy policy cannot hide an AI upload.
enum TranslationEngine { ai, ppocr, yolo26, lama, overlay }

enum ExecutionLocation { local, cloud }

class EngineCapabilities {
  const EngineCapabilities({required this.local, required this.cloud});

  final bool local;
  final bool cloud;
}

class ExecutionDecision {
  const ExecutionDecision({
    required this.location,
    required this.reason,
    this.isFallback = false,
  });

  /// Null means unavailable. Callers must surface [reason] and stop that job.
  final ExecutionLocation? location;
  final String reason;
  final bool isFallback;
  bool get isAvailable => location != null;
}

/// Selects an available location for the *same* requested concrete engine.
/// This function never substitutes AI for an unavailable vision adapter.
ExecutionDecision resolveExecution({
  required TranslationEngine engine,
  required ExecutionMode mode,
  required EngineCapabilities capabilities,
}) {
  if (engine == TranslationEngine.ai) {
    return ExecutionDecision(
      location: capabilities.cloud ? ExecutionLocation.cloud : null,
      reason: capabilities.cloud
          ? 'AI uses Gemini in the cloud in every execution mode.'
          : 'AI is unavailable: a cloud Gemini adapter is required.',
    );
  }
  if (engine == TranslationEngine.overlay) {
    return ExecutionDecision(
      location: capabilities.local ? ExecutionLocation.local : null,
      reason: capabilities.local
          ? 'Overlay rendering is local in every execution mode.'
          : 'Overlay rendering is unavailable: a local renderer is required.',
    );
  }

  final preferred = switch (mode) {
    ExecutionMode.localOnly => ExecutionLocation.local,
    ExecutionMode.cloudOnly => ExecutionLocation.cloud,
    ExecutionMode.hybrid =>
      engine == TranslationEngine.ppocr
          ? ExecutionLocation.local
          : ExecutionLocation.cloud,
  };
  bool available(ExecutionLocation location) =>
      location == ExecutionLocation.local
      ? capabilities.local
      : capabilities.cloud;

  if (available(preferred)) {
    return ExecutionDecision(
      location: preferred,
      reason: '${engine.name} will run ${preferred.name} under ${mode.name}.',
    );
  }
  if (mode == ExecutionMode.hybrid) {
    final fallback = preferred == ExecutionLocation.local
        ? ExecutionLocation.cloud
        : ExecutionLocation.local;
    if (available(fallback)) {
      return ExecutionDecision(
        location: fallback,
        isFallback: true,
        reason:
            '${engine.name} ${preferred.name} is unavailable. Hybrid '
            'allows the same engine to run ${fallback.name}.',
      );
    }
  }
  return ExecutionDecision(
    location: null,
    reason:
        '${engine.name} is unavailable under ${mode.name}: no permitted '
        'adapter is available. No other engine was substituted.',
  );
}

T _read<T>(Map<String, dynamic> json, String key, T fallback) {
  if (!json.containsKey(key)) return fallback;
  final value = json[key];
  if (value is! T) throw FormatException('$key has an invalid value type.');
  return value;
}

T? _readNullable<T>(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is! T) throw FormatException('$key has an invalid value type.');
  return value;
}

T _readEnum<T extends Enum>(
  Map<String, dynamic> json,
  String key,
  List<T> values,
  T fallback,
) {
  if (!json.containsKey(key)) return fallback;
  final value = json[key];
  for (final candidate in values) {
    if (candidate.name == value) return candidate;
  }
  throw FormatException('$key contains an unknown enum value: $value.');
}

Map<String, dynamic> _copyJsonObject(Object? value, String path) {
  if (value is! Map) throw FormatException('$path must be a JSON object.');
  final result = <String, dynamic>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is! String) {
      throw FormatException('$path must contain only string keys.');
    }
    if (_isCredentialKey(key)) {
      throw const FormatException(
        'Raw generation configuration must not contain credentials, '
        'authentication, API keys, private keys, passwords, or cookies. '
        'Use secure credential storage instead.',
      );
    }
    result[key] = _copyJsonValue(entry.value, '$path.$key');
  }
  return result;
}

dynamic _copyJsonValue(Object? value, String path) {
  if (value == null || value is String || value is bool) return value;
  if (value is num && value.isFinite) return value;
  if (value is Map) return _copyJsonObject(value, path);
  if (value is List) {
    return [
      for (var index = 0; index < value.length; index++)
        _copyJsonValue(value[index], '$path[$index]'),
    ];
  }
  throw FormatException('$path must contain finite JSON values only.');
}

bool _isCredentialKey(String key) {
  final normalized = key.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
  return const {
        'auth',
        'authorization',
        'authentication',
        'credential',
        'credentials',
        'token',
        'accesstoken',
        'refreshtoken',
        'idtoken',
        'secret',
        'secrets',
        'clientsecret',
        'privatekey',
        'password',
        'passwd',
        'cookie',
        'cookies',
        'setcookie',
        'serviceaccount',
      }.contains(normalized) ||
      normalized.endsWith('apikey');
}
