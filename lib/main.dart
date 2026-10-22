// Probe app: which layer of a Flutter app can each MCP server see?
//
// Each button exercises one path through the app:
//   - Dart HTTP      -> package:http over dart:io (Dart VM sockets)
//   - Native HTTP    -> package:ok_http (OkHttp, on the Android side)
//   - Prefs          -> shared_preferences (Android SharedPreferences)
//   - SQLite         -> sqflite (Android SQLite)
//   - WebView        -> webview_flutter (Android WebView, a platform view)
//   - Custom Tab     -> url_launcher inAppBrowserView (runs in Chrome's process)
// plus a Marionette debug extension (`probe.expireToken`).
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:marionette_flutter/marionette_flutter.dart';
import 'package:ok_http/ok_http.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

const _api = 'https://jsonplaceholder.typicode.com';

void main() {
  if (!kReleaseMode) {
    MarionetteBinding.ensureInitialized();
    _registerDebugExtensions();
  }
  runApp(const ProbeApp());
}

void _registerDebugExtensions() {
  registerMarionetteExtension(
    name: 'probe.expireToken',
    description: 'Replaces the stored auth token with an expired one.',
    inputSchema: ExtensionInputSchema(
      properties: {
        'reason': ExtensionParam.string(description: 'Why it expired.'),
      },
    ),
    callback: (params) async {
      final prefs = await SharedPreferences.getInstance();
      final old = prefs.getString('auth_token');
      final token = 'expired-${params['reason'] ?? 'manual'}';
      await prefs.setString('auth_token', token);
      return MarionetteExtensionResult.success({'old': old, 'new': token});
    },
  );
}

class ProbeApp extends StatelessWidget {
  const ProbeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DTA Flutter Probe',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const ProbeScreen(),
    );
  }
}

class ProbeScreen extends StatefulWidget {
  const ProbeScreen({super.key});

  @override
  State<ProbeScreen> createState() => _ProbeScreenState();
}

class _ProbeScreenState extends State<ProbeScreen> {
  final _log = <String>[];

  void _add(String line) {
    debugPrint('[probe] $line');
    setState(() => _log.insert(0, line));
  }

  Future<void> _run(String label, Future<String> Function() action) async {
    try {
      _add('$label: ${await action()}');
    } catch (e) {
      _add('$label FAILED: $e');
    }
  }

  Future<String> _dartHttp() async {
    final res = await http.get(
      Uri.parse('$_api/users/1'),
      headers: {'X-Probe': 'dart-http'},
    );
    return '${res.statusCode} ${jsonDecode(res.body)['name']}';
  }

  // One long-lived client: OkHttpClient.close() evicts the connection pool on
  // the Android main thread, which throws NetworkOnMainThreadException.
  static final _okHttp = OkHttpClient();

  Future<String> _nativeHttp() async {
    final res = await _okHttp.get(
      Uri.parse('$_api/users/2'),
      headers: {'X-Probe': 'ok-http'},
    );
    return '${res.statusCode} ${jsonDecode(res.body)['name']}';
  }

  Future<String> _prefs() async {
    final prefs = await SharedPreferences.getInstance();
    final token = 'token-${DateTime.now().millisecondsSinceEpoch}';
    await prefs.setString('auth_token', token);
    await prefs.setString('user_role', 'Senior Engineer');
    return 'saved $token';
  }

  Future<String> _sqlite() async {
    final db = await openDatabase(
      p.join(await getDatabasesPath(), 'probe.db'),
      version: 1,
      onCreate: (db, _) => db.execute(
        'CREATE TABLE profile (id INTEGER PRIMARY KEY, name TEXT, role TEXT, fetched_at INTEGER)',
      ),
    );
    await db.insert(
      'profile',
      {
        'id': 1,
        'name': 'Ada Lovelace',
        'role': 'Senior Engineer',
        'fetched_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    final count = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM profile'),
    );
    return '$count row(s) in profile';
  }

  @override
  Widget build(BuildContext context) {
    final buttons = <(String, String, VoidCallback)>[
      ('dart_http', 'Dart HTTP (package:http)', () => _run('dart http', _dartHttp)),
      ('native_http', 'Native HTTP (OkHttp)', () => _run('native http', _nativeHttp)),
      ('prefs', 'Save SharedPreferences', () => _run('prefs', _prefs)),
      ('sqlite', 'Write SQLite row', () => _run('sqlite', _sqlite)),
      (
        'custom_tab',
        'Open Custom Tab',
        () => _run('custom tab', () async {
              final ok = await launchUrl(
                Uri.parse('https://jsonplaceholder.typicode.com/?probe=custom_tab'),
                mode: LaunchMode.inAppBrowserView,
              );
              return ok ? 'launched' : 'not launched';
            }),
      ),
      (
        'webview',
        'Open WebView',
        () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const WebViewScreen()),
            ),
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('DTA Flutter Probe')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (key, label, onPressed) in buttons)
                  FilledButton(
                    key: ValueKey(key),
                    onPressed: onPressed,
                    child: Text(label),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              key: const ValueKey('log'),
              padding: const EdgeInsets.all(16),
              children: [for (final line in _log) Text(line)],
            ),
          ),
        ],
      ),
    );
  }
}

class WebViewScreen extends StatefulWidget {
  const WebViewScreen({super.key});

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> {
  late final WebViewController _controller = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..loadRequest(Uri.parse('https://example.com'));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('WebView')),
      body: WebViewWidget(controller: _controller),
    );
  }
}
