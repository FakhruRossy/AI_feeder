import 'dart:async';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'config.dart';
import 'motion_energy.dart';
import 'feeder_trigger.dart';
import 'relay_service.dart';
import 'supabase_service.dart';
import 'settings_screen.dart';

class FeedingScreen extends StatefulWidget {
  final FeederConfig config;
  const FeedingScreen({super.key, required this.config});

  @override
  State<FeedingScreen> createState() => _FeedingScreenState();
}

class _FeedingScreenState extends State<FeedingScreen> {
  CameraController? _controller;
  final _extractor = MotionEnergyExtractor();
  FeederTriggerAdaptive? _trigger;
  late RelayService _relay;
  late FeederSupabaseService _supabase;

  bool _isFeeding = false;
  bool _isProcessingFrame = false;
  DateTime? _lastProcessedAt;
  double _lastEma = 0;
  double _lastPeak = 0;
  String _statusText = 'Idle';

  Duration get _minFrameInterval =>
      Duration(milliseconds: (1000 / widget.config.processingFps).round());

  @override
  void initState() {
    super.initState();
    _relay = RelayService(
      baseUrl: widget.config.relayBaseUrl,
      onPath: widget.config.relayOnPath,
      offPath: widget.config.relayOffPath,
    );
    _supabase = FeederSupabaseService(
      table: widget.config.supabaseTable,
      rowId: widget.config.supabaseRowId,
    );
    _initCamera();
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    final cam = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    _controller = CameraController(
      cam,
      // J2 Prime: resolusi rendah -- kita cuma butuh 160x120 buat motion
      // energy, ga ada gunanya proses frame 720p tiap kali di CPU segitu.
      ResolutionPreset.low,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    await _controller!.initialize();
    if (mounted) setState(() {});
  }

  int _secondsToFrames(double seconds) =>
      max(1, (seconds * widget.config.processingFps).round());

  Future<void> _startFeeding() async {
    if (_controller == null || !_controller!.value.isInitialized) return;

    await WakelockPlus.enable(); // layar/app jangan sampe disuspend pas mantau

    setState(() {
      _isFeeding = true;
      _statusText = 'Feeding...';
    });

    _extractor.reset();
    _trigger = FeederTriggerAdaptive(
      decayRatio: widget.config.decayRatio,
      minPeak: widget.config.minPeak,
      alpha: widget.config.emaAlpha,
      debounceFrames: _secondsToFrames(widget.config.debounceSeconds),
      startupTimeoutFrames: _secondsToFrames(widget.config.startupTimeoutSeconds),
      medianWindow: widget.config.medianWindow,
    );
    _lastProcessedAt = null;

    final relayOk = await _relay.turnOn();
    if (!relayOk) _showSnack('Gagal nyalain relay -- cek koneksi/IP');
    await _supabase.updateStatus(state: 'feeding');

    await _controller!.startImageStream(_onFrame);
  }

  void _onFrame(CameraImage image) {
    if (!_isFeeding || _trigger == null || _trigger!.stopped) return;
    if (_isProcessingFrame) return; // masih proses frame sebelumnya, skip

    final now = DateTime.now();
    if (_lastProcessedAt != null && now.difference(_lastProcessedAt!) < _minFrameInterval) {
      return; // throttle ke processingFps -- ini kunci performa di J2 Prime
    }
    _lastProcessedAt = now;
    _isProcessingFrame = true;

    try {
      final raw = _extractor.processFrame(image);
      final stoppedNow = _trigger!.update(raw) == 'STOP';
      final st = _trigger!.state();
      if (mounted) {
        setState(() {
          _lastEma = (st['ema'] as double?) ?? 0;
          _lastPeak = st['peak_running'] as double;
        });
      }
      if (stoppedNow) {
        _handleStop(_trigger!.lastStopReason ?? 'unknown');
      }
    } finally {
      _isProcessingFrame = false;
    }
  }

  Future<void> _handleStop(String reason) async {
    setState(() {
      _isFeeding = false;
      _statusText = 'Stopped ($reason)';
    });
    await _controller?.stopImageStream();
    await WakelockPlus.disable();
    final relayOk = await _relay.turnOff();
    if (!relayOk) {
      _showSnack('Gagal matiin relay -- cek koneksi/IP, MATIIN MANUAL!');
    }
    await _supabase.updateStatus(state: 'idle', stopReason: reason);
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void dispose() {
    _controller?.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cam = _controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Fish Feeder'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _isFeeding
                ? null
                : () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => SettingsScreen(config: widget.config),
                      ),
                    ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: cam != null && cam.value.isInitialized
                ? CameraPreview(cam)
                : const Center(child: CircularProgressIndicator()),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Text('Status: $_statusText', style: const TextStyle(fontSize: 16)),
                Text('EMA: ${_lastEma.toStringAsFixed(1)}  |  Peak: ${_lastPeak.toStringAsFixed(1)}'),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: _isFeeding ? null : _startFeeding,
                  child: Text(_isFeeding ? 'Sedang Memberi Makan...' : 'Mulai Kasih Makan'),
                ),
                if (_isFeeding)
                  TextButton(
                    onPressed: () => _handleStop('manual_stop'),
                    child: const Text('Stop Manual'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
