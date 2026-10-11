// lib/safe_restart.dart
// 🟢 REVISI (P1 / Room 9 / SPEC_P1 bagian 3.6): restart app AMAN saat idle.
//
// Latar belakang (SPEC bagian 2): tutup-buka kamera tidak pernah memulihkan
// layar hitam J2, hanya restart app. Jadi pemulihan = restart proses, tapi
// HANYA saat semuanya idle, dan tidak pernah mendekati jadwal pakan.
//
// Pemicu A : CameraManager.restartRecommended (black/stall/init_failed di
//            sesi) -> restart begitu idle (tail selesai, upload tuntas) dan
//            jadwal pakan berikutnya > 12 menit.
// Pemicu B : self-test kamera T-10 menit sebelum tiap jadwal cfg.ft (jam WIB).
//            Gagal -> restart bila sisa waktu > 6 menit.
// Pengaman : maks 1 restart per 15 menit (SharedPreferences). Tidak ada
//            restart harian. Tidak ada timer sendiri: [tick] dipanggil dari
//            tick _resourceTimer (10 dtk) milik FeedingScreen.
// Ukur     : timestamp (diminta, app mulai, BT tersambung, cfg terkirim)
//            disimpan di SharedPreferences dan ditampilkan lewat [summary].

import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;
import 'package:shared_preferences/shared_preferences.dart';

import 'camera_manager.dart' show CameraSelfTestResult;

// ---------------------------------------------------------------------------
// KONSTANTA (SPEC 3.6; bisa dituning)
// ---------------------------------------------------------------------------

/// Jarak minimum antar restart (pengaman loop).
const Duration kRestartMinGap = Duration(minutes: 15);

/// Pemicu A: jadwal pakan berikutnya harus lebih jauh dari ini.
const Duration kQuietBeforeSchedule = Duration(minutes: 12);

/// Pemicu B: self-test dimulai saat sisa waktu <= ini (T-10).
const Duration kSelfTestLead = Duration(minutes: 10);

/// Pemicu B: restart hanya bila sisa waktu > ini setelah self-test gagal.
const Duration kRestartMinRemain = Duration(minutes: 6);

/// Lama stream saat self-test.
const Duration kSelfTestDuration = Duration(seconds: 8);

/// Asumsi R9: jangan restart dalam jendela ini sesudah jadwal lewat (ESP baru
/// mulai sesi, J2 mungkin belum menerima telemetri fase aktif).
const Duration kJustAfterSchedule = Duration(minutes: 3);

/// Asumsi R9: idle harus terbaca di >= N tick berturut-turut (10 dtk/tick)
/// sebelum restart pemicu A / sebelum self-test dimulai.
const int kIdleStreakNeeded = 2;

/// Asumsi R9: jeda sebelum proses lama dimatikan native dan alarm relaunch
/// menyala (ms). Harus > waktu kill di sisi Kotlin (300 ms).
const int kRelaunchDelayMs = 1500;

/// Asumsi R9: percobaan ulang self-test bila hasilnya 'busy'/'disposed'.
const int kSelfTestBusyRetries = 3;

// ---------------------------------------------------------------------------
// KUNCI SharedPreferences
// ---------------------------------------------------------------------------
const String _kLast = 'p1_rs_last_ms'; // pengaman 15 menit (tidak pernah dihapus)
const String _kReq = 'p1_rs_req_ms'; // restart diminta
const String _kApp = 'p1_rs_app_ms'; // app mulai
const String _kBt = 'p1_rs_bt_ms'; // BT tersambung
const String _kCfg = 'p1_rs_cfg_ms'; // cfg terkirim ke ESP
const String _kReason = 'p1_rs_reason';

// ---------------------------------------------------------------------------
// LAUNCHER (relaunch proses)
// ---------------------------------------------------------------------------

abstract class RestartLauncher {
  /// true = native menerima perintah (proses akan dimatikan sebentar lagi).
  Future<bool> relaunch();
}

/// MethodChannel ke SafeRestartChannel.kt (PendingIntent + AlarmManager lalu
/// proses ditutup). Tanpa dependency pub baru.
class MethodChannelRestartLauncher implements RestartLauncher {
  const MethodChannelRestartLauncher();
  static const MethodChannel _ch = MethodChannel('catfish/safe_restart');

  @override
  Future<bool> relaunch() async {
    try {
      final r = await _ch.invokeMethod<bool>('relaunch', <String, dynamic>{
        'delayMs': kRelaunchDelayMs,
      });
      return r == true;
    } on MissingPluginException {
      return false; // MainActivity belum didaftarkan (lihat HANDOFF_R9)
    } on PlatformException {
      return false;
    }
  }
}

// ---------------------------------------------------------------------------
// PARSER JADWAL cfg.ft (jam WIB)
// ---------------------------------------------------------------------------

class FeedTime {
  const FeedTime(this.hour, this.minute);
  final int hour;
  final int minute;
  @override
  String toString() =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}

class FeedSchedule {
  const FeedSchedule({required this.known, required this.times});

  /// false = `ft` ada tapi formatnya tidak terbaca -> JANGAN restart.
  final bool known;
  final List<FeedTime> times;

  /// Jadwal berikutnya setelah [nowWib] (jam WIB dalam bingkai UTC) + sebelumnya.
  /// null bila tidak ada jadwal.
  DateTime? nextAfter(DateTime nowWib) => _nearest(nowWib, forward: true);
  DateTime? prevBefore(DateTime nowWib) => _nearest(nowWib, forward: false);

  DateTime? _nearest(DateTime nowWib, {required bool forward}) {
    DateTime? best;
    for (final t in times) {
      var c = DateTime.utc(
        nowWib.year,
        nowWib.month,
        nowWib.day,
        t.hour,
        t.minute,
      );
      if (forward) {
        if (!c.isAfter(nowWib)) c = c.add(const Duration(days: 1));
        if (best == null || c.isBefore(best)) best = c;
      } else {
        if (c.isAfter(nowWib)) c = c.subtract(const Duration(days: 1));
        if (best == null || c.isAfter(best)) best = c;
      }
    }
    return best;
  }

  /// Parser toleran (format `ft` belum terdokumentasi di SPEC; TODO verifikasi):
  /// null/[]/'' = tidak ada jadwal (known). List/String "07:00,12:30".
  /// Elemen: "H:MM" "HH:MM" "HH.MM" "HHMM" "H"; angka 0..23 = jam penuh,
  /// 100..2359 (menit<60) = HHMM; [h,m]; {h,m} / {hour,min} / {jam,menit}.
  static FeedSchedule parse(dynamic raw) {
    if (raw == null) return const FeedSchedule(known: true, times: []);
    final items = <dynamic>[];
    if (raw is List) {
      items.addAll(raw);
    } else if (raw is String) {
      for (final p in raw.split(RegExp(r'[,;\s]+'))) {
        if (p.trim().isNotEmpty) items.add(p.trim());
      }
    } else {
      items.add(raw);
    }
    final out = <FeedTime>[];
    for (final it in items) {
      final t = _parseOne(it);
      if (t == null) return const FeedSchedule(known: false, times: []);
      out.add(t);
    }
    return FeedSchedule(known: true, times: out);
  }

  static FeedTime? _parseOne(dynamic it) {
    int? h;
    int? m;
    if (it is String) {
      final s = it.trim();
      final a = RegExp(r'^(\d{1,2})[:.](\d{2})$').firstMatch(s);
      if (a != null) {
        h = int.parse(a.group(1)!);
        m = int.parse(a.group(2)!);
      } else if (RegExp(r'^\d{3,4}$').hasMatch(s)) {
        final v = int.parse(s);
        h = v ~/ 100;
        m = v % 100;
      } else if (RegExp(r'^\d{1,2}$').hasMatch(s)) {
        h = int.parse(s);
        m = 0;
      }
    } else if (it is num) {
      final v = it.toInt();
      if (v >= 0 && v <= 23) {
        h = v;
        m = 0;
      } else if (v >= 100 && v <= 2359) {
        h = v ~/ 100;
        m = v % 100;
      }
    } else if (it is List && it.length == 2 && it[0] is num && it[1] is num) {
      h = (it[0] as num).toInt();
      m = (it[1] as num).toInt();
    } else if (it is Map) {
      num? pick(List<String> keys) {
        for (final k in keys) {
          final v = it[k];
          if (v is num) return v;
        }
        return null;
      }

      h = pick(const ['h', 'hh', 'hour', 'jam'])?.toInt();
      m = (pick(const ['m', 'mm', 'min', 'minute', 'menit']) ?? 0).toInt();
    }
    if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) {
      return null;
    }
    return FeedTime(h, m);
  }
}

// ---------------------------------------------------------------------------
// SCHEDULER
// ---------------------------------------------------------------------------

class SafeRestartScheduler {
  SafeRestartScheduler({
    required this.isIdle,
    required this.getCfg,
    required this.restartRecommended,
    required this.clearRestartRecommended,
    required this.selfTest,
    this.onLog,
    RestartLauncher? launcher,
    DateTime Function()? clock,
  }) : _launcher = launcher ?? const MethodChannelRestartLauncher(),
       _clock = clock ?? DateTime.now;

  /// true = tidak feeding/tail/uji coba/live-cam/flash/preview, rantai upload
  /// kosong, push cfg selesai (diputuskan FeedingScreen).
  final Future<bool> Function() isIdle;

  /// cfg yang dipegang J2 (`_lastCfg`). Kosong = belum diketahui -> jangan restart.
  final Map<String, dynamic> Function() getCfg;
  final bool Function() restartRecommended;
  final void Function() clearRestartRecommended;
  final Future<CameraSelfTestResult> Function(Duration duration) selfTest;
  final void Function(String msg, {bool error})? onLog;

  final RestartLauncher _launcher;
  final DateTime Function() _clock;

  SharedPreferences? _prefs;
  Future<void>? _initFuture;
  bool _busy = false;
  bool _restarting = false;
  bool _disposed = false;
  int _idleStreak = 0;
  int? _testedKeyMs; // jadwal (epoch ms) yang self-test-nya sudah final
  int _busyRetries = 0;
  bool _unknownFtLogged = false;
  bool _noCfgLogged = false;

  // Cache catatan restart terakhir (untuk summary).
  int? _recReq, _recApp, _recBt, _recCfg;
  String? _recReason;

  // ======================================================================
  // INIT + TIMESTAMP
  // ======================================================================

  /// Panggil sekali di initState (fire-and-forget). Menandai "app mulai"
  /// bila app ini hasil restart yang baru diminta (<= 15 menit lalu).
  Future<void> init() => _initFuture ??= _doInit();

  Future<void> _doInit() async {
    try {
      final p = await SharedPreferences.getInstance();
      _prefs = p;
      final now = _clock().millisecondsSinceEpoch;
      final req = p.getInt(_kReq);
      if (req != null && p.getInt(_kApp) == null) {
        final age = now - req;
        if (age >= 0 && age <= kRestartMinGap.inMilliseconds) {
          await p.setInt(_kApp, now);
          _log('Restart: app mulai +${_rel(now, req)} sejak diminta');
        } else {
          _log('Catatan restart basi (${(age / 60000).round()} mnt), tidak dipakai');
        }
      }
      _loadRecord();
    } catch (e) {
      _log('SafeRestart init gagal: $e', error: true);
    }
  }

  void _loadRecord() {
    final p = _prefs;
    if (p == null) return;
    _recReq = p.getInt(_kReq);
    _recApp = p.getInt(_kApp);
    _recBt = p.getInt(_kBt);
    _recCfg = p.getInt(_kCfg);
    _recReason = p.getString(_kReason);
  }

  /// BT tersambung (dipanggil tiap onConnectionChanged(true)). Hanya yang
  /// PERTAMA setelah restart yang dicatat.
  void markBtConnected() => _mark(_kBt, 'BT tersambung');

  /// cfg penuh terkirim ke ESP. Hanya yang PERTAMA setelah restart dicatat.
  void markCfgSent() => _mark(_kCfg, 'cfg terkirim');

  Future<void> _mark(String key, String label) async {
    try {
      await init();
      final p = _prefs;
      if (p == null || _disposed) return;
      final req = p.getInt(_kReq);
      if (req == null || p.getInt(_kApp) == null || p.getInt(key) != null) {
        return;
      }
      final now = _clock().millisecondsSinceEpoch;
      final age = now - req;
      if (age < 0 || age > kRestartMinGap.inMilliseconds) return;
      await p.setInt(key, now);
      _loadRecord();
      _log('Restart: $label +${_rel(now, req)} sejak diminta');
    } catch (e) {
      _log('SafeRestart mark gagal: $e', error: true);
    }
  }

  /// Ringkasan restart terakhir (satu string; untuk baris panel Dev).
  String get summary {
    final req = _recReq;
    if (req == null) return 'belum ada restart';
    String f(int? t) => t == null ? '-' : '+${_rel(t, req)}';
    return '${_fmtWib(req)} WIB (${_recReason ?? '?'}) | '
        'app ${f(_recApp)} | BT ${f(_recBt)} | cfg ${f(_recCfg)}';
  }

  /// Tulis ulang ringkasan ke Dev Log (mis. saat mode Dev diaktifkan, karena
  /// log hanya direkam saat mode Dev).
  void logSummary() => _log('Restart terakhir: $summary');

  void dispose() => _disposed = true;

  // ======================================================================
  // TICK (dipanggil dari _resourceTimer, 10 dtk)
  // ======================================================================

  Future<void> tick() async {
    if (_busy || _restarting || _disposed) return;
    _busy = true;
    try {
      await init();
      await _tick();
    } catch (e) {
      _log('SafeRestart tick error: $e', error: true);
    } finally {
      _busy = false;
    }
  }

  DateTime _nowWib() => _clock().toUtc().add(const Duration(hours: 7));

  Future<void> _tick() async {
    final cfg = getCfg();
    if (cfg.isEmpty) {
      _idleStreak = 0;
      if (!_noCfgLogged && restartRecommended()) {
        _noCfgLogged = true;
        _log('Restart ditahan: cfg belum diketahui (jadwal tak terbaca)');
      }
      return;
    }
    final sched = FeedSchedule.parse(cfg['ft']);
    if (!sched.known) {
      _idleStreak = 0;
      if (!_unknownFtLogged) {
        _unknownFtLogged = true;
        _log(
          'Restart ditahan: format cfg.ft tidak terbaca (${cfg['ft']})',
          error: true,
        );
      }
      return;
    }

    final nowWib = _nowWib();
    final next = sched.nextAfter(nowWib);
    final prev = sched.prevBefore(nowWib);
    final until = next?.difference(nowWib); // null = tidak ada jadwal
    final since = prev == null ? null : nowWib.difference(prev);

    if (!await isIdle()) {
      _idleStreak = 0;
      return;
    }
    _idleStreak++;
    if (since != null && since < kJustAfterSchedule) return;

    final recommended = restartRecommended();

    // ---- Pemicu A ----
    if (recommended &&
        _idleStreak >= kIdleStreakNeeded &&
        (until == null || until > kQuietBeforeSchedule)) {
      await _doRestart('cam_recommended');
      return;
    }

    // ---- Pemicu B (jendela T-10 .. T-6) ----
    if (next == null || until == null) return;
    if (until > kSelfTestLead || until <= kRestartMinRemain) return;
    final key = next.millisecondsSinceEpoch;
    if (_testedKeyMs == key) return;

    if (recommended) {
      // Kamera sudah ditandai bermasalah di sesi: setara self-test gagal.
      _testedKeyMs = key;
      _log('T-${until.inMinutes} mnt: kamera sudah ditandai bermasalah');
      await _doRestart('cam_recommended_t10');
      return;
    }
    if (_idleStreak < kIdleStreakNeeded) return;

    _log('Self-test kamera T-${until.inMinutes} mnt (jadwal $next WIB)');
    final res = await selfTest(kSelfTestDuration);
    if (_disposed) return;
    if (res.reason == 'busy' || res.reason == 'disposed') {
      // Tidak konklusif: ulangi di tick berikut, dengan batas.
      if (++_busyRetries >= kSelfTestBusyRetries) {
        _testedKeyMs = key;
        _busyRetries = 0;
        _log('Self-test dilewati: manager sibuk berulang kali');
      }
      return;
    }
    _busyRetries = 0;
    _testedKeyMs = key;
    if (res.ok) {
      _log('Self-test OK: $res');
      return;
    }
    _log('Self-test GAGAL: $res', error: true);

    // Keputusan dibuat ulang dengan kondisi TERKINI.
    final until2 = next.difference(_nowWib());
    if (until2 <= kRestartMinRemain) {
      _log('Restart dibatalkan: sisa ${until2.inMinutes} mnt <= 6 mnt');
      return;
    }
    if (!await isIdle()) {
      _log('Restart dibatalkan: tidak idle lagi setelah self-test');
      return;
    }
    await _doRestart('selftest_failed');
  }

  // ======================================================================
  // EKSEKUSI RESTART
  // ======================================================================

  Future<void> _doRestart(String reason) async {
    if (_restarting || _disposed) return;
    final p = _prefs;
    if (p == null) {
      _log('Restart ditahan: SharedPreferences belum siap', error: true);
      return;
    }
    final nowMs = _clock().millisecondsSinceEpoch;
    final last = p.getInt(_kLast);
    if (last != null) {
      final gap = nowMs - last;
      if (gap >= 0 && gap < kRestartMinGap.inMilliseconds) {
        _log(
          'Restart ($reason) ditahan: restart terakhir '
          '${(gap / 60000).toStringAsFixed(1)} mnt lalu (< 15 mnt)',
        );
        return;
      }
    }

    _restarting = true; // blokir semua tick selama proses mati
    try {
      await p.setInt(_kLast, nowMs);
      await p.setInt(_kReq, nowMs);
      await p.setString(_kReason, reason);
      await p.remove(_kApp);
      await p.remove(_kBt);
      await p.remove(_kCfg);
      _loadRecord();
      _log('RESTART app diminta ($reason)');
      final ok = await _launcher.relaunch();
      if (ok) {
        clearRestartRecommended();
        return; // proses dimatikan native sebentar lagi; _restarting tetap true
      }
      _log('Relaunch native gagal (MainActivity belum didaftarkan?)', error: true);
      await p.remove(_kReq);
      await p.remove(_kReason);
      _loadRecord();
    } catch (e) {
      _log('Restart gagal: $e', error: true);
    }
    _restarting = false;
  }

  // ======================================================================
  // UTIL
  // ======================================================================

  void _log(String msg, {bool error = false}) {
    if (_disposed) return;
    final cb = onLog;
    if (cb != null) cb(msg, error: error);
  }

  static String _rel(int t, int req) =>
      '${((t - req) / 1000).toStringAsFixed(1)}s';

  static String _fmtWib(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(
      ms,
      isUtc: true,
    ).add(const Duration(hours: 7));
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }
}
