# Install the translator build on iPhone

All three routes are prepared below. Use the artifact from the exact commit you
reviewed, then follow the signing and installation steps for your route. An IPA
is a package format; its filename alone does not establish that iOS will accept
its signature or run its embedded frameworks.

The translator baseline passed 119 tests, strict analysis, an unsigned iOS
build, and an iPhone 13 simulator startup check on iOS 18.6 in
[this cloud run](https://github.com/LegendZ69/mangayomi/actions/runs/34138204626).
That evidence does not cover a signed release build, a physical iPhone, live
Vertex requests, or the pending PP-OCR, YOLO26 and LaMa adapters. See
[engine support](engine-support.md) and the [workbench guide](README.md).

## Choose the route

| Route | Build to use | Account and device requirements | Installation result |
| --- | --- | --- | --- |
| AltStore Classic / SideStore | Release IPA from `ios-sideload.yml` | Your personal Apple Account; initial setup on your own computer/device | The sideloading tool signs the package for your account and phone; refresh before its displayed expiry |
| Registered-device ad hoc | `Mangayomi-adhoc.ipa` from `ios-signed-distribution.yml` | Apple Developer Program team, matching distribution identity/profile, iPhone UDID included in the profile | Signed package restricted to its registered devices |
| TestFlight | `Mangayomi-testflight.ipa` from `ios-signed-distribution.yml` | Apple Developer Program team, App Store Connect app record, distribution identity/profile, upload access | Apple processes the upload; testers install the accepted build through TestFlight |

AltStore here means **AltStore Classic** personal sideloading. Publishing through
the separate AltStore PAL marketplace is outside these routes.

## AltStore Classic / SideStore

1. Open a successful **iOS sideload package** run in
   [GitHub Actions](https://github.com/LegendZ69/mangayomi/actions). Download
   `Mangayomi-ios-sideload-unsigned-<run_id>-<run_attempt>` and unzip it. Keep
   `Mangayomi-translator-sideload-unsigned.ipa` and its matching
   `Mangayomi-translator-sideload-unsigned.manifest.json`. Confirm the manifest's
   `source_commit` and IPA `sha256` before selecting the package in a signing tool.
2. Choose one sideloading tool and complete its current official setup:
   [AltStore Classic for macOS](https://faq.altstore.io/altstore-classic/how-to-install-altstore-macos)
   or [Windows](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows),
   or [SideStore prerequisites](https://docs.sidestore.io/docs/installation/prerequisites)
   and [installation](https://docs.sidestore.io/docs/installation/install).
3. Sign in to your Apple Account within that tool on your own computer/device.
   Keep account passwords, pairing files and two-factor codes out of chat,
   commits and GitHub Actions. Enable Developer Mode and trust the developer
   identity on the phone when the official setup for your iOS version requires it.
4. Import the downloaded IPA using the tool's app-install control. Let it finish
   signing and installing, then launch Mangayomi and complete the device checks
   below. This workflow has no personal Apple Account credentials.

The workflow builds release mode automatically for relevant translator-branch
and pull-request changes, using Flutter 3.47.2 and Xcode 26.6. Its artifact and
logs remain available for 14 days. The manifest records the bundle/version,
minimum iOS version, architecture checks and package size, and explicitly sets
`requires_resigning: true` and `installable_as_downloaded: false`.
The packager verifies the pinned Dart SDK's AOT snapshot data/text exports,
`_kDartSnapshotData` and `_kDartSnapshotText`, alongside physical-device Mach-O
and archive-integrity checks.
[Pinned Dart snapshot contract](https://github.com/dart-lang/sdk/blob/60a57cd42d64dc03e9f07aa60a2e250755c1ef28/runtime/include/dart_api.h)

AltStore Classic's free-account apps expire after seven days and share a
three-app installation limit; use its **My Apps** refresh controls before the
displayed expiry. Its server must be reachable for refreshing.
[AltStore usage guide](https://faq.altstore.io/altstore-classic/your-altstore)

SideStore's current setup uses **iloader** for initial installation and
**LocalDevVPN** on the phone. Its official prerequisites require Wi-Fi and the
local VPN while installing, updating or refreshing apps. Keep SideStore's own
installation refreshed as well as Mangayomi. Use its current instructions if
pairing needs to be renewed after an iOS update.
[SideStore prerequisites](https://docs.sidestore.io/docs/installation/prerequisites),
[installation and refresh](https://docs.sidestore.io/docs/installation/install)

The unsigned release package is a candidate for re-signing. A successful
packaging run does not prove that AltStore or SideStore can sign every embedded
framework, nor that the app launches on a physical device. Retain an app backup
before changing signing identity or bundle ID; those changes can affect access
to existing app data and secure-store credentials.

## Prepare the two signed routes

An Account Holder or Admin should register an explicit App ID under the team's
own bundle ID. The repository's upstream ID, `com.kodjodevf.mangayomi`, is not a
claim that your team owns it. Use the same bundle ID in the selected profile,
workflow input, and App Store Connect record where applicable.

For **ad hoc**, register the iPhone 13's UDID, then create an Ad Hoc profile that
includes this device and the selected Apple Distribution certificate. A new
device requires an updated profile and another export.
[Apple device registration](https://developer.apple.com/help/account/devices/register-a-single-device/),
[Ad Hoc profile creation](https://developer.apple.com/help/account/provisioning-profiles/create-an-ad-hoc-provisioning-profile/)

For **TestFlight**, create an App Store Connect distribution profile for the same
App ID and certificate. Create the iOS app record in App Store Connect with its
name, primary language, bundle ID and SKU before uploading. The Account Holder
must accept any required agreement there.
[App Store profile creation](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile/),
[app record setup](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/)

Export the selected distribution identity **including its private key** as a
password-protected `.p12` from a Mac that holds it. A certificate file without
the private key cannot sign the app. The profile, certificate, team, bundle ID
and app entitlements must agree; the workflow does not create missing Apple
resources or silently enable new capabilities.

### GitHub environment configuration

Create `ios-adhoc` and `ios-testflight` under repository **Settings >
Environments**. Restrict them to reviewed branches and configure reviewers before
adding signing material. The environment name alone does not create approval
rules. Add the following as environment secrets, directly in GitHub's settings.
Base64 is only the file transport encoding; treat the encoded values as secrets.
[GitHub environment setup](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments),
[secret setup](https://docs.github.com/en/actions/how-tos/write-workflows/choose-what-workflows-do/use-secrets)

| Exact secret name | Environment | Value supplied privately by the account owner |
| --- | --- | --- |
| `IOS_DISTRIBUTION_P12_BASE64` | Both | Base64-encoded distribution `.p12` containing its private key |
| `IOS_DISTRIBUTION_P12_PASSWORD` | Both | Password used when exporting that `.p12` |
| `IOS_ADHOC_PROFILE_BASE64` | `ios-adhoc` | Base64-encoded `.mobileprovision` including the intended device UDIDs |
| `IOS_APP_STORE_PROFILE_BASE64` | `ios-testflight` | Base64-encoded App Store Connect `.mobileprovision` |
| `ASC_API_KEY_P8_BASE64` | `ios-testflight`, only for upload | Base64-encoded App Store Connect team API private key `.p8` |
| `ASC_API_KEY_ID` | `ios-testflight`, only for upload | Key ID corresponding to that `.p8` |
| `ASC_API_ISSUER_ID` | `ios-testflight`, only for upload | Issuer ID of the App Store Connect team API key |

The optional upload uses a **team API key**; an individual API key is not a
substitute for this issuer-based configuration. Create a key with the necessary
upload permission under App Store Connect **Users and Access > Integrations**,
and save its private key securely when first downloaded. It cannot be downloaded
again. Build uploads require an eligible App Store Connect role, such as
Developer or App Manager.
[Apple API key management](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/),
[build upload permissions](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)

### Manual build inputs

The signed workflow runs only through `workflow_dispatch`. GitHub requires this
workflow to exist on the default branch before manual dispatch is available.
Review and merge its preparation separately before activation; creating a
release tag is unnecessary. Once available, choose the reviewed branch under
**Actions > Signed iOS distribution > Run workflow**.
[GitHub manual workflow requirements](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/manually-run-a-workflow)

| Input | Value and meaning |
| --- | --- |
| `route` | `adhoc` or `testflight`; selects the matching environment and profile |
| `source_sha` | Full 40-character commit SHA at the selected dispatch revision; a different SHA fails before signing |
| `bundle_id` | Your explicit registered bundle ID, matching the profile and App Store Connect record |
| `team_id` | Your ten-character Apple Developer team ID, matching the certificate and profile |
| `build_name` | Three-part numeric marketing version, for example `0.1.0` |
| `build_number` | First component `1`–`9999`, with optional second/third components `0`–`99`, without leading zeros; for example `1` or `1.2.3` |
| `upload_testflight` | `false` by default; `true` explicitly validates and uploads the TestFlight IPA using the additional API secrets; it is invalid for `adhoc` |

Use a fresh build number for a new App Store Connect upload. These inputs
override build identity in the produced artifact, while the manifest records
the reviewed source revision. Flutter maps the marketing and build versions to
the iOS bundle version fields and supports exporting IPAs with explicit Xcode
export options.
[Flutter iOS release guide](https://docs.flutter.dev/deployment/ios)

The signed workflow selects Xcode **26.6**, build **17F113**, with iPhoneOS SDK
**26.5** on the `macos-26` runner and checks the selected toolchain. This is a
repository pin, not an Apple-required exact version. Apple requires uploads to
App Store Connect to be built with Xcode 26 or later and the iOS 26 SDK or later
since April 28, 2026. The SDK requirement is distinct from the app's deployment
target; this repository currently targets iOS 15.0.
[Apple SDK upload requirement](https://developer.apple.com/news/upcoming-requirements/)

### Retrieve and install the signed build

The result artifact is named
`Mangayomi-ios-<route>-<run_id>-<run_attempt>` and contains
`Mangayomi-adhoc.ipa` or `Mangayomi-testflight.ipa` plus `source.json` and
`result.json`.
Artifacts remain available for seven days. Check the workflow's validation,
signing, export and optional upload outcomes independently.
`result.json` describes the exported IPA before any optional Apple upload; use
the separate upload step and App Store Connect status to confirm delivery.

An ad hoc IPA necessarily embeds its provisioning profile, including registered
device identifiers. This is a public repository: its Actions artifacts are not
private storage, even when signing secrets come from a protected environment.
The workflow excludes the standalone private key and signing-material files
from uploads, but cannot remove the embedded profile from a usable ad hoc IPA.
Use a private repository or private distribution workflow before exporting if
those device identifiers must remain private.
[GitHub artifact download access](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/download-workflow-artifacts)

For ad hoc, transfer the signed IPA to the registered phone using Apple's
registered-device installation workflow, such as Xcode's Devices and Simulators
window on a connected Mac. Installation on a device missing from the profile
will fail. Downloading the artifact in Safari alone does not perform installation.
[Apple registered-device distribution](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices)

For TestFlight with upload disabled, retain the IPA for review or upload it later
through Apple's Transporter or the documented Flutter/Apple upload flow. With
upload enabled, a successful upload means Apple received the binary; processing
and availability still need to be checked in App Store Connect.
[Apple build upload workflow](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/)

In App Store Connect, resolve export-compliance questions, provide beta test
information and assign the processed build to a tester group. Internal testing
supports eligible App Store Connect users; external testing may require Beta App
Review, including the first submitted build. Testers accept an invitation in
TestFlight on their phone. Builds can be tested for up to 90 days. Neither the
workflow nor an upload sends invitations or publishes an App Store release.
[Apple TestFlight workflow](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)

## Acceptance before wider distribution

| Check | Evidence still needed |
| --- | --- |
| Installation and launch | A physical iPhone 13 installs the route's signed release package and reaches the usable app UI after a cold start |
| Native dependencies | Release arm64 frameworks load on the device; media playback and any optional extension-server use are exercised separately |
| Translator | File import, queue persistence, cancel/retry, preview alignment, search/filter/swipe actions and large text work on device |
| Provider | With the owner's credentials and explicit Run action, one authorized page completes the configured Vertex request and overlay; credentials are absent from exported logs |
| Engine claims | PP-OCR, YOLO26 and LaMa continue to fail explicitly until their adapters are implemented and validated; installation does not complete those integrations |
| TestFlight acceptance | Apple processes the actual archive and any required Beta App Review succeeds; an unsigned build or simulator screenshot is insufficient |

This app includes an optional OpenJDK-based extension server and content-source
features. Their actual behavior needs review against Apple's rules on downloaded
executable code, background execution, third-party content and accurate feature
disclosure. This is a concrete unresolved distribution concern, not a claim that
Apple has accepted or rejected this build. A separate feature decision may be
needed if Apple rejects the submitted functionality; do not conceal it from
review. Signing and packaging cannot establish review compliance.
[Apple review guidelines, sections 2.3, 2.5 and 5.2](https://developer.apple.com/app-store/review/guidelines/)

These workflows do not use the repository's existing broad release automation.
Pushing a `v*` tag triggers that separate seven-platform release workflow and
its sideload-feed handling, which still needs fork-specific review. Do not use
such a tag to activate these installation routes.

Official documentation checked **2026-09-07**. Workflow pins and application
preferences above are explicitly identified as repository choices.
