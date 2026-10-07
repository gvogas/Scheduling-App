# iPhone performance measurements

Status: harness and local trace instrumentation added; **no physical-device
measurements have been collected**. Windows cannot build or profile this iOS app.
The fixture benchmark measures rendering, not startup, network, or photo uploads.

Use the same physical iPhone, iOS version, refresh-rate setting, app commit,
fixture data and network for both revisions. Record those values with every
result. Disable Low Power Mode, allow the phone to cool, and disconnect the
debugger when measuring release startup. Do five runs; retain individual results
and compare the median and tail rather than the fastest run.

## Repeatable calendar workloads

On the Mac, after the existing iOS signing/SPM setup:

```sh
flutter pub get
flutter drive --profile -d <iphone-id> \
  --driver=test_driver/performance_driver.dart \
  --target=integration_test/performance_test.dart \
  --dart-define=PERF_DEVICE_LABEL='<model>; iOS <version>; <refresh rate>'
```

The harness exercises the production month pager for 12 swipes and scrolls the
production agenda with 100 synthetic appointments. It requires no Firebase
configuration or customer records. Save `build/integration_response_data.json`
under a directory named for the commit and run number. Compare build/raster
frame distributions, missed frame budgets, and garbage collection separately.
Do not interpret the fixture as a full application startup benchmark.

The driver uses Flutter's
[`watchPerformance`](https://api.flutter.dev/flutter/package-integration_test_integration_test/IntegrationTestWidgetsFlutterBinding/watchPerformance.html).
Use a physical device in profile mode for representative Flutter timing, as
described in [Flutter's performance guidance](https://docs.flutter.dev/perf/ui-performance).

## Full app: startup, reads and photos

```sh
flutter run --profile -d <iphone-id> \
  --dart-define-from-file=dev/firebase.local.json \
  --dart-define=PROFILE_APP=true
```

Use a dedicated test account and synthetic jobs/photos. The optional traces have
fixed operation names and include no customer data, paths, or credentials:

| Trace | Scope |
|---|---|
| `dartToFirstFrame` | Dart main entry through the first Flutter frame; excludes native process launch and does not mean the account's home screen is ready |
| `clientsPage` | One filtered or unfiltered page fetch |
| `calendarRange` | A date-range read, including its retry delays |
| `photoUpload` | Storage transfer after file validation; excludes picking/compression |

Capture the full launch with Xcode Instruments/App Launch as well as Flutter's
timeline. Test a cold signed-out launch and a cold signed-in launch separately.
For each, record process-to-first-screen and process-to-interactive-calendar.

In DevTools, record these actions with both a cold and warm cache:

1. Open Clients, switch each filter, load three pages, and search within a filter.
2. Swipe 12 calendar months and scroll a day with 100 appointments.
3. Open a 20-photo job, swipe through it, then close it. Capture memory before,
   at peak, and after closing/garbage collection.
4. Pick and upload the same test photos. Measure pick/compress separately from
   the `photoUpload` transfer trace; record file sizes and connection conditions.
5. Repeat reads/uploads with a fixed network-link-conditioning profile. Record
   retry/error behavior alongside latency, not as successful fast operations.

Use Firebase emulator/request logs or the dedicated test project's usage metrics
to compare read counts. DevTools HTTP traffic alone is not a complete accounting
of native Firebase SDK requests. Never export credentials or customer payloads.

| Metric | Baseline | Revised | Status |
|---|---|---|---|
| Cold launch / interactive calendar | — | — | Physical iPhone required |
| Month/agenda frame timing | — | — | Harness ready |
| Filter/search reads and latency | — | — | Test account/network required |
| Photo upload / peak and retained memory | — | — | Physical iPhone and test photos required |

Choose regression budgets after collecting a baseline on the supported device;
no speedup or latency percentage is claimed by this audit.
