import 'package:shared_preferences/shared_preferences.dart';

/// Semua parameter yang bisa di-tune tanpa perlu rebuild app.
///
/// PENTING: decayRatio & minPeak default di bawah ini adalah hasil
/// kalibrasi dari webcam TETAP 720p (lihat phase_calibration_fixed.py).
/// Kamera HP (resolusi/FOV/jarak/goyangan tangan beda) HAMPIR PASTI
/// butuh angka yang berbeda. Jangan asumsikan default ini langsung
/// benar -- rekam sesi makan beberapa kali dulu, amati EMA & peak yang
/// ke-log, baru sesuaikan lewat Settings screen di app.
class FeederConfig {
  double decayRatio;
  double minPeak;
  double debounceSeconds;
  double startupTimeoutSeconds;
  double emaAlpha;
  int medianWindow; // ukuran window buat spike-rejection (median filter)

  // "fps virtual" -- pengganti get_video_fps() di kode Python. Kamera HP
  // gak punya fps tetap kayak file video, jadi kita THROTTLE pemrosesan
  // frame ke laju ini sendiri (lihat feeding_screen.dart), lalu
  // debounceSeconds/startupTimeoutSeconds di-convert ke frame count pakai
  // angka ini. J2 Prime itu HP low-end (Snapdragon 425) -- 3-5 fps udah
  // lebih dari cukup buat nangkep dinamika makan yang berlangsung
  // puluhan detik, dan jauh lebih ringan buat CPU-nya. Kalau di real
  // device masih berat/lag, turunin ke 2-3.
  double processingFps;

  String relayBaseUrl;
  String relayOnPath;
  String relayOffPath;

  String supabaseTable;
  String supabaseRowId;

  FeederConfig({
    this.decayRatio = 0.217,
    this.minPeak = 633.4,
    this.debounceSeconds = 4.0,
    this.startupTimeoutSeconds = 15.0,
    this.emaAlpha = 0.15,
    this.medianWindow = 5,
    this.processingFps = 4.0,
    this.relayBaseUrl = 'http://192.168.1.50', // GANTI ke IP relay kalian
    this.relayOnPath = '/relay/on',
    this.relayOffPath = '/relay/off',
    this.supabaseTable = 'feeder_status',
    this.supabaseRowId = '1',
  });

  static Future<FeederConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    return FeederConfig(
      decayRatio: prefs.getDouble('decayRatio') ?? 0.217,
      minPeak: prefs.getDouble('minPeak') ?? 633.4,
      debounceSeconds: prefs.getDouble('debounceSeconds') ?? 4.0,
      startupTimeoutSeconds: prefs.getDouble('startupTimeoutSeconds') ?? 15.0,
      emaAlpha: prefs.getDouble('emaAlpha') ?? 0.15,
      medianWindow: prefs.getInt('medianWindow') ?? 5,
      processingFps: prefs.getDouble('processingFps') ?? 4.0,
      relayBaseUrl: prefs.getString('relayBaseUrl') ?? 'http://192.168.1.50',
      relayOnPath: prefs.getString('relayOnPath') ?? '/relay/on',
      relayOffPath: prefs.getString('relayOffPath') ?? '/relay/off',
      supabaseTable: prefs.getString('supabaseTable') ?? 'feeder_status',
      supabaseRowId: prefs.getString('supabaseRowId') ?? '1',
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('decayRatio', decayRatio);
    await prefs.setDouble('minPeak', minPeak);
    await prefs.setDouble('debounceSeconds', debounceSeconds);
    await prefs.setDouble('startupTimeoutSeconds', startupTimeoutSeconds);
    await prefs.setDouble('emaAlpha', emaAlpha);
    await prefs.setInt('medianWindow', medianWindow);
    await prefs.setDouble('processingFps', processingFps);
    await prefs.setString('relayBaseUrl', relayBaseUrl);
    await prefs.setString('relayOnPath', relayOnPath);
    await prefs.setString('relayOffPath', relayOffPath);
    await prefs.setString('supabaseTable', supabaseTable);
    await prefs.setString('supabaseRowId', supabaseRowId);
  }
}
