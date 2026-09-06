import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mangayomi/services/translation/translation_controller.dart';
import 'package:mangayomi/services/translation/vertex_translation_client.dart';
import 'package:mangayomi/utils/share.dart';
import 'package:share_plus/share_plus.dart';

import 'translation_preview.dart';
import 'translation_settings_panel.dart';

/// The persistent translation queue, its configuration, and diagnostic history.
class TranslationScreen extends StatefulWidget {
  const TranslationScreen({super.key, this.controller});
  final TranslationController? controller;

  @override
  State<TranslationScreen> createState() => _TranslationScreenState();
}

enum _QueueSort { newest, oldest, name, status }

class _TranslationScreenState extends State<TranslationScreen> {
  late final TranslationController _controller;
  final _queueSearch = TextEditingController();
  final _logSearch = TextEditingController();
  TranslationJobStatus? _statusFilter;
  _QueueSort _sort = _QueueSort.newest;
  String? _phaseFilter;
  bool _importing = false;
  bool _newestLogsFirst = true;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? TranslationController.instance;
    _controller.initialize();
  }

  @override
  void dispose() {
    _queueSearch.dispose();
    _logSearch.dispose();
    super.dispose();
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _importPage() async {
    setState(() => _importing = true);
    try {
      final selected = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp'],
        allowMultiple: false,
        withData: false,
      );
      if (selected == null || selected.files.isEmpty) return;
      final file = selected.files.single;
      const maxBytes = 7000000;
      if (file.size <= 0 || file.size > maxBytes) {
        _message('Choose a nonempty image no larger than 7 MB (7,000,000 bytes).');
        return;
      }
      final bytes = file.bytes ??
          (file.path == null ? null : await File(file.path!).readAsBytes());
      if (bytes == null || bytes.isEmpty || bytes.length > maxBytes) {
        _message('This image could not be read, or exceeds 7 MB.');
        return;
      }
      final extension = file.extension?.toLowerCase();
      final mimeType = switch (extension) {
        'png' => 'image/png',
        'webp' => 'image/webp',
        _ => 'image/jpeg',
      };
      // Every new batch requires an explicit Run/upload confirmation.
      _controller.pause();
      final job = await _controller.enqueue(
        imageBytes: bytes,
        title: file.name,
        mimeType: mimeType,
      );
      _message(job == null
          ? (_controller.error ?? 'The page could not be queued.')
          : 'Page added. Review settings, then Run to authorize upload.');
    } catch (_) {
      // Platform exceptions can contain file paths; do not echo their payload.
      _message('Could not import the image. Please try another file.');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _run() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Send queued pages for translation?'),
        content: const SingleChildScrollView(
          child: Text(
            'Queued page images and extracted text will be sent to Google '
            'Vertex AI using each job’s saved settings. API charges may apply. '
            'Only upload content you are permitted to process.\n\n'
            'Gemini translation always requires the cloud. “Local only” '
            'controls supported non-AI vision engines; it does not mean offline. '
            'Jobs with unavailable engines will fail before upload.\n\n'
            'If raw-body logging is enabled, page text and model responses '
            'may also be retained on this device and included in log exports.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Authorize & run'),
          ),
        ],
      ),
    );
    if (accepted == true) {
      await _controller.run();
      if (_controller.error != null) _message(_controller.error!);
    }
  }

  Future<void> _jobAction(TranslationJob job, String action) async {
    switch (action) {
      case 'preview':
        if (!mounted) return;
        await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => TranslationPreview(job: job, controller: _controller),
        ));
      case 'retry':
        _controller.pause();
        await _controller.retry(job.id);
        _message('Job queued again. Run to authorize its next upload.');
      case 'cancel':
        await _controller.cancel(job.id);
      case 'requeue':
        final copy = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Queue a copy with current settings?'),
            content: Text(job.status == TranslationJobStatus.queued
                ? 'The original queued job will be cancelled but kept in history. '
                    'A new job will use the currently saved settings. Run is '
                    'required before the new copy can upload.'
                : 'The original job and history are kept. A new copy will use '
                    'the currently saved settings and requires Run before uploading.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep as is')),
              FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Queue new copy')),
            ],
          ),
        );
        if (copy != true) return;
        if (job.status == TranslationJobStatus.queued) await _controller.cancel(job.id);
        final added = await _controller.requeueWithCurrentSettings(job.id);
        _message(added == null
            ? (_controller.error ?? 'Could not queue a new copy of this page.')
            : 'New job queued with current settings. Run to authorize upload.');
      case 'remove':
        final remove = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Remove this job?'),
            content: const Text(
              'The saved page, translation result, and this job’s history '
              'will be removed from the translation queue. This cannot be undone.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Keep'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Remove'),
              ),
            ],
          ),
        );
        if (remove == true) await _controller.remove(job.id);
    }
  }

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    child: AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('Page translator'),
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.queue_outlined), text: 'Queue'),
              Tab(icon: Icon(Icons.tune), text: 'Settings'),
              Tab(icon: Icon(Icons.receipt_long_outlined), text: 'Logs'),
            ],
          ),
        ),
        body: SafeArea(
          top: false,
          child: !_controller.isLoaded
              ? const Center(child: CircularProgressIndicator())
              : TabBarView(
                  children: [
                    _buildQueue(context),
                    TranslationSettingsPanel(controller: _controller),
                    _buildLogs(context),
                  ],
                ),
        ),
      ),
    ),
  );

  Widget _buildQueue(BuildContext context) {
    final query = _queueSearch.text.trim().toLowerCase();
    final jobs = _controller.jobs.where((job) {
      return (_statusFilter == null || job.status == _statusFilter) &&
          (query.isEmpty ||
              '${job.title} ${job.id} ${job.stage} ${job.error ?? ''}'
                  .toLowerCase()
                  .contains(query));
    }).toList();
    jobs.sort((a, b) => switch (_sort) {
      _QueueSort.newest => b.createdAt.compareTo(a.createdAt),
      _QueueSort.oldest => a.createdAt.compareTo(b.createdAt),
      _QueueSort.name => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      _QueueSort.status => a.status.index.compareTo(b.status.index),
    });
    final queued = _controller.jobs
        .where((job) => job.status == TranslationJobStatus.queued)
        .length;
    return CustomScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        SliverToBoxAdapter(child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  FilledButton.icon(
                    onPressed: queued == 0 ||
                            (_controller.isRunning && !_controller.isPaused)
                        ? null
                        : _run,
                    icon: const Icon(Icons.play_arrow),
                    label: Text('Run ($queued)'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _controller.isPaused ? null : _controller.pause,
                    icon: const Icon(Icons.pause),
                    label: const Text('Pause'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _importing ? null : _importPage,
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    label: Text(_importing ? 'Importing…' : 'Add page'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                _controller.isPaused
                    ? 'Paused · New jobs keep a snapshot of current settings.'
                    : 'Running · Pause stops after the active request finishes.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (_controller.error != null)
                _Notice(
                  icon: Icons.error_outline,
                  message: _controller.error!,
                ),
              const SizedBox(height: 12),
              TextField(
                controller: _queueSearch,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'Search pages, status, or errors',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _queueSearch.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear search',
                          onPressed: () => setState(_queueSearch.clear),
                          icon: const Icon(Icons.close),
                        ),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<TranslationJobStatus?>(
                      initialValue: _statusFilter,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Status'),
                      items: [
                        const DropdownMenuItem(
                          value: null,
                          child: Text('All statuses'),
                        ),
                        ...TranslationJobStatus.values.map(
                          (status) => DropdownMenuItem(
                            value: status,
                            child: Text(_statusLabel(status)),
                          ),
                        ),
                      ],
                      onChanged: (value) => setState(() => _statusFilter = value),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: DropdownButtonFormField<_QueueSort>(
                      initialValue: _sort,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Sort'),
                      items: const [
                        DropdownMenuItem(
                          value: _QueueSort.newest,
                          child: Text('Newest first'),
                        ),
                        DropdownMenuItem(
                          value: _QueueSort.oldest,
                          child: Text('Oldest first'),
                        ),
                        DropdownMenuItem(
                          value: _QueueSort.name,
                          child: Text('Page name'),
                        ),
                        DropdownMenuItem(
                          value: _QueueSort.status,
                          child: Text('Status'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value != null) setState(() => _sort = value);
                      },
                    ),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '${jobs.length} of ${_controller.jobs.length} jobs · '
                  'Swipe right to retry; left to cancel/remove.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        )),
        if (jobs.isEmpty)
          SliverToBoxAdapter(child: _EmptyState(
                  icon: Icons.translate,
                  title: _controller.jobs.isEmpty
                      ? 'Your next chapter, translated'
                      : 'No matching jobs',
                  message: _controller.jobs.isEmpty
                      ? 'Add a JPEG, PNG, or WebP page, or send a page from the '
                          'reader. Configure Vertex AI, then run the queue.'
                      : 'Try another search or status filter.',
                ))
        else
          SliverList(delegate: SliverChildBuilderDelegate(
            (context, index) => index.isOdd
                ? const Divider(height: 1)
                : _jobTile(jobs[index ~/ 2]),
            childCount: jobs.length * 2 - 1,
          )),
        const SliverToBoxAdapter(child: SizedBox(height: 16)),
      ],
    );
  }

  Widget _jobTile(TranslationJob job) {
    final active = job.status == TranslationJobStatus.running ||
        job.status == TranslationJobStatus.queued;
    final canRetry = const {
      TranslationJobStatus.failed,
      TranslationJobStatus.cancelled,
      TranslationJobStatus.interrupted,
    }.contains(job.status);
    final color = switch (job.status) {
      TranslationJobStatus.failed || TranslationJobStatus.interrupted =>
        Theme.of(context).colorScheme.error,
      TranslationJobStatus.succeeded => Theme.of(context).colorScheme.primary,
      _ => Theme.of(context).colorScheme.onSurfaceVariant,
    };
    return Dismissible(
      key: ValueKey(job.id),
      direction: canRetry
          ? DismissDirection.horizontal
          : DismissDirection.endToStart,
      background: _SwipeBackground(
        icon: canRetry ? Icons.refresh : Icons.cancel_outlined,
        label: canRetry ? 'Retry' : 'Cancel',
        alignment: AlignmentDirectional.centerStart,
      ),
      secondaryBackground: _SwipeBackground(
        icon: active ? Icons.cancel_outlined : Icons.delete_outline,
        label: active ? 'Cancel' : 'Remove',
        alignment: AlignmentDirectional.centerEnd,
      ),
      confirmDismiss: (direction) async {
        await _jobAction(
          job,
          direction == DismissDirection.startToEnd
              ? 'retry'
              : active ? 'cancel' : 'remove',
        );
        // Controller owns the list; never let Dismissible mutate queue state.
        return false;
      },
      child: ListTile(
        isThreeLine: true,
        leading: Icon(_statusIcon(job.status), color: color),
        title: Text(job.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${_statusLabel(job.status)} · ${job.stage}'),
            Text(
              '${_formatTime(job.createdAt)} · ${job.settings.targetLanguage}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (job.status == TranslationJobStatus.running)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(
                  value: job.progress.clamp(0.0, 1.0),
                  semanticsLabel: 'Translation progress',
                ),
              ),
            if (job.error != null)
              Text(
                job.error!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: color),
              ),
          ],
        ),
        onTap: () => _jobAction(job, 'preview'),
        trailing: PopupMenuButton<String>(
          tooltip: 'Actions for ${job.title}',
          onSelected: (action) => _jobAction(job, action),
          itemBuilder: (_) => [
            const PopupMenuItem(
              value: 'preview',
              child: ListTile(
                leading: Icon(Icons.visibility_outlined),
                title: Text('Preview & details'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            if (canRetry)
              const PopupMenuItem(
                value: 'retry',
                child: ListTile(
                  leading: Icon(Icons.refresh),
                  title: Text('Retry'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            if (job.status != TranslationJobStatus.running)
              const PopupMenuItem(
                value: 'requeue',
                child: ListTile(
                  leading: Icon(Icons.playlist_add),
                  title: Text('Queue with current settings'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            PopupMenuItem(
              value: active ? 'cancel' : 'remove',
              child: ListTile(
                leading: Icon(active ? Icons.cancel_outlined : Icons.delete_outline),
                title: Text(active ? 'Cancel' : 'Remove'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLogs(BuildContext context) {
    final query = _logSearch.text.trim().toLowerCase();
    final allLogs = _controller.logs;
    final phases = allLogs.map((event) => event.phase).toSet().toList()..sort();
    final selectedPhase = phases.contains(_phaseFilter) ? _phaseFilter : null;
    final logs = allLogs.where((event) {
      return (selectedPhase == null || event.phase == selectedPhase) &&
          (query.isEmpty || jsonEncode(event.toJson()).toLowerCase().contains(query));
    }).toList();
    logs.sort((a, b) => _newestLogsFirst
        ? b.timestamp.compareTo(a.timestamp)
        : a.timestamp.compareTo(b.timestamp));
    return CustomScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      slivers: [
        SliverToBoxAdapter(child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _logSearch,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  hintText: 'Search logs and captured bodies',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _logSearch.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear log search',
                          onPressed: () => setState(_logSearch.clear),
                          icon: const Icon(Icons.close),
                        ),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String?>(
                      key: ValueKey(selectedPhase),
                      initialValue: selectedPhase,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Stage'),
                      items: [
                        const DropdownMenuItem(value: null, child: Text('All stages')),
                        ...phases.map((phase) => DropdownMenuItem(
                          value: phase,
                          child: Text(phase, overflow: TextOverflow.ellipsis),
                        )),
                      ],
                      onChanged: (value) => setState(() => _phaseFilter = value),
                    ),
                  ),
                  IconButton(
                    tooltip: _newestLogsFirst ? 'Show oldest first' : 'Show newest first',
                    onPressed: () => setState(() => _newestLogsFirst = !_newestLogsFirst),
                    icon: Icon(_newestLogsFirst ? Icons.arrow_downward : Icons.arrow_upward),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Log actions',
                    onSelected: _logAction,
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'copy', child: Text('Copy all logs')),
                      PopupMenuItem(value: 'export', child: Text('Export all logs')),
                      PopupMenuItem(value: 'clear', child: Text('Clear all logs')),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '${logs.length} of ${allLogs.length} events · Credentials are '
                'redacted. Raw bodies may contain private page text.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        )),
        if (logs.isEmpty)
          const SliverToBoxAdapter(child: _EmptyState(
                  icon: Icons.receipt_long_outlined,
                  title: 'No matching events',
                  message: 'Queue actions, settings, timing, and API outcomes '
                      'appear here. Raw bodies are off by default.',
                ))
        else
          SliverList(delegate: SliverChildBuilderDelegate(
            (context, index) => _LogTile(event: logs[index]),
            childCount: logs.length,
          )),
        const SliverToBoxAdapter(child: SizedBox(height: 16)),
      ],
    );
  }

  Future<void> _logAction(String action) async {
    if (action == 'clear') {
      final clear = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Clear all translation logs?'),
          content: const Text('This removes the saved diagnostic history and '
              'captured raw bodies. Queue jobs and results are kept.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear logs')),
          ],
        ),
      );
      if (clear == true) await _controller.clearLogs();
      return;
    }
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(action == 'copy' ? 'Copy diagnostic logs?' : 'Export diagnostic logs?'),
        content: const Text('Credentials are redacted, but logs may include page '
            'names, project settings, extracted text, and model responses. '
            'Only share them with someone you trust.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Continue')),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    final logs = _controller.exportLogs();
    try {
      if (action == 'copy') {
        await Clipboard.setData(ClipboardData(text: logs));
        _message('Redacted logs copied.');
      } else {
        final box = context.findRenderObject() as RenderBox?;
        await shareOrCopy(
          ShareParams(
            files: [XFile.fromData(utf8.encode(logs), mimeType: 'application/json')],
            fileNameOverrides: const ['translation-logs.json'],
            subject: 'Mangayomi translation diagnostics',
            sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
          ),
          fallbackName: 'translation-logs.json',
        );
      }
    } catch (_) {
      _message('Logs could not be shared. Try Copy all logs instead.');
    }
  }
}

class _LogTile extends StatelessWidget {
  const _LogTile({required this.event});
  final TranslationApiEvent event;

  @override
  Widget build(BuildContext context) {
    final raw = const JsonEncoder.withIndent('  ').convert(
      redactTranslationData(event.toJson()),
    );
    const previewLimit = 12000;
    final preview = raw.length <= previewLimit
        ? raw
        : '${raw.substring(0, previewLimit)}\n… Preview truncated. Export logs for retained data.';
    return ExpansionTile(
      leading: const Icon(Icons.article_outlined),
      title: Text(event.message, maxLines: 3, overflow: TextOverflow.ellipsis),
      subtitle: Text('${_formatTime(event.timestamp)} · ${event.phase}'),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      expandedCrossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 300),
          child: SingleChildScrollView(child: SelectableText(preview)),
        ),
        TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: raw));
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Redacted event copied; it may contain page text.')),
              );
            }
          },
          icon: const Icon(Icons.copy),
          label: const Text('Copy redacted event'),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.icon, required this.title, required this.message});
  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 16),
          Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(message, textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.message});
  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: Theme.of(context).colorScheme.error),
        const SizedBox(width: 8),
        Expanded(child: Text(message)),
      ],
    ),
  );
}

class _SwipeBackground extends StatelessWidget {
  const _SwipeBackground({required this.icon, required this.label, required this.alignment});
  final IconData icon;
  final String label;
  final AlignmentDirectional alignment;

  @override
  Widget build(BuildContext context) => Container(
    color: Theme.of(context).colorScheme.secondaryContainer,
    padding: const EdgeInsets.symmetric(horizontal: 24),
    alignment: alignment,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [Icon(icon), const SizedBox(width: 8), Text(label)],
    ),
  );
}

String _statusLabel(TranslationJobStatus status) => switch (status) {
  TranslationJobStatus.queued => 'Queued',
  TranslationJobStatus.running => 'Running',
  TranslationJobStatus.succeeded => 'Complete',
  TranslationJobStatus.failed => 'Failed',
  TranslationJobStatus.cancelled => 'Cancelled',
  TranslationJobStatus.interrupted => 'Interrupted',
};

IconData _statusIcon(TranslationJobStatus status) => switch (status) {
  TranslationJobStatus.queued => Icons.schedule,
  TranslationJobStatus.running => Icons.sync,
  TranslationJobStatus.succeeded => Icons.check_circle_outline,
  TranslationJobStatus.failed => Icons.error_outline,
  TranslationJobStatus.cancelled => Icons.cancel_outlined,
  TranslationJobStatus.interrupted => Icons.warning_amber_outlined,
};

String _formatTime(DateTime time) {
  final local = time.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}
