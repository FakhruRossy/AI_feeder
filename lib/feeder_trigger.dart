/// Port 1:1 dari feeder_trigger_robust.py.
///
/// PENTING soal fps: versi Python ini murni frame-based (debounceFrames,
/// startupTimeoutFrames dihitung dari fps VIDEO yang tetap/diketahui via
/// get_video_fps()). Kamera HP fps-nya jitter/gak konstan -- SUPAYA port
/// ini beneran drop-in-equivalent (bukan cuma "mirip"), feeding_screen.dart
/// men-THROTTLE pemanggilan update() ke laju tetap (`processingFps`),
/// lalu debounceSeconds/startupTimeoutSeconds di-convert ke frame count
/// pakai processingFps itu -- persis peran get_video_fps() di kode asli,
/// bedanya di sini KITA yang nentuin nilainya (bukan dibaca dari file).
class FeederTriggerAdaptive {
  final double decayRatio;
  final double minPeak;
  final double alpha;
  final int debounceFrames;
  final int startupTimeoutFrames;
  final int medianWindow;
  final double spikeRejectFactor;
  final double releaseMargin;

  FeederTriggerAdaptive({
    required this.decayRatio,
    required this.minPeak,
    this.alpha = 0.15,
    this.debounceFrames = 30,
    this.startupTimeoutFrames = 150,
    this.medianWindow = 5,
    this.spikeRejectFactor = 3.0,
    this.releaseMargin = 1.15,
  }) {
    reset();
  }

  late List<double> _rawBuf;
  double? ema;
  double peakRunning = 0.0;
  bool peakReached = false;
  int belowCounter = 0;
  int frameIdx = 0;
  String? lastStopReason;
  bool stopped = false;

  /// Panggil tiap mulai sesi feeding baru (feeder ON) -- sama seperti
  /// .reset() versi Python.
  void reset() {
    _rawBuf = <double>[];
    ema = null;
    peakRunning = 0.0;
    peakReached = false;
    belowCounter = 0;
    frameIdx = 0;
    lastStopReason = null;
    stopped = false;
  }

  double _median() {
    final buf = [..._rawBuf]..sort();
    final n = buf.length;
    final mid = n ~/ 2;
    return n % 2 == 1 ? buf[mid] : 0.5 * (buf[mid - 1] + buf[mid]);
  }

  double _filterSample(double raw) {
    _rawBuf.add(raw);
    while (_rawBuf.length > medianWindow) {
      _rawBuf.removeAt(0);
    }
    if (_rawBuf.length < 3) return raw;
    final med = _median();
    // raw jauh di atas median lokal -> outlier sesaat, pakai median
    if (med > 0 && raw > spikeRejectFactor * med) return med;
    return raw;
  }

  /// Panggil tiap ada 1 "frame terproses" baru (di laju processingFps,
  /// BUKAN tiap raw camera frame). Return "STOP" atau null.
  String? update(double rawSample) {
    if (stopped) return 'STOP';

    frameIdx += 1;
    final filtered = _filterSample(rawSample);

    ema = ema == null ? filtered : alpha * filtered + (1 - alpha) * ema!;

    if (ema! > peakRunning) peakRunning = ema!;
    if (!peakReached && peakRunning >= minPeak) peakReached = true;

    if (!peakReached) {
      if (frameIdx >= startupTimeoutFrames) {
        stopped = true;
        lastStopReason = 'startup_timeout';
        return 'STOP';
      }
      return null;
    }

    final decayTh = decayRatio * peakRunning;
    final releaseTh = decayTh * releaseMargin;

    if (ema! < decayTh) {
      belowCounter += 1;
    } else if (ema! > releaseTh) {
      belowCounter = 0;
    }
    // else: zona hysteresis -- counter dibiarkan apa adanya (gak naik gak reset)

    if (belowCounter >= debounceFrames) {
      stopped = true;
      lastStopReason = 'decay';
      return 'STOP';
    }
    return null;
  }

  /// Buat logging real-time / debug overlay di app.
  Map<String, dynamic> state() => {
        'frame': frameIdx,
        'ema': ema != null ? double.parse(ema!.toStringAsFixed(1)) : null,
        'peak_running': double.parse(peakRunning.toStringAsFixed(1)),
        'peak_reached': peakReached,
        'below_counter': belowCounter,
        'stopped': stopped,
        'reason': lastStopReason,
      };
}
