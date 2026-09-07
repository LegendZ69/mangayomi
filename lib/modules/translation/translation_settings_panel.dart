import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mangayomi/services/translation/translation_controller.dart';
import 'package:mangayomi/services/translation/translation_settings.dart';
import 'package:mangayomi/services/translation/vertex_translation_client.dart';
import 'package:url_launcher/url_launcher.dart';

/// Edits a draft. Saving never mutates settings already attached to queue jobs.
class TranslationSettingsPanel extends StatefulWidget {
  const TranslationSettingsPanel({super.key, required this.controller});
  final TranslationController controller;

  @override
  State<TranslationSettingsPanel> createState() =>
      _TranslationSettingsPanelState();
}

class _TranslationSettingsPanelState extends State<TranslationSettingsPanel>
    with AutomaticKeepAliveClientMixin {
  late TranslationSettings _draft;
  final _fields = <String, TextEditingController>{};
  final _credential = TextEditingController();
  bool _credentialSaved = false;
  bool _savingCredential = false;
  bool _saving = false;
  String? _feedback;
  bool _feedbackIsError = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadDraft(widget.controller.settings);
    _refreshCredentialStatus();
  }

  void _loadDraft(TranslationSettings settings) {
    _draft = settings;
    final values = <String, String>{
      'projectId': settings.projectId,
      'location': settings.location,
      'model': settings.model,
      'targetLanguage': settings.targetLanguage,
      'maxOutputTokens': settings.maxOutputTokens?.toString() ?? '',
      'rawGenerationConfig': const JsonEncoder.withIndent('  ')
          .convert(settings.rawGenerationConfig),
      'timeoutSeconds': settings.timeoutSeconds.toString(),
      'maxRetries': settings.maxRetries.toString(),
      'maxLogEntries': settings.maxLogEntries.toString(),
      'fontFamily': settings.fontFamily ?? '',
      'fontSize': settings.fontSize?.toString() ?? '',
      'fontWeight': settings.fontWeight?.toString() ?? '',
      'backgroundColor': _colorText(settings.backgroundColor),
      'textColor': _colorText(settings.textColor),
      'ppocrDetectionModel': settings.ppocrDetectionModel,
      'ppocrRecognitionModel': settings.ppocrRecognitionModel,
      'yoloModel': settings.yoloModel,
    };
    for (final entry in values.entries) {
      if (_fields.containsKey(entry.key)) {
        _fields[entry.key]!.text = entry.value;
      } else {
        _fields[entry.key] = TextEditingController(text: entry.value);
      }
    }
  }

  @override
  void dispose() {
    for (final controller in _fields.values) {
      controller.dispose();
    }
    _credential.dispose();
    super.dispose();
  }

  Future<void> _refreshCredentialStatus() async {
    final mode = _draft.vertexMode;
    try {
      final exists = await widget.controller.hasCredential(mode);
      if (mounted && _draft.vertexMode == mode) {
        setState(() => _credentialSaved = exists);
      }
    } catch (_) {
      if (mounted) setState(() => _credentialSaved = false);
    }
  }

  void _report(String message, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _feedback = message;
      _feedbackIsError = error;
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String _text(String key) => _fields[key]!.text.trim();

  int _integer(String key, String label, {int? fallback}) {
    if (_text(key).isEmpty && fallback != null) return fallback;
    final value = int.tryParse(_text(key));
    if (value == null) throw FormatException('$label must be a whole number.');
    return value;
  }

  int? _optionalInteger(String key, String label) =>
      _text(key).isEmpty ? null : _integer(key, label);

  int? _parseColor(String key, String label) {
    final raw = _text(key).replaceFirst(RegExp(r'^#'), '');
    if (raw.isEmpty) return null;
    if (!RegExp(r'^[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$').hasMatch(raw)) {
      throw FormatException('$label must be #RRGGBB or #AARRGGBB, or blank.');
    }
    return int.parse(raw.length == 6 ? 'ff$raw' : raw, radix: 16);
  }

  TranslationSettings _readDraft() {
    final raw = _text('rawGenerationConfig');
    if (raw.length > 32768) {
      throw const FormatException(
        'Raw generation JSON exceeds the 32,768-character app safety limit.',
      );
    }
    final decoded = raw.isEmpty ? <String, dynamic>{} : jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'Raw generation configuration must be a JSON object.',
      );
    }
    final fontSize = _text('fontSize').isEmpty
        ? null
        : double.tryParse(_text('fontSize'));
    if (_text('fontSize').isNotEmpty && fontSize == null) {
      throw const FormatException(
        'Font size must be a number, or blank for system default.',
      );
    }
    return _draft.copyWith(
      projectId: _text('projectId'),
      location: _text('location'),
      model: _text('model'),
      targetLanguage: _text('targetLanguage'),
      maxOutputTokens: _optionalInteger(
        'maxOutputTokens',
        'Maximum output tokens',
      ),
      rawGenerationConfig: decoded,
      timeoutSeconds: _integer('timeoutSeconds', 'Timeout'),
      maxRetries: _integer('maxRetries', 'Maximum retries'),
      maxLogEntries: _integer('maxLogEntries', 'Maximum log entries'),
      fontFamily: _text('fontFamily').isEmpty ? null : _text('fontFamily'),
      fontSize: fontSize,
      fontWeight: _optionalInteger('fontWeight', 'Font weight'),
      backgroundColor: _parseColor('backgroundColor', 'Overlay background'),
      textColor: _parseColor('textColor', 'Overlay text color'),
      ppocrDetectionModel: _text('ppocrDetectionModel'),
      ppocrRecognitionModel: _text('ppocrRecognitionModel'),
      yoloModel: _text('yoloModel'),
    );
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    setState(() => _saving = true);
    try {
      final settings = _readDraft();
      final errors = [
        ...settings.validate(),
        ...VertexTranslationClient.validateGenerationConfig(settings),
      ];
      if (errors.isNotEmpty) throw FormatException(errors.join('\n'));
      final saved = await widget.controller.saveSettings(settings);
      if (saved) {
        _draft = settings;
        _report(
          'Settings saved for newly queued pages. Existing jobs keep their snapshot.',
        );
      } else {
        _report(
          widget.controller.error ?? 'Settings could not be saved.',
          error: true,
        );
      }
    } on FormatException catch (error) {
      _report(error.message, error: true);
    } catch (_) {
      _report(
        'Settings could not be saved. Check the values and try again.',
        error: true,
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveCredential({bool remove = false}) async {
    if (!remove && _credential.text.trim().isEmpty) {
      _report('Enter an access token or API key first.', error: true);
      return;
    }
    if (remove) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Remove the saved credential?'),
          content: const Text(
            'Queued jobs using this Vertex mode will need a new credential before they can run.',
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
      if (confirmed != true) return;
    }
    setState(() => _savingCredential = true);
    try {
      final saved = await widget.controller.saveCredential(
        _draft.vertexMode,
        remove ? '' : _credential.text.trim(),
      );
      if (saved) {
        _credential.clear();
        await _refreshCredentialStatus();
        _report(
          remove
              ? 'Saved credential removed.'
              : 'Credential saved securely. It is never included in logs.',
        );
      } else {
        _report('The credential could not be saved securely.', error: true);
      }
    } catch (_) {
      _report(
        'Secure credential storage is unavailable. No credential was logged.',
        error: true,
      );
    } finally {
      if (mounted) setState(() => _savingCredential = false);
    }
  }

  Future<void> _setRawCapture(bool enabled) async {
    if (enabled) {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Retain raw API bodies?'),
          content: const SingleChildScrollView(
            child: Text(
              'Raw diagnostic bodies may include source text, translations, '
              'prompts, and provider responses. They are stored on this device and '
              'included when you copy or export logs. Credentials and inline image '
              'bytes are redacted.\n\n'
              'Enable only while troubleshooting and clear logs afterward. '
              'Turning this off does not delete previously captured bodies.',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep off'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Enable raw capture'),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
    }
    setState(() => _draft = _draft.copyWith(captureRawBodies: enabled));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final unsupported = _draft.validateRuntimeSupport();
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Text('Make it yours', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text(
          'Defaults: hybrid vision execution, full Vertex AI, global, '
          'gemini-3.8-flash, AI detection/OCR, and local overlays. '
          'Save changes before adding pages. Credentials are stored separately.',
        ),
        if (_feedback != null)
          _SettingsNotice(
            icon: _feedbackIsError
                ? Icons.error_outline
                : Icons.check_circle_outline,
            text: _feedback!,
            isError: _feedbackIsError,
          ),
        const SizedBox(height: 16),
        _section(
          title: 'Pipeline & execution',
          icon: Icons.account_tree_outlined,
          initiallyExpanded: true,
          children: [
            _picker<ExecutionMode>(
              label: 'Vision engine execution',
              value: _draft.executionMode,
              labels: const {
                ExecutionMode.hybrid: 'Hybrid (default)',
                ExecutionMode.cloudOnly: 'Cloud only',
                ExecutionMode.localOnly: 'Local only',
              },
              onChanged: (value) => setState(
                () => _draft = _draft.copyWith(executionMode: value),
              ),
            ),
            const _SettingsNotice(
              icon: Icons.cloud_upload_outlined,
              text:
                  'Local only applies to PP-OCR / YOLO26 / LaMa. Selected AI '
                  'stages still upload pages to Google; Gemini translation is '
                  'always cloud-based and overlays always render locally.',
            ),
            Text(
              _draft.executionMode == ExecutionMode.hybrid
                  ? 'Hybrid prefers local PP-OCR and cloud YOLO26/LaMa when their '
                        'adapters exist. Only the same engine may fall back to another permitted location.'
                  : 'No cross-location fallback for non-AI vision engines. An '
                        'unavailable adapter stops the job; it is never silently replaced.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            _picker<DetectionEngine>(
              label: 'Text detection',
              value: _draft.detectionEngine,
              labels: const {
                DetectionEngine.ai: 'AI (default; cloud)',
                DetectionEngine.ppocr: 'PP-OCR — adapter unavailable',
                DetectionEngine.ppocrAi: 'PP-OCR + AI — adapter unavailable',
                DetectionEngine.yolo26: 'YOLO26 — adapter unavailable',
              },
              onChanged: (value) => setState(
                () => _draft = _draft.copyWith(detectionEngine: value),
              ),
            ),
            _picker<OcrEngine>(
              label: 'OCR',
              value: _draft.ocrEngine,
              labels: const {
                OcrEngine.ai: 'AI (default; cloud)',
                OcrEngine.ppocr: 'PP-OCR — adapter unavailable',
                OcrEngine.ppocrAi: 'PP-OCR + AI — adapter unavailable',
              },
              onChanged: (value) =>
                  setState(() => _draft = _draft.copyWith(ocrEngine: value)),
            ),
            _picker<InpaintEngine>(
              label: 'Background treatment',
              value: _draft.inpaintEngine,
              labels: const {
                InpaintEngine.overlay: 'Overlay (default; local)',
                InpaintEngine.lama: 'LaMa — adapter unavailable',
              },
              onChanged: (value) => setState(
                () => _draft = _draft.copyWith(inpaintEngine: value),
              ),
            ),
            if (unsupported.isNotEmpty)
              _SettingsNotice(
                icon: Icons.warning_amber_outlined,
                text:
                    'Configuration only — cannot run this pipeline:\n${unsupported.join('\n')}',
              ),
            const Text(
              'This build executes AI detection + OCR + translation in '
              'one cloud request, followed by an on-device overlay preview. '
              'PP-OCR, YOLO26, and LaMa require engine/model integrations; '
              'selecting them does not install a model.',
            ),
            const SizedBox(height: 16),
            _modelSelector(
              'ppocrDetectionModel',
              'PP-OCR detection model',
              _ppocrDetectionModels,
            ),
            _modelSelector(
              'ppocrRecognitionModel',
              'PP-OCR recognition model',
              _ppocrRecognitionModels,
            ),
            const Text(
              'PP-OCRv6 medium/small include Japanese; v6 tiny does '
              'not. The documented v6 languages do not include Korean. '
              'Use a language-appropriate model; a newer version is not '
              'a universal replacement.',
            ),
            const SizedBox(height: 16),
            _modelSelector('yoloModel', 'YOLO26 detection scale', _yoloModels),
            const Text(
              'YOLO26’s ordinary COCO checkpoints do not detect manga '
              'text or speech bubbles. Suitable trained weights and an '
              'adapter are required. Segmentation, pose, classification, '
              'and historical exports are different tasks/artifacts, '
              'not interchangeable detection models.',
            ),
          ],
        ),
        _section(
          title: 'Vertex AI & credentials',
          icon: Icons.cloud_outlined,
          initiallyExpanded: true,
          children: [
            _picker<VertexMode>(
              label: 'Vertex mode',
              value: _draft.vertexMode,
              labels: const {
                VertexMode.full: 'Full Vertex AI (default)',
                VertexMode.express: 'Express mode',
              },
              onChanged: (value) {
                setState(() {
                  _draft = _draft.copyWith(vertexMode: value);
                  _credential.clear();
                  _credentialSaved = false;
                });
                _refreshCredentialStatus();
              },
            ),
            _field(
              'projectId',
              'Google Cloud project ID',
              helper: _draft.vertexMode == VertexMode.full
                  ? 'Required for full mode. Use the project ID, not its display name.'
                  : 'Not sent by the Express endpoint.',
            ),
            _field(
              'location',
              'Location',
              helper: 'Default: global. Model availability varies by location.',
            ),
            _field(
              'model',
              'Model ID',
              helper: 'This adapter currently validates only gemini-3.8-flash. Other IDs fail explicitly; no silent substitution.',
            ),
            if (_draft.vertexMode == VertexMode.express)
              const _SettingsNotice(
                icon: Icons.warning_amber_outlined,
                text:
                    'Gemini 3.8 Flash is not listed in Google’s Express model '
                    'table; availability must be verified. A saved model ID is '
                    'not proof that Express can serve it.',
              ),
            const SizedBox(height: 8),
            TextField(
              controller: _credential,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              keyboardType: TextInputType.visiblePassword,
              decoration: InputDecoration(
                labelText: _draft.vertexMode == VertexMode.full
                    ? 'Short-lived OAuth access token'
                    : 'Express API key',
                helperText: _credentialSaved
                    ? 'A credential is saved. Enter a value only to replace it.'
                    : 'No credential is saved for this mode.',
                helperMaxLines: 3,
                prefixIcon: const Icon(Icons.key_outlined),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _draft.vertexMode == VertexMode.full
                  ? 'Stored in iOS Keychain / platform secure storage. Access '
                        'tokens expire; replace them when needed. Never paste a '
                        'service-account JSON file or private key.'
                  : 'Stored in iOS Keychain / platform secure storage. Do not '
                        'put an API key in project settings or the raw JSON editor.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _savingCredential ? null : () => _saveCredential(),
                  icon: const Icon(Icons.lock_outline),
                  label: Text(
                    _savingCredential ? 'Saving…' : 'Save credential',
                  ),
                ),
                TextButton.icon(
                  onPressed: _savingCredential || !_credentialSaved
                      ? null
                      : () => _saveCredential(remove: true),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Remove'),
                ),
              ],
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Priority PayGo'),
              subtitle: const Text(
                'Off by default. Requires provider support; '
                'this toggle does not buy or provision capacity.',
              ),
              value: _draft.priorityPaygo,
              onChanged: (value) => setState(
                () => _draft = _draft.copyWith(priorityPaygo: value),
              ),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Provisioned Throughput'),
              subtitle: const Text(
                'Off by default. Requires separately purchased '
                'capacity. Unsupported combinations fail explicitly.',
              ),
              value: _draft.provisionedThroughput,
              onChanged: (value) => setState(
                () => _draft = _draft.copyWith(provisionedThroughput: value),
              ),
            ),
          ],
        ),
        _section(
          title: 'Translation & raw API configuration',
          icon: Icons.data_object,
          children: [
            _field(
              'targetLanguage',
              'Target language',
              helper: 'App preference: English. Any unambiguous language name can be requested.',
            ),
            _picker<String>(
              label: 'Thinking level',
              value: _draft.thinkingLevel,
              labels: {
                if (_draft.thinkingLevel == 'MINIMAL')
                  'MINIMAL': 'Minimal — unsupported for 3.8',
                'LOW': 'Low',
                'MEDIUM': 'Medium (provider default)',
                'HIGH': 'High',
              },
              onChanged: (value) => setState(
                () => _draft = _draft.copyWith(thinkingLevel: value),
              ),
            ),
            _field(
              'maxOutputTokens',
              'Maximum output tokens',
              numeric: true,
              helper: 'Blank omits the field and uses the provider default. The API enforces model-specific limits.',
            ),
            const _SettingsNotice(
              icon: Icons.info_outline,
              text:
                  'Gemini 3.8 ignores temperature, topP, and topK. Legacy '
                  'thinkingBudget and unsupported fields are rejected; they '
                  'are not silently converted. Effective settings are recorded in Logs.',
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _fields['rawGenerationConfig'],
              minLines: 5,
              maxLines: 12,
              maxLength: 32768,
              autocorrect: false,
              enableSuggestions: false,
              enableIMEPersonalizedLearning: false,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(
                labelText: 'Raw generationConfig JSON',
                alignLabelWithHint: true,
                helperText:
                    'JSON object only; no credentials, URL, headers, or '
                    'image content. Validated against the client’s supported '
                    'request contract. The structured translation response '
                    'schema is reserved by the app.',
                helperMaxLines: 5,
                border: OutlineInputBorder(),
              ),
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                onPressed: () => _fields['rawGenerationConfig']!.text = '{}',
                icon: const Icon(Icons.restart_alt),
                label: const Text('Clear raw overrides'),
              ),
            ),
          ],
        ),
        _section(
          title: 'Queue & diagnostic retention',
          icon: Icons.receipt_long_outlined,
          children: [
            const Text(
              'These are app policies, not Google model defaults. '
              'Jobs run sequentially to limit iPhone memory and request bursts.',
            ),
            const SizedBox(height: 16),
            _field(
              'timeoutSeconds',
              'Request timeout (seconds)',
              numeric: true,
              helper: 'App default: 60. A timed-out request may still have incurred provider charges.',
            ),
            _field(
              'maxRetries',
              'Maximum automatic retries',
              numeric: true,
              helper: 'App default: 2. Transient failures only; retried requests may incur charges.',
            ),
            _field(
              'maxLogEntries',
              'Retained log events',
              numeric: true,
              helper: 'App default: 500. App safety range: 1–10,000; older events are removed.',
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Capture raw request / response bodies'),
              subtitle: const Text(
                'Off by default. Includes private page text; '
                'credentials and inline image bytes stay redacted.',
              ),
              value: _draft.captureRawBodies,
              onChanged: _setRawCapture,
            ),
          ],
        ),
        _section(
          title: 'Overlay style',
          icon: Icons.palette_outlined,
          children: [
            const Text(
              'Blank values inherit the system theme’s font, size, '
              'weight, and surface/text colors. Overrides affect newly queued '
              'pages. Overlays scale down to fit their detected region; the '
              'Text tab always exposes the full translation.',
            ),
            const SizedBox(height: 16),
            _field(
              'fontFamily',
              'Font family override',
              helper: 'Blank: system theme. A named font must already be installed or bundled.',
            ),
            _field(
              'fontSize',
              'Font size override',
              numeric: true,
              decimal: true,
              helper: 'Blank: system theme. Positive logical pixels before region fitting.',
            ),
            _field(
              'fontWeight',
              'Font weight override',
              numeric: true,
              helper: 'Blank: system theme. 100–900 in steps of 100.',
            ),
            _field(
              'backgroundColor',
              'Overlay background color',
              helper: 'Blank: system surface. #RRGGBB or #AARRGGBB.',
            ),
            _colorPresets('backgroundColor'),
            _field(
              'textColor',
              'Overlay text color',
              helper: 'Blank: system text. #RRGGBB or #AARRGGBB.',
            ),
            _colorPresets('textColor'),
            OutlinedButton.icon(
              onPressed: () {
                for (final key in [
                  'fontFamily',
                  'fontSize',
                  'fontWeight',
                  'backgroundColor',
                  'textColor',
                ]) {
                  _fields[key]!.clear();
                }
                setState(
                  () => _draft = _draft.copyWith(
                    fontFamily: null,
                    fontSize: null,
                    fontWeight: null,
                    backgroundColor: null,
                    textColor: null,
                  ),
                );
              },
              icon: const Icon(Icons.restart_alt),
              label: const Text('Use all system style defaults'),
            ),
          ],
        ),
        _section(
          title: 'Official references',
          icon: Icons.menu_book_outlined,
          children: [
            const Text(
              'Model/API constraints come from official documentation. '
              'App defaults and safety caps are labelled separately. '
              'A listed model variant does not imply an installed engine.',
            ),
            _reference(
              'Gemini 3.8 Flash model guide',
              'https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/guides/gemini-3-8-flash',
            ),
            _reference(
              'Vertex AI Express supported models',
              'https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/start/express-mode/overview',
            ),
            _reference(
              'PaddleOCR iOS deployment',
              'https://www.paddleocr.ai/main/en/version3.x/inference_deployment/cross_platform/ios_deployment.html',
            ),
            _reference(
              'Ultralytics YOLO26',
              'https://docs.ultralytics.com/models/yolo26/',
            ),
          ],
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _saving ? null : _save,
          icon: const Icon(Icons.save_outlined),
          label: Text(_saving ? 'Saving…' : 'Validate & save settings'),
        ),
        TextButton.icon(
          onPressed: _saving
              ? null
              : () {
                  setState(() {
                    _loadDraft(widget.controller.settings);
                    _feedback = 'Unsaved edits discarded.';
                    _feedbackIsError = false;
                  });
                  _credential.clear();
                  _refreshCredentialStatus();
                },
          icon: const Icon(Icons.undo),
          label: const Text('Discard unsaved changes'),
        ),
      ],
    );
  }

  Widget _section({
    required String title,
    required IconData icon,
    required List<Widget> children,
    bool initiallyExpanded = false,
  }) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    child: ExpansionTile(
      leading: Icon(icon),
      title: Text(title),
      initiallyExpanded: initiallyExpanded,
      maintainState: true,
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );

  Widget _picker<T extends Object>({
    required String label,
    required T value,
    required Map<T, String> labels,
    required ValueChanged<T> onChanged,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: DropdownButtonFormField<T>(
      key: ValueKey('$label-$value'),
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      items: labels.entries
          .map(
            (entry) => DropdownMenuItem(
              value: entry.key,
              child: Text(
                entry.value,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          )
          .toList(),
      onChanged: (selected) {
        if (selected != null) onChanged(selected);
      },
    ),
  );

  Widget _field(
    String key,
    String label, {
    String? helper,
    bool numeric = false,
    bool decimal = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextField(
      controller: _fields[key],
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: numeric
          ? TextInputType.numberWithOptions(decimal: decimal)
          : TextInputType.text,
      inputFormatters: numeric && !decimal
          ? [FilteringTextInputFormatter.digitsOnly]
          : null,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: 5,
        border: const OutlineInputBorder(),
      ),
    ),
  );

  Widget _colorPresets(String field) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        ActionChip(
          avatar: const Icon(Icons.settings_suggest_outlined),
          label: const Text('System'),
          onPressed: () => _fields[field]!.clear(),
        ),
        for (final entry in const {
          'Black': 0xff000000,
          'White': 0xffffffff,
          'Cream': 0xfffff3d6,
        }.entries)
          ActionChip(
            avatar: Icon(Icons.circle, color: Color(entry.value)),
            label: Text(entry.key),
            onPressed: () => _fields[field]!.text = _colorText(entry.value),
          ),
      ],
    ),
  );

  Widget _reference(String label, String url) => TextButton.icon(
    style: TextButton.styleFrom(alignment: AlignmentDirectional.centerStart),
    onPressed: () async {
      try {
        if (!await launchUrl(
          Uri.parse(url),
          mode: LaunchMode.externalApplication,
        )) {
          _report('Could not open the official documentation.', error: true);
        }
      } catch (_) {
        _report('Could not open the official documentation.', error: true);
      }
    },
    icon: const Icon(Icons.open_in_new),
    label: Text(label),
  );

  Widget _modelSelector(String field, String label, List<String> models) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _field(
              field,
              label,
              helper:
                  'Configuration only — adapter unavailable. '
                  'Enter an exact artifact/model ID or choose an upstream catalog entry.',
            ),
            OutlinedButton.icon(
              onPressed: () async {
                final selected = await showDialog<String>(
                  context: context,
                  builder: (_) =>
                      _ModelCatalogDialog(title: label, models: models),
                );
                if (selected != null && mounted)
                  _fields[field]!.text = selected;
              },
              icon: const Icon(Icons.search),
              label: Text('Browse ${models.length} published models'),
            ),
          ],
        ),
      );
}

// Exact IDs from official upstream catalogs, reviewed 2026-09-06.
// See docs/translation/engine-support.md. None imply an installed adapter.
const _ppocrDetectionModels = [
  'PP-OCRv6_medium_det',
  'PP-OCRv6_small_det',
  'PP-OCRv6_tiny_det',
  'PP-OCRv5_server_det',
  'PP-OCRv5_mobile_det',
  'PP-OCRv4_server_det',
  'PP-OCRv4_mobile_det',
];
const _ppocrRecognitionModels = [
  'PP-OCRv6_medium_rec',
  'PP-OCRv6_small_rec',
  'PP-OCRv6_tiny_rec',
  'PP-OCRv5_server_rec',
  'PP-OCRv5_mobile_rec',
  'en_PP-OCRv5_mobile_rec',
  'korean_PP-OCRv5_mobile_rec',
  'latin_PP-OCRv5_mobile_rec',
  'eslav_PP-OCRv5_mobile_rec',
  'th_PP-OCRv5_mobile_rec',
  'el_PP-OCRv5_mobile_rec',
  'arabic_PP-OCRv5_mobile_rec',
  'cyrillic_PP-OCRv5_mobile_rec',
  'devanagari_PP-OCRv5_mobile_rec',
  'te_PP-OCRv5_mobile_rec',
  'ta_PP-OCRv5_mobile_rec',
  'PP-OCRv4_server_rec_doc',
  'PP-OCRv4_mobile_rec',
  'PP-OCRv4_server_rec',
  'en_PP-OCRv4_mobile_rec',
  'PP-OCRv3_mobile_rec',
  'en_PP-OCRv3_mobile_rec',
  'korean_PP-OCRv3_mobile_rec',
  'japan_PP-OCRv3_mobile_rec',
  'chinese_cht_PP-OCRv3_mobile_rec',
  'te_PP-OCRv3_mobile_rec',
  'ka_PP-OCRv3_mobile_rec',
  'ta_PP-OCRv3_mobile_rec',
  'latin_PP-OCRv3_mobile_rec',
  'arabic_PP-OCRv3_mobile_rec',
  'cyrillic_PP-OCRv3_mobile_rec',
  'devanagari_PP-OCRv3_mobile_rec',
];
const _yoloModels = ['yolo26n', 'yolo26s', 'yolo26m', 'yolo26l', 'yolo26x'];

class _ModelCatalogDialog extends StatefulWidget {
  const _ModelCatalogDialog({required this.title, required this.models});
  final String title;
  final List<String> models;

  @override
  State<_ModelCatalogDialog> createState() => _ModelCatalogDialogState();
}

class _ModelCatalogDialogState extends State<_ModelCatalogDialog> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final matches = widget.models
        .where(
          (model) =>
              model.toLowerCase().contains(_search.text.trim().toLowerCase()),
        )
        .toList();
    // Apply keyboard insets immediately. Dialog's inset animation can retain
    // the taller portrait keyboard while rotation has already reduced height,
    // briefly leaving less room than its fixed Close action needs.
    return Padding(
      padding: MediaQuery.viewInsetsOf(context),
      child: MediaQuery.removeViewInsets(
        context: context,
        removeLeft: true,
        removeTop: true,
        removeRight: true,
        removeBottom: true,
        child: AlertDialog(
          scrollable: true,
          title: Text(widget.title),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Search model IDs',
                    prefixIcon: Icon(Icons.search),
                  ),
                ),
                const SizedBox(height: 8),
                const Text('Published upstream · not integrated in this build'),
                const SizedBox(height: 8),
                for (final model in matches)
                  ListTile(
                    title: Text(model),
                    trailing: const Icon(Icons.add_circle_outline),
                    onTap: () => Navigator.pop(context, model),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }
}

String _colorText(int? color) => color == null
    ? ''
    : '#${color.toRadixString(16).padLeft(8, '0').toUpperCase()}';

class _SettingsNotice extends StatelessWidget {
  const _SettingsNotice({
    required this.icon,
    required this.text,
    this.isError = false,
  });
  final IconData icon;
  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.symmetric(vertical: 8),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: isError
          ? Theme.of(context).colorScheme.errorContainer
          : Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon),
        const SizedBox(width: 8),
        Expanded(child: Text(text)),
      ],
    ),
  );
}
