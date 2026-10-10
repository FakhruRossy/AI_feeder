import 'dart:math' as math;

/// Keputusan untuk SATU putaran pakan (dihitung di akhir jendela evaluasi).
class RoundDecision {
  final int round;

  /// Rata-rata EMA di jendela [roundWinStartS, roundWinEndS] setelah pulsa.
  final double? winMean;

  /// Respon bersih = winMean - baseline (>= 0). Null kalau tidak bisa dihitung.
  final double? response;

  /// Acuan sesi (respon terkuat sejauh ini) SESUDAH putaran ini diproses.
  final double ref;

  /// response / ref. 1.0 untuk putaran acuan. Null kalau tidak ada keputusan.
  final double? ratio;

  /// Jumlah putaran "lemah" berturut-turut SESUDAH putaran ini.
  final int strikes;

  /// anchor | active | weak | sated | sated_hard | weak_signal |
  /// no_baseline | no_data
  final String verdict;

  /// LANJUT | STOP | NONE (NONE = AI tidak memutuskan, ESP pakai fmax/feval).
  final String action;

  final double? baseline;
  final int samples;

  const RoundDecision({
    required this.round,
    required this.winMean,
    required this.response,
    required this.ref,
    required this.ratio,
    required this.strikes,
    required this.verdict,
    required this.action,
    required this.baseline,
    required this.samples,
  });

  static double? _r(double? v, int d) =>
      v == null ? null : double.parse(v.toStringAsFixed(d));

  /// Superset dari format event 'round' versi lama (r, win_mean, ref, ratio,
  /// verdict, n) supaya skrip analisis lama tetap bisa membaca.
  Map<String, dynamic> toJson() => {
    'r': round,
    'win_mean': _r(winMean, 1),
    'resp': _r(response, 1),
    'ref': _r(ref, 1),
    'ratio': _r(ratio, 3),
    'strikes': strikes,
    'verdict': verdict,
    'action': action,
    'base': _r(baseline, 1),
    'n': samples,
  };
}

/// Logika lanjut/stop berbasis RASIO ANTAR PUTARAN (revisi v3).
///
/// Ide: jangan pernah bandingkan dengan angka tetap. Bandingkan respon lele
/// terhadap pakan SEKARANG dengan respon terkuat di sesi YANG SAMA.
/// Skala kamera/cahaya/kekeruhan berbeda tiap hari, tapi rasionya stabil.
///
/// Alur:
///  1. BASELINE: sebelum pulsa pertama, kumpulkan EMA saat kolam "sepi".
///     Baseline = median EMA (jendela terakhir sebelum pulsa 1).
///  2. Tiap putaran: setelah pulsa berhenti, rata-rata EMA di jendela
///     [roundWinStartS, roundWinEndS] dikurangi baseline = respon bersih.
///  3. Putaran pertama yang lolos gerbang sinyal (winMean >= snrMin x
///     baseline) jadi ACUAN. Acuan tidak pernah memutuskan STOP.
///  4. Putaran berikutnya: ratio = respon / acuan.
///       ratio >= ratioOk            -> LANJUT, strikes = 0, acuan = max()
///       ratio <  ratioHard          -> STOP langsung
///       selain itu                  -> strikes + 1; strikes >= strikesToStop
///                                      -> STOP, kalau belum -> LANJUT
///  5. Baseline tidak valid / sinyal lemah -> action NONE (AI diam).
///     Di produksi itu artinya ESP jalan dengan batas fmax/feval-nya sendiri.
///
/// Yang SENGAJA dibuang dari versi lama: decay dalam satu putaran (selalu
/// turun walau lele masih lapar), min_peak/activity_floor mutlak, dan
/// startup_timeout.
///
/// MODE DRY-RUN (dryRun: true): semua dihitung dan dicatat, tapi update()
/// TIDAK pernah mengunci stopped / mengembalikan 'STOP'. Kandidat stop
/// tercatat di wouldStopReason.
///
/// TAIL (rev): mode TAIL RECORDING (enterTail()) sama sekali berbeda dari
/// dryRun secara maksud (dryRun = kalibrasi/uji; tail = sesi sungguhan yang
/// aktuatornya sudah selesai tapi kamera masih merekam pemulihan), tapi
/// secara EFEK pada penguncian/STOP, perlakuannya sama: tidak pernah
/// mengunci `stopped`, tidak pernah mengembalikan 'STOP' ke caller. Frame,
/// EMA, dan jendela evaluasi putaran terakhir tetap diproses dan
/// dituntaskan secara normal selama tail -- hanya efek SAMPING (lock/STOP)
/// yang ditahan.
class FeederTriggerAdaptive {
  final double tauSeconds;
  final int medianWindow;
  final double spikeRejectFactor;
  final double roundWinStartS;
  final double roundWinEndS;
  final double ratioOk;
  final double ratioHard;
  final int strikesToStop;
  final double snrMin;
  final double baselineSkipS;
  final double baselineMaxS;
  final double baselineMinS;
  final bool dryRun;

  FeederTriggerAdaptive({
    this.tauSeconds = 7.0,
    this.medianWindow = 5,
    this.spikeRejectFactor = 3.0,
    this.roundWinStartS = 10.0,
    this.roundWinEndS = 40.0,
    this.ratioOk = 0.65,
    this.ratioHard = 0.50,
    this.strikesToStop = 2,
    this.snrMin = 2.0,
    this.baselineSkipS = 10.0,
    this.baselineMaxS = 180.0,
    this.baselineMinS = 20.0,
    this.dryRun = false,
  }) {
    reset();
  }

  // ---- level sesi ----
  final List<double> _rawBuf = <double>[];
  final List<double> _baseT = <double>[]; // detik sejak frame pertama
  final List<double> _baseE = <double>[];
  double? ema;
  int frameIdx = 0;
  int round = 0;
  double refLevel = 0.0;
  int strikes = 0;
  double? baseline;
  bool baselineValid = false;
  bool _baselineFrozen = false;
  DateTime? _lastT;
  DateTime? _tStart;
  bool stopped = false;
  String? lastStopReason;
  String? wouldStopReason;
  RoundDecision? lastDecision;
  RoundDecision? _pendingDecision;

  // TAIL (rev): true sejak enterTail() dipanggil sampai instance trigger
  // ini dibuang (feeding_screen men-null-kan _trigger di _endTail).
  bool _inTail = false;
  bool get inTail => _inTail;

  // ---- level putaran ----
  double peakRunning = 0.0; // EMA tertinggi sejak putaran ini mulai
  bool _inPulse = false;
  DateTime? _pulseEnd;
  double _winSum = 0.0;
  int _winN = 0;
  bool _evaluated = true;

  /// Reset penuh (awal sesi / awal uji coba).
  void reset() {
    _rawBuf.clear();
    _baseT.clear();
    _baseE.clear();
    ema = null;
    frameIdx = 0;
    round = 0;
    refLevel = 0.0;
    strikes = 0;
    baseline = null;
    baselineValid = false;
    _baselineFrozen = false;
    _lastT = null;
    _tStart = null;
    stopped = false;
    lastStopReason = null;
    wouldStopReason = null;
    lastDecision = null;
    _pendingDecision = null;
    _inTail = false; // TAIL (rev)
    peakRunning = 0.0;
    _inPulse = false;
    _pulseEnd = null;
    _winSum = 0.0;
    _winN = 0;
    _evaluated = true;
  }

  /// TAIL (rev): masuk mode tail. Aktuator sudah selesai (ESP tidak lagi
  /// dikirimi perintah apa pun), tapi kamera/AI tetap merekam. Tidak
  /// mereset apa pun -- acuan sesi, strikes, baseline, dan putaran
  /// terakhir yang masih dalam evaluasi tetap jalan apa adanya.
  void enterTail() {
    _inTail = true;
  }

  // ---- kompatibilitas dengan kolom log lama (tidak perlu ubah tabel) ----
  /// Dulu belowCounter; sekarang = jumlah strike berturut-turut.
  int get belowCounter => strikes;

  /// Dulu peakReached; sekarang = acuan sesi sudah terbentuk.
  bool get peakReached => refLevel > 0;

  /// True selama keputusan terakhir LANJUT dan putaran berikutnya belum
  /// mulai. Dipakai caller untuk keep-alive CMD:LANJUT.
  /// TAIL (rev): selalu false saat tail -- tidak boleh ada keep-alive.
  bool get continueGranted =>
      !_inTail &&
      !stopped &&
      _evaluated &&
      !_inPulse &&
      lastDecision?.action == 'LANJUT';

  /// Fase untuk indikator: tail | idle | baseline | pulse | eval | continue |
  /// stop | no_decision | wait
  /// TAIL (rev): 'tail' punya prioritas di atas 'stop'.
  String get phase {
    if (_inTail) return 'tail';
    if (stopped) return 'stop';
    if (frameIdx == 0) return 'idle';
    if (round == 0 && !_inPulse) return 'baseline';
    if (_inPulse) return 'pulse';
    if (!_evaluated) return 'eval';
    final a = lastDecision?.action;
    if (a == 'LANJUT') return 'continue';
    if (a == 'STOP') return 'stop';
    if (a == 'NONE') return 'no_decision';
    return 'wait';
  }

  /// Feeder mulai berputar (tepi naik relay act.f). EMA, baseline dan acuan
  /// sesi TIDAK di-reset.
  void beginRound(DateTime now) {
    if (!_evaluated) _finishWindow();
    if (round == 0) _freezeBaseline();
    round += 1;
    _inPulse = true;
    _pulseEnd = null;
    _evaluated = true;
    peakRunning = ema ?? 0.0;
  }

  /// Feeder berhenti (tepi turun act.f). Jendela evaluasi dihitung dari sini.
  void pulseEnded(DateTime now) {
    if (round == 0) {
      _freezeBaseline();
      round = 1;
    }
    _inPulse = false;
    _pulseEnd = now;
    _winSum = 0.0;
    _winN = 0;
    _evaluated = false;
  }

  RoundDecision? takeDecision() {
    final d = _pendingDecision;
    _pendingDecision = null;
    return d;
  }

  double _sec(DateTime later, DateTime earlier) =>
      later.difference(earlier).inMicroseconds / 1e6;

  double _median(List<double> src) {
    final buf = [...src]..sort();
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
    final med = _median(_rawBuf);
    if (med > 0 && raw > spikeRejectFactor * med) return med;
    return raw;
  }

  void _freezeBaseline() {
    if (_baselineFrozen) return;
    _baselineFrozen = true;
    if (_baseE.length >= 30 && (_baseT.last - _baseT.first) >= baselineMinS) {
      final m = _median(_baseE);
      baseline = m;
      baselineValid = m > 0;
    } else {
      baseline = null;
      baselineValid = false;
    }
    _baseT.clear();
    _baseE.clear();
  }

  /// Panggil tiap 1 frame yang berhasil diproses, dengan timestamp nyata.
  /// Return 'STOP' atau null (selalu null di dryRun DAN selalu null saat
  /// tail -- lihat TAIL (rev) di bawah).
  String? update(double rawSample, DateTime now) {
    // TAIL (rev): early-return murni ('STOP' terkunci, tidak diproses lagi)
    // HANYA kalau sudah stopped dan BUKAN sedang tail. Selama tail, frame,
    // EMA, dan jendela evaluasi putaran terakhir tetap diproses normal.
    if (stopped && !_inTail) return 'STOP';

    frameIdx += 1;
    _tStart ??= now;
    final filtered = _filterSample(rawSample);

    if (ema == null || _lastT == null) {
      ema = filtered;
    } else {
      final dt = _sec(now, _lastT!).clamp(0.02, 10.0).toDouble();
      final a = 1.0 - math.exp(-dt / tauSeconds);
      ema = a * filtered + (1.0 - a) * ema!;
    }
    _lastT = now;
    if (ema! > peakRunning) peakRunning = ema!;

    if (round == 0 && !_inPulse) {
      final t = _sec(now, _tStart!);
      if (t >= baselineSkipS) {
        _baseT.add(t);
        _baseE.add(ema!);
        while (_baseT.isNotEmpty && t - _baseT.first > baselineMaxS) {
          _baseT.removeAt(0);
          _baseE.removeAt(0);
        }
      }
    }

    final pe = _pulseEnd;
    if (pe != null && !_evaluated) {
      final el = _sec(now, pe);
      if (el >= roundWinStartS) {
        if (el <= roundWinEndS) {
          _winSum += ema!;
          _winN += 1;
        } else {
          _finishWindow();
        }
      }
    }

    final pending = _pendingDecision;
    if (pending != null && pending.action == 'STOP') {
      final reason = 'ai_${pending.verdict}';
      // TAIL (rev): saat tail, keputusan STOP diperlakukan seperti dryRun --
      // dicatat di wouldStopReason, TIDAK PERNAH mengunci `stopped` maupun
      // dikembalikan ke caller. Tidak ada "keputusan STOP baru" yang efektif
      // selama tail.
      if (dryRun || _inTail) {
        wouldStopReason ??= reason;
      } else {
        stopped = true;
        lastStopReason = reason;
        return 'STOP';
      }
    }
    return null;
  }

  void _finishWindow() {
    _evaluated = true;
    final base = baseline;
    double? winMean;
    double? resp;
    double? ratio;
    var verdict = '';
    var action = 'NONE';

    if (_winN == 0) {
      verdict = 'no_data';
    } else if (!baselineValid || base == null) {
      winMean = _winSum / _winN;
      verdict = 'no_baseline';
    } else {
      winMean = _winSum / _winN;
      resp = math.max(0.0, winMean - base);
      if (refLevel <= 0) {
        // Belum ada acuan: putaran ini calon acuan, harus lolos gerbang sinyal.
        if (winMean < snrMin * base || resp <= 0) {
          verdict = 'weak_signal';
        } else {
          refLevel = resp;
          ratio = 1.0;
          verdict = 'anchor';
          action = 'LANJUT';
        }
      } else {
        ratio = resp / refLevel;
        if (ratio >= ratioOk) {
          strikes = 0;
          if (resp > refLevel) refLevel = resp;
          verdict = 'active';
          action = 'LANJUT';
        } else if (ratio < ratioHard) {
          verdict = 'sated_hard';
          action = 'STOP';
        } else {
          strikes += 1;
          if (strikes >= strikesToStop) {
            verdict = 'sated';
            action = 'STOP';
          } else {
            verdict = 'weak';
            action = 'LANJUT';
          }
        }
      }
    }

    final d = RoundDecision(
      round: round,
      winMean: winMean,
      response: resp,
      ref: refLevel,
      ratio: ratio,
      strikes: strikes,
      verdict: verdict,
      action: action,
      baseline: base,
      samples: _winN,
    );
    lastDecision = d;
    _pendingDecision = d;
  }

  /// Buat logging real-time / debug overlay di app.
  Map<String, dynamic> state() => {
    'frame': frameIdx,
    'phase': phase,
    'ema': ema != null ? double.parse(ema!.toStringAsFixed(1)) : null,
    'peak_running': double.parse(peakRunning.toStringAsFixed(1)),
    'round': round,
    'ref': double.parse(refLevel.toStringAsFixed(1)),
    'strikes': strikes,
    'baseline': baseline != null
        ? double.parse(baseline!.toStringAsFixed(1))
        : null,
    'baseline_valid': baselineValid,
    'stopped': stopped,
    'reason': lastStopReason,
    'would_stop': wouldStopReason,
    'tail': _inTail, // TAIL (rev)
  };
}
