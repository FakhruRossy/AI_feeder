import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:screen_brightness/screen_brightness.dart';

import 'config.dart';
import 'motion_energy.dart';
import 'feeder_trigger.dart';
import 'relay_service.dart';
import 'supabase_service.dart';
import 'settings_screen.dart';
import 'local_server.dart';

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
  late LocalServer _localServer;

  // State Kontrol Utama
  bool _isFeeding = false;
  bool _isPowerSave = false; // Mode hemat daya (Layar Hitam)
  bool _isProcessingFrame = false;
  DateTime? _lastProcessedAt;

  // State UI
  double _lastEma = 0;
  double _lastPeak = 0;
  String _statusText = 'Idle';

  // Resource Monitoring
  Timer? _resourceTimer;
  String _tempText = "-- °C";
  String _cpuText = "-- %";

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
    _startResourceMonitor(); // Jalankan pembaca Suhu & CPU

    _localServer = LocalServer(
      onMulai: () {
        if (!_isFeeding) {
          print('PERINTAH ESP DITERIMA: Mulai!');
          _startFeeding();
        }
      },
      onBerhenti: () {
        if (_isFeeding) {
          print('PERINTAH ESP DITERIMA: Berhenti!');
          _handleStop('perintah_esp');
        }
      },
    );
    _localServer.start();
  }

  // ==========================================
  // HARDWARE MONITORING (Suhu & CPU DIY)
  // ==========================================
  void _startResourceMonitor() {
    _resourceTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      // 🛡️ RESOURCE MANAGEMENT: Skip jika app sudah keluar atau sedang Power Save
      if (!mounted || _isPowerSave) return;

      try {
        // Baca Suhu (Thermal Zone)
        final tempFile = File('/sys/class/thermal/thermal_zone0/temp');
        if (await tempFile.exists()) {
          final tempRaw = await tempFile.readAsString();
          final tempC = int.parse(tempRaw.trim()) / 1000.0;
          _tempText = "${tempC.toStringAsFixed(1)}°C";
        }

        // Baca Beban CPU (Asumsi 4 Core untuk J2 Prime)
        final loadFile = File('/proc/loadavg');
        if (await loadFile.exists()) {
          final loadRaw = await loadFile.readAsString();
          final load1Min = double.parse(loadRaw.split(' ')[0]);
          final cpuUsage = (load1Min / 4.0) * 100;
          _cpuText = "${cpuUsage.clamp(0, 100).toStringAsFixed(0)}%";
        }
      } catch (e) {
        // 🛡️ CRASH HANDLING: Abaikan jika OS memblokir akses file (tergantung kernel)
      }

      if (mounted) setState(() {});
    });
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    final cam = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    _controller = CameraController(
      cam,
      ResolutionPreset.medium,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    await _controller!.initialize();
    if (mounted) setState(() {});
  }

  int _secondsToFrames(double seconds) =>
      max(1, (seconds * widget.config.processingFps).round());

  // ==========================================
  // POWER SAVE LOGIC (Layar Hitam & Brightness)
  // ==========================================
  Future<void> _togglePowerSave() async {
    setState(() {
      _isPowerSave = !_isPowerSave;
    });

    try {
      if (_isPowerSave) {
        await ScreenBrightness().setScreenBrightness(0.0);
      } else {
        await ScreenBrightness().resetScreenBrightness();
      }
    } catch (e) {
      print("Gagal set brightness: $e");
    }
  }

  // ==========================================
  // FEEDING LOGIC
  // ==========================================
  Future<void> _startFeeding() async {
    if (_controller == null || !_controller!.value.isInitialized) return;

    await WakelockPlus.enable();

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
      startupTimeoutFrames: _secondsToFrames(
        widget.config.startupTimeoutSeconds,
      ),
      medianWindow: widget.config.medianWindow,
    );
    _lastProcessedAt = null;

    _relay.turnOnPersistent(
      onFailure: () {
        if (mounted) _showSnack('Gagal nyalain relay -- cek koneksi/IP');
      },
    );

    // 🛡️ CRASH HANDLING: Mencegah force close saat gagal bind hardware
    try {
      await _controller!.startImageStream(_onFrame);
    } catch (e) {
      print('GAGAL memulai stream kamera: $e');
      _showSnack('Gagal akses kamera, coba mulai ulang aplikasi');
    }
  }

  void _onFrame(CameraImage image) {
    if (!_isFeeding || _trigger == null || _trigger!.stopped) return;
    if (_isProcessingFrame) return;

    final now = DateTime.now();
    if (_lastProcessedAt != null &&
        now.difference(_lastProcessedAt!) < _minFrameInterval) {
      return;
    }
    _lastProcessedAt = now;
    _isProcessingFrame = true;

    try {
      final raw = _extractor.processFrame(image);

      final stoppedNow = _trigger!.update(raw) == 'STOP';
      final st = _trigger!.state();

      // 🛡️ CPU OPTIMIZATION (UI FREEZE): Jangan update teks jika layar sedang dihemat
      if (mounted && !_isPowerSave) {
        setState(() {
          _lastEma = (st['ema'] as double?) ?? 0;
          _lastPeak = st['peak_running'] as double;
        });
      }

      if (stoppedNow) {
        _handleStop(_trigger!.lastStopReason ?? 'unknown');
      }
    } finally {
      // 🛡️ MEMORY MANAGEMENT: Pastikan flag pemrosesan selalu dilepas meskipun ada error di pipeline
      _isProcessingFrame = false;
    }
  }

  Future<void> _handleStop(String reason) async {
    setState(() {
      _isFeeding = false;
      // _isPowerSave = false; // Matikan status power save
      _statusText = 'Stopped ($reason)';
    });

    // 🛡️ BRIGHTNESS FAILSAFE: Pastikan terang kembali saat feeding selesai otomatis
    // try {
    //   await ScreenBrightness().resetScreenBrightness();
    // } catch (e) {
    //   print("Gagal reset brightness: $e");
    // }

    // 🛡️ CRASH HANDLING: Hentikan stream hanya jika memang sedang berjalan
    if (_controller != null && _controller!.value.isStreamingImages) {
      try {
        await _controller!.stopImageStream();
      } catch (e) {
        print('Abaikan error stop: $e');
      }
    }

    await WakelockPlus.disable();

    _relay.turnOffPersistent(
      onFailure: () {
        if (mounted) _showSnack('Gagal matiin relay -- MATIIN MANUAL!');
      },
    );
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ==========================================
  // DISPOSE & CLEANUP
  // ==========================================
  @override
  void dispose() {
    // 🛡️ MEMORY & RESOURCE CLEANUP
    _resourceTimer?.cancel();
    _controller?.dispose();
    WakelockPlus.disable();
    try {
      ScreenBrightness().resetScreenBrightness();
    } catch (e) {}
    _localServer.stop();
    super.dispose();
  }

  // ==========================================
  // USER INTERFACE
  // ==========================================
  @override
  Widget build(BuildContext context) {
    // ⬛ TAMPILAN POWER SAVE (FULL HITAM)
    if (_isPowerSave) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: GestureDetector(
          onTap: _togglePowerSave,
          behavior: HitTestBehavior.opaque,
          child: SizedBox.expand(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text(
                  "⚡ Mode Hemat Daya Aktif",
                  style: TextStyle(color: Colors.white54, fontSize: 18),
                ),
                const SizedBox(height: 16),
                Text(
                  _isFeeding
                      ? "Algoritma berjalan di latar belakang..."
                      : "Idle: Menunggu perintah (Standby)...",
                  style: const TextStyle(color: Colors.white30, fontSize: 14),
                ),
                const SizedBox(height: 32),
                const Text(
                  "(Ketuk layar di mana saja untuk kembali)",
                  style: TextStyle(color: Colors.white24, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // ⬜ TAMPILAN NORMAL
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
                ? Center(
                    child: AspectRatio(
                      // 📐 MENCEGAH STRETCH (Goal 3)
                      aspectRatio:
                          MediaQuery.of(context).orientation ==
                              Orientation.portrait
                          ? 1 / cam.value.aspectRatio
                          : cam.value.aspectRatio,
                      child: CameraPreview(cam),
                    ),
                  )
                : const Center(child: CircularProgressIndicator()),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Text(
                  'Status: $_statusText',
                  style: const TextStyle(fontSize: 16),
                ),
                Text(
                  'EMA: ${_lastEma.toStringAsFixed(1)}  |  Peak: ${_lastPeak.toStringAsFixed(1)}',
                ),
                const SizedBox(height: 8),

                // 🌡️ Indikator Suhu & CPU
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(
                      Icons.thermostat,
                      size: 16,
                      color: Colors.orange,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _tempText,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(width: 16),
                    const Icon(Icons.memory, size: 16, color: Colors.blue),
                    const SizedBox(width: 4),
                    Text(
                      _cpuText,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                ElevatedButton(
                  onPressed: _isFeeding ? null : _startFeeding,
                  child: Text(
                    _isFeeding
                        ? 'Sedang Memberi Makan...'
                        : 'Mulai Kasih Makan',
                  ),
                ),

                if (_isFeeding) ...[
                  TextButton(
                    onPressed: () => _handleStop('manual_stop'),
                    child: const Text('Stop Manual'),
                  ),
                ],
                const SizedBox(height: 12),

                // ⚡ Tombol Hemat Baterai (Selalu Ada)
                ElevatedButton.icon(
                  onPressed: _togglePowerSave,
                  icon: const Icon(Icons.power_settings_new),
                  label: const Text('⚡ Hemat Baterai (Layar Gelap)'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.grey[800],
                    foregroundColor: Colors.amber,
                    minimumSize: const Size(double.infinity, 45),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
