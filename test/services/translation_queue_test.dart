import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/services/translation/translation_controller.dart';
import 'package:mangayomi/services/translation/translation_settings.dart';
import 'package:mangayomi/services/translation/translation_store.dart';
import 'package:mangayomi/services/translation/vertex_translation_client.dart';

const _result = TranslationResult(regions: []);

Map<String, dynamic> _copy(Map<String, dynamic> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

class _MemoryStore extends TranslationStore {
  Map<String, dynamic>? data;
  final images = <String, Uint8List>{};
  final deleted = <String>[];
  bool failSaves = false;
  bool failLoad = false;
  int imageReads = 0;
  Completer<void>? imageWriteGate;

  @override
  Future<Map<String, dynamic>?> load() async {
    if (failLoad) throw const FormatException('bad queue');
    return data == null ? null : _copy(data!);
  }

  @override
  Future<void> save(Map<String, dynamic> value) async {
    if (failSaves) throw const FileSystemException('disk full');
    data = _copy(value);
  }

  @override
  Future<void> saveImage(String id, Uint8List bytes) async {
    if (imageWriteGate != null) await imageWriteGate!.future;
    images[id] = Uint8List.fromList(bytes);
  }

  @override
  Future<Uint8List> readImage(String id) async {
    imageReads++;
    return images[id]!;
  }

  @override
  Future<void> deleteImage(String id) async {
    deleted.add(id);
    images.remove(id);
  }
}

class _MemoryCredentials extends TranslationCredentialStore {
  final values = <VertexMode, String>{VertexMode.full: 'test-secret'};
  int reads = 0;
  bool fail = false;

  @override
  Future<String?> read(VertexMode mode) async {
    reads++;
    if (fail) throw StateError('unavailable');
    return values[mode];
  }

  @override
  Future<void> write(VertexMode mode, String value) async {
    if (fail) throw StateError('unavailable');
    if (value.trim().isEmpty) {
      values.remove(mode);
    } else {
      values[mode] = value.trim();
    }
  }
}

class _ControlledClient extends VertexTranslationClient {
  final completion = Completer<TranslationResult>();
  void Function(TranslationApiEvent)? emit;
  TranslationSettings? receivedSettings;
  bool cancelled = false;
  bool closed = false;

  @override
  Future<TranslationResult> translate({
    required Uint8List imageBytes,
    required String mimeType,
    required TranslationSettings settings,
    required String credential,
    void Function(TranslationApiEvent)? onEvent,
  }) {
    emit = onEvent;
    receivedSettings = settings;
    return completion.future;
  }

  @override
  void cancel() {
    cancelled = true;
    super.cancel();
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}

Future<void> _until(bool Function() condition) async {
  for (var step = 0; step < 200; step++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('The expected queue transition did not occur.');
}

void main() {
  late _MemoryStore store;
  late _MemoryCredentials credentials;
  late List<_ControlledClient> clients;
  late TranslationController controller;

  setUp(() async {
    store = _MemoryStore();
    credentials = _MemoryCredentials();
    clients = [];
    controller = TranslationController(
      store: store,
      credentials: credentials,
      clientFactory: () {
        final client = _ControlledClient();
        clients.add(client);
        return client;
      },
    );
    await controller.initialize();
    await controller.saveSettings(
      const TranslationSettings(projectId: 'test-project'),
    );
  });

  tearDown(() => controller.dispose());

  Future<TranslationJob> addPage([int byte = 1]) async => (await controller
      .enqueue(imageBytes: Uint8List.fromList([byte]), title: 'Page $byte'))!;

  test('empty and oversized reader pages are rejected before saving', () async {
    for (final bytes in [Uint8List(0), Uint8List(7000001)]) {
      expect(
        await controller.enqueue(imageBytes: bytes, title: 'Invalid page'),
        isNull,
      );
    }
    expect(controller.jobs, isEmpty);
    expect(store.images, isEmpty);
    expect(clients, isEmpty);
    expect(credentials.reads, 0);
    expect(controller.isPaused, isTrue);
  });

  test(
    'enqueue is durable and paused; duplicate rapid imports do not queue twice',
    () async {
      final results = await Future.wait([
        controller.enqueue(imageBytes: Uint8List.fromList([1]), title: 'A'),
        controller.enqueue(imageBytes: Uint8List.fromList([1]), title: 'A'),
      ]);
      expect(results.whereType<TranslationJob>(), hasLength(1));
      expect(controller.jobs, hasLength(1));
      expect(controller.isPaused, isTrue);
      expect(clients, isEmpty);
      expect(credentials.reads, 0);
      expect(store.data!['jobs'], hasLength(1));
      expect(store.images, hasLength(1));
    },
  );

  test(
    'pause lets the active request finish but prevents the next request',
    () async {
      final first = await addPage();
      final second = await addPage(2);
      final running = controller.run();
      await _until(() => clients.isNotEmpty);
      controller.pause();
      clients.first.completion.complete(_result);
      await running;
      expect(first.status, TranslationJobStatus.succeeded);
      expect(second.status, TranslationJobStatus.queued);
      expect(clients, hasLength(1));
      expect(controller.isPaused, isTrue);
    },
  );

  test(
    'new import during a run pauses further dispatch pending fresh consent',
    () async {
      await addPage();
      final running = controller.run();
      await _until(() => clients.isNotEmpty);
      final added = await addPage(2);
      clients.first.completion.complete(_result);
      await running;
      expect(added.status, TranslationJobStatus.queued);
      expect(clients, hasLength(1));
    },
  );

  test(
    'Run approves only visible queued IDs, not a still-pending import',
    () async {
      await addPage();
      store.imageWriteGate = Completer<void>();
      final pendingImport = addPage(2);
      // Allow enqueue to reach its asynchronous image write before Run.
      await Future<void>.delayed(Duration.zero);
      final running = controller.run();
      await _until(() => clients.isNotEmpty);
      store.imageWriteGate!.complete();
      final imported = await pendingImport;
      clients.single.completion.complete(_result);
      await running;
      expect(imported.status, TranslationJobStatus.queued);
      expect(controller.isPaused, isTrue);
      expect(clients, hasLength(1));
    },
  );

  test(
    'cancel closes transport and suppresses late completion; retry is explicit',
    () async {
      final job = await addPage();
      final running = controller.run();
      await _until(() => clients.isNotEmpty);
      await controller.cancel(job.id);
      expect(clients.single.cancelled, isTrue);
      clients.single.completion.complete(
        _result,
      ); // Deliberately ignores cancellation.
      await running;
      expect(job.status, TranslationJobStatus.cancelled);
      expect(job.result, isNull);
      await controller.retry(job.id);
      expect(job.status, TranslationJobStatus.queued);
      expect(controller.isPaused, isTrue);
      expect(clients, hasLength(1));
      final retried = controller.run();
      await _until(() => clients.length == 2);
      clients.last.completion.complete(_result);
      await retried;
      expect(job.status, TranslationJobStatus.succeeded);
    },
  );

  test('repeated Run taps never create parallel workers', () async {
    await addPage();
    final firstRun = controller.run();
    final secondRun = controller.run();
    await _until(() => clients.isNotEmpty);
    expect(clients, hasLength(1));
    clients.single.completion.complete(_result);
    await Future.wait([firstRun, secondRun]);
    expect(clients, hasLength(1));
  });

  test(
    'cold launch converts running to interrupted and never resubmits it',
    () async {
      final job = await addPage();
      final persistedJob =
          (store.data!['jobs'] as List).single as Map<String, dynamic>;
      persistedJob['status'] = 'running';
      controller.dispose();
      controller = TranslationController(
        store: store,
        credentials: credentials,
        clientFactory: () => throw StateError('Must not run on initialization'),
      );
      await controller.initialize();
      expect(controller.jobs.single.id, job.id);
      expect(controller.jobs.single.status, TranslationJobStatus.interrupted);
      expect(controller.jobs.single.error, contains('may have been billed'));
      expect(controller.isPaused, isTrue);
      await controller.run();
      expect(credentials.reads, 0);
      expect(controller.jobs.single.status, TranslationJobStatus.interrupted);
    },
  );

  test(
    'unavailable engines fail before image/secret reads or client construction',
    () async {
      for (final engine in [
        DetectionEngine.ppocr,
        DetectionEngine.ppocrAi,
        DetectionEngine.yolo26,
      ]) {
        await controller.saveSettings(
          controller.settings.copyWith(detectionEngine: engine),
        );
        final job = await addPage(engine.index + 1);
        await controller.run();
        expect(job.status, TranslationJobStatus.failed);
        expect(job.error, contains('unavailable'));
      }
      expect(credentials.reads, 0);
      expect(store.imageReads, 0);
      expect(clients, isEmpty);
    },
  );

  test(
    'enqueued settings are deep snapshots and do not change on edits',
    () async {
      final raw = <String, dynamic>{'seed': 1};
      await controller.saveSettings(
        controller.settings.copyWith(rawGenerationConfig: raw),
      );
      final job = await addPage();
      raw['seed'] = 2;
      await controller.saveSettings(
        controller.settings.copyWith(targetLanguage: 'French'),
      );
      expect(job.settings.targetLanguage, 'English');
      expect(job.settings.rawGenerationConfig['seed'], 1);
      final running = controller.run();
      await _until(() => clients.isNotEmpty);
      expect(clients.single.receivedSettings!.targetLanguage, 'English');
      clients.single.completion.complete(_result);
      await running;
    },
  );

  test(
    'requeue uses current settings without altering original history',
    () async {
      await controller.saveSettings(const TranslationSettings());
      final original = await addPage();
      await controller.saveSettings(
        const TranslationSettings(
          projectId: 'configured-project',
          targetLanguage: 'French',
        ),
      );
      final requeued = await controller.requeueWithCurrentSettings(original.id);
      expect(requeued, isNotNull);
      expect(requeued!.id, isNot(original.id));
      expect(requeued.settings.projectId, 'configured-project');
      expect(requeued.settings.targetLanguage, 'French');
      expect(original.settings.projectId, isEmpty);
      expect(original.settings.targetLanguage, 'English');
      expect(controller.jobs, hasLength(2));
      expect(controller.isPaused, isTrue);
      expect(clients, isEmpty);
    },
  );

  test('cannot dispatch if running state could not be persisted', () async {
    final job = await addPage();
    store.failSaves = true;
    await controller.run();
    expect(job.status, TranslationJobStatus.failed);
    expect(job.error, contains('No request was sent'));
    expect(clients, isEmpty);
    expect(credentials.reads, 0);
    expect(controller.isPaused, isTrue);
  });

  test(
    'failed enqueue snapshot retains page bytes until a durable run',
    () async {
      store.failSaves = true;
      final job = await addPage();
      expect(store.images.containsKey(job.id), isTrue);
      expect(controller.isPaused, isTrue);
      expect(clients, isEmpty);
      expect(controller.error, contains('Could not save'));
      store.failSaves = false;
      final running = controller.run();
      await _until(() => clients.isNotEmpty);
      expect((store.data!['jobs'] as List).single['status'], 'running');
      clients.single.completion.complete(_result);
      await running;
      expect(job.status, TranslationJobStatus.succeeded);
    },
  );

  test(
    'corrupt queue is not overwritten by initialization or enqueue',
    () async {
      final original = jsonEncode(store.data);
      store.failLoad = true;
      controller.dispose();
      controller = TranslationController(
        store: store,
        credentials: credentials,
      );
      await controller.initialize();
      final added = await controller.enqueue(
        imageBytes: Uint8List.fromList([1]),
        title: 'A',
      );
      expect(added, isNull);
      expect(controller.error, contains('not been overwritten'));
      expect(jsonEncode(store.data), original);
    },
  );

  test(
    'logs retain structured payloads, redact secrets and stay bounded',
    () async {
      await controller.saveSettings(
        controller.settings.copyWith(maxLogEntries: 3),
      );
      final job = await addPage();
      final running = controller.run();
      await _until(() => clients.isNotEmpty);
      for (var index = 0; index < 6; index++) {
        clients.single.emit!(
          TranslationApiEvent(
            timestamp: DateTime.now(),
            phase: 'response',
            message: 'Bearer test-secret',
            data: {
              'requestIndex': index,
              'authorization': 'test-secret',
              'nested': {
                'apiKey': 'private-key',
                'inlineData': {'data': 'image-content'},
              },
              'usageMetadata': {'promptTokenCount': 12},
            },
          ),
        );
      }
      clients.single.completion.complete(_result);
      await running;
      final exported = controller.exportLogs();
      expect(exported, isNot(contains('test-secret')));
      expect(exported, isNot(contains('private-key')));
      expect(exported, isNot(contains('image-content')));
      expect(exported, contains('promptTokenCount'));
      expect(exported, contains('requestIndex'));
      expect(controller.logs, hasLength(3));
      expect(job.logs, hasLength(3));
      expect(jsonEncode(store.data), isNot(contains('test-secret')));
    },
  );

  test(
    'secure storage failure surfaces without a plaintext fallback',
    () async {
      credentials.fail = true;
      expect(
        await controller.saveCredential(VertexMode.express, 'never-on-disk'),
        isFalse,
      );
      expect(controller.error, contains('No plaintext copy'));
      expect(jsonEncode(store.data), isNot(contains('never-on-disk')));
    },
  );

  test(
    'raw credential fields are rejected before settings persistence',
    () async {
      final original = jsonEncode(store.data);
      for (final raw in <Map<String, dynamic>>[
        {'apiKey': 'never-on-disk'},
        {'accessToken': 'never-on-disk'},
        {
          'thinkingConfig': {
            'thinkingLevel': 'MEDIUM',
            'credential': 'never-on-disk',
          },
        },
      ]) {
        final saved = await controller.saveSettings(
          controller.settings.copyWith(rawGenerationConfig: raw),
        );
        expect(saved, isFalse);
        expect(jsonEncode(store.data), original);
        expect(jsonEncode(store.data), isNot(contains('never-on-disk')));
      }
    },
  );

  test(
    'remove only deletes terminal jobs and commits before removing bytes',
    () async {
      final job = await addPage();
      await controller.remove(job.id);
      expect(controller.jobs, hasLength(1));
      await controller.cancel(job.id);
      store.failSaves = true;
      await controller.remove(job.id);
      expect(controller.jobs, hasLength(1));
      expect(store.deleted, isEmpty);
      store.failSaves = false;
      await controller.remove(job.id);
      expect(controller.jobs, isEmpty);
      expect(store.deleted, [job.id]);
    },
  );

  test('file store serializes snapshots and refuses traversal IDs', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'translation-store-test-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final fileStore = TranslationStore(directory: temporary);
    await Future.wait([
      fileStore.save({'version': 1, 'sequence': 1}),
      fileStore.save({'version': 1, 'sequence': 2}),
    ]);
    expect((await fileStore.load())!['sequence'], 2);
    await expectLater(fileStore.deleteImage('../outside'), throwsArgumentError);
    await fileStore.saveImage('safe-id', Uint8List.fromList([1, 2]));
    expect(await fileStore.readImage('safe-id'), [1, 2]);
    await fileStore.deleteImage('safe-id');
    expect(
      await File('${temporary.path}/images/safe-id.bin').exists(),
      isFalse,
    );
  });
}
