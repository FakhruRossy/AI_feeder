// 🟢 REVISI (P1 / Room 2): CameraManager -- satu-satunya pemilik CameraController.
//
// Kenapa ada: kamera J2 Prime memakai HAL1 (lihat SPEC_P1.md bagian 2), tutup-buka
// cepat rawan layar hitam. Kode lama tanpa mutex, men-null-kan _controller sebelum
// dispose selesai, dan tidak mengecek kebutuhan terbaru setelah await. Di sini:
//  - SATU antrean serial; apply(needCamera, needStream, wantTorch) idempotent dan
//    panggilan bertumpuk digabung (yang dieksekusi = kebutuhan TERBARU).
//  - Tidak pernah ada dua controller; dispose di-await tuntas + jeda kReopenGap.
//  - Watchdog stall/black: DETEKSI + CATAT saja, tanpa re-init.

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;

import 'dev_log.dart';

// ---------------------------------------------------------------------------
// KONSTANTA (bisa dituning)
// ---------------------------------------------------------------------------

/// Jeda minimal antara dispose selesai dan buka kamera lagi (HAL1).
const Duration kReopenGap = Duration(milliseconds: 1000);

/// Batas waktu CameraController.initialize().
const Duration kInitTimeout = Duration(seconds: 10);

/// Jarak minimal antar percobaan buka setelah gagal (bukan batas jumlah).
const Duration kInitRetryGap = Duration(seconds: 3);

/// Tunggu setelah torch berubah sebelum exposure dikunci (auto-exposure settle).
const Duration kLockSettle = Duration(seconds: 2);

const Duration kWatchdogPeriod = Duration(seconds: 5);

/// Masa tenang sejak stream mulai sebelum stall dinilai.
const Duration kWatchdogQuiet = Duration(seconds: 3);

/// Tidak ada frame selama ini => stall.
const Duration kStallAfter = Duration(seconds: 5);

/// Frame hitam bertahan selama ini => black.
const Duration kBlackFor = Duration(seconds: 10);

/// Ambang provisional black (luma rata-rata & simpangan baku, skala 0..255).
/// Nilai luma selalu dicatat di event supaya ambang bisa dikalibrasi.
const double kBlackMeanMax = 4.0;
const double kBlackStdMax = 1.5;

/// Ambil 1 dari N byte Y-plane. Sengaja bilangan prima (bukan 64) supaya tidak
/// selalu jatuh di kolom yang sama saat row stride kelipatan 64.
const int kLumaSampleStep = 67;

/// Sampling luma paling sering sekali per interval ini (hemat CPU).
const Duration kLumaSampleEvery = Duration(milliseconds: 500);

const int kSelfTestMinFrames = 3;

// ---------------------------------------------------------------------------
// ABSTRAKSI BACKEND (supaya bisa dites tanpa plugin kamera)
// ---------------------------------------------------------------------------

/// Satu sesi kamera yang sudah terbuka (di produksi: pembungkus CameraController).
abstract class CameraSession {
  bool get isInitialized;
  bool get isStreaming;
  bool get hasError;
  Size? get previewSize;

  /// CameraController asli (untuk widget CameraPreview); null di backend palsu.
  Object? get nativeController;

  Future<void> startStream(void Function(CameraImage image) onImage);
  Future<void> stopStream();
  Future<void> setTorch(bool on);
  Future<void> setFocusLocked(bool locked);
  Future<void> setExposureLocked(bool locked);

  /// Listener error controller (dipanggil saat controller melaporkan error).
  void setErrorListener(void Function(String description)? listener);

  /// Matikan total (stop stream bila perlu + dispose). Harus aman dipanggil
  /// pada sesi setengah rusak.
  Future<void> dispose();
}

abstract class CameraBackend {
  /// Buka kamera belakang dan kembalikan sesi yang SUDAH initialized.
  /// Melempar bila gagal (backend wajib membersihkan controller setengah jadi).
  Future<CameraSession> open();
}

/// Backend produksi. Parameter kamera dipertahankan dari _initCamera lama:
/// kamera belakang, ResolutionPreset.medium, tanpa audio, yuv420.
class RealCameraBackend implements CameraBackend {
  const RealCameraBackend({this.resolution = ResolutionPreset.medium});
  final ResolutionPreset resolution;

  @override
  Future<CameraSession> open() async {
    final cameras = await availableCameras();
    final cam = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    final controller = CameraController(
      cam,
      resolution,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    try {
      await controller.initialize();
    } catch (_) {
      // Gagal init => dispose SEKALI di sini, lalu lempar ulang.
      try {
        await controller.dispose();
      } catch (_) {}
      rethrow;
    }
    return _RealCameraSession(controller);
  }
}

class _RealCameraSession implements CameraSession {
  _RealCameraSession(this._c) {
    _listener = () {
      if (_c.value.hasError) {
        _onError?.call(_c.value.errorDescription ?? 'unknown');
      }
    };
    _c.addListener(_listener);
  }

  final CameraController _c;
  late final void Function() _listener;
  void Function(String)? _onError;

  @override
  bool get isInitialized => _c.value.isInitialized;
  @override
  bool get isStreaming => _c.value.isStreamingImages;
  @override
  bool get hasError => _c.value.hasError;
  @override
  Size? get previewSize => _c.value.previewSize;
  @override
  Object? get nativeController => _c;

  @override
  Future<void> startStream(void Function(CameraImage image) onImage) =>
      _c.startImageStream(onImage);

  @override
  Future<void> stopStream() async {
    if (_c.value.isStreamingImages) await _c.stopImageStream();
  }

  @override
  Future<void> setTorch(bool on) =>
      _c.setFlashMode(on ? FlashMode.torch : FlashMode.off);

  @override
  Future<void> setFocusLocked(bool locked) =>
      _c.setFocusMode(locked ? FocusMode.locked : FocusMode.auto);

  @override
  Future<void> setExposureLocked(bool locked) =>
      _c.setExposureMode(locked ? ExposureMode.locked : ExposureMode.auto);

  @override
  void setErrorListener(void Function(String description)? listener) {
    _onError = listener;
  }

  @override
  Future<void> dispose() async {
    _onError = null;
    try {
      _c.removeListener(_listener);
    } catch (_) {}
    try {
      if (_c.value.isStreamingImages) await _c.stopImageStream();
    } catch (_) {}
    await _c.dispose();
  }
}

// ---------------------------------------------------------------------------
// HASIL SELF-TEST
// ---------------------------------------------------------------------------

class CameraSelfTestResult {
  const CameraSelfTestResult({
    required this.ok,
    required this.frames,
    required this.elapsedMs,
    this.meanLuma,
    this.stdLuma,
    this.reason,
  });

  /// true = kamera terbuka, frame mengalir (>= kSelfTestMinFrames) dan tidak hitam.
  final bool ok;
  final int frames;
  final int elapsedMs;
  final double? meanLuma;
  final double? stdLuma;

  /// null bila ok. Selain itu: busy | disposed | open_failed: ... |
  /// stream_failed: ... | no_frames | black
  final String? reason;

  @override
  String toString() =>
      'SelfTest(ok=$ok frames=$frames luma=${meanLuma?.toStringAsFixed(1)} '
      'std=${stdLuma?.toStringAsFixed(1)} reason=$reason ${elapsedMs}ms)';
}

class _LumaStat {
  const _LumaStat(this.mean, this.std);
  final double mean;
  final double std;
}

class _SelfTestAcc {
  int frames = 0;
  int n = 0;
  double sumMean = 0;
  double sumStd = 0;
}

// ---------------------------------------------------------------------------
// CAMERA MANAGER
// ---------------------------------------------------------------------------

class CameraManager with WidgetsBindingObserver {
  CameraManager({
    required CameraBackend backend,
    required this.onImage,
    this.onLog,
    this.onEvent,
    this.onTorchChanged,
    this.onIssue,
    this.onRecovered,
    this.onStateChanged,
    this.reopenGap = kReopenGap,
    this.initTimeout = kInitTimeout,
    this.initRetryGap = kInitRetryGap,
    this.lockSettle = kLockSettle,
    this.watchdogPeriod = kWatchdogPeriod,
    this.watchdogQuiet = kWatchdogQuiet,
    this.stallAfter = kStallAfter,
    this.blackFor = kBlackFor,
    this.uiDetachDelay = const Duration(milliseconds: 80),
    bool observeLifecycle = true,
  }) : _backend = backend {
    if (observeLifecycle) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
  }

  final CameraBackend _backend;

  // ---- callback ----
  /// Frame untuk loop AI (hanya saat stream diharapkan, bukan saat self-test).
  final void Function(CameraImage image) onImage;
  final void Function(LogDirection direction, String channel, String message)?
  onLog;

  /// Event ke CalibRecorder: cam_open, cam_close, torch, cam_black, cam_stall,
  /// cam_ok, cam_lock.
  final void Function(String name, Map<String, dynamic>? data)? onEvent;
  final void Function(bool torchActual)? onTorchChanged;

  /// kind: 'black' | 'stall' | 'init_failed'. Dipanggil tiap TRANSISI masuk
  /// masalah (bukan berulang selama masalah bertahan). Dedup "sekali per jenis
  /// per sesi" untuk feeder_status dilakukan pemanggil (Room 5).
  final void Function(String kind, Map<String, dynamic> data)? onIssue;

  /// Masalah black/stall hilang sendiri (event cam_ok sudah dikirim).
  final void Function()? onRecovered;

  /// TAMBAHAN opsional: controller/preview berubah (buka/tutup) -> setState UI.
  final void Function()? onStateChanged;

  // ---- tuning ----
  final Duration reopenGap;
  final Duration initTimeout;
  final Duration initRetryGap;
  final Duration lockSettle;
  final Duration watchdogPeriod;
  final Duration watchdogQuiet;
  final Duration stallAfter;
  final Duration blackFor;
  final Duration uiDetachDelay;

  // ---- kebutuhan terbaru (ditulis sinkron oleh apply) ----
  bool _wantCamera = false;
  bool _wantStream = false;
  bool _wantTorch = false;
  bool _lockWanted = false;

  // ---- antrean ----
  Future<void> _chain = Future.value();
  Future<void>? _pendingApply; // sudah antre, belum mulai jalan
  bool _applyRunning = false;
  int _gen = 0; // naik tiap ada kebutuhan baru; job mengulang sampai stabil

  // ---- state kamera ----
  CameraSession? _session;
  bool _closing = false;
  bool _disposed = false;
  bool _observing = false;
  bool _torchActual = false;
  bool _locked = false;
  DateTime? _torchChangedAt;
  DateTime? _lastClosedAt;
  DateTime? _lastInitFailAt;
  Future<void>? _lateOpen; // open yang timeout tapi belum selesai
  String? _dropReason;
  bool _errorSeen = false;

  // ---- watchdog ----
  Timer? _watchdog;
  DateTime? _streamStartedAt;
  DateTime? _lastFrameAt;
  DateTime? _lastLumaAt;
  DateTime? _blackSince;
  double? _lastLumaMean;
  double? _lastLumaStd;
  bool _reportedStall = false;
  bool _reportedBlack = false;
  bool _restartRecommended = false;

  _SelfTestAcc? _selfTest;

  // ======================================================================
  // GETTER PUBLIK
  // ======================================================================

  /// Kamera terbuka dan siap dipakai UI.
  bool get isCameraActive {
    final s = _session;
    return s != null && !_closing && s.isInitialized;
  }

  /// CameraController asli untuk CameraPreview; null selama menutup/tertutup.
  CameraController? get controller {
    final s = _session;
    if (s == null || _closing || !s.isInitialized) return null;
    final n = s.nativeController;
    return n is CameraController ? n : null;
  }

  Size? get previewSize => _session?.previewSize;
  bool get isStreaming => _session?.isStreaming ?? false;

  /// Torch yang BENAR-BENAR menyala (setFlashMode(torch) sukses).
  bool get torchActual => _torchActual;
  bool get torchWanted => _wantTorch;

  /// Watchdog mendeteksi black/stall (atau kamera mati) -> disarankan restart
  /// app di saat idle. Tidak dihapus otomatis saat pulih sendiri.
  bool get restartRecommended => _restartRecommended;
  void clearRestartRecommended() => _restartRecommended = false;

  bool get isDisposed => _disposed;

  // ======================================================================
  // API PUBLIK
  // ======================================================================

  /// Titik tunggal pengatur kamera. Idempotent. needStream/wantTorch otomatis
  /// menyertakan needCamera. Future selesai setelah kebutuhan TERBARU terpenuhi
  /// (atau percobaan gagal; kegagalan dilaporkan lewat onIssue, bukan exception).
  Future<void> apply(bool needCamera, bool needStream, bool wantTorch) {
    if (_disposed) return Future.value();
    _wantStream = needStream;
    _wantTorch = wantTorch;
    _wantCamera = needCamera || needStream || wantTorch;
    if (!_wantCamera) _lockWanted = false;
    _syncWatchdog();
    return _schedule();
  }

  /// Kunci fokus + exposure (pengganti _lockCameraAuto). Aman dipanggil sebelum
  /// kamera terbuka: kunci dipasang begitu sesi siap (dan torch sudah settle).
  Future<void> lockAuto() {
    if (_disposed) return Future.value();
    _lockWanted = true;
    return _schedule();
  }

  Future<void> unlockAuto() {
    if (_disposed) return Future.value();
    _lockWanted = false;
    return _schedule();
  }

  /// Buka kamera + stream sebentar, hitung frame & kecerahan, tutup. Hanya
  /// berjalan bila manager idle; kalau tidak, hasilnya reason='busy'.
  /// [useTorch] menyalakan torch selama tes (supaya malam hari tidak dianggap
  /// hitam). Tidak memicu onIssue / restartRecommended.
  Future<CameraSelfTestResult> selfTest(
    Duration duration, {
    bool useTorch = false,
  }) {
    final c = Completer<CameraSelfTestResult>();
    _enqueue(() async {
      try {
        c.complete(await _runSelfTest(duration, useTorch));
      } catch (e) {
        c.complete(
          CameraSelfTestResult(
            ok: false,
            frames: 0,
            elapsedMs: 0,
            reason: 'open_failed: $e',
          ),
        );
      }
    });
    return c.future;
  }

  /// Matikan semuanya (dipanggil dari dispose widget; boleh tanpa await).
  Future<void> disposeAll() {
    if (_disposed) return _chain;
    _disposed = true;
    _wantCamera = _wantStream = _wantTorch = _lockWanted = false;
    _watchdog?.cancel();
    _watchdog = null;
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
    _gen++;
    return _enqueue(() => _closeSession('dispose', detach: false));
  }

  // ---- lifecycle ----
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _checkHealth('resumed');
  }

  void _checkHealth(String why) {
    final s = _session;
    if (_disposed || s == null || _closing) return;
    if (!s.isInitialized || s.hasError) {
      _log(LogDirection.error, 'Controller kamera tidak sehat ($why)');
      _dropReason = 'unhealthy:$why';
      _raise('init_failed', {'reason': 'unhealthy', 'why': why}, event: false);
    }
    // Idempotent: kalau stream terhenti selama background, reconcile menyalakannya.
    _schedule();
  }

  // ======================================================================
  // ANTREAN
  // ======================================================================

  Future<void> _schedule() {
    _gen++;
    return _pendingApply ??= _enqueue(_runApply);
  }

  Future<void> _enqueue(Future<void> Function() op) {
    final next = _chain.then((_) async {
      try {
        await op();
      } catch (e) {
        _log(LogDirection.error, 'Kesalahan internal CameraManager: $e');
      }
    });
    _chain = next;
    return next;
  }

  Future<void> _runApply() async {
    _pendingApply = null;
    _applyRunning = true;
    try {
      int seen;
      do {
        seen = _gen;
        await _reconcile();
      } while (seen != _gen && !_disposed);
    } finally {
      _applyRunning = false;
    }
  }

  /// Satu kali penyelarasan terhadap kebutuhan TERBARU (dibaca ulang tiap langkah).
  Future<void> _reconcile() async {
    final drop = _dropReason;
    _dropReason = null;
    if (drop != null && _session != null) await _closeSession(drop);

    if (_disposed || !_wantCamera) {
      await _closeSession(_disposed ? 'dispose' : 'idle', detach: !_disposed);
      return;
    }

    if (_session == null) {
      final err = await _openSession();
      if (err != null) return;
      if (_disposed || !_wantCamera) return; // putaran berikutnya menutup
    }
    final s = _session;
    if (s == null) return;

    // 1) matikan stream dulu bila tidak perlu
    if (!_wantStream && s.isStreaming) await _stopStream(s);
    // 2) torch (sebelum stream mulai & sebelum exposure dikunci)
    await _syncTorch(s);
    // 3) nyalakan stream bila perlu
    if (_wantStream && !s.isStreaming && !_disposed) await _startStream(s);
    // 4) kunci fokus/exposure
    await _syncLock(s);
  }

  // ======================================================================
  // GUARD TIMEOUT: panggilan platform (HAL1) kadang tidak pernah kembali dan
  // akan membekukan antrean serial. true = selesai tepat waktu.
  // ======================================================================

  bool _hangSeen = false;

  Future<bool> _guard(String what, Future<void> f, Duration t) async {
    try {
      await f.timeout(t);
      return true;
    } on TimeoutException {
      _hangSeen = true;
      _log(
        LogDirection.error,
        '$what macet >${t.inSeconds}s (platform tidak kembali)',
      );
      _raise('init_failed', {'reason': 'hang', 'what': what}, event: false);
      return false;
    }
  }

  // ======================================================================
  // BUKA / TUTUP
  // ======================================================================

  /// Return null bila sukses, selain itu deskripsi error.
  Future<String?> _openSession({bool force = false, bool report = true}) async {
    if (!await _waitBeforeOpen(force)) return 'aborted';

    final late = _lateOpen;
    if (late != null) {
      // Open lama yang timeout harus tuntas (dan di-dispose) dulu: tidak boleh
      // ada dua controller.
      try {
        await late.timeout(const Duration(seconds: 12));
      } catch (_) {}
      if (_disposed || (!force && !_wantCamera)) return 'aborted';
    }

    final sw = Stopwatch()..start();
    final fut = _backend.open();
    final CameraSession s;
    try {
      s = await fut.timeout(initTimeout);
    } on TimeoutException {
      _lateOpen = _disposeLate(fut);
      return _openFailed('timeout ${initTimeout.inSeconds}s', report);
    } catch (e) {
      return _openFailed('$e', report);
    }

    _session = s;
    _errorSeen = false;
    _lastInitFailAt = null;
    s.setErrorListener(_onSessionError);
    _event('cam_open', {
      'ok': true,
      'ms': sw.elapsedMilliseconds,
      'preview': s.previewSize == null
          ? null
          : '${s.previewSize!.width.toInt()}x${s.previewSize!.height.toInt()}',
    });
    _log(LogDirection.info, 'Kamera dinyalakan');
    _notifyState();
    return null;
  }

  Future<void> _disposeLate(Future<CameraSession> fut) {
    final f = fut.then<void>((s) async {
      try {
        await s.dispose();
      } catch (_) {}
    }, onError: (_) {});
    f.whenComplete(() {
      if (identical(_lateOpen, f)) _lateOpen = null;
    });
    return f;
  }

  String _openFailed(String err, bool report) {
    _lastInitFailAt = DateTime.now();
    _setTorchActual(false, 'init_failed');
    _event('cam_open', {'ok': false, 'err': err});
    _log(LogDirection.error, 'Gagal nyalain kamera: $err');
    if (report) _raise('init_failed', {'err': err}, event: false);
    return err;
  }

  /// Tunggu jeda buka-ulang (setelah dispose) dan jarak antar percobaan (setelah
  /// gagal). false = dibatalkan karena kebutuhan berubah/dispose.
  Future<bool> _waitBeforeOpen(bool force) async {
    while (true) {
      final now = DateTime.now();
      var wait = Duration.zero;
      if (_lastClosedAt != null) {
        final r = reopenGap - now.difference(_lastClosedAt!);
        if (r > wait) wait = r;
      }
      if (_lastInitFailAt != null) {
        final r = initRetryGap - now.difference(_lastInitFailAt!);
        if (r > wait) wait = r;
      }
      if (wait <= Duration.zero) return true;
      await Future<void>.delayed(wait);
      if (_disposed || (!force && !_wantCamera)) return false;
    }
  }

  Future<void> _closeSession(String reason, {bool detach = true}) async {
    final s = _session;
    if (s == null) return;
    // UI harus berhenti memakai controller SEBELUM dispose (getter controller
    // sudah null), tapi _session baru dilepas SETELAH dispose tuntas.
    _closing = true;
    _notifyState();
    if (detach && uiDetachDelay > Duration.zero) {
      await Future<void>.delayed(uiDetachDelay);
    }
    s.setErrorListener(null);
    _locked = false;
    _streamStartedAt = null;
    _lastFrameAt = null;
    _blackSince = null;
    _hangSeen = false;
    if (_torchActual) {
      try {
        await _guard('setTorch(off)', s.setTorch(false), const Duration(seconds: 4));
      } catch (_) {}
      _setTorchActual(false, reason);
    }
    try {
      if (s.isStreaming) {
        await _guard('stopStream', s.stopStream(), const Duration(seconds: 4));
      }
    } catch (_) {}
    try {
      await _guard('dispose', s.dispose(), const Duration(seconds: 8));
    } catch (e) {
      _log(LogDirection.error, 'Gagal matiin kamera: $e');
    }
    _session = null;
    _closing = false;
    _errorSeen = false;
    _lastClosedAt = DateTime.now();
    // Ada panggilan yang macet: beri jeda ekstra sebelum buka ulang.
    if (_hangSeen) _lastInitFailAt = DateTime.now();
    _event('cam_close', {'reason': reason});
    _log(LogDirection.info, 'Kamera dimatikan total ($reason)');
    _notifyState();
  }

  void _onSessionError(String description) {
    if (_disposed || _closing || _session == null || _errorSeen) return;
    _errorSeen = true;
    _log(LogDirection.error, 'Controller kamera error: $description');
    _dropReason = 'controller_error';
    _raise('init_failed', {
      'reason': 'controller_error',
      'err': description,
    }, event: false);
    _schedule(); // buang controller mati; buka ulang (bila masih perlu) lewat gap
  }

  // ======================================================================
  // STREAM / TORCH / LOCK
  // ======================================================================

  Future<void> _startStream(CameraSession s) async {
    _streamStartedAt = DateTime.now();
    _lastFrameAt = null;
    _blackSince = null;
    _reportedStall = false;
    _reportedBlack = false;
    try {
      final ok = await _guard(
        'startStream',
        s.startStream(_onRawImage),
        const Duration(seconds: 8),
      );
      if (!ok) _streamStartedAt = null;
    } catch (e) {
      _streamStartedAt = null;
      _log(LogDirection.error, 'Gagal start image stream: $e');
    }
  }

  Future<void> _stopStream(CameraSession s) async {
    try {
      await s.stopStream();
    } catch (e) {
      _log(LogDirection.error, 'Gagal stop image stream: $e');
    }
    _streamStartedAt = null;
    _lastFrameAt = null;
    _blackSince = null;
  }

  Future<void> _syncTorch(CameraSession s) async {
    final want = _wantTorch;
    if (want == _torchActual) return;
    // Torch berubah saat terkunci: unlock dulu; _syncLock mengunci lagi setelah
    // lockSettle.
    if (_locked) await _setLock(s, false);
    try {
      final ok = await _guard(
        'setTorch',
        s.setTorch(want),
        const Duration(seconds: 5),
      );
      if (ok) _setTorchActual(want, 'apply');
    } catch (e) {
      _log(LogDirection.error, 'Gagal atur flash: $e');
      _event('torch', {'on': want, 'ok': false, 'err': '$e'});
      if (want) _setTorchActual(false, 'failed');
    }
  }

  Future<void> _syncLock(CameraSession s) async {
    if (_lockWanted && !_locked) {
      final t = _torchChangedAt;
      if (t != null) {
        final rem = lockSettle - DateTime.now().difference(t);
        if (rem > Duration.zero) await Future<void>.delayed(rem);
      }
      if (_disposed || !_lockWanted || !identical(_session, s) || _closing) {
        return;
      }
      await _setLock(s, true);
    } else if (!_lockWanted && _locked) {
      await _setLock(s, false);
    }
  }

  Future<void> _setLock(CameraSession s, bool lock) async {
    try {
      await s.setFocusLocked(lock);
    } catch (e) {
      _log(LogDirection.info, 'Kunci fokus tidak didukung: $e');
    }
    try {
      await s.setExposureLocked(lock);
    } catch (e) {
      _log(LogDirection.info, 'Kunci exposure tidak didukung: $e');
    }
    _locked = lock;
    if (lock) {
      _event('cam_lock', null);
      _log(LogDirection.info, 'Fokus & exposure dikunci untuk sesi AI');
    } else {
      _log(LogDirection.info, 'Fokus & exposure dilepas');
    }
  }

  void _setTorchActual(bool v, String why) {
    if (_torchActual == v) return;
    _torchActual = v;
    _torchChangedAt = DateTime.now();
    _event('torch', {'on': v, 'ok': true, 'why': why});
    _log(LogDirection.info, v ? 'Flash menyala' : 'Flash mati ($why)');
    if (!_disposed) onTorchChanged?.call(v);
  }

  // ======================================================================
  // FRAME + WATCHDOG
  // ======================================================================

  void _onRawImage(CameraImage image) {
    if (_disposed || _closing) return;
    final now = DateTime.now();
    _ingest(now, _sampleLuma(image, now));
    if (_selfTest != null || !_wantStream) return;
    onImage(image);
  }

  _LumaStat? _sampleLuma(CameraImage image, DateTime now) {
    if (_lastLumaAt != null &&
        now.difference(_lastLumaAt!) < kLumaSampleEvery) {
      return null;
    }
    _lastLumaAt = now;
    final bytes = image.planes[0].bytes;
    if (bytes.isEmpty) return null;
    double sum = 0, sumSq = 0;
    int n = 0;
    for (int i = 0; i < bytes.length; i += kLumaSampleStep) {
      final v = bytes[i];
      sum += v;
      sumSq += v * v;
      n++;
    }
    final mean = sum / n;
    final variance = math.max(0.0, sumSq / n - mean * mean);
    return _LumaStat(mean, math.sqrt(variance));
  }

  void _ingest(DateTime now, _LumaStat? stat) {
    _lastFrameAt = now;
    final acc = _selfTest;
    if (acc != null) {
      acc.frames++;
      if (stat != null) {
        acc.n++;
        acc.sumMean += stat.mean;
        acc.sumStd += stat.std;
      }
    }
    if (_reportedStall) {
      _reportedStall = false;
      _recovered('stall', stat);
    }
    if (stat != null) {
      _lastLumaMean = stat.mean;
      _lastLumaStd = stat.std;
      final black = stat.mean < kBlackMeanMax && stat.std < kBlackStdMax;
      if (black) {
        _blackSince ??= now;
      } else {
        _blackSince = null;
        if (_reportedBlack) {
          _reportedBlack = false;
          _recovered('black', stat);
        }
      }
    }
  }

  /// Hanya untuk tes: suntik statistik frame tanpa CameraImage.
  @visibleForTesting
  void debugIngestFrame({
    required double luma,
    double std = 20,
    DateTime? at,
  }) {
    _ingest(at ?? DateTime.now(), _LumaStat(luma, std));
  }

  void _syncWatchdog() {
    if (_disposed || !_wantStream) {
      _watchdog?.cancel();
      _watchdog = null;
      return;
    }
    _watchdog ??= Timer.periodic(watchdogPeriod, (_) => _watchdogTick());
  }

  void _watchdogTick() {
    if (_disposed || !_wantStream) return;
    final idle = !_applyRunning && _pendingApply == null;
    final s = _session;

    // Kamera belum terbuka (mis. init gagal sebelumnya): lanjutkan percobaan.
    // _waitBeforeOpen menjaga jarak >= initRetryGap. Ini bukan re-init karena
    // black/stall, hanya percobaan buka yang memang belum berhasil.
    if (s == null) {
      if (idle) _schedule();
      return;
    }
    if (_closing) return;
    // Stream seharusnya jalan tapi tidak (start gagal / berhenti di background).
    if (!s.isStreaming) {
      if (idle) _schedule();
      return;
    }

    final started = _streamStartedAt;
    if (started == null) return;
    final now = DateTime.now();
    if (now.difference(started) < watchdogQuiet) return;

    final ref = _lastFrameAt ?? started;
    if (now.difference(ref) > stallAfter && !_reportedStall) {
      _reportedStall = true;
      _raise('stall', {'silent_ms': now.difference(ref).inMilliseconds});
    }
    final bs = _blackSince;
    if (bs != null && now.difference(bs) >= blackFor && !_reportedBlack) {
      _reportedBlack = true;
      _raise('black', {
        'luma': _lastLumaMean,
        'std': _lastLumaStd,
        'secs': now.difference(bs).inSeconds,
      });
    }
  }

  void _raise(String kind, Map<String, dynamic> data, {bool event = true}) {
    _restartRecommended = true;
    if (event) _event('cam_$kind', data);
    _log(LogDirection.error, 'Masalah kamera: $kind $data');
    if (!_disposed) onIssue?.call(kind, data);
  }

  void _recovered(String kind, _LumaStat? stat) {
    _event('cam_ok', {'from': kind, 'luma': stat?.mean, 'std': stat?.std});
    _log(LogDirection.info, 'Kamera pulih sendiri dari $kind');
    if (!_disposed) onRecovered?.call();
  }

  // ======================================================================
  // SELF-TEST
  // ======================================================================

  Future<CameraSelfTestResult> _runSelfTest(
    Duration duration,
    bool useTorch,
  ) async {
    final sw = Stopwatch()..start();
    CameraSelfTestResult fail(String reason, {int frames = 0}) =>
        CameraSelfTestResult(
          ok: false,
          frames: frames,
          elapsedMs: sw.elapsedMilliseconds,
          reason: reason,
        );

    if (_disposed) return fail('disposed');
    if (_wantCamera || _session != null || _selfTest != null) {
      return fail('busy');
    }

    final acc = _SelfTestAcc();
    _selfTest = acc;
    try {
      final err = await _openSession(force: true, report: false);
      if (err != null) return fail('open_failed: $err');
      final s = _session!;
      if (useTorch) {
        try {
          await s.setTorch(true);
          _setTorchActual(true, 'selftest');
        } catch (e) {
          _log(LogDirection.error, 'Self-test: gagal atur flash: $e');
        }
      }
      try {
        await s.startStream(_onRawImage);
      } catch (e) {
        return fail('stream_failed: $e');
      }
      await Future<void>.delayed(duration);
      try {
        await s.stopStream();
      } catch (_) {}

      final mean = acc.n > 0 ? acc.sumMean / acc.n : null;
      final std = acc.n > 0 ? acc.sumStd / acc.n : null;
      String? reason;
      if (acc.frames < kSelfTestMinFrames) {
        reason = 'no_frames';
      } else if (mean != null &&
          std != null &&
          mean < kBlackMeanMax &&
          std < kBlackStdMax) {
        reason = 'black';
      }
      final res = CameraSelfTestResult(
        ok: reason == null,
        frames: acc.frames,
        elapsedMs: sw.elapsedMilliseconds,
        meanLuma: mean,
        stdLuma: std,
        reason: reason,
      );
      _log(LogDirection.info, 'Self-test kamera: $res');
      return res;
    } finally {
      await _closeSession('selftest');
      _selfTest = null;
    }
  }

  // ======================================================================
  // UTIL
  // ======================================================================

  void _log(LogDirection d, String msg) {
    if (_disposed) return;
    onLog?.call(d, 'CAM', msg);
  }

  void _event(String name, Map<String, dynamic>? data) {
    if (_disposed) return;
    onEvent?.call(name, data);
  }

  void _notifyState() {
    if (_disposed) return;
    onStateChanged?.call();
  }
}
