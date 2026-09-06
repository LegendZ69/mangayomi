# Translation engine support

Documentation reviewed: 2026-09-06. Catalog entries describe upstream models,
not completed Mangayomi integrations or measured iPhone 13 performance.

## Implementation boundary

The implementation slice currently in development is the **AI detection → AI
OCR → AI translation → overlay** workbench, including secure Vertex AI full and
Express REST configuration. This document does not certify completion, live API
access, an iOS build, or physical-device validation.

PP-OCR, PP-OCR + AI, YOLO26, and LaMa are **not integrated** in this slice. Neither
native nor remote non-AI engine adapters are implemented. Showing a setting or
an upstream model name does not make its pipeline executable. Unavailable
choices must explain the missing integration, and must never silently run AI
or overlay under another engine's label.

Track these three independent facts for every engine/model combination:

| Status | Evidence required |
| --- | --- |
| Published upstream | Official model/configuration source and exact artifact identity |
| Adapter implemented | Compatible runtime, input/output contract, preprocessing, postprocessing, and tests |
| Device validated | Recorded results for the exact export, runtime, iOS version, and physical iPhone 13 |

## Vision engine execution

Use the label **Vision engine execution**, not “offline mode.” This setting
governs non-AI computer-vision engine placement. Gemini remains a cloud service
for AI detection, AI OCR, AI refinement, and translation under every policy.

| Policy | Intended non-AI engine placement |
| --- | --- |
| Hybrid — default | Permit compatible local and configured remote adapters; show the actual execution location for each stage |
| Cloud only | Use a configured remote adapter for the selected non-AI engine |
| Local only | Use a validated native adapter; do not upload to a remote non-AI adapter when unavailable |

These are application policies, not Vertex AI or model-provider settings. Until
non-AI adapters exist, changing the policy cannot enable PP-OCR, YOLO26, or LaMa.
Selecting Local only does not make the AI/AI/overlay pipeline offline. If an
enabled stage needs cloud AI, show that fact before submitting its images/text.

Hybrid fallback rules must be explicit and observable, including the selected
adapter and any upload. An unavailable adapter must produce an actionable
capability error. It must not silently change the engine, model, or user policy.

Overlay is local text/layout rendering over the page; it does not reconstruct
the hidden artwork. LaMa performs image reconstruction from an image and mask.

## PP-OCR current upstream catalog

The following is a bounded snapshot of the current official module catalogs.
It is not a list of models bundled with this app. Supported runtime versions,
language dictionaries, export formats, and input shapes must be recorded for
each installed artifact.

### Detection — 7 model IDs

| Generation | Exact model ID |
| --- | --- |
| v6 | `PP-OCRv6_medium_det` |
| v6 | `PP-OCRv6_small_det` |
| v6 | `PP-OCRv6_tiny_det` |
| v5 | `PP-OCRv5_server_det` |
| v5 | `PP-OCRv5_mobile_det` |
| v4 | `PP-OCRv4_server_det` |
| v4 | `PP-OCRv4_mobile_det` |

Source: [official text detection module](https://www.paddleocr.ai/main/en/version3.x/module_usage/text_detection.html).

### Recognition — 32 model IDs

| Generation | Exact model ID |
| --- | --- |
| v6 | `PP-OCRv6_medium_rec` |
| v6 | `PP-OCRv6_small_rec` |
| v6 | `PP-OCRv6_tiny_rec` |
| v5 | `PP-OCRv5_server_rec` |
| v5 | `PP-OCRv5_mobile_rec` |
| v5 | `en_PP-OCRv5_mobile_rec` |
| v5 | `korean_PP-OCRv5_mobile_rec` |
| v5 | `latin_PP-OCRv5_mobile_rec` |
| v5 | `eslav_PP-OCRv5_mobile_rec` |
| v5 | `th_PP-OCRv5_mobile_rec` |
| v5 | `el_PP-OCRv5_mobile_rec` |
| v5 | `arabic_PP-OCRv5_mobile_rec` |
| v5 | `cyrillic_PP-OCRv5_mobile_rec` |
| v5 | `devanagari_PP-OCRv5_mobile_rec` |
| v5 | `te_PP-OCRv5_mobile_rec` |
| v5 | `ta_PP-OCRv5_mobile_rec` |
| v4 | `PP-OCRv4_server_rec_doc` |
| v4 | `PP-OCRv4_mobile_rec` |
| v4 | `PP-OCRv4_server_rec` |
| v4 | `en_PP-OCRv4_mobile_rec` |
| v3 | `PP-OCRv3_mobile_rec` |
| v3 | `en_PP-OCRv3_mobile_rec` |
| v3 | `korean_PP-OCRv3_mobile_rec` |
| v3 | `japan_PP-OCRv3_mobile_rec` |
| v3 | `chinese_cht_PP-OCRv3_mobile_rec` |
| v3 | `te_PP-OCRv3_mobile_rec` |
| v3 | `ka_PP-OCRv3_mobile_rec` |
| v3 | `ta_PP-OCRv3_mobile_rec` |
| v3 | `latin_PP-OCRv3_mobile_rec` |
| v3 | `arabic_PP-OCRv3_mobile_rec` |
| v3 | `cyrillic_PP-OCRv3_mobile_rec` |
| v3 | `devanagari_PP-OCRv3_mobile_rec` |

Sources: [official recognition module](https://www.paddleocr.ai/main/en/version3.x/module_usage/text_recognition.html)
and its [source table](https://github.com/PaddlePaddle/PaddleOCR/blob/main/docs/version3.x/module_usage/text_recognition.en.md).
The source table contains 32 unique IDs; nearby prose still says 20. Use the
actual entries, not that stale count.

Language compatibility matters: PP-OCRv6 medium/small include Japanese, but
tiny excludes Japanese. The documented v6 language set does not include Korean;
do not select it for Korean solely because it has the newest version number.
See the [official PP-OCRv6 description](https://github.com/PaddlePaddle/PaddleOCR/blob/main/docs/version3.x/algorithm/PP-OCRv6/PP-OCRv6.en.md).
The recognition catalog includes `korean_PP-OCRv5_mobile_rec` for Korean.

### Historical variants

“All variants” must distinguish the current module catalog from the separate
[legacy 2.x catalog](https://www.paddleocr.ai/main/en/version2.x/legacy/model_list_2.x.html),
which includes earlier language, server/mobile, and slim exports. Legacy v3/v4
and current v3/v4 exports are explicitly not interchangeable. Do not relabel
legacy IDs as current models or assume one decoder can run every historical
export. Legacy support requires its own compatible artifact manifest and
adapter validation before being advertised as runnable.

## PP-OCR on iPhone

The [official iOS sample](https://www.paddleocr.ai/main/en/version3.x/inference_deployment/cross_platform/ios_deployment.html)
uses SwiftUI and ONNX Runtime's Objective-C API for on-device detection and
recognition. Its requirements are Xcode 16+ and iOS 16+. Its download presets
are `PP-OCRv6_small` (default), `PP-OCRv6_tiny`, and `PP-OCRv5_mobile`.

The sample exposes CPU, XNNPACK, and Core ML execution-provider preferences.
Operators unsupported by a preferred provider may still run on CPU. This is
an upstream sample, not an integrated Mangayomi Flutter/native bridge, and its
presets do not establish support for all recognition languages or all exports.
Its benchmark tooling covers latency, memory, accuracy checks, and runtime
profiling; use physical iPhone 13 measurements before making performance claims.

## YOLO26 catalog and text detection limits

| Upstream detection checkpoint | Scale |
| --- | --- |
| `yolo26n.pt` | Nano |
| `yolo26s.pt` | Small |
| `yolo26m.pt` | Medium |
| `yolo26l.pt` | Large |
| `yolo26x.pt` | Extra large |

The [official YOLO26 catalog](https://docs.ultralytics.com/models/yolo26) also lists
five-scale segmentation, semantic segmentation, depth, classification, pose,
and oriented-detection families. They are distinct tasks, not interchangeable
text-detection variants. P2/P6 detection configurations (`yolo26-p2.yaml`,
`yolo26-p6.yaml`) are architecture-only: no scale-specific pretrained P2/P6
checkpoints are published in that catalog.

The ordinary detection checkpoints are COCO-trained. The
[official COCO class list](https://docs.ultralytics.com/datasets/detect/coco)
has no manga-text or speech-bubble class. A manga text/bubble detector requires
suitable trained weights, class mappings, and evaluation data. A class filter
cannot add classes that a model was not trained to recognize.

[Core ML export](https://docs.ultralytics.com/integrations/coreml) is documented,
but export support is not an iPhone 13 performance guarantee. Input shape,
quantization, and output/NMS mode must match the specific export. The published
iPhone 17 Pro measurements must not be reused as iPhone 13 results. Review
[Ultralytics licensing](https://www.ultralytics.com/license) and the selected
checkpoint's provenance before distribution; model and app packaging need an
explicit license-compatibility review.

## LaMa — native execution unverified

The [official LaMa project](https://github.com/advimman/lama) performs inpainting
using an image and mask, with Big-LaMa among its published checkpoints. A
remote adapter needs a defined image/mask contract and a compatible inference
environment; there is no LaMa remote adapter in this implementation slice.

The author-linked [CoreMLaMa converter](https://github.com/mallman/CoreMLaMa)
targets macOS. Its README reports unsuccessful iOS attempts, especially with
FP16/Neural Engine execution, and does not claim successful iOS deployment.
Native LaMa must remain **not integrated / iPhone 13 unvalidated** until the
exact converted artifact passes correctness, memory, and device tests.

LaMa's [official prediction configuration](https://github.com/advimman/lama/blob/main/configs/prediction/default.yaml)
is a server/Python configuration, not a portable iPhone settings schema.
Checkpoint selection, padding, refinement, device, and output options must be
mapped through the chosen adapter. GPU IDs, CUDA settings, and optimization
refinement must not appear as functional iPhone controls. The original
[Apache-2.0 license](https://github.com/advimman/lama/blob/main/LICENSE) does not
replace a provenance review of converted weights and third-party dependencies.

## Configuration provenance

Keep model-sensitive options nullable as **Model default** and expose both
requested and resolved settings. Do not invent a universal default or slider
range. The [PP-OCR detection API](https://www.paddleocr.ai/main/en/version3.x/module_usage/text_detection.html)
defers thresholds, resizing, input shape, and expansion settings to the model
when unset. The [OCR pipeline page](https://www.paddleocr.ai/main/en/version3.x/pipeline_usage/OCR.html)
currently has examples and prose with different effective expansion values;
the loaded artifact/runtime configuration must resolve that ambiguity.

Document each exposed control's source, version, units, default origin, valid
values, applicability, and whether it is a runtime option or export property.
For example, the [YOLO prediction API](https://docs.ultralytics.com/modes/predict)
distinguishes ordinary NMS from its NMS-free path; IoU-based NMS controls must
not misleadingly claim to alter NMS-free predictions. Exported precision is
not an unrestricted runtime toggle.

Queue concurrency, retry policy, retention, cache limits, swipe actions,
filters, and display preferences are **application preferences**, not official
Vertex/PP-OCR/YOLO/LaMa constants. System font, size, and weight defaults mean
inherit platform/theme typography unless overridden; they are not model
parameters. App defaults must be labeled as such and validated separately from
provider request constraints.

Raw configuration/request access must preserve authentication and transport
boundaries. Detailed logs must redact credentials and distinguish requested
configuration, resolved configuration, original engine output, and AI-refined
output. Record fallback decisions and execution location without claiming an
unimplemented engine executed.

## Remaining acceptance checklist

### Artifact and capability manifests

- [ ] Pin upstream/runtime versions and record exact artifact URLs, hashes,
      formats, licenses, and provenance.
- [ ] Record stage/task, language/dictionary, class map, input shape, coordinate
      convention, precision, preprocessing, postprocessing, and output schema.
- [ ] Record native/remote compatibility and implemented/tested status; expose
      all variants as runnable only after their artifact and capability
      manifests exist and their adapters pass the relevant checks.
- [ ] Keep published-but-unavailable entries visibly **not integrated**, with
      clear missing-artifact or missing-adapter explanations.
- [ ] Validate mixed detection/recognition choices and reject unsupported
      language, decoder, shape, runtime, or task combinations.

### Native adapters and iPhone 13 validation

- [ ] Implement the Flutter/native bridge and model lifecycle without blocking
      reader interactions.
- [ ] Validate crop/orientation/resizing transforms and original-page polygon
      mapping, including vertical Japanese and Korean/Chinese page fixtures.
- [ ] Compare native results with a reference runtime using the same artifacts.
- [ ] Measure cold/warm latency, peak memory, sustained thermal behavior,
      cancellation, and recovery on a physical iPhone 13.
- [ ] Inspect actual execution-provider placement and CPU fallbacks; do not
      equate requesting Core ML with all operations running on the Neural Engine.
- [ ] Validate LaMa conversion, mask semantics, image fidelity, and memory
      independently; preserve the source image and make reconstruction reversible.

### Remote non-AI adapters

- [ ] Specify and version the service protocol for capabilities, artifact
      selection, images/crops/masks, outputs, errors, cancellation, and timeouts.
- [ ] Implement PP-OCR, manga-trained YOLO26, and LaMa adapters; a generic URL
      field alone does not implement those services.
- [ ] Enforce HTTPS/authentication, credential redaction, bounded payloads,
      explicit upload disclosure, and output-schema validation.
- [ ] Report the actual server model/version and effective settings; do not
      assume a server accepted an unsupported client configuration field.
- [ ] Test unavailable services, incompatible manifests, malformed results,
      timeout/retry/cancellation, and queue recovery without duplicate results.
- [ ] Verify Hybrid/Cloud only/Local only behavior, especially that Local only
      never falls back to a remote non-AI engine and that cloud Gemini stages
      remain clearly disclosed under every policy.

### End-to-end truthfulness

- [ ] Preserve raw PP-OCR output separately from AI refinement in combined
      pipelines, with disagreements and stage failures inspectable.
- [ ] Verify pipeline selections match the engines actually executed and show
      **not integrated** before a queue job can run an unsupported selection.
- [ ] Test queue/log search, filters, sorting, quick/swipe actions, accessibility,
      configuration reset/export, and redacted diagnostics against real states.
- [ ] Replace any performance or compatibility claims only with recorded
      evidence; do not treat this catalog or an upstream demo as app validation.
