import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import 'translation_settings.dart';
import 'translation_store.dart';
import 'vertex_translation_client.dart';

enum TranslationJobStatus {
  queued,
  running,
  succeeded,
  failed,
  cancelled,
  interrupted,
}

class TranslationJob {
  TranslationJob({
    required this.id,
    required this.title,
    required this.mimeType,
    required this.settings,
    required this.createdAt,
    this.fingerprint = '',
    DateTime? updatedAt,
    this.status = TranslationJobStatus.queued,
    this.progress = 0,
    this.stage = 'queued',
    this.result,
    this.error,
    List<TranslationApiEvent>? logs,
  }) : updatedAt = updatedAt ?? createdAt,
       _logs = logs ?? [];

  final String id;
  final String title;
  final String mimeType;
  final TranslationSettings settings;
  final DateTime createdAt;
  final String fingerprint;
  DateTime updatedAt;
  TranslationJobStatus status;
  double progress;
  String stage;
  TranslationResult? result;
  String? error;
  final List<TranslationApiEvent> _logs;
  List<TranslationApiEvent> get logs => List.unmodifiable(_logs);

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'mimeType': mimeType,
    'settings': settings.toJson(),
    'createdAt': createdAt.toUtc().toIso8601String(),
    'fingerprint': fingerprint,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'status': status.name,
    'progress': progress,
    'stage': stage,
    'result': result?.toJson(),
    'error': error,
    'logs': _logs.map((event) => event.toJson()).toList(),
  };

  factory TranslationJob.fromJson(Map<String, dynamic> json) => TranslationJob(
    id: json['id'] as String,
    title: json['title'] as String,
    mimeType: json['mimeType'] as String,
    settings: TranslationSettings.fromJson(
      Map<String, dynamic>.from(json['settings'] as Map),
    ),
    createdAt: DateTime.parse(json['createdAt'] as String),
    fingerprint: json['fingerprint'] as String? ?? '',
    updatedAt: DateTime.parse(json['updatedAt'] as String),
    status: TranslationJobStatus.values.byName(json['status'] as String),
    progress: (json['progress'] as num?)?.toDouble() ?? 0,
    stage: json['stage'] as String? ?? 'queued',
    result: json['result'] == null
        ? null
        : TranslationResult.fromJson(
            Map<String, dynamic>.from(json['result'] as Map),
          ),
    error: json['error'] as String?,
    logs: (json['logs'] as List? ?? []).map((event) {
      return TranslationApiEvent.fromJson(
        Map<String, dynamic>.from(event as Map),
      );
    }).toList(),
  );
}

/// One opt-in worker, immutable per-page settings, and durable lifecycle events.
/// Restart never silently repeats a possibly billed request.
class TranslationController extends ChangeNotifier {
  TranslationController({
    TranslationStore? store,
    TranslationCredentialStore? credentials,
    VertexTranslationClient Function()? clientFactory,
    DateTime Function()? clock,
  }) : _store = store ?? TranslationStore(),
       _credentials = credentials ?? TranslationCredentialStore(),
       _clientFactory = clientFactory ?? (() => VertexTranslationClient()),
       _clock = clock ?? DateTime.now;

  static final instance = TranslationController();
  final TranslationStore _store;
  final TranslationCredentialStore _credentials;
  final VertexTranslationClient Function() _clientFactory;
  final DateTime Function() _clock;
  final List<TranslationJob> _jobs = [];
  final List<TranslationApiEvent> _logs = [];
  final Set<String> _pendingEnqueues = {};
  final Set<String> _approvedIds = {};
  TranslationSettings _settings = const TranslationSettings();
  bool _isLoaded = false;
  bool _isPaused = true;
  bool _storageReady = false;
  bool _disposed = false;
  String? _error;
  Future<void>? _initializing;
  Future<void>? _worker;
  VertexTranslationClient? _activeClient;
  String? _activeId;
  String? _activeCredential;
  int _attempt = 0;
  int _sequence = 0;

  List<TranslationJob> get jobs => List.unmodifiable(_jobs);
  List<TranslationApiEvent> get logs => List.unmodifiable(_logs);
  TranslationSettings get settings => _settings;
  bool get isLoaded => _isLoaded;
  bool get isPaused => _isPaused;
  bool get isRunning => _activeId != null;
  String? get error => _error;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() => _initializing ??= _load();

  Future<void> _load() async {
    try {
      final data = await _store.load();
      if (data != null) {
        _settings = TranslationSettings.fromJson(
          Map<String, dynamic>.from(data['settings'] as Map),
        );
        final restored = (data['jobs'] as List).map((job) {
          return TranslationJob.fromJson(Map<String, dynamic>.from(job as Map));
        }).toList();
        // Finish parsing before touching in-memory state if the file is corrupt.
        final restoredLogs = (data['logs'] as List? ?? []).map((event) {
          return TranslationApiEvent.fromJson(
            Map<String, dynamic>.from(event as Map),
          );
        }).toList();
        _jobs.addAll(restored);
        _logs.addAll(restoredLogs);
      }
      _storageReady = true;
      for (final job in _jobs) {
        _trim(job._logs, job.settings.maxLogEntries);
        if (job.status == TranslationJobStatus.running) {
          job.status = TranslationJobStatus.interrupted;
          job.stage = 'interrupted';
          job.updatedAt = _clock();
          job.error = 'App closed during a request. Retry explicitly; the previous request may have been billed.';
          _log('recovery', job.error!, job: job);
        }
      }
      _trim(_logs, _settings.maxLogEntries);
      await _persist();
    } catch (_) {
      _storageReady = false;
      _error = 'Could not load the translation queue. Existing data has not been overwritten.';
    } finally {
      _isLoaded = true;
      _isPaused = true;
      _notify();
    }
  }

  Future<bool> _persist() async {
    if (!_storageReady) return false;
    try {
      await _store.save({
        'version': 1,
        'settings': _settings.toJson(),
        'jobs': _jobs.map((job) => job.toJson()).toList(),
        'logs': _logs.map((event) => event.toJson()).toList(),
      });
      return true;
    } catch (_) {
      _error = 'Could not save the translation queue. Processing is paused; check available storage.';
      _isPaused = true;
      _notify();
      return false;
    }
  }

  Future<bool> saveSettings(TranslationSettings value) async {
    await initialize();
    final problems = [
      ...value.validate(),
      ...VertexTranslationClient.validateGenerationConfig(value),
    ];
    if (problems.isNotEmpty) {
      _error = problems.join('\n');
      _notify();
      return false;
    }
    if (!_storageReady) return false;
    final previous = _settings;
    final snapshot = TranslationSettings.fromJson(value.toJson());
    _settings = snapshot;
    _error = null;
    _trim(_logs, _settings.maxLogEntries);
    final saved = await _persist();
    if (!saved && identical(_settings, snapshot)) _settings = previous;
    _notify();
    return saved;
  }

  Future<bool> saveCredential(VertexMode mode, String value) async {
    try {
      await _credentials.write(mode, value);
      _error = null;
      _notify();
      return true;
    } catch (_) {
      _error = 'Secure credential storage is unavailable. No plaintext copy was saved.';
      _notify();
      return false;
    }
  }

  Future<bool> hasCredential(VertexMode mode) async {
    try {
      return (await _credentials.read(mode))?.isNotEmpty ?? false;
    } catch (_) {
      _error = 'Could not read secure credential storage.';
      _notify();
      return false;
    }
  }

  Future<Uint8List?> readImageBytes(String id) async {
    if (!_jobs.any((job) => job.id == id)) return null;
    try {
      return await _store.readImage(id);
    } catch (_) {
      _error = 'The saved page image could not be read.';
      _notify();
      return null;
    }
  }

  Future<TranslationJob?> enqueue({
    required Uint8List imageBytes,
    required String title,
    String mimeType = 'image/jpeg',
  }) async {
    await initialize();
    if (!_storageReady) return null;
    _isPaused =
        true; // A new image always requires another explicit Run consent.
    if (imageBytes.isEmpty || imageBytes.length > 7000000) {
      _error = 'Choose a non-empty page image no larger than 7 MB (7,000,000 bytes).';
      _notify();
      return null;
    }
    final pageBytes = Uint8List.fromList(imageBytes);
    final now = _clock();
    final snapshot = TranslationSettings.fromJson(_settings.toJson());
    final fingerprint = sha256
        .convert(
          utf8.encode(
            '$mimeType:${sha256.convert(pageBytes)}:${jsonEncode(snapshot.toJson())}',
          ),
        )
        .toString();
    if (_pendingEnqueues.contains(fingerprint) ||
        _jobs.any(
          (job) =>
              job.fingerprint == fingerprint &&
              [
                TranslationJobStatus.queued,
                TranslationJobStatus.running,
              ].contains(job.status),
        )) {
      _error = 'This page with these settings is already queued.';
      _notify();
      return null;
    }
    _pendingEnqueues.add(fingerprint);
    final job = TranslationJob(
      id: '${now.microsecondsSinceEpoch}-${_sequence++}-${Random.secure().nextInt(1 << 32)}',
      title: title.trim().isEmpty ? 'Untitled page' : title.trim(),
      mimeType: mimeType,
      settings: snapshot,
      createdAt: now,
      fingerprint: fingerprint,
    );
    try {
      await _store.saveImage(job.id, pageBytes);
      _jobs.add(job);
      _error = null;
      _log('queued', 'Page queued; waiting for explicit Run.', job: job);
      if (!await _persist()) {
        // Keep the page bytes and in-memory job if a snapshot fails. Another
        // concurrent snapshot may already reference it; deleting here could
        // leave a durable queue entry without its image. Run must persist it
        // successfully before any request can be sent.
        _notify();
        return job;
      }
      _notify();
      return job;
    } catch (_) {
      _error = 'Could not save this page. Nothing was sent to a provider.';
      _notify();
      return null;
    } finally {
      _pendingEnqueues.remove(fingerprint);
    }
  }

  Future<void> run() async {
    await initialize();
    if (!_storageReady || _disposed) return;
    _approvedIds
      ..clear()
      ..addAll(
        _jobs
            .where((job) => job.status == TranslationJobStatus.queued)
            .map((job) => job.id),
      );
    _isPaused = false;
    _error = null;
    _notify();
    // Repeated taps join the same worker; at most one request can run.
    final existingWorker = _worker;
    if (existingWorker != null) return existingWorker;
    final worker = _drain();
    _worker = worker;
    try {
      await worker;
    } finally {
      _worker = null;
      _notify();
    }
  }

  void pause() {
    _isPaused = true;
    _notify();
  }

  Future<void> _drain() async {
    while (!_isPaused && !_disposed) {
      final queued = _jobs.where(
        (job) =>
            job.status == TranslationJobStatus.queued &&
            _approvedIds.contains(job.id),
      );
      if (queued.isEmpty) break;
      await _process(queued.first);
    }
    _isPaused = true;
    _notify();
  }

  bool _current(TranslationJob job, int attempt) =>
      !_disposed &&
      _attempt == attempt &&
      job.status == TranslationJobStatus.running;

  Future<void> _process(TranslationJob job) async {
    final attempt = ++_attempt;
    _activeId = job.id;
    job.status = TranslationJobStatus.running;
    job.stage = 'validating';
    job.progress = 0.05;
    job.error = null;
    job.updatedAt = _clock();
    _log(
      'validating',
      'Validating requested execution and pipeline settings.',
      job: job,
    );
    _notify();
    try {
      // Persist running BEFORE reading credentials or starting a paid request.
      if (!await _persist()) {
        job.status = TranslationJobStatus.failed;
        job.stage = 'failed';
        job.error =
            'Could not durably record this attempt. No request was sent.';
        return;
      }
      if (!_current(job, attempt)) return;
      final problems = [
        ...job.settings.validateForExecution(),
        ...VertexTranslationClient.validateGenerationConfig(job.settings),
      ];
      if (problems.isNotEmpty) {
        throw TranslationApiException(
          'unsupported_configuration',
          problems.join('\n'),
        );
      }
      final credential = await _credentials.read(job.settings.vertexMode);
      if (!_current(job, attempt)) return;
      if (credential == null || credential.trim().isEmpty) {
        throw TranslationApiException(
          'missing_credential',
          'Save a credential for the selected Vertex mode before running.',
        );
      }
      _activeCredential = credential;
      final bytes = await _store.readImage(job.id);
      if (!_current(job, attempt)) return;
      final client = _clientFactory();
      _activeClient = client;
      job.stage = 'requesting';
      job.progress = 0.2;
      _notify();
      final result = await client.translate(
        imageBytes: bytes,
        mimeType: job.mimeType,
        settings: job.settings,
        credential: credential,
        onEvent: (event) {
          if (!_current(job, attempt)) return;
          _record(event, job: job);
          job.stage = event.phase;
          job.updatedAt = _clock();
          _notify();
          unawaited(_persist());
        },
      );
      if (!_current(job, attempt)) return;
      job.result = result;
      job.status = TranslationJobStatus.succeeded;
      job.stage = 'succeeded';
      job.progress = 1;
      _log(
        'succeeded',
        'Translation completed.',
        job: job,
        data: {
          'regionCount': result.regions.length,
          'usageMetadata': result.usageMetadata,
        },
      );
    } catch (failure) {
      if (!_current(job, attempt)) return;
      job.status = TranslationJobStatus.failed;
      job.stage = 'failed';
      job.error = failure is TranslationApiException
          ? _redact(failure.message).toString()
          : 'Translation failed (${failure.runtimeType}). Check the saved image, secure storage, and connectivity.';
      _log(
        'failed',
        job.error!,
        job: job,
        data: {if (failure is TranslationApiException) 'code': failure.code},
      );
    } finally {
      _activeClient?.close();
      _activeClient = null;
      _activeId = null;
      _activeCredential = null;
      job.updatedAt = _clock();
      await _persist();
      _notify();
    }
  }

  TranslationJob? _find(String id) {
    for (final job in _jobs) {
      if (job.id == id) return job;
    }
    return null;
  }

  Future<void> cancel(String id) async {
    final job = _find(id);
    if (job == null ||
        ![
          TranslationJobStatus.queued,
          TranslationJobStatus.running,
        ].contains(job.status)) {
      return;
    }
    if (_activeId == id) {
      ++_attempt; // Ignore a late success even if transport cancellation loses a race.
      _activeClient?.cancel();
    }
    job.status = TranslationJobStatus.cancelled;
    job.stage = 'cancelled';
    job.updatedAt = _clock();
    _log(
      'cancelled',
      'Cancelled locally. A provider request already sent may still be billed.',
      job: job,
    );
    await _persist();
    _notify();
  }

  Future<void> retry(String id) async {
    final job = _find(id);
    if (job == null ||
        _activeId == id ||
        ![
          TranslationJobStatus.failed,
          TranslationJobStatus.cancelled,
          TranslationJobStatus.interrupted,
        ].contains(job.status)) {
      return;
    }
    _isPaused = true;
    job.status = TranslationJobStatus.queued;
    job.stage = 'queued';
    job.progress = 0;
    job.error = null;
    job.result = null;
    job.updatedAt = _clock();
    _log(
      'queued',
      'Explicit retry queued with its original settings; Run is required.',
      job: job,
    );
    await _persist();
    _notify();
  }

  /// An explicit new job, never an edit to the original request or its history.
  /// Enqueue pauses the queue and requires a fresh Run/upload confirmation.
  Future<TranslationJob?> requeueWithCurrentSettings(String id) async {
    await initialize();
    final job = _find(id);
    if (job == null || _activeId == id) return null;
    final bytes = await readImageBytes(id);
    if (bytes == null || _activeId == id) return null;
    return enqueue(imageBytes: bytes, title: job.title, mimeType: job.mimeType);
  }

  Future<void> remove(String id) async {
    final job = _find(id);
    if (job == null ||
        _activeId == id ||
        [
          TranslationJobStatus.queued,
          TranslationJobStatus.running,
        ].contains(job.status)) {
      return;
    }
    final index = _jobs.indexOf(job);
    _jobs.remove(job);
    // Commit removal before deleting bytes: never leave a durable job without
    // its image because a state write failed.
    if (!await _persist()) {
      _jobs.insert(index.clamp(0, _jobs.length).toInt(), job);
    } else {
      try {
        await _store.deleteImage(id);
      } catch (_) {
        _error = 'Job removed, but its saved image could not be deleted.';
      }
    }
    _notify();
  }

  Future<void> clearLogs() async {
    _logs.clear();
    for (final job in _jobs) {
      job._logs.clear();
    }
    await _persist();
    _notify();
  }

  String exportLogs() => const JsonEncoder.withIndent('  ').convert(
    _redact({
      'version': 1,
      'exportedAt': _clock().toUtc().toIso8601String(),
      'notice': 'Credentials and inline image data are redacted. Raw bodies may contain page text; review before sharing.',
      'events': _logs.map((event) => event.toJson()).toList(),
      'jobs': _jobs
          .map(
            (job) => {
              'id': job.id,
              'title': job.title,
              'status': job.status.name,
              'settings': job.settings.toJson(),
              'error': job.error,
              'events': job.logs.map((event) => event.toJson()).toList(),
            },
          )
          .toList(),
    }),
  );

  void _trim(List<TranslationApiEvent> events, int limit) {
    final bounded = limit.clamp(1, 10000).toInt();
    if (events.length > bounded) events.removeRange(0, events.length - bounded);
  }

  void _log(
    String phase,
    String message, {
    TranslationJob? job,
    Map<String, dynamic> data = const {},
  }) {
    _record(
      TranslationApiEvent(
        timestamp: _clock(),
        phase: phase,
        message: message,
        data: data,
      ),
      job: job,
    );
  }

  void _record(TranslationApiEvent event, {TranslationJob? job}) {
    final safe = TranslationApiEvent(
      timestamp: event.timestamp,
      phase: event.phase,
      message: _redact(event.message).toString(),
      data: {
        ...Map<String, dynamic>.from(_redact(event.data) as Map),
        if (job != null) 'jobId': job.id,
      },
    );
    _logs.add(safe);
    _trim(_logs, _settings.maxLogEntries);
    if (job != null) {
      job._logs.add(safe);
      _trim(job._logs, job.settings.maxLogEntries);
    }
  }

  Object? _redact(Object? value) {
    if (value is Map) {
      return value.map(
        (key, entry) => MapEntry(
          key.toString(),
          RegExp(
                r'authorization|credential|api.?key|access.?token|refresh.?token|secret|password|private.?key|cookie|signature|inline.?data|file.?data|image.?bytes|base64|^key$',
                caseSensitive: false,
              ).hasMatch(key.toString())
              ? '[REDACTED]'
              : _redact(entry),
        ),
      );
    }
    if (value is List) return value.map(_redact).toList();
    if (value is String) {
      final safe = redactTranslationData(
        value,
        secrets: [?_activeCredential],
      ).toString().replaceAll(RegExp(r'AIza[0-9A-Za-z_-]+'), '[REDACTED]');
      return safe.length > 16000
          ? '${safe.substring(0, 16000)} [TRUNCATED]'
          : safe;
    }
    return value;
  }

  @override
  void dispose() {
    _disposed = true;
    _isPaused = true;
    ++_attempt;
    _activeClient?.cancel();
    super.dispose();
  }
}
