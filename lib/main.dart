import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:model_viewer_plus/model_viewer_plus.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

const double _metersToFeetDisplay = 3.28084;

double? parseMeasurementDouble(dynamic value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

int? parseMeasurementInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

/// Text for a pipe row in "Detected Pipes" lists. When [includeLengthFt] is true,
/// length includes both meters and feet (for GLB overlay); home list uses meters only.
String _formatPipeCardLine(
  Map<String, dynamic> p,
  int index, {
  bool includeLengthFt = false,
}) {
  final length = parseMeasurementDouble(p['length_m']);
  final lengthFt = length != null ? length * _metersToFeetDisplay : null;
  final diameter = parseMeasurementDouble(p['diameter_mm']);
  final elong = parseMeasurementDouble(p['elongation']);
  final conf = parseMeasurementDouble(p['confidence']);
  final rodCount = parseMeasurementInt(p['rod_count']);
  final rodTotal = parseMeasurementDouble(p['rod_total_ft']);

  final lengthSeg = includeLengthFt
      ? 'Length: ${length?.toStringAsFixed(2) ?? '?'} m / ${lengthFt?.toStringAsFixed(3) ?? '?'} ft'
      : 'Length: ${length?.toStringAsFixed(2) ?? '?'} m';

  return 'Pipe ${index + 1}  •  '
      '$lengthSeg  •  '
      'Diameter: ${diameter?.toStringAsFixed(1) ?? '?'} mm  •  '
      'Elong: ${elong?.toStringAsFixed(2) ?? '?'}  •  '
      'Conf: ${conf?.toStringAsFixed(2) ?? '?'}  •  '
      'Rods: ${rodCount ?? '?'}  •  '
      'Rod Total: ${rodTotal?.toStringAsFixed(2) ?? '?'} ft';
}

/// Normalizes a path string from [FilePicker] before using [File].
/// - `file:` URIs → [Uri.toFilePath] (never use the raw encoded URL as a path).
/// - Paths containing `%` → [Uri.decodeComponent] (encoded segments from some providers).
String? _resolvePickerPathToFilesystem(String? raw) {
  if (raw == null) return null;
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.startsWith('file:')) {
    try {
      return Uri.parse(trimmed).toFilePath();
    } catch (_) {
      return null;
    }
  }
  if (trimmed.contains('%')) {
    try {
      return Uri.decodeComponent(trimmed);
    } catch (_) {
      return trimmed;
    }
  }
  return trimmed;
}

bool _platformFileLooksLikeGlb(PlatformFile file) {
  if (file.name.toLowerCase().endsWith('.glb')) return true;
  final pathStr = file.path;
  return pathStr != null &&
      pathStr.isNotEmpty &&
      pathStr.toLowerCase().endsWith('.glb');
}

String _friendlyHttpFailure(String endpoint, int statusCode, String body) {
  final t = body.trim();
  final short = t.length > 480 ? '${t.substring(0, 480)}…' : t;
  return '$endpoint failed (HTTP $statusCode): $short';
}

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
  final TextEditingController _urlController = TextEditingController(
    text: 'http://192.168.4.70:8000',
  );

  // Job metadata
  final TextEditingController _jobController = TextEditingController();
  final TextEditingController _operatorController = TextEditingController();
  final TextEditingController _siteController = TextEditingController();

  // Hanger rod length for each rod (ft)
  final TextEditingController _rodLengthController = TextEditingController(
    text: '1.0',
  );

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

  /// Last successful scan kind: point_json, synthetic, glb_mesh, replay_file, smoke, or null.
  String? _lastRunSource;

  /// Snapshot of scan-level fields from the last successful pipe-processing response (for exports).
  Map<String, dynamic>? _lastApiEnvelope;

  /// Shown below status when the last scan returned no pipes.
  String? _zeroPipesHint;

  /// Recent successful jobs (newest first); persisted under [job_history_v1].
  List<Map<String, dynamic>> _jobHistory = [];

  static const Duration shortTimeout = Duration(seconds: 15);
  static const Duration longTimeout = Duration(seconds: 60);

  static const double _oneFootMeters = 0.3048;

  static const String _zeroPipesUserHint =
      'No pipes detected. For GLB try another model or adjust PC thresholds; for JSON ensure enough points.';

  static const String _glbSourceCaption =
      'Source: MetaRoom GLB (mesh sample) — from mesh geometry, not raw LiDAR.';

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
      if (url != null && url.trim().isNotEmpty) {
        _urlController.text = url.trim();
      }
      if (job != null) _jobController.text = job;
      if (operatorName != null) _operatorController.text = operatorName;
      if (site != null) _siteController.text = site;
      if (rodLength != null && rodLength.trim().isNotEmpty) {
        _rodLengthController.text = rodLength.trim();
      }
      final hist = _prefs?.getString('job_history_v1');
      if (hist != null && hist.isNotEmpty) {
        try {
          final decoded = json.decode(hist);
          if (decoded is List) {
            _jobHistory = decoded.map((e) {
              if (e is! Map) return <String, dynamic>{};
              final m = Map<String, dynamic>.from(e);
              return <String, dynamic>{
                'ts': m['ts']?.toString() ?? '',
                'job_name': m['job_name']?.toString() ?? '',
                'operator': m['operator']?.toString() ?? '',
                'source': m['source']?.toString() ?? '',
                'pipe_count': m['pipe_count'],
                if (m['sampled_points'] != null)
                  'sampled_points': m['sampled_points'],
                if (m['glb_name'] != null) 'glb_name': m['glb_name'].toString(),
              };
            }).toList();
          }
        } catch (_) {}
      }
    });
  }

  Future<void> _persistHistory() async {
    await _prefs?.setString('job_history_v1', json.encode(_jobHistory));
  }

  Future<void> _clearJobHistory() async {
    if (!mounted) return;
    setState(() => _jobHistory = []);
    await _prefs?.remove('job_history_v1');
  }

  int _pipeCountFromResponse(Map<String, dynamic> response, int cardsLength) {
    final pc = parseMeasurementInt(response['pipe_count']);
    if (pc != null) return pc;
    return cardsLength;
  }

  Map<String, dynamic> _buildJobHistoryEntry(
    Map<String, dynamic> response,
    String source, {
    String? glbFileName,
  }) {
    final meta = _metaPayload();
    final sampled =
        parseMeasurementInt(response['sampled_points']) ??
        parseMeasurementInt(response['points_sampled']) ??
        parseMeasurementInt(response['sent_points']);
    final rawPipes = response['pipes'];
    final listLen = rawPipes is List ? rawPipes.length : 0;
    final entry = <String, dynamic>{
      'ts': DateTime.now().toIso8601String(),
      'job_name': meta['job_name'] ?? '',
      'operator': meta['operator'] ?? '',
      'source': source,
      'pipe_count': _pipeCountFromResponse(response, listLen),
    };
    if (sampled != null) entry['sampled_points'] = sampled;
    if (glbFileName != null && glbFileName.isNotEmpty) {
      entry['glb_name'] = glbFileName;
    }
    return entry;
  }

  /// Records scan-level API fields for JSON/CSV export. Call inside [setState] only.
  void _rememberLastScan(
    Map<String, dynamic> enriched, {
    required String runSource,
    String? glbFileName,
  }) {
    final rawPipes = enriched['pipes'];
    final listLen = rawPipes is List ? rawPipes.length : 0;
    final pc = parseMeasurementInt(enriched['pipe_count']);
    final sampled = parseMeasurementInt(enriched['sampled_points']) ??
        parseMeasurementInt(enriched['points_sampled']) ??
        parseMeasurementInt(enriched['sent_points']);
    _lastApiEnvelope = <String, dynamic>{
      'lastRunSource': runSource,
      'source': runSource,
      'pipe_count': pc ?? listLen,
      if (enriched['processing_ms'] != null) 'processing_ms': enriched['processing_ms'],
      if (enriched['device'] != null) 'device': enriched['device'],
      'sampled_points': ?sampled,
      if (enriched['meta'] != null) 'meta': enriched['meta'],
      if (enriched['job_metadata'] != null) 'job_metadata': enriched['job_metadata'],
      if (glbFileName != null && glbFileName.isNotEmpty) 'glb_file_name': glbFileName,
    };
  }

  /// Prepends a history row (newest first). Optional keys only; safe for old prefs data.
  /// Call inside [setState]; then call [_persistHistory].
  void _addHistoryEntry(
    Map<String, dynamic> response,
    String source, {
    String? glbFileName,
  }) {
    final entry = _buildJobHistoryEntry(
      response,
      source,
      glbFileName: glbFileName,
    );
    _jobHistory = [entry, ..._jobHistory];
    if (_jobHistory.length > 40) {
      _jobHistory = _jobHistory.sublist(0, 40);
    }
  }

  void _onAnyInputChanged() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 400), () async {
      await _prefs?.setString('backend_url', _urlController.text.trim());
      await _prefs?.setString('job_name', _jobController.text.trim());
      await _prefs?.setString('operator_name', _operatorController.text.trim());
      await _prefs?.setString('site_address', _siteController.text.trim());
      await _prefs?.setString(
        'rod_length_ft_each',
        _rodLengthController.text.trim(),
      );
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
        final p = Map<String, dynamic>.from(item);

        final lengthM = parseMeasurementDouble(
          p['length_meters'] ?? p['length_m'] ?? p['length'],
        );
        final lengthFt = lengthM != null
            ? lengthM * _metersToFeetDisplay
            : null;

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

  void _updatePipeCardsFromResponse(
    Map<String, dynamic> response, {
    String? runSource,
    String? glbFileName,
  }) {
    final raw = response['pipes'];
    final cards = <Map<String, dynamic>>[];
    final rodEachFt = _currentRodLengthFt();

    if (raw is List) {
      for (final item in raw) {
        if (item is! Map) continue;
        final p = Map<String, dynamic>.from(item);

        final lengthM = parseMeasurementDouble(
          p['length_meters'] ?? p['length'],
        );
        final diameterM = parseMeasurementDouble(
          p['diameter_meters'] ?? p['diameter'],
        );
        final elong = parseMeasurementDouble(p['elongation']);
        final confidence = parseMeasurementDouble(p['confidence']);

        int rodCount =
            parseMeasurementInt(p['recommended_hanger_rod_count']) ??
            ((lengthM != null && lengthM < _oneFootMeters) ? 1 : 2);

        final rodTotalFt =
            parseMeasurementDouble(p['recommended_hanger_rod_total_ft']) ??
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

    final pipeCountField = parseMeasurementInt(response['pipe_count']);
    final zeroPipes =
        cards.isEmpty || (pipeCountField != null && pipeCountField == 0);

    if (!mounted) return;
    setState(() {
      _lastProcessingMs = parseMeasurementInt(response['processing_ms']);
      _lastDevice = response['device']?.toString();
      _pipeCards = cards;
      if (runSource != null) {
        _lastRunSource = runSource;
        _rememberLastScan(
          response,
          runSource: runSource,
          glbFileName: glbFileName,
        );
        _addHistoryEntry(response, runSource, glbFileName: glbFileName);
      }
      _zeroPipesHint = zeroPipes ? _zeroPipesUserHint : null;
    });

    if (runSource != null) {
      _persistHistory();
    }

    if (zeroPipes && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(_zeroPipesUserHint),
            duration: const Duration(seconds: 6),
          ),
        );
      });
    }
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
    final dynamic raw = (decoded is Map<String, dynamic>)
        ? decoded['points']
        : decoded;

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
          body: json.encode({'points': points, 'meta': _metaPayload()}),
        ),
        longTimeout,
      );

      final enriched = _enrichWithRodMetadata(result);
      _updatePipeCardsFromResponse(enriched, runSource: 'synthetic');

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
      final listResult = await _request(
        http.get(_uri('/list_scans')),
        shortTimeout,
      );
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
      _updatePipeCardsFromResponse(enriched, runSource: 'replay_file');

      await _setOutput({
        'endpoint': '/process_scan_file',
        'file_path': filePath,
        'response': enriched,
      });
    });
  }

  /// Picks a .glb via [FilePicker], copies to temp as [asciiDestName] (safe ASCII path).
  Future<String> _copyPickedGlbToAsciiTemp(
    PlatformFile file, {
    String asciiDestName = 'metaroom_glb_preview.glb',
  }) async {
    final tempDir = await getTemporaryDirectory();
    final destPath = '${tempDir.path}/$asciiDestName';

    var glbBytes = file.bytes;
    if (glbBytes == null || glbBytes.isEmpty) {
      final srcPath = _resolvePickerPathToFilesystem(file.path);
      if (srcPath == null || srcPath.isEmpty) {
        throw Exception('Could not open GLB file.');
      }
      final srcFile = File(srcPath);
      if (!await srcFile.exists()) {
        throw Exception('Could not open GLB file.');
      }
      glbBytes = await srcFile.readAsBytes();
    }

    await File(destPath).writeAsBytes(glbBytes, flush: true);
    return destPath;
  }

  Future<void> _previewGlbMetaroom() async {
    if (_busy) return;

    final picked = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
      withData: false,
    );

    if (!mounted) return;
    if (picked == null || picked.files.isEmpty) return;

    final file = picked.files.first;
    if (!_platformFileLooksLikeGlb(file)) {
      if (mounted) setState(() => _status = 'Please choose a .glb file');
      return;
    }

    try {
      final destPath = await _copyPickedGlbToAsciiTemp(file);

      if (!mounted) return;
      final pipeSnapshot = _pipeCards.isEmpty
          ? null
          : List<Map<String, dynamic>>.from(
              _pipeCards.map((m) => Map<String, dynamic>.from(m)),
            );
      final metaSnapshot = Map<String, dynamic>.from(_metaPayload());
      final glbLabel = file.name.trim().isEmpty ? null : file.name.trim();
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (context) => GlbViewerPage(
            glbSrc: destPath,
            glbFileLabel: glbLabel,
            pipeCards: pipeSnapshot,
            jobMeta: metaSnapshot,
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> _sendGlbToPc() async {
    await _run('Send GLB to PC', () async {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
        withData: false,
      );

      if (picked == null || picked.files.isEmpty) {
        throw Exception('File selection cancelled');
      }

      final file = picked.files.first;
      if (!_platformFileLooksLikeGlb(file)) {
        throw Exception('Please choose a .glb file');
      }

      final destPath = await _copyPickedGlbToAsciiTemp(file);

      final req = http.MultipartRequest('POST', _uri('/process_glb'));
      req.files.add(
        await http.MultipartFile.fromPath(
          'file',
          destPath,
          filename: 'metaroom_glb_preview.glb',
        ),
      );
      req.fields['meta'] = json.encode(_metaPayload());
      req.fields['max_points'] = '50000';

      final streamed = await req.send();
      final response = await http.Response.fromStream(
        streamed,
      ).timeout(const Duration(seconds: 180));

      final body = response.body.isEmpty ? '{}' : response.body;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(
          _friendlyHttpFailure('/process_glb', response.statusCode, body),
        );
      }

      final decoded = json.decode(body);
      final result = decoded is Map<String, dynamic>
          ? decoded
          : {'data': decoded};

      final enriched = _enrichWithRodMetadata(result);
      final glbLabel = file.name.trim();
      _updatePipeCardsFromResponse(
        enriched,
        runSource: 'glb_mesh',
        glbFileName: glbLabel.isEmpty ? null : glbLabel,
      );

      await _setOutput({
        'endpoint': '/process_glb',
        'file': 'metaroom_glb_preview.glb',
        'meta': _metaPayload(),
        'max_points': 50000,
        'response': enriched,
      });
    });
  }

  Future<void> _loadScanJson() async {
    await _run('Load JSON scan', () async {
      // FileType.any avoids iOS Files greying out JSON like it does for .glb + custom types.
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.any,
        allowMultiple: false,
        withData: true,
      );

      if (picked == null || picked.files.isEmpty) {
        throw Exception('File selection cancelled');
      }

      final file = picked.files.first;
      final nameOk = file.name.toLowerCase().endsWith('.json');
      final pathStr = file.path;
      final pathOk = pathStr != null &&
          pathStr.isNotEmpty &&
          pathStr.toLowerCase().endsWith('.json');
      if (!nameOk && !pathOk) {
        throw Exception('Please choose a .json file');
      }

      final fileName = file.name;

      String content;
      if (file.bytes != null && file.bytes!.isNotEmpty) {
        content = utf8.decode(file.bytes!);
      } else {
        final path = _resolvePickerPathToFilesystem(file.path);
        if (path == null || path.isEmpty) {
          throw Exception('Unable to read selected file');
        }
        content = await File(path).readAsString();
      }

      if (content.isNotEmpty && content.codeUnitAt(0) == 0xfeff) {
        content = content.substring(1);
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

  List<List<double>> _preparePointsForUpload(
    List<List<double>> points, {
    int maxPoints = 25000,
  }) {
    if (points.length <= maxPoints) return points;

    final step = (points.length / maxPoints).ceil();
    final reduced = <List<double>>[];
    for (int i = 0; i < points.length; i += step) {
      reduced.add(points[i]);
    }
    return reduced;
  }

  Future<void> _processLoadedScan() async {
    await _run('Process loaded scan', () async {
      final points = _loadedPoints;
      if (points == null || points.isEmpty) {
        throw Exception('No loaded file. Tap "Load Scan JSON" first.');
      }

      if (points.length < 200) {
        throw Exception(
          'Loaded file has too few points (${points.length}). Need at least 200.',
        );
      }

      // Reduce huge files to keep payload reliable on mobile network paths
      final prepared = _preparePointsForUpload(points, maxPoints: 25000);

      final response = await http
          .post(
            _uri('/process_scan'),
            headers: {'Content-Type': 'application/json'},
            body: json.encode({'points': prepared, 'meta': _metaPayload()}),
          )
          .timeout(const Duration(seconds: 120));

      final body = response.body.isEmpty ? '{}' : response.body;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(
          'process_scan failed (HTTP ${response.statusCode}): $body',
        );
      }

      final decoded = json.decode(body);
      final result = decoded is Map<String, dynamic>
          ? decoded
          : {'data': decoded};

      final enriched = _enrichWithRodMetadata(result);
      _updatePipeCardsFromResponse(enriched, runSource: 'point_json');

      await _setOutput({
        'endpoint': '/process_scan',
        'source_file': _loadedFileName ?? 'loaded.json',
        'original_points': points.length,
        'sent_points': prepared.length,
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
      if (pipeCount < 1) {
        throw Exception('Smoke test failed: pipe_count=$pipeCount');
      }

      final enriched = _enrichWithRodMetadata(replay);
      _updatePipeCardsFromResponse(enriched, runSource: 'smoke');

      await _setOutput({
        'smoke_test': 'PASS',
        'meta': _metaPayload(),
        'health': health,
        'save_scan': save,
        'replay': enriched,
      });
    });
  }

  /// Merges on-screen [_output] JSON with [_lastApiEnvelope] so exports include run source, counts, meta.
  Map<String, dynamic> _composeExportReportDocument() {
    final trimmed = _output.trim();
    Map<String, dynamic> base;
    if (trimmed.isEmpty || trimmed == 'No output yet.') {
      base = <String, dynamic>{};
    } else {
      try {
        final d = json.decode(trimmed);
        if (d is Map<String, dynamic>) {
          base = Map<String, dynamic>.from(d);
        } else {
          base = <String, dynamic>{'app_output': d};
        }
      } catch (_) {
        base = <String, dynamic>{'raw_output': trimmed};
      }
    }

    final env = _lastApiEnvelope;
    if (env != null) {
      base['lastRunSource'] = env['lastRunSource'];
      base['source'] = env['source'];
      base['pipe_count'] = env['pipe_count'];
      if (env['sampled_points'] != null) {
        base['sampled_points'] = env['sampled_points'];
      }
      if (env['processing_ms'] != null) {
        base['processing_ms'] = env['processing_ms'];
      }
      if (env['device'] != null) {
        base['device'] = env['device'];
      }
      if (env['meta'] != null) {
        base['meta'] = env['meta'];
      }
      if (env['job_metadata'] != null) {
        base['job_metadata'] = env['job_metadata'];
      }
      if (env['glb_file_name'] != null) {
        base['glb_file_name'] = env['glb_file_name'];
      }
      base['latest_scan_envelope'] = Map<String, dynamic>.from(env);
    } else if (_lastRunSource != null) {
      base['lastRunSource'] = _lastRunSource;
      base['source'] = _lastRunSource;
    }

    return base;
  }

  Future<void> _exportLatestReport() async {
    await _run('Export report', () async {
      final doc = _composeExportReportDocument();
      if (doc.isEmpty) {
        throw Exception('No report available. Run a scan first.');
      }

      final reportText =
          const JsonEncoder.withIndent('  ').convert(doc);

      final now = DateTime.now().toIso8601String().replaceAll(':', '-');
      final fileName = 'pipe_report_$now.json';
      final tempDir = await getTemporaryDirectory();

      final file = File('${tempDir.path}/$fileName');
      await file.writeAsString(reportText);

      await SharePlus.instance.share(
        ShareParams(text: 'Pipe Layout report', files: [XFile(file.path)]),
      );
    });
  }

  String _csvEscape(dynamic value) {
    if (value == null) return '';
    final raw = value.toString().replaceAll('"', '""');
    final needsQuotes =
        raw.contains(',') || raw.contains('\n') || raw.contains('"');
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
      // New columns are appended at the end for backward compatibility.
      // run_source and sampled_points are scan-level (not per-pipe); same value on every row.
      sb.writeln(
        'timestamp,job_name,operator,site_address,pipe_index,length_m,length_ft,diameter_mm,elongation,confidence,rod_count,rod_total_ft,processing_ms,device,run_source,sampled_points',
      );

      final runSourceCol = _lastRunSource ?? '';
      final sampledCol = _lastApiEnvelope?['sampled_points']?.toString() ?? '';

      for (var i = 0; i < _pipeCards.length; i++) {
        final p = _pipeCards[i];
        final lengthM = parseMeasurementDouble(p['length_m']);
        final lengthFt = lengthM != null
            ? lengthM * _metersToFeetDisplay
            : null;
        final diameterMm = parseMeasurementDouble(p['diameter_mm']);
        final elong = parseMeasurementDouble(p['elongation']);
        final conf = parseMeasurementDouble(p['confidence']);
        final rodCount = parseMeasurementInt(p['rod_count']);
        final rodTotalFt = parseMeasurementDouble(p['rod_total_ft']);

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
          runSourceCol,
          sampledCol,
        ];

        sb.writeln(row.map(_csvEscape).join(','));
      }

      final fileName =
          'pipe_report_${DateTime.now().toIso8601String().replaceAll(':', '-')}.csv';
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/$fileName');
      await file.writeAsString(sb.toString());

      await SharePlus.instance.share(
        ShareParams(text: 'Pipe Layout CSV report', files: [XFile(file.path)]),
      );
    });
  }

  Widget _actionButton(
    String title,
    VoidCallback onTap, {
    Color? color,
    bool enabled = true,
  }) {
    final bg = color ?? const Color(0xFFFF69B4);
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: ElevatedButton(
          onPressed: (_busy || !enabled) ? null : onTap,
          style: ElevatedButton.styleFrom(
            backgroundColor: bg,
            foregroundColor: Colors.black,
            disabledBackgroundColor: const Color(0xFFFFC0DB),
            disabledForegroundColor: Colors.black54,
            textStyle: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          child: Text(title),
        ),
      ),
    );
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
                constraints: BoxConstraints(
                  minHeight: constraints.maxHeight - 24,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Backend URL',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 6),
                    TextField(
                      controller: _urlController,
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        hintText: 'http://192.168.4.70:8000',
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      "On iPhone, use your Windows PC's LAN IP (e.g. http://192.168.x.x:8000), not 127.0.0.1.",
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Colors.grey.shade700,
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
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        border: OutlineInputBorder(),
                        labelText: 'Rod Length Each (ft)',
                        hintText: '1.0',
                      ),
                    ),

                    const SizedBox(height: 8),
                    _actionButton(
                      'Health Check',
                      _healthCheck,
                      color: Colors.blue,
                    ),
                    _actionButton(
                      'Send Synthetic Scan',
                      _sendSyntheticScan,
                      color: Colors.green,
                    ),
                    _actionButton(
                      'Save Synthetic Scan',
                      _saveSyntheticScan,
                      color: Colors.orange,
                    ),
                    _actionButton(
                      'Replay Latest Scan',
                      _replayLatestScan,
                      color: Colors.purple,
                    ),
                    _actionButton(
                      'Load Scan JSON',
                      _loadScanJson,
                      color: Colors.teal,
                    ),
                    _actionButton(
                      'Process Loaded Scan',
                      _processLoadedScan,
                      color: Colors.indigo,
                      enabled:
                          _loadedPoints != null && _loadedPoints!.isNotEmpty,
                    ),
                    _actionButton(
                      'Run Smoke Test',
                      _runSmokeTest,
                      color: Colors.redAccent,
                    ),
                    _actionButton(
                      'Export Latest Report',
                      _exportLatestReport,
                      color: Colors.brown,
                    ),
                    _actionButton(
                      'Export CSV Report',
                      _exportCsvReport,
                      color: Colors.deepOrange,
                    ),
                    _actionButton(
                      'Preview GLB (Metaroom)',
                      _previewGlbMetaroom,
                      color: Colors.blueGrey,
                    ),
                    _actionButton(
                      'Send GLB to PC',
                      _sendGlbToPc,
                      color: const Color(0xFFFF69B4),
                    ),

                    const SizedBox(height: 8),
                    Text(
                      'Status: $_status',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    if (_lastRunSource == 'glb_mesh')
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          _glbSourceCaption,
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.blueGrey.shade700,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    if (_zeroPipesHint != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          _zeroPipesHint!,
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.orange.shade900,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    if (_jobHistory.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          const Text(
                            'Job history',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: _busy ? null : _clearJobHistory,
                            child: const Text('Clear'),
                          ),
                        ],
                      ),
                      ..._jobHistory.take(6).map((e) {
                        final ts = e['ts']?.toString() ?? '';
                        final shortTs = ts.length > 19
                            ? ts.substring(0, 19)
                            : ts;
                        final src = e['source']?.toString() ?? '?';
                        final pc = e['pipe_count'];
                        final job = e['job_name']?.toString() ?? '';
                        final glb = e['glb_name']?.toString();
                        final tail = glb != null && glb.isNotEmpty
                            ? ' • $glb'
                            : '';
                        return Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            '$shortTs • $src • pipes: $pc${job.isNotEmpty ? ' • $job' : ''}$tail',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade800,
                            ),
                          ),
                        );
                      }),
                    ],
                    if (_loadedPoints != null) ...[
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'Loaded file: ${_loadedFileName ?? '-'} | points: ${_loadedPoints!.length}',
                        ),
                      ),
                      if (_loadedPoints!.length < 200)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            'Warning: backend needs at least 200 points (you have ${_loadedPoints!.length}).',
                            style: TextStyle(
                              color: Colors.orange.shade800,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                        ),
                    ],

                    if (processingLine != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        processingLine,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ],

                    if (_pipeCards.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      const Text(
                        'Detected Pipes',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      SizedBox(
                        height: 180,
                        child: ListView.builder(
                          itemCount: _pipeCards.length,
                          itemBuilder: (context, index) {
                            final p = _pipeCards[index];

                            return Card(
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              child: Padding(
                                padding: const EdgeInsets.all(10),
                                child: Text(
                                  _formatPipeCardLine(p, index),
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
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
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 13,
                            ),
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

String? _jobMetaSummaryLine(Map<String, dynamic>? jobMeta) {
  if (jobMeta == null || jobMeta.isEmpty) return null;
  final parts = <String>[];
  final job = jobMeta['job_name']?.toString().trim();
  final op = jobMeta['operator']?.toString().trim();
  final site = jobMeta['site_address']?.toString().trim();
  if (job != null && job.isNotEmpty) parts.add('Job: $job');
  if (op != null && op.isNotEmpty) parts.add('Op: $op');
  if (site != null && site.isNotEmpty) parts.add('Site: $site');
  if (parts.isEmpty) return null;
  return parts.join('  •  ');
}

Future<void> _shareGlbPreviewBundle(
  BuildContext context, {
  String? glbFileLabel,
  Map<String, dynamic>? jobMeta,
  List<Map<String, dynamic>>? pipeCards,
}) async {
  try {
    final tempDir = await getTemporaryDirectory();
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final file = File('${tempDir.path}/preview_bundle_$stamp.json');
    final payload = <String, dynamic>{
      'glb_label': glbFileLabel,
      'meta': jobMeta ?? <String, dynamic>{},
      'pipes': pipeCards ?? <Map<String, dynamic>>[],
    };
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(payload),
    );
    if (!context.mounted) return;
    await SharePlus.instance.share(
      ShareParams(text: '3D preview bundle', files: [XFile(file.path)]),
    );
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }
}

/// [glbSrc] is a plain absolute filesystem path to the GLB (e.g. temp copy);
/// [ModelViewer] uses `Uri.file(glbSrc).toString()` — do not pass encoded URLs.
class GlbViewerPage extends StatelessWidget {
  const GlbViewerPage({
    super.key,
    required this.glbSrc,
    this.glbFileLabel,
    this.pipeCards,
    this.jobMeta,
  });

  final String glbSrc;
  final String? glbFileLabel;
  final List<Map<String, dynamic>>? pipeCards;
  final Map<String, dynamic>? jobMeta;

  static const String _noMeasurementsMessage =
      'No measurements yet — run Process scan / Process loaded scan on the PC first.';

  @override
  Widget build(BuildContext context) {
    final metaLine = _jobMetaSummaryLine(jobMeta);
    final hasPipes = pipeCards != null && pipeCards!.isNotEmpty;

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF121212),
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '3D preview + measurements',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            if (glbFileLabel != null && glbFileLabel!.isNotEmpty)
              Text(
                glbFileLabel!,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.share_outlined),
            tooltip: 'Export preview bundle',
            onPressed: () => _shareGlbPreviewBundle(
              context,
              glbFileLabel: glbFileLabel,
              jobMeta: jobMeta,
              pipeCards: pipeCards,
            ),
          ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(
            child: SafeArea(
              bottom: false,
              child: ModelViewer(
                src: Uri.file(glbSrc).toString(),
                cameraControls: true,
                autoRotate: true,
                backgroundColor: const Color(0xFF121212),
                alt: '3D model preview',
                debugLogging: false,
              ),
            ),
          ),
          DraggableScrollableSheet(
            initialChildSize: 0.34,
            minChildSize: 0.18,
            maxChildSize: 0.58,
            builder: (context, scrollController) {
              return Material(
                color: const Color(0xE61E1E1E),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(12),
                ),
                clipBehavior: Clip.antiAlias,
                child: SafeArea(
                  top: false,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const SizedBox(height: 8),
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.grey.shade600,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      if (metaLine != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                          child: Text(
                            metaLine,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      const Padding(
                        padding: EdgeInsets.fromLTRB(12, 4, 12, 6),
                        child: Text(
                          'Detected pipes',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      Expanded(
                        child: ListView(
                          controller: scrollController,
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                          children: [
                            if (!hasPipes)
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 20),
                                child: Center(
                                  child: Text(
                                    _noMeasurementsMessage,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              )
                            else
                              ...pipeCards!.asMap().entries.map((e) {
                                final index = e.key;
                                final p = e.value;
                                return Card(
                                  margin: const EdgeInsets.symmetric(
                                    vertical: 4,
                                  ),
                                  color: Colors.grey.shade800,
                                  child: Padding(
                                    padding: const EdgeInsets.all(10),
                                    child: Text(
                                      _formatPipeCardLine(p, index),
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                );
                              }),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}
