import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

void main() {
  runApp(const PipeLayoutApp());
}

class PipeLayoutApp extends StatelessWidget {
  const PipeLayoutApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pipe Layout Scanner',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const PipeLayoutHomePage(),
    );
  }
}

class PipeLayoutHomePage extends StatefulWidget {
  const PipeLayoutHomePage({super.key});

  @override
  State<PipeLayoutHomePage> createState() => _PipeLayoutHomePageState();
}

class _PipeLayoutHomePageState extends State<PipeLayoutHomePage> {
  final TextEditingController _urlController =
      TextEditingController(text: 'http://192.168.4.70:8000');
  final ScrollController _scrollController = ScrollController();

  SharedPreferences? _prefs;
  Timer? _saveUrlDebounce;

  bool _busy = false;
  String _status = 'Ready';
  String _output = '';

  List<List<double>>? _loadedPoints;
  String? _loadedFileName;

  // New: latest processed result summary
  int? _lastProcessingMs;
  String? _lastDevice;
  List<Map<String, dynamic>> _pipeCards = [];

  static const Duration shortTimeout = Duration(seconds: 15);
  static const Duration longTimeout = Duration(seconds: 60);

  @override
  void initState() {
    super.initState();
    _initPrefs();
    _urlController.addListener(_onUrlChanged);
  }

  Future<void> _initPrefs() async {
    _prefs = await SharedPreferences.getInstance();
    final saved = _prefs?.getString('backend_url');
    if (saved != null && saved.trim().isNotEmpty && mounted) {
      setState(() => _urlController.text = saved.trim());
    }
  }

  void _onUrlChanged() {
    _saveUrlDebounce?.cancel();
    _saveUrlDebounce = Timer(const Duration(milliseconds: 500), () async {
      final url = _urlController.text.trim();
      if (url.isNotEmpty) {
        await _prefs?.setString('backend_url', url);
      }
    });
  }

  Uri _uri(String path) {
    final base = _urlController.text.trim().replaceAll(RegExp(r'/$'), '');
    return Uri.parse('$base$path');
  }

  double? _toDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  int? _toInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  void _updatePipeCardsFromResponse(Map<String, dynamic> resp) {
    final rawPipes = resp['pipes'];
    final cards = <Map<String, dynamic>>[];

    if (rawPipes is List) {
      for (final p in rawPipes) {
        if (p is! Map<String, dynamic>) continue;

        final lengthM = _toDouble(p['length_meters'] ?? p['length']);
        final diameterM = _toDouble(p['diameter_meters'] ?? p['diameter']);
        final elong = _toDouble(p['elongation']);

        cards.add({
          'length_m': lengthM,
          'diameter_mm': diameterM != null ? diameterM * 1000.0 : null,
          'elongation': elong,
        });
      }
    }

    if (!mounted) return;
    setState(() {
      _lastProcessingMs = _toInt(resp['processing_ms']);
      _lastDevice = resp['device']?.toString();
      _pipeCards = cards;
    });
  }

  Future<void> _setStatus(String text) async {
    if (!mounted) return;
    setState(() => _status = text);
  }

  Future<void> _setOutput(dynamic obj) async {
    if (!mounted) return;
    setState(() => _output = const JsonEncoder.withIndent('  ').convert(obj));
    await Future.delayed(const Duration(milliseconds: 10));
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  Future<Map<String, dynamic>> _request(Future<http.Response> req, Duration timeout) async {
    final resp = await req.timeout(timeout);
    final body = resp.body.isEmpty ? '{}' : resp.body;

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('HTTP ${resp.statusCode}: $body');
    }

    final decoded = json.decode(body);
    if (decoded is Map<String, dynamic>) return decoded;
    return {'data': decoded};
  }

  Future<void> _run(String label, Future<void> Function() fn) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = '$label...';
    });

    try {
      await fn();
      await _setStatus('$label OK');
    } on TimeoutException {
      await _setStatus('$label timeout');
      await _setOutput({'error': 'Request timeout'});
    } catch (e) {
      await _setStatus('$label failed');
      await _setOutput({'error': e.toString()});
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<List<double>> _syntheticPoints({int pipePoints = 8000, int noisePoints = 500}) {
    final rnd = Random();
    final points = <List<double>>[];

    for (int i = 0; i < pipePoints; i++) {
      final x = -2.0 + rnd.nextDouble() * 4.0;
      final t = rnd.nextDouble() * 2 * pi;
      final r = 0.02 + (rnd.nextDouble() * 0.004 - 0.002);
      final y = r * cos(t) + (rnd.nextDouble() * 0.004 - 0.002);
      final z = r * sin(t) + (rnd.nextDouble() * 0.004 - 0.002);
      points.add([x, y, z]);
    }

    for (int i = 0; i < noisePoints; i++) {
      points.add([
        -3 + rnd.nextDouble() * 6,
        -3 + rnd.nextDouble() * 6,
        -3 + rnd.nextDouble() * 6,
      ]);
    }

    return points;
  }

  List<List<double>> _extractPoints(dynamic data) {
    final dynamic raw = (data is Map<String, dynamic>) ? data['points'] : data;
    if (raw is! List) {
      throw Exception('JSON must be a list or {"points":[...]}');
    }

    final out = <List<double>>[];
    for (final p in raw) {
      if (p is List && p.length == 3) {
        final x = (p[0] as num?)?.toDouble();
        final y = (p[1] as num?)?.toDouble();
        final z = (p[2] as num?)?.toDouble();
        if (x != null && y != null && z != null) out.add([x, y, z]);
      }
    }

    if (out.length < 200) {
      throw Exception('Need at least 200 valid points, found ${out.length}');
    }

    return out;
  }

  Future<void> _health() async {
    await _run('Health', () async {
      final result = await _request(http.get(_uri('/health')), shortTimeout);
      await _setOutput({'endpoint': '/health', 'response': result});
    });
  }

  Future<void> _sendSynthetic() async {
    await _run('Synthetic scan', () async {
      final points = _syntheticPoints();
      final result = await _request(
        http.post(
          _uri('/process_scan'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({'points': points}),
        ),
        longTimeout,
      );
      _updatePipeCardsFromResponse(result);
      await _setOutput({'endpoint': '/process_scan', 'points_sent': points.length, 'response': result});
    });
  }

  Future<void> _saveSynthetic() async {
    await _run('Save synthetic', () async {
      final points = _syntheticPoints();
      final result = await _request(
        http.post(
          _uri('/save_scan'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({'points': points, 'tag': 'flutter'}),
        ),
        longTimeout,
      );
      await _setOutput({'endpoint': '/save_scan', 'response': result});
    });
  }

  Future<void> _replayLatest() async {
    await _run('Replay latest', () async {
      final list = await _request(http.get(_uri('/list_scans')), shortTimeout);
      final scans = list['scans'];
      if (scans is! List || scans.isEmpty) throw Exception('No scans from /list_scans');

      final latest = scans.first;
      final filePath = (latest is Map<String, dynamic>) ? latest['file_path'] : null;
      if (filePath == null) throw Exception('Latest scan missing file_path');

      final result = await _request(
        http.post(
          _uri('/process_scan_file'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({'file_path': filePath}),
        ),
        longTimeout,
      );
      _updatePipeCardsFromResponse(result);
      await _setOutput({'endpoint': '/process_scan_file', 'file_path': filePath, 'response': result});
    });
  }

  Future<void> _loadScanJson() async {
    await _run('Load JSON file', () async {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
      );

      if (picked == null || picked.files.isEmpty) {
        throw Exception('File selection cancelled');
      }

      final file = picked.files.first;
      final name = file.name;
      String content;

      if (file.bytes != null) {
        content = utf8.decode(file.bytes!);
      } else if (file.path != null) {
        content = await File(file.path!).readAsString();
      } else {
        throw Exception('Cannot read selected file');
      }

      final decoded = json.decode(content);
      final pts = _extractPoints(decoded);

      if (!mounted) return;
      setState(() {
        _loadedPoints = pts;
        _loadedFileName = name;
      });

      await _setOutput({'action': 'load_scan_json', 'file': name, 'valid_points': pts.length});
    });
  }

  Future<void> _processLoadedScan() async {
    await _run('Process loaded scan', () async {
      final pts = _loadedPoints;
      if (pts == null || pts.isEmpty) {
        throw Exception('No loaded scan. Tap "Load Scan JSON" first.');
      }

      final result = await _request(
        http.post(
          _uri('/process_scan'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({'points': pts}),
        ),
        longTimeout,
      );
      _updatePipeCardsFromResponse(result);
      await _setOutput({
        'endpoint': '/process_scan',
        'source': _loadedFileName ?? 'loaded_json',
        'points_sent': pts.length,
        'response': result,
      });
    });
  }

  Future<void> _smokeTest() async {
    await _run('Smoke test', () async {
      final health = await _request(http.get(_uri('/health')), shortTimeout);
      if (health['ok'] != true) throw Exception('Health check did not return ok=true');

      final points = _syntheticPoints(pipePoints: 5000, noisePoints: 300);
      final save = await _request(
        http.post(
          _uri('/save_scan'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({'points': points, 'tag': 'smoke_flutter'}),
        ),
        longTimeout,
      );

      final filePath = save['file_path'];
      if (filePath == null || filePath.toString().isEmpty) {
        throw Exception('save_scan did not return file_path');
      }

      final replay = await _request(
        http.post(
          _uri('/process_scan_file'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({'file_path': filePath}),
        ),
        longTimeout,
      );

      final pipeCount = (replay['pipe_count'] as num?)?.toInt() ?? 0;
      if (pipeCount < 1) throw Exception('Smoke test failed: pipe_count=$pipeCount');

      _updatePipeCardsFromResponse(replay);
      await _setOutput({'smoke_test': 'PASS', 'health': health, 'save_scan': save, 'replay': replay});
    });
  }


  Future<void> _exportLatestReport() async {
    await _run('Export report', () async {
      final report = _output.trim();
      if (report.isEmpty || report == 'No output yet.') {
        throw Exception('No report available. Run a scan first.');
      }

      final now = DateTime.now().toIso8601String().replaceAll(':', '-');
      final fileName = 'pipe_report_$now.json';

      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/$fileName');
      await file.writeAsString(report);

      await SharePlus.instance.share(
        ShareParams(
          text: 'Pipe Layout report',
          files: [XFile(file.path)],
        ),
      );
    });
  }

  Widget _button(String title, VoidCallback onPressed, {Color? color}) {
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: ElevatedButton(
          onPressed: _busy ? null : onPressed,
          style: ElevatedButton.styleFrom(
            backgroundColor: color,
            textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          child: Text(title),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _saveUrlDebounce?.cancel();
    _urlController.removeListener(_onUrlChanged);
    _urlController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pipe Layout Scanner')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Backend URL', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              TextField(
                controller: _urlController,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText: 'http://192.168.4.70:8000',
                ),
              ),
              const SizedBox(height: 8),

              _button('Health Check', _health, color: Colors.blue),
              _button('Send Synthetic Scan', _sendSynthetic, color: Colors.green),
              _button('Save Synthetic Scan', _saveSynthetic, color: Colors.orange),
              _button('Replay Latest Scan', _replayLatest, color: Colors.purple),
              _button('Load Scan JSON', _loadScanJson, color: Colors.teal),
              _button('Process Loaded Scan', _processLoadedScan, color: Colors.indigo),
              _button('Run Smoke Test', _smokeTest, color: Colors.redAccent),
              _button('Export Latest Report', _exportLatestReport, color: Colors.brown),

              const SizedBox(height: 6),
              Text('Status: $_status', style: const TextStyle(fontWeight: FontWeight.w600)),
              if (_loadedPoints != null) ...[
                const SizedBox(height: 4),
                Text('Loaded file: ${_loadedFileName ?? '-'} | points: ${_loadedPoints!.length}'),
              ],

              if (_lastProcessingMs != null || _pipeCards.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  'Latest Processing: ${_lastProcessingMs ?? '?'} ms on ${_lastDevice ?? '?'}',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  height: 140,
                  child: _pipeCards.isEmpty
                      ? const Center(child: Text('No pipes detected in latest run.'))
                      : ListView.builder(
                          itemCount: _pipeCards.length,
                          itemBuilder: (context, i) {
                            final p = _pipeCards[i];
                            final l = p['length_m'] as double?;
                            final d = p['diameter_mm'] as double?;
                            final e = p['elongation'] as double?;

                            return Card(
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              child: Padding(
                                padding: const EdgeInsets.all(10),
                                child: Text(
                                  'Pipe ${i + 1}  •  Length: ${l?.toStringAsFixed(2) ?? '?'} m  •  '
                                  'Diameter: ${d?.toStringAsFixed(1) ?? '?'} mm  •  '
                                  'Elongation: ${e?.toStringAsFixed(2) ?? '?'}',
                                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                                ),
                              ),
                            );
                          },
                        ),
                ),
              ],

              const SizedBox(height: 6),
              const Divider(height: 1),
              const SizedBox(height: 6),

              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade400),
                    borderRadius: BorderRadius.circular(8),
                    color: Colors.grey.shade50,
                  ),
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    child: Text(
                      _output.isEmpty ? 'No output yet.' : _output,
                      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
