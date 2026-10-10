/// Perekam data kalibrasi tingkat-frame.
///
/// Masalah data lama: log 2 detik hanya memuat SATU nilai ai_raw terakhir
/// dan EMA yang sudah menelan frame di antaranya. Jadi spike, median, dan
/// fps efektif tidak bisa direkonstruksi.
///
/// Recorder ini menampung SEMUA frame yang diproses di antara dua upload
/// dan men-dump-nya sebagai satu JSON ringkas ke kolom `ai_diag` (jsonb).
/// Skema (v=1):
/// {
///   "v": 1,
///   "t0": epoch ms frame pertama di jendela ini,
///   "dt": [ms sejak t0 per frame],          // timestamp tiap frame
///   "ms": [durasi proses per frame, ms],    // beban CPU nyata
///   "s1": [...], "s2": [...], "s4": [...], "s8": [...],
///                                            // skor per stride, -1 = n/a
///   "ev": [{"t": epoch ms, "e": nama event, "d": {...}}],
///   "cfg": {...}                             // hanya di flush pertama sesi
/// }
/// Dengan ini, offline bisa dihitung ulang EMA/median/decay untuk fps
/// efektif F, F/2, F/4, F/8 persis dari frame yang sama.
class CalibRecorder {
  static const List<int> strides = [1, 2, 4, 8];

  /// Batas pengaman memori kalau upload macet lama (sekitar 75 dtk @ 8 fps).
  static const int _maxFrames = 600;

  DateTime? _t0;
  final List<int> _dt = <int>[];
  final List<int> _ms = <int>[];
  final Map<int, List<int>> _s = {for (final k in strides) k: <int>[]};
  final List<Map<String, dynamic>> _events = <Map<String, dynamic>>[];
  Map<String, dynamic>? _cfg;

  void reset() {
    _t0 = null;
    _dt.clear();
    _ms.clear();
    for (final k in strides) {
      _s[k]!.clear();
    }
    _events.clear();
    _cfg = null;
  }

  /// Snapshot konfigurasi yang dipakai sesi ini (ikut di flush pertama).
  void setCfg(Map<String, dynamic> cfg) => _cfg = cfg;

  void addEvent(DateTime t, String name, [Map<String, dynamic>? data]) {
    _events.add({
      't': t.millisecondsSinceEpoch,
      'e': name,
      if (data != null) 'd': data,
    });
  }

  void addFrame(DateTime t, Map<int, double> scores, int procMs) {
    _t0 ??= t;
    if (_dt.length >= _maxFrames) {
      _dt.removeAt(0);
      _ms.removeAt(0);
      for (final k in strides) {
        _s[k]!.removeAt(0);
      }
    }
    _dt.add(t.difference(_t0!).inMilliseconds);
    _ms.add(procMs);
    for (final k in strides) {
      _s[k]!.add((scores[k] ?? -1).round());
    }
  }

  /// Ambil semua data sejak flush terakhir lalu kosongkan buffer.
  /// Null kalau tidak ada apa-apa untuk dikirim.
  Map<String, dynamic>? flush() {
    if (_dt.isEmpty && _events.isEmpty && _cfg == null) return null;
    final out = <String, dynamic>{
      'v': 1,
      if (_t0 != null) 't0': _t0!.millisecondsSinceEpoch,
      'dt': List<int>.from(_dt),
      'ms': List<int>.from(_ms),
      for (final k in strides) 's$k': List<int>.from(_s[k]!),
      if (_events.isNotEmpty) 'ev': List<Map<String, dynamic>>.from(_events),
      if (_cfg != null) 'cfg': _cfg,
    };
    _t0 = null;
    _dt.clear();
    _ms.clear();
    for (final k in strides) {
      _s[k]!.clear();
    }
    _events.clear();
    _cfg = null;
    return out;
  }
}
