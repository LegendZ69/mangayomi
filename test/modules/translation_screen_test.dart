import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mangayomi/modules/translation/translation_screen.dart';
import 'package:mangayomi/services/translation/translation_controller.dart';
import 'package:mangayomi/services/translation/translation_settings.dart';
import 'package:mangayomi/services/translation/translation_store.dart';

class _MemoryStore extends TranslationStore {
  Map<String, dynamic>? data;
  final images = <String, Uint8List>{};

  @override
  Future<Map<String, dynamic>?> load() async => data == null
      ? null
      : jsonDecode(jsonEncode(data)) as Map<String, dynamic>;

  @override
  Future<void> save(Map<String, dynamic> value) async {
    data = jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
  }

  @override
  Future<void> saveImage(String id, Uint8List bytes) async {
    images[id] = Uint8List.fromList(bytes);
  }

  @override
  Future<Uint8List> readImage(String id) async => images[id]!;

  @override
  Future<void> deleteImage(String id) async {
    images.remove(id);
  }
}

class _MemoryCredentials extends TranslationCredentialStore {
  final values = <VertexMode, String>{};

  @override
  Future<String?> read(VertexMode mode) async => values[mode];

  @override
  Future<void> write(VertexMode mode, String value) async {
    if (value.isEmpty) {
      values.remove(mode);
    } else {
      values[mode] = value;
    }
  }
}

Future<void> _mount(
  WidgetTester tester,
  TranslationController controller, {
  double textScale = 1,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await controller.initialize();
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: TranslationScreen(controller: controller),
  ));
  await tester.pumpAndSettle();
}

void main() {
  late TranslationController controller;
  late int clientCreations;

  setUp(() {
    clientCreations = 0;
    controller = TranslationController(
      store: _MemoryStore(),
      credentials: _MemoryCredentials(),
      clientFactory: () {
        clientCreations++;
        throw StateError('A widget test must not make a provider request.');
      },
    );
  });

  tearDown(() => controller.dispose());

  testWidgets('iPhone 13 queue has labelled actions and no large-text overflow', (tester) async {
    await _mount(tester, controller, textScale: 1.6);

    expect(find.text('Queue'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Logs'), findsOneWidget);
    expect(find.text('Add page'), findsOneWidget);
    expect(find.text('Run (0)'), findsOneWidget);
    expect(find.text('Pause'), findsOneWidget);
    expect(find.text('Your next chapter, translated'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(clientCreations, 0);
  });

  testWidgets('vision execution options do not imply offline Gemini', (tester) async {
    await _mount(tester, controller, textScale: 1.6);
    await tester.tap(find.widgetWithText(Tab, 'Settings'));
    await tester.pumpAndSettle();

    expect(find.text('Vision engine execution'), findsOneWidget);
    expect(find.textContaining('Local only applies to PP-OCR / YOLO26 / LaMa.'), findsOneWidget);
    final picker = find.byType(DropdownButtonFormField<ExecutionMode>);
    await tester.ensureVisible(picker);
    // ensureVisible changes the scroll offset; paint it before hit testing.
    await tester.pumpAndSettle();
    expect(picker.hitTestable(), findsOneWidget);
    await tester.tap(picker.hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('Cloud only'), findsWidgets);
    await tester.tap(find.text('Local only').last);
    await tester.pumpAndSettle();

    // Selection edits a draft; it does not silently save or upload anything.
    expect(controller.settings.executionMode, ExecutionMode.hybrid);
    expect(find.textContaining('Gemini translation is always cloud-based'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(clientCreations, 0);
  });

  testWidgets('Run requires explicit upload consent and cancellation sends nothing', (tester) async {
    await controller.initialize();
    await controller.enqueue(
      imageBytes: Uint8List.fromList([1, 2, 3]),
      title: 'A manga page with a long descriptive chapter name',
    );
    await _mount(tester, controller);
    await tester.tap(find.text('Run (1)'));
    await tester.pumpAndSettle();

    expect(find.text('Send queued pages for translation?'), findsOneWidget);
    expect(find.textContaining('API charges may apply.'), findsOneWidget);
    expect(find.text('Authorize & run'), findsOneWidget);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();

    expect(controller.isPaused, isTrue);
    expect(controller.jobs.single.status, TranslationJobStatus.queued);
    expect(clientCreations, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('queue and log headers scroll with a keyboard and in landscape', (tester) async {
    await _mount(tester, controller, textScale: 1.6);
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    tester.view.viewInsets = const FakeViewPadding();
    tester.view.physicalSize = const Size(844, 390);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.tap(find.widgetWithText(Tab, 'Logs'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(clientCreations, 0);
  });

  testWidgets('model catalog remains scrollable with large text and a keyboard', (tester) async {
    await _mount(tester, controller, textScale: 1.6);
    await tester.tap(find.widgetWithText(Tab, 'Settings'));
    await tester.pumpAndSettle();
    final browse = find.text('Browse 32 published models');
    await tester.ensureVisible(browse);
    await tester.pumpAndSettle();
    expect(browse.hitTestable(), findsOneWidget);
    await tester.tap(browse.hitTestable());
    await tester.pumpAndSettle();

    expect(find.text('Search model IDs'), findsOneWidget);
    expect(tester.takeException(), isNull);
    tester.view.viewInsets = const FakeViewPadding(bottom: 320);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    tester.view.physicalSize = const Size(844, 390);
    tester.view.viewInsets = const FakeViewPadding(bottom: 120);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(clientCreations, 0);
  });
}
