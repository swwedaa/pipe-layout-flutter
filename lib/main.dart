import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  // Job metadata
  final TextEditingController _jobController = TextEditingController();
  final TextEditingController _operatorController = TextEditingController();
  final TextEditingController _siteController = TextEditingController();

  // Hanger rod length for each rod (ft)
  final TextEditingController _rodLengthController =
      TextEditingController(text: '1.0');

  final ScrollController _outputScrollController = ScrollController();

  SharedPreferences? _prefs;
  Timer? _saveDebounce;

  bool _busy = false;
  String _status = 'Ready';
  String _output = '';

  List<List<double>>? _loadedPoints;
  String? _loadedFileName;

  int? _lastProcessingMs;
  String? _lastDevice;
  List<Map<String, dynamic>> _pipeCards = [];

  static const Duration shortTimeout = Duration(seconds: 15);
  static const Duration longTimeout = Duration(seconds: 60);

  static const double _metersToFeet = 3.28084;
  static const double _oneFootMeters = 0.3048;

  @override
  void initState() {
    super.initState();
    _initPrefs();

    _urlController.addListener(_onAnyInputChanged);
    _jobController.addListener(_onAnyInputChanged);
    _operatorController.addListener(_onAnyInputChanged);
    _siteController.addListener(_onAnyInputChanged);
    _rodLengthController.addListener(_onAnyInputChanged);
  }

  Future<void> _initPrefs() async {
    _prefs = await SharedPreferences.getInstance();

    final url = _prefs?.getString('backend_url');
    final job = _prefs?.getString('job_name');
    final operatorName = _prefs?.getString('operator_name');
    final site = _prefs?.getString('site_address');
    final rodLength = _prefs?.getString('rod_length_ft_each');

    if (!mounted) return;

    setState(() {
      if (url != null && url.trim().isNotEmpty) _urlController.text = url.trim();
      if (job != null) _jobController.text = job;
      if (operatorName != null) _operatorController.text = operatorName;
      if (site != null) _siteController.text = site;
      if (rodLength != null && rodLength.trim().isNotEmpty) {
        _rodLengthController.text = rodLength.trim();
      }
    });
  }

  void _onAnyInputChanged() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 400), () async {
      await _prefs?.setString('backend_url', _urlController.text.trim());
      await _prefs?.setString('job_name', _jobController.text.trim());
      await _prefs?.setString('operator_name', _operatorController.text.trim());
      await _prefs?.setString('site_address', _siteController.text.trim());
      await _prefs?.setString('rod_length_ft_each', _rodLengthController.text.trim());
    });
  }

  Uri _uri(String path) {
    final base = _urlController.text.trim().replaceAll(RegExp(r'/$'), '');
    return Uri.parse('$base$path');
  }

  double _currentRodLengthFt() {
    final v = double.tryParse(_rodLengthController.text.trim());
    if (v == null || v <= 0) return 1.0;
    return v;
  }

  double? _toDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  int? _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  Map<String, dynamic> _metaPayload() {
    final meta = <String, dynamic>{};

    final job = _jobController.text.trim();
    final op = _operatorController.text.trim();
    final site = _siteController.text.trim();
    final rodEachFt = _currentRodLengthFt();

    if (job.isNotEmpty) meta['job_name'] = job;
    if (op.isNotEmpty) meta['operator'] = op;
    if (site.isNotEmpty) meta['site_address'] = site;

    meta['rod_length_ft_each'] = rodEachFt;
    meta['rod_rule'] = '2 rods per pipe; if pipe length < 1 ft then 1 rod';

    return meta;
  }

  /// App-side enrichment:
  /// - if pipe < 1ft => 1 rod
  /// - else => 2 rods
  Map<String, dynamic> _enrichWithRodMetadata(Map<String, dynamic> response) {
    final out = Map<String, dynamic>.from(response);
    final rodEachFt = _currentRodLengthFt();

    final rawPipes = out['pipes'];
    if (rawPipes is List) {
      final enriched = <Map<String, dynamic>>[];

      for (final item in rawPipes) {
        if (item is! Map) continue;
        final p = Map<String, dynamic>.from(item as Map);

        final lengthM = _toDouble(
          p['length_meters'] ?? p['length_m'] ?? p['length'],
        );
        final lengthFt = lengthM != null ? lengthM * _metersToFeet : null;

        int rodCount = 2;
        if (lengthM != null && lengthM < _oneFootMeters) rodCount = 1;

        final rodLengthsFt = List<double>.filled(rodCount, rodEachFt);
        final rodTotalFt = rodCount * rodEachFt;

        p['pipe_length_ft'] = lengthFt;
        p['recommended_hanger_rod_count'] = rodCount;
        p['recommended_hanger_rod_lengths_ft'] = rodLengthsFt;
        p['recommended_hanger_rod_total_ft'] = rodTotalFt;
        p['rod_rule_applied'] = 'if length < 1ft => 1 rod else 2 rods';

        enriched.add(p);
      }

      out['pipes'] = enriched;
    }

    final mergedMeta = <String, dynamic>{};
    if (out['meta'] is Map) {
      mergedMeta.addAll(Map<String, dynamic>.from(out['meta'] as Map));
    }
    mergedMeta.addAll(_metaPayload());
    out['meta'] = mergedMeta;
    out['job_metadata'] = mergedMeta;

    return out;
  }

  void _updatePipeCardsFromResponse(Map<String, dynamic> response) {
    final raw = response['pipes'];
    final cards = <Map<String, dynamic>>[];
    final rodEachFt = _currentRodLengthFt();

    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        final p = Map<String, dynamic>.from(item as Map);

        final lengthM = _toDouble(p['length_meters'] ?? p['length']);
        final diameterM = _toDouble(p['diameter_meters'] ?? p['diameter']);
        final elong = _toDouble(p['elongation']);
        final confidence = _toDouble(p['confidence']);

        int rodCount = _toInt(p['recommended_hanger_rod_count']) ??
            ((lengthM != null && lengthM < _oneFootMeters) ? 1 : 2);

        final rodTotalFt = _toDouble(p['recommended_hanger_rod_total_ft']) ??
            (rodCount * rodEachFt);

        cards.add({
          'length_m': lengthM,
          'diameter_mm': diameterM != null ? diameterM * 1000.0 : null,
          'elongation': elong,
          'confidence': confidence,
          'rod_count': rodCount,
          'rod_total_ft': rodTotalFt,
        });
      }
    }

    if (!mounted) return;
    setState(() {
      _lastProcessingMs = _toInt(response['processing_ms']);
      _lastDevice = response['device']?.toString();
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
    if (_outputScrollController.hasClients) {
      _outputScrollController.animateTo(
        _outputScrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  Future<Map<String, dynamic>> _request(
    Future<http.Response> request,
    Duration timeout,
  ) async {
    final resp = await request.timeout(timeout);
    final body = resp.body.isEmpty ? '{}' : resp.body;

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('HTTP ${resp.statusCode}: $body');
    }

    final decoded = json.decode(body);
    if (decoded is Map<String, dynamic>) return decoded;
    return {'data': decoded};
  }

  Future<void> _run(String label, Future<void> Function() action) async {
    if (_busy) return;

    setState(() {
      _busy = true;
      _status = '$label...';
    });

    try {
      await action();
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

  List<List<double>> _syntheticPoints({
    int pipePoints = 8000,
    int noisePoints = 500,
  }) {
    final rnd = Random();
    final points = <List<double>>[];

    for (int i = 0; i < pipePoints; i++) {
      final x = -2.0 + rnd.nextDouble() * 4.0;
      final theta = rnd.nextDouble() * 2 * pi;
      final r = 0.02 + (rnd.nextDouble() * 0.004 - 0.002);
      final y = r * cos(theta) + (rnd.nextDouble() * 0.004 - 0.002);
      final z = r * sin(theta) + (rnd.nextDouble() * 0.004 - 0.002);
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

  List<List<double>> _extractPoints(dynamic decoded) {
    final dynamic raw = (decoded is Map<String, dynamic>) ? decoded['points'] : decoded;

    if (raw is! List) {
      throw Exception('JSON must be a list or {"points":[...]}');
    }

    final result = <List<double>>[];
    for (final p in raw) {
      if (p is List && p.length == 3) {
        final x = (p[0] as num?)?.toDouble();
        final y = (p[1] as num?)?.toDouble();
        final z = (p[2] as num?)?.toDouble();
        if (x != null && y != null && z != null) result.add([x, y, z]);
      }
    }

    if (result.length < 200) {
      throw Exception('Need at least 200 valid points, found ${result.length}');
    }

    return result;
  }

  Future<void> _healthCheck() async {
    await _run('Health check', () async {
      final result = await _request(http.get(_uri('/health')), shortTimeout);
      await _setOutput({'endpoint': '/health', 'response': result});
    });
  }

  Future<void> _sendSyntheticScan() async {
    await _run('Process synthetic scan', () async {
      final points = _syntheticPoints();
      final result = await _request(
        http.post(
          _uri('/process_scan'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'points': points,
            'meta': _metaPayload(),
          }),
        ),
        longTimeout,
      );

      final enriched = _enrichWithRodMetadata(result);
      _updatePipeCardsFromResponse(enriched);

      await _setOutput({
        'endpoint': '/process_scan',
        'points_sent': points.length,
        'meta': _metaPayload(),
        'response': enriched,
      });
    });
  }

  Future<void> _saveSyntheticScan() async {
    await _run('Save synthetic scan', () async {
      final points = _syntheticPoints();
      final result = await _request(
        http.post(
          _uri('/save_scan'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'points': points,
            'tag': 'flutter',
            'meta': _metaPayload(),
          }),
        ),
        longTimeout,
      );

      await _setOutput({
        'endpoint': '/save_scan',
        'meta': _metaPayload(),
        'response': result,
      });
    });
  }

  Future<void> _replayLatestScan() async {
    await _run('Replay latest scan', () async {
      final listResult = await _request(http.get(_uri('/list_scans')), shortTimeout);
      final scans = listResult['scans'];

      if (scans is! List || scans.isEmpty) {
        throw Exception('No scans available from /list_scans');
      }

      final latest = scans.first;
      if (latest is! Map || latest['file_path'] == null) {
        throw Exception('Latest scan missing file_path');
      }

      final filePath = latest['file_path'].toString();

      final result = await _request(
        http.post(
          _uri('/process_scan_file'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({'file_path': filePath}),
        ),
        longTimeout,
      );

      final enriched = _enrichWithRodMetadata(result);
      _updatePipeCardsFromResponse(enriched);

      await _setOutput({
        'endpoint': '/process_scan_file',
        'file_path': filePath,
        'response': enriched,
      });
    });
  }

  Future<void> _loadScanJson() async {
    await _run('Load JSON scan', () async {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
      );

      if (picked == null || picked.files.isEmpty) {
        throw Exception('File selection cancelled');
      }

      final file = picked.files.first;
      final fileName = file.name;

      String content;
      if (file.bytes != null) {
        content = utf8.decode(file.bytes!);
      } else if (file.path != null) {
        content = await File(file.path!).readAsString();
      } else {
        throw Exception('Unable to read selected file');
      }

      final decoded = json.decode(content);
      final points = _extractPoints(decoded);

      if (!mounted) return;
      setState(() {
        _loadedPoints = points;
        _loadedFileName = fileName;
      });

      await _setOutput({
        'action': 'load_scan_json',
        'file': fileName,
        'valid_points': points.length,
      });
    });
  }

  Future<void> _processLoadedScan() async {
    await _run('Process loaded scan', () async {
      final points = _loadedPoints;
      if (points == null || points.isEmpty) {
        throw Exception('No loaded file. Tap "Load Scan JSON" first.');
      }

      final result = await _request(
        http.post(
          _uri('/process_scan'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'points': points,
            'meta': _metaPayload(),
          }),
        ),
        longTimeout,
      );

      final enriched = _enrichWithRodMetadata(result);
      _updatePipeCardsFromResponse(enriched);

      await _setOutput({
        'endpoint': '/process_scan',
        'source_file': _loadedFileName ?? 'loaded.json',
        'points_sent': points.length,
        'meta': _metaPayload(),
        'response': enriched,
      });
    });
  }

  Future<void> _runSmokeTest() async {
    await _run('Smoke test', () async {
      final health = await _request(http.get(_uri('/health')), shortTimeout);
      if (health['ok'] != true) throw Exception('Health check failed');

      final points = _syntheticPoints(pipePoints: 5000, noisePoints: 300);
      final save = await _request(
        http.post(
          _uri('/save_scan'),
          headers: {'Content-Type': 'application/json'},
          body: json.encode({
            'points': points,
            'tag': 'smoke_flutter',
            'meta': _metaPayload(),
          }),
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

      final enriched = _enrichWithRodMetadata(replay);
      _updatePipeCardsFromResponse(enriched);

      await _setOutput({
        'smoke_test': 'PASS',
        'meta': _metaPayload(),
        'health': health,
        'save_scan': save,
        'replay': enriched,
      });
    });
  }

  Future<void> _exportLatestReport() async {
    await _run('Export report', () async {
      final reportText = _output.trim();
      if (reportText.isEmpty || reportText == 'No output yet.') {
        throw Exception('No report available. Run a scan first.');
      }

      final now = DateTime.now().toIso8601String().replaceAll(':', '-');
      final fileName = 'pipe_report_$now.json';
      final tempDir = await getTemporaryDirectory();

      final file = File('${tempDir.path}/$fileName');
      await file.writeAsString(reportText);

      await SharePlus.instance.share(
        ShareParams(
          text: 'Pipe Layout report',
          files: [XFile(file.path)],
        ),
      );
    });
  }

  String _csvEscape(dynamic value) {
    if (value == null) return '';
    final raw = value.toString().replaceAll('"', '""');
    final needsQuotes = raw.contains(',') || raw.contains('\n') || raw.contains('"');
    return needsQuotes ? '"$raw"' : raw;
  }

  Future<void> _exportCsvReport() async {
    await _run('Export CSV report', () async {
      if (_pipeCards.isEmpty) {
        throw Exception('No pipe data to export. Run a scan first.');
      }

      final meta = _metaPayload();
      final timestamp = DateTime.now().toIso8601String();

      final sb = StringBuffer();
      sb.writeln(
        'timestamp,job_name,operator,site_address,pipe_index,length_m,length_ft,diameter_mm,elongation,confidence,rod_count,rod_total_ft,processing_ms,device',
      );

      for (var i = 0; i < _pipeCards.length; i++) {
        final p = _pipeCards[i];
        final lengthM = _toDouble(p['length_m']);
        final lengthFt = lengthM != null ? lengthM * _metersToFeet : null;
        final diameterMm = _toDouble(p['diameter_mm']);
        final elong = _toDouble(p['elongation']);
        final conf = _toDouble(p['confidence']);
        final rodCount = _toInt(p['rod_count']);
        final rodTotalFt = _toDouble(p['rod_total_ft']);

        final row = [
          timestamp,
          meta['job_name'] ?? '',
          meta['operator'] ?? '',
          meta['site_address'] ?? '',
          i + 1,
          lengthM?.toStringAsFixed(4) ?? '',
          lengthFt?.toStringAsFixed(3) ?? '',
          diameterMm?.toStringAsFixed(2) ?? '',
          elong?.toStringAsFixed(3) ?? '',
          conf?.toStringAsFixed(3) ?? '',
          rodCount ?? '',
          rodTotalFt?.toStringAsFixed(3) ?? '',
          _lastProcessingMs ?? '',
          _lastDevice ?? '',
        ];

        sb.writeln(row.map(_csvEscape).join(','));
      }

      final fileName =
          'pipe_report_${DateTime.now().toIso8601String().replaceAll(':', '-')}.csv';
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$fileName');
      await file.writeAsString(sb.toString());

      await SharePlus.instance.share(
        ShareParams(
          text: 'Pipe Layout CSV report',
          files: [XFile(file.path)],
        ),
      );
    });
  }

  Widget _actionButton(String title, VoidCallback onTap, {Color? color}) {
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: ElevatedButton(
          onPressed: _busy ? null : onTap,
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
    _saveDebounce?.cancel();

    _urlController.removeListener(_onAnyInputChanged);
    _jobController.removeListener(_onAnyInputChanged);
    _operatorController.removeListener(_onAnyInputChanged);
    _siteController.removeListener(_onAnyInputChanged);
    _rodLengthController.removeListener(_onAnyInputChanged);

    _urlController.dispose();
    _jobController.dispose();
    _operatorController.dispose();
    _siteController.dispose();
    _rodLengthController.dispose();
    _outputScrollController.dispose();

    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final processingLine = (_lastProcessingMs != null || _lastDevice != null)
        ? 'Latest processing: ${_lastProcessingMs ?? '?'} ms on ${_lastDevice ?? '?'}'
        : null;

    return Scaffold(
      appBar: AppBar(title: const Text('Pipe Layout Scanner')),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight - 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Backend URL',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _urlController,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText: 'http://192.168.4.70:8000',
                      ),
                    ),

                    const SizedBox(height: 8),
                    TextField(
                      controller: _jobController,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        labelText: 'Job Name',
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _operatorController,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        labelText: 'Operator',
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _siteController,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        labelText: 'Site Address',
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _rodLengthController,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        labelText: 'Rod Length Each (ft)',
                        hintText: '1.0',
                      ),
                    ),

                    const SizedBox(height: 8),
                    _actionButton('Health Check', _healthCheck, color: Colors.blue),
                    _actionButton('Send Synthetic Scan', _sendSyntheticScan, color: Colors.green),
                    _actionButton('Save Synthetic Scan', _saveSyntheticScan, color: Colors.orange),
                    _actionButton('Replay Latest Scan', _replayLatestScan, color: Colors.purple),
                    _actionButton('Load Scan JSON', _loadScanJson, color: Colors.teal),
                    _actionButton('Process Loaded Scan', _processLoadedScan, color: Colors.indigo),
                    _actionButton('Run Smoke Test', _runSmokeTest, color: Colors.redAccent),
                    _actionButton('Export Latest Report', _exportLatestReport, color: Colors.brown),
                    _actionButton('Export CSV Report', _exportCsvReport, color: Colors.deepOrange),

                    const SizedBox(height: 8),
                    Text('Status: $_status', style: const TextStyle(fontWeight: FontWeight.w600)),
                    if (_loadedPoints != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'Loaded file: ${_loadedFileName ?? '-'} | points: ${_loadedPoints!.length}',
                        ),
                      ),

                    if (processingLine != null) ...[
                      const SizedBox(height: 8),
                      Text(processingLine, style: const TextStyle(fontWeight: FontWeight.w700)),
                    ],

                    if (_pipeCards.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      const Text(
                        'Detected Pipes',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      SizedBox(
                        height: 180,
                        child: ListView.builder(
                          itemCount: _pipeCards.length,
                          itemBuilder: (context, index) {
                            final p = _pipeCards[index];
                            final length = p['length_m'] as double?;
                            final diameter = p['diameter_mm'] as double?;
                            final elong = p['elongation'] as double?;
                            final conf = p['confidence'] as double?;
                            final rodCount = p['rod_count'] as int?;
                            final rodTotal = p['rod_total_ft'] as double?;

                            return Card(
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              child: Padding(
                                padding: const EdgeInsets.all(10),
                                child: Text(
                                  'Pipe ${index + 1}  •  '
                                  'Length: ${length?.toStringAsFixed(2) ?? '?'} m  •  '
                                  'Diameter: ${diameter?.toStringAsFixed(1) ?? '?'} mm  •  '
                                  'Elong: ${elong?.toStringAsFixed(2) ?? '?'}  •  '
                                  'Conf: ${conf?.toStringAsFixed(2) ?? '?'}  •  '
                                  'Rods: ${rodCount ?? '?'}  •  '
                                  'Rod Total: ${rodTotal?.toStringAsFixed(2) ?? '?'} ft',
                                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],

                    const SizedBox(height: 10),
                    const Divider(height: 1),
                    const SizedBox(height: 8),

                    SizedBox(
                      height: 260,
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey.shade400),
                          borderRadius: BorderRadius.circular(8),
                          color: Colors.grey.shade50,
                        ),
                        child: SingleChildScrollView(
                          controller: _outputScrollController,
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
            );
          },
        ),
      ),
    );
  }
}
