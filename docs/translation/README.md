# Page translation workbench

This feature adds a translation workbench to Mangayomi. It is under development;
the engine support matrix in [engine-support.md](engine-support.md) distinguishes
published models from integrated and device-validated adapters.

## Execution modes

**Vision engine execution** controls PP-OCR, YOLO26 and LaMa placement:

| Mode | Non-AI vision engines | Gemini | Display and overlay |
| --- | --- | --- | --- |
| Hybrid (default) | Prefer validated local PP-OCR and remote YOLO26/LaMa; resolve only available implementations of the selected engine | Cloud | On device |
| Cloud only | Require a remote implementation; no native vision fallback | Cloud | On device |
| Local only | Require a native implementation; no remote vision fallback | Cloud | On device |

Local only is **not offline translation**. It does not make Gemini a local model.
AI detection, AI OCR and text translation still send page content to Google when
the user starts a queue. No engine mode authorizes infrastructure provisioning.
An unavailable selected engine blocks the job; it is never substituted with AI.

## Initial supported path

The initial workbench supports AI detection + AI OCR + translation in one
structured Vertex request, followed by an on-device overlay preview. A combined
request avoids pretending that three independent service calls have occurred;
its log reports the actual request and parsing stages.

- Open **Settings > Page translation**, or long-press a reader page and choose
  **Queue page for translation**.
- Configure the target language and Vertex credentials. Full Vertex defaults to
  `gemini-3.8-flash`, `global`, Standard PayGo, with Priority PayGo and Provisioned
  Throughput disabled. English is an application starting preference, not a
  provider requirement.
- Full Vertex uses a short-lived OAuth access token and project ID. Express uses
  an API key. Credential refresh and a production token-broker service are not
  implemented by this workbench; refresh an expired token before retrying.
- Review the queue and start it explicitly. Enqueueing a page does not upload it.
- Preview the original image with source-relative translated boxes; zoom the
  composite image and text together. This is a separate preview, not an overlay
  injected into every reader renderer or an exported typeset chapter.

Express mode uses a different URL shape, without project or location path
segments. Its published model list does not currently confirm Gemini 3.8 Flash;
the workbench warns about this and never silently selects another model.

## Configuration and API accuracy

Settings are serialized separately from credentials and snapshotted when a job
is queued. Changing defaults does not silently alter an existing job's request.
Use **Queue with current settings** to create a new snapshot; the confirmation
cancels an original pending job while retaining its history. Retrying a job uses
its original settings. Both actions require a new explicit Run authorization.
System typography is inherited unless the user selects an explicit override.

For Gemini 3.8, use `LOW`, `MEDIUM` (provider default), or `HIGH` thinking levels.
The model-specific guide says temperature/top-p/top-k are ignored and frequency
penalty, presence penalty and candidate count are rejected. The workbench must
not send legacy defaults just because the generic model card lists them.

The raw generation-configuration editor is an advanced JSON override, not a
credential/header editor. It validates supported fields and protects the
structured-output contract required to draw translated regions. HTTP requests
are sent directly through a dedicated TLS-verifying client.

Queue concurrency, timeout, retry budget, log retention, colors and typography
are application policies, not universal API/model defaults. Unspecified
model-sensitive settings should remain on the model's own defaults. Never infer
iPhone 13 performance from desktop or newer-iPhone benchmark numbers.

## Queue, privacy and diagnostics

- Queue data and page copies remain in application-support storage. Credentials
  use the platform secure store; there is no plaintext credential fallback.
- Start/resume is explicit. Interrupted requests are not automatically replayed
  on launch, because the provider may already have processed or billed them.
- Pause stops scheduling new work; cancelling an active request closes its
  transport and suppresses late results. Cancellation cannot undo provider work
  or charges already incurred.
- Logs are translation-specific and bounded. Credentials, authorization headers,
  API-key query parameters and inline image data are redacted. Raw request and
  response body capture is opt-in; captured text can still be sensitive.
- Review exports before sharing. Clearing logs and removing a job are explicit
  actions; removing a job removes its local page copy, not the original manga.
- iOS may suspend or terminate the app. Queue persistence supports recovery;
  this feature does not promise uninterrupted background translation.

## Verification and outstanding integration

Tests have been written for execution boundaries, configuration persistence,
request construction, structured-result validation, log redaction, queue
lifecycle, and iPhone-sized widget layouts. They have **not been executed** in
this environment: Flutter bootstrap attempted to contact a cloud instance
metadata endpoint and was stopped by the environment's security review. No
workaround was attempted. Static source review and whitespace checks are not
a substitute for compiler, analyzer, or test results.

A successful build, automated tests, and physical iPhone 13 tests are still
required before calling this device-validated. Run those checks in an authorized
Flutter/Xcode environment. Live Google calls require user credentials and
explicit start; the added automated tests use injected fake transports/stores
and must not contact Google or cloud instance metadata.

Follow-up work includes native/mobile and remote vision adapters, verified model
artifacts, per-variant configuration manifests, chapter-wide scheduling,
background-task integration, automatic token renewal, translated image exports,
and overlay alignment in cropped/split/rotated reader modes. See the detailed
[engine acceptance checklist](engine-support.md).

## Official references

Checked 2026-09-06; model-specific guides take precedence over generic examples
when the published defaults conflict.

- [Gemini 3.8 Flash developer guide](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/guides/gemini-3-8-flash)
- [Gemini 3.8 model card](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/gemini/3-8-flash)
- [Express mode and supported models](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/start/express-mode/overview)
- [Provisioned Throughput request routing](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/provisioned-throughput/use-provisioned-throughput)
- [Priority PayGo](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/priority-paygo)
- [Structured output](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/capabilities/control-generated-output)
- [API key security](https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/start/api-keys)
