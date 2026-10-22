# dta_flutter_probe

What can a coding agent see in a Flutter app running on Android?

This is a small Flutter app that deliberately touches both layers of a Flutter
app on Android: Dart, and the native Android app around it. I ran three MCP
servers against it and recorded what each one could see and do:

| Server | Version | Works through |
|---|---|---|
| [Dart & Flutter MCP server](https://github.com/dart-lang/ai/tree/main/pkgs/dart_mcp_server) | 1.2.0 (bundled with Dart 3.13.5) | Dart VM service and DTD |
| [Marionette MCP](https://github.com/leancodepl/marionette_mcp) | 0.7.0 | Dart VM service |
| [DTA](https://github.com/yamsergey/dta) | sidekick 0.9.40 | in-process Android agent (debug builds) |

Tested on 9 October 2026 with Flutter 3.47.7 on an Android emulator (Pixel 10, API 37).

## The short version

The Dart side is well covered: widget tree, hot reload, runtime errors, and Dart's
HTTP profile. The native side is almost invisible to the Flutter tools: WebView
content, Custom Tabs, what plugins wrote to SharedPreferences and SQLite, the
activity lifecycle, and native SDK traffic. The one exception is `ok_http`, which
reports its requests into Dart's HTTP profile through `package:http_profile`.

Reading the runtime is half of it. The other half is changing it: mocking a
backend response, putting a stale token back, seeding a database, so a bug happens
on demand. DTA did that for the native side here: it mocked a 500 that the Flutter
app really received, and that Dart's profiler recorded as a genuine response.

| What the agent needs to know | Dart & Flutter MCP | Marionette | DTA |
|---|---|---|---|
| Which widgets are on screen | ✅ | ✅ with keys, tappable | ❌ one `FlutterView` |
| What Dart's HTTP client sent and received | ✅ after profiling is enabled | ❌ | ❌ |
| What OkHttp (`ok_http`) sent and received | ✅ via `package:http_profile` | ❌ | ✅ recorded from launch |
| What's inside the WebView | ❌ | ❌ | ✅ full DOM with bounds |
| Whether a Custom Tab is open, and its traffic | ❌ | ❌ | ✅ |
| What's stored in SharedPreferences and SQLite | ❌ | only via a custom extension | ✅ |
| Make the backend fail on demand | ❌ | ❌ | ✅ mock rules on OkHttp |
| Which code created an element | partly: one widget at a time, after a tap in selection mode | ❌ | ❌ for Flutter widgets |

DTA is Android-only. The same in-process approach works on iOS:
[FLEX](https://github.com/FLEXTool/FLEX) has long shown that network traffic, files
and user defaults can be inspected and edited from inside an iOS app. It just isn't
exposed to agents.

## Videos

Claude Code with all three servers connected, on the left; the app on the right.
The prompts describe what to find out, not which tool to use. Waits where only the
spinner moves are sped up.

The workspace's CLAUDE.md lists the device, the package and the VM service URI. It
also says that `layout_tree` includes WebView content only when called without
filters: in DTA 0.9.40, a `type: "WebView"` filter drops the page's DOM, and
agents tend to reach for that filter.

**WebView: where does the link go?** Marionette opens the screen; DTA's
`layout_tree` reads the page inside the WebView, including the link's target,
without tapping it.

[![WebView](videos/webview.jpg)](videos/webview.mp4)

**Mocked 500.** DTA makes the `ok_http` request return a 500. The Flutter app
receives it, and the agent notices the app treats it as a normal response because
`_nativeHttp` never checks the status code.

[![Mocked 500](videos/mock500.jpg)](videos/mock500.mp4)

**Custom Tab.** The page opens in Chrome's process, outside the app. DTA reads
what's on it and every request it made.

[![Custom Tab](videos/customtab.jpg)](videos/customtab.mp4)

## What's in the app

One screen with a button per path through the app, plus a WebView screen:

| Button (widget key) | What it does | Layer |
|---|---|---|
| Dart HTTP (`dart_http`) | `package:http` GET `/users/1` | Dart (`dart:io` sockets) |
| Native HTTP (`native_http`) | `ok_http` GET `/users/2` | Android (OkHttp) |
| Save SharedPreferences (`prefs`) | `shared_preferences`: `auth_token`, `user_role` | Android SharedPreferences |
| Write SQLite row (`sqlite`) | `sqflite`: `probe.db`, table `profile` | Android SQLite |
| Open Custom Tab (`custom_tab`) | `url_launcher`, `LaunchMode.inAppBrowserView` | Chrome's process |
| Open WebView (`webview`) | `webview_flutter`, loads example.com | Android WebView (platform view) |

It also registers a Marionette extension, `probe.expireToken`, which replaces the
stored token with an expired one.

## Reproducing it

### Prerequisites

- Flutter 3.47+ (Dart 3.9+ for `dart mcp-server`)
- An Android emulator or device. API 28+ for all of DTA's features.
- Marionette: `dart pub global activate marionette_mcp`
- DTA: `brew tap yamsergey/packages && brew install dta-cli`, or the DTA plugin
  for Android Studio

### Run the app

```sh
flutter run -d <device> --print-dtd
```

Note the VM service URI and the DTD URI it prints, then export them for the
scripts:

```sh
export VM_SERVICE_WS=ws://127.0.0.1:<port>/<token>=/ws   # VM service URI, http → ws, plus /ws
export DTD_URI=ws://127.0.0.1:<port>/<token>=
```

`ISOLATE_ID` comes from the `getVM` call in `02-dart-mcp-enable-http-profile.json`
(the `main` isolate).

The debug build already includes the DTA sidekick (see
`android/app/build.gradle.kts`). With the DTA Android Studio plugin or
`dta-cli run`, it's injected automatically and that dependency can be removed.

### Run the scenarios

`scripts/mcp_batch.py` sends a list of tool calls to an MCP server over stdio and
prints the results. Each file in `scripts/calls/` is one scenario:

```sh
cd scripts
MARIONETTE="dart pub global run marionette_mcp"
python3 mcp_batch.py calls/01-marionette-exercise-app.json 2000 -- $MARIONETTE
python3 mcp_batch.py calls/02-dart-mcp-enable-http-profile.json 2000 -- dart mcp-server
python3 mcp_batch.py calls/04-dta-native-side.json 3000 -- dta-cli mcp serve
```

| Calls file | Server | Shows |
|---|---|---|
| `01-marionette-exercise-app.json` | Marionette | Presses every button by key; calls the `probe.expireToken` extension |
| `02-dart-mcp-enable-http-profile.json` | Dart MCP | Finds the isolate; turns on Dart's HTTP profiling |
| `03-dart-mcp-read-http-profile.json` | Dart MCP | Dart's HTTP profile: `dart:io` and `ok_http` entries (`from_package/N`) |
| `04-dta-native-side.json` | DTA | OkHttp traffic, SharedPreferences, SQLite rows, lifecycle |
| `05-dta-mock-500.json` | DTA | Mocks `/users/2` with a 500. Press Native HTTP again, then rerun `03` |
| `06-marionette-webview.json` | Marionette | Opens the WebView; only the back button and title are visible |
| `07-dta-layout-tree.json` | DTA | On the WebView screen: the page's DOM inside the platform view |
| `08-marionette-custom-tab.json` | Marionette | Opens the Custom Tab; still lists the Flutter buttons behind it |
| `09-dta-custom-tab-traffic.json` | DTA | The tab's attach trace and traffic |
| `10-dart-mcp-widget-locations.json` | Dart MCP | `get_widget_tree` without locations; the raw inspector call with `fullDetails` returns `creationLocation` |

Delete the mock rule afterwards with `mock_delete_rule`.

## Selected outputs

The WebView screen, as Marionette sees it:

```
Found 2 interactive element(s):
Type: BackButton
Type: Text, Text: "WebView"
```

The same screen, from DTA's `layout_tree`:

```
FlutterView
 └ PlatformViewWrapper
    └ WebViewPlatformView
       └ web "Example Domain"
          ├ web "This domain is for use in documentation examples…"
          └ web "Learn more"
```

The mocked request, in Dart's HTTP profile (`getHttpProfileRequest`):

```
id: from_package/2   uri: .../users/2   status: 500
body: {"name":"MOCKED BY DTA"}   connectionInfo: package:ok_http / OkHttpClient
```

The same request, in DTA:

```
url: .../users/2   responseCode: 500   mocked: true   mockRuleId: 254e6aac-…   source: OkHttp
```

## Two notes on the Dart & Flutter MCP server

- `get_widget_tree` sends `fullDetails: 'false'` to
  `ext.flutter.inspector.getRootWidgetTree` (hard-coded in
  `lib/src/mixins/dtd.dart`), which drops each widget's `creationLocation`. The
  same call with `fullDetails: 'true'` returns, for example,
  `main.dart:179:19` for each `FilledButton`. Today `get_selected_widget` is the
  only way to get a location: one widget at a time, after a tap in selection mode.
- Apps can register `ext.*` service extensions and the server can call them
  through `vm_service`, but `getIsolate` lists only their names. Marionette's
  `registerMarionetteExtension` with an `inputSchema` shows how such extensions
  can become described, named MCP tools.

## Build notes

- `ok_http` depends on `jni`, whose Android module compiles against API 31.
  `android/build.gradle.kts` raises `compileSdk` for plugin modules to 36.
- `OkHttpClient.close()` evicts the connection pool on the Android main thread
  and throws `NetworkOnMainThreadException`, so the app keeps one long-lived
  client.
- On Android 11+, `url_launcher` needs the `<queries>` entries in
  `AndroidManifest.xml` to find a Custom Tabs browser.
