import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mangayomi/services/translation/translation_controller.dart';
import 'package:mangayomi/services/translation/translation_settings.dart';
import 'package:mangayomi/services/translation/vertex_translation_client.dart';

/// An aspect-correct, memory-bounded preview of a queued page and its overlay.
class TranslationPreview extends StatefulWidget {
  const TranslationPreview({super.key, required this.job, this.controller});
  final TranslationJob job;
  final TranslationController? controller;

  @override
  State<TranslationPreview> createState() => _TranslationPreviewState();
}

class _TranslationPreviewState extends State<TranslationPreview> {
  late final TranslationController _controller;
  final _transformation = TransformationController();
  ui.Image? _image;
  Size? _sourceSize;
  String? _loadError;
  bool _showTranslation = true;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? TranslationController.instance;
    _loadPage();
  }

  @override
  void dispose() {
    _image?.dispose();
    _transformation.dispose();
    super.dispose();
  }

  Future<void> _loadPage() async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? decoded;
    try {
      final bytes = await _controller.readImageBytes(widget.job.id);
      if (bytes == null || bytes.isEmpty) {
        throw const FormatException('The saved page is no longer available.');
      }
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      // Read dimensions without first decoding a potentially huge long strip.
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final width = descriptor.width;
      final height = descriptor.height;
      if (width <= 0 || height <= 0) {
        throw const FormatException('The page dimensions are invalid.');
      }
      // App preview memory policy, not a provider/image-model limit.
      const maxPreviewPixels = 4000000;
      const maxPreviewSide = 8192;
      final scale = math.min(
        1.0,
        math.min(
          math.sqrt(maxPreviewPixels / (width * height)),
          maxPreviewSide / math.max(width, height),
        ),
      );
      codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (width * scale).floor()),
        targetHeight: math.max(1, (height * scale).floor()),
      );
      decoded = (await codec.getNextFrame()).image;
      if (!mounted) return;
      setState(() {
        _image = decoded;
        _sourceSize = Size(width.toDouble(), height.toDouble());
      });
      decoded = null; // The widget now owns the decoded image.
    } catch (_) {
      if (mounted) {
        setState(() => _loadError =
            'The saved page could not be decoded. Re-import it as JPEG, PNG, or WebP.');
      }
    } finally {
      decoded?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    child: AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final job = _controller.jobs
            .where((candidate) => candidate.id == widget.job.id)
            .firstOrNull ?? widget.job;
        return Scaffold(
          appBar: AppBar(
            title: Text(job.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            bottom: const TabBar(
              tabs: [
                Tab(text: 'Page', icon: Icon(Icons.image_outlined)),
                Tab(text: 'Text', icon: Icon(Icons.translate)),
                Tab(text: 'Details', icon: Icon(Icons.info_outline)),
              ],
            ),
          ),
          body: SafeArea(
            top: false,
            child: TabBarView(
              children: [
                _page(context, job),
                _transcript(context, job),
                _details(context, job),
              ],
            ),
          ),
        );
      },
    ),
  );

  Widget _page(BuildContext context, TranslationJob job) => CustomScrollView(
    slivers: [
      SliverToBoxAdapter(child: Column(children: [
        Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: const Text('Translation overlay'),
                subtitle: Text(job.result == null
                    ? 'Available after translation completes'
                    : 'Pinch to zoom; drag to read'),
                value: _showTranslation,
                onChanged: job.result == null
                    ? null
                    : (value) => setState(() => _showTranslation = value),
              ),
            ),
            IconButton(
              tooltip: 'Reset zoom and position',
              onPressed: () => _transformation.value = Matrix4.identity(),
              icon: const Icon(Icons.fit_screen),
            ),
          ],
        ),
        ),
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            'Preview only; original page is unchanged. Full text is in the Text tab. '
            'Preview decoding is capped at 4 million pixels / 8,192 pixels per side.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ])),
      SliverFillRemaining(
        hasScrollBody: true,
        child: _loadError != null
            ? Center(child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(_loadError!, textAlign: TextAlign.center),
              ))
            : _image == null || _sourceSize == null
                ? const Center(child: CircularProgressIndicator())
                : LayoutBuilder(
                    builder: (context, constraints) {
                      final width = constraints.maxWidth;
                      final height = width * _sourceSize!.height / _sourceSize!.width;
                      return ClipRect(
                        child: InteractiveViewer(
                          transformationController: _transformation,
                          constrained: false,
                          alignment: Alignment.topLeft,
                          minScale: 1,
                          maxScale: 6,
                          boundaryMargin: const EdgeInsets.all(24),
                          child: SizedBox(
                            width: width,
                            height: height,
                            child: Stack(
                              children: [
                                Positioned.fill(
                                  child: Semantics(
                                    label: 'Original page: ${job.title}',
                                    image: true,
                                    child: RawImage(image: _image, fit: BoxFit.fill),
                                  ),
                                ),
                                if (_showTranslation && job.result != null)
                                  for (final region in job.result!.regions)
                                    _regionOverlay(context, region, job.settings, width, height),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
      ),
    ],
  );

  Widget _regionOverlay(
    BuildContext context,
    TranslationRegion region,
    TranslationSettings settings,
    double pageWidth,
    double pageHeight,
  ) {
    final left = region.left.clamp(0, 1000) / 1000 * pageWidth;
    final top = region.top.clamp(0, 1000) / 1000 * pageHeight;
    final right = region.right.clamp(0, 1000) / 1000 * pageWidth;
    final bottom = region.bottom.clamp(0, 1000) / 1000 * pageHeight;
    final width = math.max(1.0, right - left);
    final height = math.max(1.0, bottom - top);
    final theme = Theme.of(context);
    final style = (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
      fontFamily: settings.fontFamily,
      fontSize: settings.fontSize,
      fontWeight: settings.fontWeight == null
          ? null
          : FontWeight.values[(settings.fontWeight! ~/ 100 - 1).clamp(0, 8)],
      color: settings.textColor == null
          ? theme.colorScheme.onSurface
          : Color(settings.textColor!),
    );
    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: ClipRect(
        child: ColoredBox(
          color: settings.backgroundColor == null
              ? theme.colorScheme.surface
              : Color(settings.backgroundColor!),
          child: Padding(
            padding: EdgeInsets.all(math.min(3, math.min(width, height) / 8)),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: SizedBox(
                width: math.max(1, width - 6),
                child: Text(
                  region.translatedText,
                  textAlign: TextAlign.center,
                  style: style,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _transcript(BuildContext context, TranslationJob job) {
    final regions = job.result?.regions ?? const <TranslationRegion>[];
    if (regions.isEmpty) {
      return Center(child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(job.status == TranslationJobStatus.succeeded
            ? 'No readable text detected on this page.'
            : 'No translated text yet. Complete this job from the queue.'),
      ));
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: regions.length,
      separatorBuilder: (_, _) => const Divider(height: 32),
      itemBuilder: (context, index) {
        final region = regions[index];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Region ${index + 1}', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Text('Original', style: Theme.of(context).textTheme.labelMedium),
            SelectableText(region.sourceText),
            const SizedBox(height: 12),
            Text(job.settings.targetLanguage, style: Theme.of(context).textTheme.labelMedium),
            SelectableText(region.translatedText),
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: region.translatedText));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Translation copied.')),
                  );
                }
              },
              icon: const Icon(Icons.copy),
              label: const Text('Copy translation'),
            ),
          ],
        );
      },
    );
  }

  Widget _details(BuildContext context, TranslationJob job) {
    final settings = const JsonEncoder.withIndent('  ').convert(
      redactTranslationData(job.settings.toJson()),
    );
    final usage = const JsonEncoder.withIndent('  ').convert(job.result?.usageMetadata ?? {});
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('Job ${job.id}', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text('Status: ${job.status.name} · ${job.stage}'),
        Text('Created: ${job.createdAt.toLocal()}'),
        Text('Updated: ${job.updatedAt.toLocal()}'),
        if (_sourceSize != null)
          Text('Source: ${_sourceSize!.width.toInt()} × ${_sourceSize!.height.toInt()} pixels'),
        if (job.error != null) ...[
          const SizedBox(height: 16),
          Text(job.error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
        const SizedBox(height: 24),
        Text('Requested settings snapshot', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        const Text('Settings changes apply to newly queued pages. Effective API '
            'settings, timing, and errors are recorded in Logs.'),
        const SizedBox(height: 12),
        SelectableText(settings.length > 12000
            ? '${settings.substring(0, 12000)}\n… Settings preview truncated.'
            : settings),
        const SizedBox(height: 24),
        Text('Provider usage metadata', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        SelectableText(usage.length > 6000 ? '${usage.substring(0, 6000)}\n… Truncated.' : usage),
      ],
    );
  }
}
