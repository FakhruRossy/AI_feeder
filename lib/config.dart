import 'package:shared_preferences/shared_preferences.dart';

/// Semua parameter yang bisa di-tune tanpa perlu rebuild app.
///
/// PENTING (v3): logika lanjut/stop sekarang berbasis RASIO antar putaran
/// (lihat feeder_trigger.dart), bukan ambang angka mutlak. Parameter di sini
/// semuanya berupa rasio/durasi, jadi tidak ikut berubah saat skala skor
/// kamera berubah (siang/malam, air jernih/keruh). Default awal diturunkan
/// dari 3 sesi uji (18 putaran) dan MASIH PROVISIONAL -- jalankan replay
/// offline (replay_trigger.py) pada rekaman baru sebelum dibekukan.
/// Kunci calib yang dikenali: ratio_ok, ratio_hard, strikes_to_stop,
/// snr_min, baseline_skip_s, baseline_max_s, baseline_min_s, ema_tau_s,
/// round_win_start_s, round_win_end_s, median_window, processing_fps,
/// keepalive_s, screen_timeout_s, live_cam_interval_s.
/// TAIL (rev): dua kunci calib baru (TIDAK menaikkan _calibVersion):
///   - tail_record_s (number): lama tail recording dalam detik. 0 = tail
///     mati (perilaku lama). Nilai > 0 di-clamp ke [tailMin, tailMax] via
///     clampTail(). Diterapkan di feeding_screen._applyCalib.
///   - tail_cancel (int, seq naik): pembatalan tail dari webapp, dedup
///     dengan pola yang sama seperti label_cmd.seq/_lastLabelSeq --
///     feeding_screen menyimpan _lastTailCancelSeq dan hanya memproses
///     seq yang lebih besar dari sebelumnya.
/// 🟢 REVISI (P1 / SPEC 4): kunci calib opsional baru (TIDAK menaikkan
/// _calibVersion, TIDAK disimpan ke prefs -- key tidak ada = default J2):
///   - flash_timeout_s (default 600, clamp 30..3600): batas nyala flash manual.
///   - flash_renew (int, naik): mereset timer flash manual (runtime saja).
///   - flash_auto_session (bool, default false): flash nyala otomatis selama sesi.
///   - live_cam_max_min (default 30, clamp 0..240; 0 = tanpa batas).
/// Kunci lama (decay_ratio, min_peak, debounce_s, startup_timeout_s,
/// round_ratio, activity_floor) sudah TIDAK dipakai dan diabaikan.
///
/// CATATAN ARSITEKTUR (revisi komunikasi):
/// Field `relayBaseUrl` / `relayOnPath` / `relayOffPath` versi lama
/// SUDAH DIHAPUS. Skema sekarang:
///   ESP32 <--Bluetooth classic--> J2 Prime <--WiFi--> Supabase <--> Webapp
/// J2 TIDAK PERNAH mengontrol aktuator lewat HTTP lokal ke ESP. Semua
/// override pompa/feeder/charger dikirim sebagai JSON `ovr` via
/// Bluetooth, karena ESP cuma bisa aktif salah satu antara BT atau WiFi
/// di waktu yang sama, dan yang dipilih adalah BT ke J2.
///
/// CATATAN REVISI #2: `supabaseDeviceInfoTable` (baterai HP) versi lama
/// sudah DIHAPUS -- info device J2 (baterai, suhu, cpu, status BT)
/// sekarang digabung jadi satu payload dengan `supabaseTelemetryTable`,
/// dikirim setiap J2 terima 1 paket dari ESP (bukan timer 60s terpisah).
///
/// CATATAN REVISI #3 (layar): `screenTimeoutSeconds` ditambahkan --
/// dulu hardcode 10 detik di feeding_screen.dart. Sekarang default 15
/// detik, bisa diubah dari Settings screen ATAU dari webapp lewat
/// `calib.screen_timeout_s`. Isi 0 = auto-dark dimatikan. Timer ini juga
/// otomatis NONAKTIF selama Mode Dev aktif.
///
/// TAIL (rev): `tailRecordSeconds` ditambahkan -- lama kamera/AI tetap
/// merekam SETELAH sesi pakan berakhir (aktuator sudah selesai), supaya
/// grafik EMA terlihat turun kembali. 0 = mati (perilaku lama, langsung
/// berhenti total). Durasi efektif yang benar-benar dipakai tetap
/// dihitung di feeding_screen sebagai
/// max(tailRecordSeconds, roundWinEndS + 10).
class FeederConfig {
  static const int _calibVersion = 3;

  /// Putaran dianggap "masih aktif" kalau respon bersih >= ratioOk x acuan.
  double ratioOk;

  /// Di bawah ratioHard x acuan = STOP langsung (jelas kenyang).
  double ratioHard;

  /// Berapa putaran "lemah" (antara ratioHard dan ratioOk) berturut-turut
  /// sebelum STOP.
  int strikesToStop;

  /// Gerbang sinyal putaran acuan: rata-rata jendela harus >= snrMin x
  /// baseline, kalau tidak AI diam (tidak memutuskan).
  double snrMin;

  /// Baseline: abaikan N detik pertama (kamera menstabilkan eksposur),
  /// pakai paling banyak baselineMaxS detik terakhir sebelum pulsa 1, dan
  /// butuh minimal baselineMinS detik data agar dianggap valid.
  double baselineSkipS;
  double baselineMaxS;
  double baselineMinS;

  /// Konstanta waktu EMA (detik). Alpha per frame dihitung dari timestamp:
  /// a = 1 - exp(-dt / tau), jadi tidak bergantung fps efektif.
  double emaTauSeconds;

  /// Jendela evaluasi per putaran, dihitung dari saat feeder BERHENTI:
  /// rata-rata EMA di [roundWinStartS, roundWinEndS] = respon putaran itu.
  /// Keputusan baru ada roundWinEndS detik setelah pulsa berhenti, jadi
  /// `feval` di ESP harus lebih besar dari itu (+ margin).
  double roundWinStartS;
  double roundWinEndS;

  int medianWindow; // ukuran window buat spike-rejection (median filter)

  // "fps virtual" -- pengganti get_video_fps() di kode Python. Kamera HP
  // gak punya fps tetap kayak file video, jadi kita THROTTLE pemrosesan
  // frame ke laju ini sendiri (lihat feeding_screen.dart), lalu
  // durasi dalam detik dikonversi ke frame count pakai
  // angka ini. J2 Prime itu HP low-end (Snapdragon 425) -- 3-5 fps udah
  // lebih dari cukup buat nangkep dinamika makan yang berlangsung
  // puluhan detik, dan jauh lebih ringan buat CPU-nya. Kalau di real
  // device masih berat/lag, turunin ke 2-3.
  double processingFps;

  /// Nama device Bluetooth ESP32. HARUS sama persis dengan
  /// `SerialBT.begin("...")` di firmware (CommsBT.cpp).
  String btDeviceName;

  /// Interval (detik) J2 mengirim ulang `<CMD:LANJUT>` selama keputusan
  /// terakhir AI adalah LANJUT dan putaran berikutnya belum mulai.
  /// (Bukan lagi keep-alive buta: tanpa keputusan LANJUT tidak ada kiriman.)
  double keepAliveSeconds;

  /// Jeda tanpa aktivitas user sebelum layar digelapkan (brightness 0).
  /// 0 = auto-dark OFF. Otomatis diabaikan selama Mode Dev.
  double screenTimeoutSeconds;

  /// Interval (detik) antar frame LIVE-CAM yang dikirim ke webapp lewat
  /// Supabase Realtime Broadcast (lihat live_cam_service.dart). Timer ini
  /// HANYA pernah jalan kalau ada viewer nyambung ke channel-nya -- kalau
  /// tidak ada yang nonton, nilai ini sama sekali tidak berefek apa pun
  /// (nol biaya kuota), berapa pun sesi AI/feeding lagi jalan.
  ///
  /// Bisa diubah dari Settings screen ATAU dari webapp lewat
  /// `calib.live_cam_interval_s` (pola sama seperti ratioOk dkk, lihat
  /// _applyCalib di feeding_screen.dart). DI-CLAMP ke [liveCamIntervalMin]
  /// .. [liveCamIntervalMax] di titik penerapannya -- supaya nilai liar
  /// dari webapp (mis. kesalahan input 0 atau 0.01) TIDAK bisa memaksa
  /// J2 ngirim frame membanjir dan boros kuota/CPU/baterai tanpa sengaja.
  double liveCamIntervalSeconds;

  static const double liveCamIntervalMin = 1.0;
  static const double liveCamIntervalMax = 30.0;

  static double clampLiveCamInterval(double seconds) =>
      seconds.clamp(liveCamIntervalMin, liveCamIntervalMax).toDouble();

  /// TAIL (rev): lama tail recording (detik) SETELAH sesi pakan berakhir.
  /// 0 = tail mati (perilaku lama). Durasi efektif yang benar-benar
  /// dipakai = max(tailRecordSeconds, roundWinEndS + 10) -- dihitung di
  /// feeding_screen, bukan di sini, karena bergantung pada roundWinEndS
  /// saat itu. Bisa diubah dari Settings screen ATAU dari webapp lewat
  /// `calib.tail_record_s`. DI-CLAMP via [clampTail] di titik
  /// penerapannya -- nilai > 0 dipaksa ke [tailMin]..[tailMax], nilai 0
  /// (tail mati) TIDAK ikut diclamp ke tailMin.
  double tailRecordSeconds;

  static const double tailMin = 45.0;
  static const double tailMax = 120.0;

  /// 0 tetap 0 (tail mati). Selain itu di-clamp ke [tailMin]..[tailMax].
  static double clampTail(double seconds) {
    if (seconds <= 0) return 0.0;
    return seconds.clamp(tailMin, tailMax).toDouble();
  }

  /// 🟢 REVISI (P1 / SPEC 3.3, 3.4, 4): nilai runtime dari calib webapp.
  /// SENGAJA tidak ikut load()/save(): tanpa key di calib = default di bawah,
  /// diterapkan di feeding_screen._applyCalib.
  double flashTimeoutSeconds;
  bool flashAutoSession;
  int liveCamMaxMinutes;

  static const double flashTimeoutDefault = 600.0;
  static const double flashTimeoutMin = 30.0;
  static const double flashTimeoutMax = 3600.0;
  static const int liveCamMaxMinDefault = 30;
  static const int liveCamMaxMinCeil = 240;

  static double clampFlashTimeout(double seconds) =>
      seconds.clamp(flashTimeoutMin, flashTimeoutMax).toDouble();

  /// 0 tetap 0 (tanpa batas). Selain itu di-clamp ke 0..[liveCamMaxMinCeil].
  static int clampLiveCamMaxMin(int minutes) =>
      minutes.clamp(0, liveCamMaxMinCeil).toInt();

  /// Berapa baris log traffic terakhir yang disimpan di panel Dev
  /// (lihat dev_log.dart). Dibatasi kecil biar hemat RAM.
  int devLogMaxLines;

  String supabaseTelemetryTable; // data gabungan: sensor ESP + info device J2
  String
  supabaseFeedSessionTable; // status sesi AI CV lokal (state, stop_reason)
  String
  supabaseConfigTable; // config/override/reset/kalibrasi dari webapp (realtime)
  String supabaseRowId;

  // NILAI DEFAULT AI DI BAWAH = PROVISIONAL, dari replay 3 sesi uji
  // (18 putaran, tanpa pompa). processingFps default 8 = fps DASAR perekaman
  // kalibrasi (stride 1/2/4/8); fps efektif nyata sekitar 5,7.
  FeederConfig({
    this.ratioOk = 0.65,
    this.ratioHard = 0.50,
    this.strikesToStop = 2,
    this.snrMin = 2.0,
    this.baselineSkipS = 10.0,
    this.baselineMaxS = 180.0,
    this.baselineMinS = 20.0,
    this.emaTauSeconds = 7.0,
    this.roundWinStartS = 10.0,
    this.roundWinEndS = 40.0,
    this.medianWindow = 5,
    this.processingFps = 8.0,
    this.btDeviceName = 'ESP32_Aquaponics',
    this.keepAliveSeconds = 5.0,
    this.screenTimeoutSeconds = 15.0,
    // Default 3 detik/frame -- cukup buat "ngecek kondisi", masih hemat
    // kuota & CPU. Lihat catatan lengkap di deklarasi field di atas.
    this.liveCamIntervalSeconds = 3.0,
    // TAIL (rev): default 60s, clamp [45, 120], 0 = mati.
    this.tailRecordSeconds = 60.0,
    // 🟢 REVISI (P1): default flash/live-cam (SPEC bagian 4).
    this.flashTimeoutSeconds = flashTimeoutDefault,
    this.flashAutoSession = false,
    this.liveCamMaxMinutes = liveCamMaxMinDefault,
    // Dinaikkan dari 10 -> 150: nilai lama terlalu kecil untuk layar
    // penuh + filter (item 2) -- 10 baris habis dalam hitungan detik saat
    // traffic BT ramai. HP idle sebagian besar waktu, jadi menyimpan ~150
    // baris teks pendek di RAM (bukan disk) masih sangat murah.
    this.devLogMaxLines = 150,
    this.supabaseTelemetryTable = 'device_telemetry',
    this.supabaseFeedSessionTable = 'feeder_status',
    this.supabaseConfigTable = 'device_config',
    this.supabaseRowId = '1',
  });

  static Future<FeederConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    // MIGRASI: parameter AI lama (decay/min_peak/round_ratio/activity_floor,
    // dst) tersimpan di prefs HP. Kalau versi kalibrasi tersimpan < 3,
    // abaikan nilai AI lama dan pakai default baru (berbasis rasio).
    final fresh = (prefs.getInt('calibVersion') ?? 0) < _calibVersion;
    final d = FeederConfig();
    double gd(String k, double def) =>
        fresh ? def : (prefs.getDouble(k) ?? def);
    return FeederConfig(
      ratioOk: gd('ratioOk', d.ratioOk),
      ratioHard: gd('ratioHard', d.ratioHard),
      strikesToStop: fresh
          ? d.strikesToStop
          : (prefs.getInt('strikesToStop') ?? d.strikesToStop),
      snrMin: gd('snrMin', d.snrMin),
      baselineSkipS: gd('baselineSkipS', d.baselineSkipS),
      baselineMaxS: gd('baselineMaxS', d.baselineMaxS),
      baselineMinS: gd('baselineMinS', d.baselineMinS),
      emaTauSeconds: gd('emaTauSeconds', d.emaTauSeconds),
      roundWinStartS: gd('roundWinStartS', d.roundWinStartS),
      roundWinEndS: gd('roundWinEndS', d.roundWinEndS),
      medianWindow: fresh
          ? d.medianWindow
          : (prefs.getInt('medianWindow') ?? d.medianWindow),
      processingFps: gd('processingFps', d.processingFps),
      btDeviceName: prefs.getString('btDeviceName') ?? 'ESP32_Aquaponics',
      keepAliveSeconds: gd('keepAliveSeconds', d.keepAliveSeconds),
      screenTimeoutSeconds: prefs.getDouble('screenTimeoutSeconds') ?? 15.0,
      liveCamIntervalSeconds: clampLiveCamInterval(
        prefs.getDouble('liveCamIntervalSeconds') ?? 3.0,
      ),
      // TAIL (rev): bukan bagian dari migrasi `fresh` -- field baru, tidak
      // ada nilai lama yang perlu dibuang. _calibVersion TIDAK dinaikkan.
      tailRecordSeconds: clampTail(
        prefs.getDouble('tailRecordSeconds') ?? 60.0,
      ),
      devLogMaxLines: prefs.getInt('devLogMaxLines') ?? 150,
      supabaseTelemetryTable:
          prefs.getString('supabaseTelemetryTable') ?? 'device_telemetry',
      supabaseFeedSessionTable:
          prefs.getString('supabaseFeedSessionTable') ?? 'feeder_status',
      supabaseConfigTable:
          prefs.getString('supabaseConfigTable') ?? 'device_config',
      supabaseRowId: prefs.getString('supabaseRowId') ?? '1',
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('ratioOk', ratioOk);
    await prefs.setDouble('ratioHard', ratioHard);
    await prefs.setInt('strikesToStop', strikesToStop);
    await prefs.setDouble('snrMin', snrMin);
    await prefs.setDouble('baselineSkipS', baselineSkipS);
    await prefs.setDouble('baselineMaxS', baselineMaxS);
    await prefs.setDouble('baselineMinS', baselineMinS);
    await prefs.setDouble('emaTauSeconds', emaTauSeconds);
    await prefs.setDouble('roundWinStartS', roundWinStartS);
    await prefs.setDouble('roundWinEndS', roundWinEndS);
    await prefs.setInt('calibVersion', _calibVersion);
    await prefs.setInt('medianWindow', medianWindow);
    await prefs.setDouble('processingFps', processingFps);
    await prefs.setString('btDeviceName', btDeviceName);
    await prefs.setDouble('keepAliveSeconds', keepAliveSeconds);
    await prefs.setDouble('screenTimeoutSeconds', screenTimeoutSeconds);
    await prefs.setDouble('liveCamIntervalSeconds', liveCamIntervalSeconds);
    await prefs.setDouble('tailRecordSeconds', tailRecordSeconds); // TAIL (rev)
    await prefs.setInt('devLogMaxLines', devLogMaxLines);
    await prefs.setString('supabaseTelemetryTable', supabaseTelemetryTable);
    await prefs.setString('supabaseFeedSessionTable', supabaseFeedSessionTable);
    await prefs.setString('supabaseConfigTable', supabaseConfigTable);
    await prefs.setString('supabaseRowId', supabaseRowId);
  }
}
