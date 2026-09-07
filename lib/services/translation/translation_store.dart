import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'translation_settings.dart';

/// App-owned queue storage, deliberately independent of the Isar schema.
/// Atomic replacement and serialization preserve the previous complete snapshot
/// if a write fails. Credentials never enter this store.
class TranslationStore {
  TranslationStore({this._directory});

  Directory? _directory;
  Future<void> _writes = Future<void>.value();

  Future<Directory> _root() async {
    final directory = _directory ??= Directory(
      '${(await getApplicationSupportDirectory()).path}/translation_queue_v1',
    );
    await directory.create(recursive: true);
    return directory;
  }

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final result = _writes.then((_) => operation());
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<Map<String, dynamic>?> load() async {
    await _writes;
    final file = File('${(await _root()).path}/queue.json');
    if (!await file.exists()) return null;
    final data = jsonDecode(await file.readAsString());
    if (data is! Map<String, dynamic> || data['version'] != 1) {
      throw const FormatException('Unsupported translation queue data.');
    }
    return data;
  }

  Future<void> save(Map<String, dynamic> data) {
    // Encode now so later caller mutations cannot change an enqueued snapshot.
    final encoded = utf8.encode(jsonEncode(data));
    return _serialized(() async {
      final target = File('${(await _root()).path}/queue.json');
      final temporary = File('${target.path}.tmp');
      await temporary.writeAsBytes(encoded, flush: true);
      await temporary.rename(target.path);
    });
  }

  Future<File> _image(String id) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,96}$').hasMatch(id)) {
      throw ArgumentError.value(id, 'id', 'Invalid translation job identifier');
    }
    final directory = Directory('${(await _root()).path}/images');
    await directory.create(recursive: true);
    return File('${directory.path}/$id.bin');
  }

  Future<void> saveImage(String id, Uint8List bytes) => _serialized(() async {
    final target = await _image(id);
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(target.path);
  });

  Future<Uint8List> readImage(String id) async {
    await _writes;
    return (await _image(id)).readAsBytes();
  }

  /// Only accepts one validated job ID; never traverses/deletes directories.
  Future<void> deleteImage(String id) => _serialized(() async {
    final file = await _image(id);
    if (await file.exists()) await file.delete();
  });
}

/// Platform-backed secret storage. Failure is surfaced; there is no plaintext
/// fallback. Full mode accepts a user-supplied short-lived OAuth access token;
/// express mode accepts an API key. Neither is returned to the settings UI.
class TranslationCredentialStore {
  TranslationCredentialStore({FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  String _key(VertexMode mode) => 'mangayomi.translation.vertex.${mode.name}';

  Future<String?> read(VertexMode mode) => _storage.read(key: _key(mode));

  Future<void> write(VertexMode mode, String value) async {
    final credential = value.trim();
    if (credential.isEmpty) {
      await _storage.delete(key: _key(mode));
    } else {
      await _storage.write(key: _key(mode), value: credential);
    }
  }
}
