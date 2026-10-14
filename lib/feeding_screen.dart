// ini feeding_screen.dart
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:battery_plus/battery_plus.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:screen_brightness/screen_brightness.dart';

import 'config.dart';
import 'motion_energy.dart';
import 'feeder_trigger.dart';
import 'calib_recorder.dart';
import 'supabase_service.dart';
import 'settings_screen.dart';
import 'bluetooth_service.dart';
import 'telemetry_packet.dart';
import 'dev_log.dart';
import 'live_cam_service.dart';
import 'camera_manager.dart'; // 🟢 REVISI (P1): pemilik tunggal CameraController
import 'safe_restart.dart'; // 🟢 REVISI (P1/R9): restart app aman saat idle

/// CATATAN REVISI ARSITEKTUR & FITUR (lihat instruksi user untuk detail):
/// 1. Mode Normal/Dev (SegmentedButton) -- panel Dev nampilin log traffic
///    BT & Supabase (max `config.devLogMaxLines` baris, dibuang otomatis),
///    nilai mentah ESP, RAM/CPU/suhu J2, tombol reset/factory ESP, kamera
///    override manual, dan uji coba AI. Log HANYA direkam saat mode Dev
///    aktif (hemat resource di mode Normal).
/// 2. Auto-reconnect BT tiap 15s ditangani di dalam BluetoothService
///    sendiri (non-blocking), tap ikon BT tetap memicu percobaan instan.
/// 3. Tidak ada lagi timer baterai 60s terpisah -- baterai, suhu, cpu,
///    status BT digabung ke payload yang sama dengan upload telemetry,
///    dikirim tiap kali 1 paket utuh diterima dari ESP (mengikuti
///    interval `cfg.up` milik ESP, yang bisa diubah dari webapp).
///    Upload di-serialize lewat _uploadChain supaya gak ada race/bentrok
///    kalau paket datang beruntun (mis. saat force_bt_send).
/// 4. Kamera TIDAK auto-init saat idle -- baru dinyalakan saat memang
///    dibutuhkan (feeding / override manual dev / uji coba AI), dan
///    di-dispose total begitu tidak dibutuhkan lagi, supaya HP gak
///    panas/berat. Container kamera di UI tetap di tempat yang sama,
///    cuma isinya "Kamera OFF" saat idle.
/// 5. Auto-dark setelah `config.screenTimeoutSeconds` detik (default 15s,
///    dulu 10s) tanpa AKTIVITAS user. "Aktivitas" sekarang = SEMUA event
///    pointer (tap, drag/scroll jari, pointer move/up) + ScrollNotification,
///    ditangkap pakai Listener + NotificationListener -- bukan lagi cuma
///    GestureDetector.onTap. Ini memperbaiki bug layar mati saat user
///    lagi scroll (drag dimenangkan arena gesture-nya oleh scrollable,
///    jadi onTap tidak pernah terpanggil).
///    Auto-dark DIMATIKAN TOTAL saat Mode Dev (layar wajib tetap terang
///    buat baca log). Tombol "Hemat Baterai" manual tetap jalan di dua
///    mode. Transisi Idle->Feed otomatis TIDAK menerangkan layar gelap.
/// 6. Uji Coba AI (mode Dev) -- nyalain kamera & jalanin motion-energy
///    loop tanpa batas waktu dan TANPA kirim command ke ESP, sampai
///    ditekan "Selesai".
/// 7. WakelockPlus.enable() dipanggil sekali di initState dan TIDAK
///    pernah di-disable selama app hidup (CPU gak boleh tidur, supaya
///    comms BT & Supabase tetap jalan walau layar gelap).
class FeedingScreen extends StatefulWidget {
  final FeederConfig config;
  const FeedingScreen({super.key, required this.config});

  @override
  State<FeedingScreen> createState() => _FeedingScreenState();
}

class _FeedingScreenState extends State<FeedingScreen>
    with WidgetsBindingObserver {
  // 🟢 REVISI (P1): CameraController dimiliki CameraManager (_cam), bukan layar ini.
  late final CameraManager _cam;
  final _extractor = MotionEnergyExtractor();
  FeederTriggerAdaptive? _trigger;

  /// Perekam data tingkat-frame untuk kalibrasi (kolom ai_diag).
  final _recorder = CalibRecorder();

  /// Status relay feeder dari paket telemetri sebelumnya, buat deteksi tepi
  /// (naik = mulai putaran, turun = pulsa selesai -> jendela evaluasi mulai).
  bool? _lastFeederRelay;

  // Upload data kalibrasi (tabel ai_diag_log), JALUR TERPISAH dari telemetri
  // ESP: timer sendiri tiap 2 dtk, tidak menunggu paket ESP dan tidak
  // bergantung cfg.up. Backlog menahan data kalau upload gagal/lambat.
  Timer? _diagTimer;
  bool _diagBusy = false;
  final List<Map<String, dynamic>> _diagBacklog = <Map<String, dynamic>>[];
  static const int _diagBacklogMax = 300;
  bool _camLogged = false;
  Timer? _camLockTimer;

  late FeederSupabaseService _supabase;
  late BluetoothService _btService;
  final Battery _battery = Battery();
  late DevLogBuffer _devLog;
  late LiveCamService _liveCam;

  // 🟢 REVISI (P1/R9 / SPEC 3.6): restart app hanya saat idle. Tanpa timer
  // baru: scheduler dipanggil dari tick _resourceTimer (10 dtk).
  late final SafeRestartScheduler _restart;
  int _cfgPushing = 0; // >0 = _pushFullConfigToEsp sedang berjalan

  bool _isDevMode = false;
  bool _isFeeding = false;
  bool _isAiTestMode = false;
  int? _trialSessionId;
  DateTime? _trialStartedAt;
  int? _trialDurationMin;
  Timer? _trialLogTimer;
  Timer? _trialDurationTimer;
  // ---------------------------------------------------------------------
  // FLASH (torch) -- dua sumber, satu efek:
  //   _flashManual : dinyalakan user (tombol di app J2 ATAU webapp flash_on).
  //   _flashAuto   : dinyalakan otomatis selama SESI PAKAN (ovr maupun RTC,
  //                  karena keduanya lewat _startFeeding) + tail-nya.
  // Torch fisik nyala kalau salah satunya true. Mematikan dari tombol/web
  // membatalkan KEDUANYA (user selalu menang). Uji Coba AI, live-cam, dan
  // kamera off TIDAK menyalakan flash otomatis -- murni manual.
  // ---------------------------------------------------------------------
  bool _flashManual = false;
  bool _flashAuto = false;
  bool get _flashOn => _flashManual || _flashAuto;
  bool _cameraForcedOn = false;

  // ---------------------------------------------------------------------
  // KAMERA (🟢 REVISI P1): antrean/watchdog/restart lama dipindah ke
  // CameraManager. Di sini tinggal jembatan sesi + penanda dispose.
  // ---------------------------------------------------------------------
  bool _sessionStarting = false; // jembatan antar _endTail -> _startFeeding
  bool _disposing = false;

  // 🟢 REVISI (P1 / SPEC 3.3): bookkeeping flash MANUAL. Tanpa timer baru:
  // timeout dicek di tick _resourceTimer (10 dtk) yang sudah ada.
  DateTime? _flashManualSince; // kapan flash manual mulai / terakhir di-renew
  bool _flashViewerSeen =
      false; // ada viewer live-cam selagi flash manual nyala
  bool _flashOffDirty = false; // tulis flash_on=false ke DB gagal -> ulangi
  int _lastFlashRenew = 0; // dedup calib.flash_renew (seq naik)
  // 🟢 REVISI (P1 / SPEC 3.2): jenis masalah kamera yang SUDAH ditulis ke
  // feeder_status pada sesi ini (sekali per jenis per sesi).
  final Set<String> _camIssueReported = <String>{};

  Timer? _liveCamOffTimer;
  bool _btStatusDirty = false;
  bool _btStatusLast = false;
  bool _isProcessingFrame = false;
  bool _isBtConnected = false;
  DateTime? _lastProcessedAt;

  // ---------------------------------------------------------------------
  // LIVE-CAM (lihat live_cam_service.dart)
  //
  // _isLiveCamActive HANYA pernah di-set lewat _onLiveCamWatchersChanged,
  // yang HANYA dipanggil LiveCamService saat presence viewer benar-benar
  // berubah -- bukan flag yang bisa dipicu manual dari UI J2, dan bukan
  // pesan start/stop yang bisa "gak sampai". Jadi satu-satunya cara flag
  // ini ON adalah: ada viewer nyambung SEKARANG ke channel-nya. Begitu
  // viewer terakhir putus (tab ditutup/koneksi hilang/apa pun), Supabase
  // sendiri yang men-trigger presence "leave" -> flag ini otomatis balik
  // ke false tanpa J2 perlu tahu ALASAN putusnya. Ini yang mencegah bug
  // "kamera nyangkut nyala ngirim ke channel kosong selamanya".
  bool _isLiveCamActive = false;
  bool _isEncodingLiveCamFrame = false;
  DateTime? _lastLiveCamSentAt;

  double _lastEma = 0;
  double _lastPeak = 0;
  String _statusText = 'Idle';

  TelemetryPacket? _lastTelemetry;

  // 🟢 FIX BUG "STOP prematur sebelum putaran ke-2/3 dst": FeederTriggerAdaptive
  // (lihat feeder_trigger.dart) cuma direset SEKALI di awal sesi (_startFeeding),
  // jadi peak/decay-nya dihitung terus-menerus untuk SELURUH sesi multi-putaran --
  // begitu EMA turun sebentar (jeda alami antar-putaran: pelet jatuh, lele sadar,
  // baru EMA naik lagi), trigger salah baca itu sebagai "sesi selesai" dan langsung
  // kirim CMD:STOP walau masih ada sisa putaran (fmax) di ESP.
  //
  // Fix: J2 melacak fd.cnt (jumlah putaran, lihat FeederTelemetry.count) dari
  // telemetri ESP. Begitu angkanya NAIK dibanding paket sebelumnya, itu tandanya
  // ESP baru saja memulai putaran motor feed berikutnya (setelah CMD:LANJUT kita
  // diterima & diproses ESP) -- J2 me-reset _trigger supaya babak startup_timeout
  // (nunggu lele sadar & EMA membentuk peak baru) dan decay-detection-nya mulai
  // fresh lagi untuk putaran itu, bukan masih memakai peak dari putaran sebelumnya.

  // Antrian upload supaya gak ada 2 upload jalan barengan/bentrok state
  // kalau ESP kirim paket beruntun.
  Future<void> _uploadChain = Future.value();

  Timer? _resourceTimer;
  Timer? _keepAliveTimer;
  Timer? _inactivityTimer;

  // 🟢 LOG AI GRANULAR (device_telemetry -> trg_telemetry_hist -> history):
  // _aiSessionId dipakai supaya baris-baris log dari 1 sesi pakan bisa
  // dikelompokkan saat export/analisis (tanpa ini kurva EMA antar-sesi
  // nyambung jadi satu garis panjang di grafik/CSV). _lastRawScore
  // nampung skor motion energy MENTAH (sebelum median-filter/EMA) dari
  // _onFrame, karena MotionEnergyExtractor.processFrame() cuma
  // me-return-nya sekali per panggilan, tidak disimpan sbg field publik.
  int? _aiSessionId;
  double? _lastRawScore;
  Timer? _aiLogTimer;
  double _lastTempC = 0;
  int _lastCpuPercent = 0;
  double _lastRamMb = 0;
  String _tempText = '-- °C';
  String _cpuText = '-- %';
  String _ramJ2Text = '-- MB';

  bool _isDark = false;

  // ---------------------------------------------------------------------
  // GATE PERINTAH REMOTE (ovr / rst)
  //
  // Supabase realtime mengirim SELURUH ISI BARIS setiap kali ada kolom apa
  // pun yang berubah. Kolom `ovr` dan `rst` itu register PERINTAH yang tidak
  // pernah dibersihkan oleh siapa pun (ESP tidak menulis balik ke Supabase),
  // jadi nilai lama nyangkut di sana selamanya. Tanpa gate ini, menekan
  // "Nyalakan Charger" (yang cuma menulis c=1) ikut MENGIRIM ULANG p=1 dan
  // f=1 yang lama -> pompa nyala, sesi pakan jalan, semua relay hidup bareng.
  //
  // Tiga variabel di bawah menyimpan nilai TERAKHIR YANG SUDAH DIEKSEKUSI,
  // supaya J2 cuma meneruskan PERUBAHAN (edge), bukan isi baris.
  // ---------------------------------------------------------------------
  final Map<String, int> _lastOvr = {};
  // 🟢 FIX BUG "override pompa/charger stuck di 1" (item 1): timestamp
  // kapan J2 TERAKHIR KALI mengirim tiap kunci ovr, dipakai supaya
  // sinkronisasi balik dari telemetri (lihat _syncOverrideGateFromTelemetry)
  // tidak "menang balapan" membatalkan command yang baru saja dikirim J2
  // sendiri, sebelum ESP sempat melaporkan status barunya lewat telemetri.
  final Map<String, DateTime> _lastOvrSentAt = {};
  int _lastRst = 0;
  // 🟢 REVISI: nilai rst yang update "-> 0"-nya ke Supabase sedang berjalan
  // (0 = tidak ada). Cegah panggilan ganda untuk nilai SAMA; nilai berbeda
  // (mis. 1 lalu 2) tetap boleh jalan paralel. Lihat _clearRstInDb.
  int _rstClearingValue = 0;

  // ROOM 2: antrean reboot ESP (sys.rr) -> tabel esp_reboots. ASUMSI: tidak
  // ada penyimpanan lokal bawaan, jadi antrean hanya di memori (hilang bila
  // app mati) dan dikirim ulang oleh tick _resourceTimer 10 dtk saat koneksi
  // pulih. Dibatasi 50 entri (terlama dibuang).
  final List<Map<String, dynamic>> _rebootBacklog = <Map<String, dynamic>>[];
  bool _rebootBusy = false;
  static const int _rebootBacklogMax = 50;

  /// Seq label terakhir dari webapp (device_config.label_cmd.seq). Gate supaya
  /// label lama yang nyangkut di DB tidak dicatat ulang saat app restart.
  int _lastLabelSeq = 0;
  Map<String, dynamic> _lastCfg = {};
  // 🧪 Dedup untuk kolom top-level `auto_mode` (lihat _onRemoteConfigChanged)
  // -- null di awal supaya nilai PERTAMA yang masuk (baseline) tetap
  // dikirim sekali ke ESP walau kebetulan sama dengan default firmware.
  int? _lastAutoMode;
  bool _remoteBaselineReady = false;

  // 🟢 Echo mode operasi yang BENAR-BENAR dijalankan ESP (sys.am dari
  // telemetri), BUKAN tebakan dari command terakhir yang J2 kirim
  // (_lastAutoMode di atas itu command KELUAR, ini status MASUK/aktual).
  // Null selama belum ada paket yang membawa field ini.
  int? _lastAutoModeEcho;

  // 🟢 REVISI: mode operasi yang DIINGINKAN webapp (kolom top-level
  // row['auto_mode'] di Supabase). Dipakai untuk (1) ikut didorong ulang ke
  // ESP tiap link BT tersambung (ESP tanpa NVS balik ke auto_mode=1 tiap
  // reboot) dan (2) membandingkan dengan echo sys.am dari ESP.
  int? _desiredAutoMode;

  /// 🟢 REVISI: kapan terakhir J2 mengoreksi auto_mode ESP dari hasil
  /// bandingan echo (jeda minimal 10 detik antar koreksi).
  DateTime? _autoModeFixAt;

  /// 🟢 REVISI: true = cek drift jam ESP sudah dilakukan pada koneksi BT ini
  /// (maks 1x per koneksi; di-reset saat BT tersambung lagi).
  bool _syncChecked = false;

  // 🟢 FIX BUG "charger nyangkut ON walau baterai 100%": cmin/cmax SUDAH
  // ada di skema (cfg, dikirim ke ESP, ditampilkan juga di webapp -- lihat
  // ControlPanel.svelte "relay otomatis di luar rentang cmin-cmax%"), TAPI
  // sebelum patch ini TIDAK ADA satu baris kode pun di J2 yang benar-benar
  // membaca baterai lalu mengeksekusinya. Firmware (config.h) sudah
  // eksplisit menulis "(Server/J2 Prime yang mengeksekusi)" untuk field
  // ini -- karena ESP sendiri TIDAK PUNYA akses ke persentase baterai HP,
  // cuma J2 yang tahu. Tanpa logika ini, `ovr.c` HANYA PERNAH berubah dari
  // toggle manual (webapp/tombol T25) -- begitu dinyalakan sekali (mis.
  // buat testing), ia nyangkut ON SELAMANYA, apa pun persentase baterainya,
  // karena tidak ada apa pun yang pernah mengirim `ovr.c:0` lagi secara
  // otomatis. Ini akar masalah yang dilaporkan, BUKAN bug relay/firmware.
  bool? _lastChargerAutoTarget;

  // 🟢 FIX BUG "kamera nyala lagi setelah Stop AI": begitu user menekan stop
  // manual, ESP butuh waktu (jeda BT + siklus loop-nya) untuk benar-benar
  // memproses abort dan mengubah fd.msg. Selama jeda itu, telemetri yang
  // MASIH menunjukkan fase aktif (PREP AI/DISPENSE/WAIT AI) TIDAK boleh
  // dibaca sebagai "sesi baru mulai" oleh _onTelemetry.
  DateTime? _suppressAutoRestartUntil;

  // ---------------------------------------------------------------------
  // TAIL (rev): TAIL RECORDING -- lihat KEPUTUSAN di instruksi fitur ini.
  // Setelah sesi pakan berakhir (aktuator selesai), kamera/AI tetap
  // merekam _effectiveTailSeconds() detik lagi supaya grafik EMA terlihat
  // turun kembali. Fase aktif + tail = SATU sesi, ai_session_id yang sama.
  // ---------------------------------------------------------------------
  bool _isTailRecording = false;
  Timer? _tailTimer;
  DateTime? _tailEndsAt;
  String? _tailReason; // alasan ASLI sesi berakhir (bukan cause _endTail)
  DateTime? _panicSentAt; // kapan ovr.x (STOP DARURAT) terakhir diteruskan
  int _lastTailCancelSeq =
      0; // dedup calib.tail_cancel, pola sama _lastLabelSeq

  Timer? _metricsTimer;

  /// Throttle reset timer: pointer move bisa nembak ratusan event/detik
  /// saat scroll, gak perlu bikin ulang Timer sesering itu.
  DateTime? _lastActivityAt;
  static const Duration _activityThrottle = Duration(milliseconds: 400);

  bool get _isCameraActive => _cam.isCameraActive; // 🟢 REVISI (P1)

  /// 🟢 REVISI (P1): untuk Room 9 (SafeRestartScheduler). true = watchdog
  /// kamera mendeteksi black/stall/init_failed; restart app dijadwalkan saat idle.
  bool get restartRecommended => _cam.restartRecommended;

  Duration get _minFrameInterval =>
      Duration(milliseconds: (1000 / widget.config.processingFps).round());

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _devLog = DevLogBuffer(maxLines: widget.config.devLogMaxLines);

    final rowId = int.tryParse(widget.config.supabaseRowId) ?? 1;
    _supabase = FeederSupabaseService(
      telemetryTable: widget.config.supabaseTelemetryTable,
      feedSessionTable: widget.config.supabaseFeedSessionTable,
      configTable: widget.config.supabaseConfigTable,
      rowId: rowId,
      onLog: _devLog.add,
    );

    _btService = BluetoothService(
      targetDeviceName: widget.config.btDeviceName,
      onConnectionChanged: (connected) {
        if (mounted) setState(() => _isBtConnected = connected);
        // ESP kehilangan SELURUH config setiap kali restart (penyimpanan NVS
        // masih dinonaktifkan di firmware), dan satu-satunya petunjuk yang
        // dimiliki J2 bahwa ESP baru saja boot adalah link BT yang putus lalu
        // nyambung lagi. Jadi tiap kali tersambung, dorong ulang `cfg`
        // terakhir dari Supabase. `ovr`/`rst` SENGAJA tidak ikut -- itu
        // perintah sesaat, bukan state yang boleh diputar ulang.
        // 🟢 REVISI: koneksi baru -> cek drift jam ESP lagi (1x), dan buang
        // target auto-charger lama supaya cmin/cmax dievaluasi ulang
        // (ESP bisa saja mematikan charger sendiri saat BT putus >10 menit).
        if (connected) {
          _syncChecked = false;
          _lastChargerAutoTarget = null;
        }
        if (connected) _pushFullConfigToEsp();
        // 🟢 REVISI: begitu link tersambung, tulis bt_connected=true SEKALI
        // (sebelumnya hanya false yang ditulis; true menunggu telemetri).
        if (connected) _pushBtStatus(true);
        if (connected) _restart.markBtConnected(); // 🟢 REVISI (P1/R9)
        // 🟢 FIX: begitu link putus, tidak akan ada paket telemetri
        // berikutnya yang bisa "membawa" status bt_connected ke Supabase --
        // jadi tulis langsung SEKALI di sini (bukan timer/heartbeat
        // berulang, itu sudah dibatalkan sejak revisi arsitektur #3 di atas)
        // supaya Supabase/webapp langsung tahu link putus tanpa delay.
        if (!connected) _pushBtStatus(false);
      },
      onTelemetry: _onTelemetry,
      onEspReboot: _onEspReboot, // ROOM 2
      onLog: _devLog.add,
    );

    // 🟢 REVISI (P1): CameraManager dibuat setelah _devLog & _recorder siap.
    _cam = CameraManager(
      backend: const RealCameraBackend(),
      onImage: _onFrame,
      onLog: _devLog.add,
      onEvent: _camEvent,
      onTorchChanged: _onTorchActualChanged,
      onIssue: _onCamIssue,
      // onRecovered sengaja kosong: manager sudah mencatat 'cam_ok' + log.
      onStateChanged: () {
        if (mounted && !_disposing) setState(() {});
      },
    );

    // Nama channel disatukan sama rowId perangkat -- kalau suatu saat ada
    // >1 unit J2, tiap unit punya channel live-cam sendiri, gak nabrak.
    _liveCam = LiveCamService(
      channelName: 'livecam:$rowId',
      onWatchersChanged: _onLiveCamWatchersChanged,
      onLog: _devLog.add,
      maxMinutes: widget.config.liveCamMaxMinutes, // 🟢 REVISI (P1 / SPEC 3.4)
    );
    _liveCam.start();

    // 🟢 REVISI (P1/R9 / SPEC 3.6): dibuat sebelum BT/resource timer jalan.
    _restart = SafeRestartScheduler(
      isIdle: _isRestartIdle,
      getCfg: () => _lastCfg,
      restartRecommended: () => _cam.restartRecommended,
      clearRestartRecommended: _cam.clearRestartRecommended,
      // Torch self-test meniru sesi: hanya bila flash_auto_session aktif.
      selfTest: (d) =>
          _cam.selfTest(d, useTorch: widget.config.flashAutoSession),
      onLog: (m, {bool error = false}) => _devLog.add(
        error ? LogDirection.error : LogDirection.info,
        'RESTART',
        m,
      ),
    );
    _restart.init(); // fire-and-forget: tandai "app mulai" bila hasil restart

    // CPU gak boleh tidur -- comms BT & Supabase harus tetap jalan walau
    // layar gelap/hemat daya. Sengaja TIDAK pernah di-disable.
    WakelockPlus.enable();

    _startResourceMonitor();
    _connectBT();
    _supabase.subscribeConfig(onConfigChanged: _onRemoteConfigChanged);
    _seedRemoteBaseline();
    _resetInactivityTimer();
  }

  Future<void> _connectBT() async {
    await _btService.initAndConnect();
  }

  /// Tulis status BT ke Supabase. Kalau gagal (mis. internet ikut putus),
  /// ditandai dirty dan dicoba lagi oleh timer resource 10 dtk yang SUDAH ada
  /// (tidak menambah timer/DB write baru selama tidak ada kegagalan).
  Future<void> _pushBtStatus(bool connected) async {
    _btStatusLast = connected;
    final ok = await _supabase.updateBtStatus(connected);
    if (_btStatusLast == connected) _btStatusDirty = !ok;
  }

  // ---------------------------------------------------------------------
  // ROOM 2: REBOOT ESP (sys.rr) -> esp_reboots
  // ---------------------------------------------------------------------

  void _onEspReboot(int reason, bool intentional, DateTime at) {
    _devLog.add(
      LogDirection.info,
      'BT',
      'ESP reboot terdeteksi (sys.rr=$reason, disengaja=$intentional)',
    );
    _rebootBacklog.add({
      'reason': reason,
      'intentional': intentional,
      'at': at,
    });
    while (_rebootBacklog.length > _rebootBacklogMax) {
      _rebootBacklog.removeAt(0);
    }
    _flushRebootBacklog();
  }

  /// Kirim antrean satu per satu berurutan; berhenti di kegagalan pertama
  /// (dicoba lagi oleh tick resource 10 dtk).
  Future<void> _flushRebootBacklog() async {
    if (_rebootBusy || _rebootBacklog.isEmpty) return;
    _rebootBusy = true;
    try {
      while (_rebootBacklog.isNotEmpty) {
        final item = _rebootBacklog.first;
        await _supabase.insertEspReboot(
          reason: item['reason'] as int,
          intentional: item['intentional'] as bool,
          at: item['at'] as DateTime,
        );
        _rebootBacklog.removeAt(0);
      }
    } catch (e) {
      _devLog.add(
        LogDirection.error,
        'SUPA',
        'Gagal catat esp_reboots (${_rebootBacklog.length} ditahan): $e',
      );
    } finally {
      _rebootBusy = false;
    }
  }

  // ---------------------------------------------------------------------
  // TELEMETRI MASUK DARI ESP (via BT)
  // ---------------------------------------------------------------------

  void _onTelemetry(TelemetryPacket packet) {
    _devLog.add(
      LogDirection.inbound,
      'BT',
      'sen p=${packet.sensor.phTrim} t=${packet.sensor.turbTrim} st=${packet.sensor.state} | '
          'act p=${packet.actuator.pump ? 1 : 0} f=${packet.actuator.feeder ? 1 : 0} c=${packet.actuator.charger ? 1 : 0} | '
          'fd=${packet.feeder.msg}(${packet.feeder.count})',
    );

    // 🟢 FIX: sesi AI ditentukan oleh FASE feeder (fd.msg), BUKAN oleh bit
    // relay act.f. Di antara dua putaran, ESP masuk fase "WAIT AI" dengan
    // relay feeder MATI sambil menunggu keputusan AI selama feval detik.
    // Kalau J2 masih memakai bit relay, sesi dianggap selesai di situ --
    // kamera mati, keep-alive CMD:LANJUT berhenti, dan ESP selalu berakhir
    // karena timeout, tidak pernah lanjut ke putaran berikutnya.
    final prevPhase = _lastTelemetry?.feeder.msg;
    _lastTelemetry = packet;

    // 🟢 sys.am: mode operasi yang BENAR-BENAR dijalankan ESP saat ini
    // (bukan tebakan dari command terakhir yang J2 kirim, lihat
    // _lastAutoMode/_onRemoteConfigChanged). Null kalau paket ini belum
    // membawa field-nya (mis. paket mini lama sebelum ESP direvisi) --
    // jangan dianggap berubah kalau memang belum ada datanya.
    final autoModeEcho = packet.system.autoMode;
    if (autoModeEcho != null && autoModeEcho != _lastAutoModeEcho) {
      _lastAutoModeEcho = autoModeEcho;
      _devLog.add(
        LogDirection.info,
        'BT',
        'ESP melaporkan mode: ${autoModeEcho == 1 ? "Otomatis" : "Manual"} (sys.am)',
      );
    }

    // 🟢 REVISI: cek drift jam ESP -- hanya dari paket LENGKAP (sysFresh).
    _maybeSyncEspClock(packet);

    // 🟢 REVISI: reconcile mode operasi dari echo sys.am. ESP tanpa NVS balik
    // ke Otomatis tiap reboot; kalau echo FRESH beda dari yang diinginkan
    // webapp, koreksi (maks 1x per 10 detik). Paket mini (sysFresh=false)
    // diabaikan karena sys.am-nya cuma data lama hasil merge.
    if (packet.sysFresh && _isBtConnected) {
      final espAm = packet.system.autoMode;
      final wantAm = _desiredAutoMode;
      final nowFix = DateTime.now();
      if (espAm != null &&
          wantAm != null &&
          espAm != wantAm &&
          (_autoModeFixAt == null ||
              nowFix.difference(_autoModeFixAt!) >
                  const Duration(seconds: 10))) {
        _autoModeFixAt = nowFix;
        _btService.sendConfig({'auto_mode': wantAm});
        _devLog.add(
          LogDirection.outbound,
          'BT',
          'Koreksi mode ESP: ${espAm == 1 ? "Otomatis" : "Manual"} -> '
              '${wantAm == 1 ? "Otomatis" : "Manual"} (echo sys.am != webapp)',
        );
      }
    }

    const activePhases = {'PREP AI', 'DISPENSE', 'WAIT AI'};
    final sessionActive = activePhases.contains(packet.feeder.msg);
    final sessionEnded =
        prevPhase != null && activePhases.contains(prevPhase) && !sessionActive;

    final suppressed =
        _suppressAutoRestartUntil != null &&
        DateTime.now().isBefore(_suppressAutoRestartUntil!);

    if (!_isFeeding && !_isAiTestMode && sessionActive && !suppressed) {
      // TAIL (rev): _startFeeding() sendiri yang memotong tail bila perlu
      // (KEPUTUSAN #5) -- lihat awal fungsi itu.
      _startFeeding();
    }

    if (_isFeeding && sessionEnded) {
      // TAIL (rev): kalau STOP DARURAT (ovr.x) baru saja diteruskan ke ESP
      // (<= 15 dtk lalu), sessionEnded ini adalah akibatnya -- reason
      // 'panic', BUKAN 'esp_menghentikan_feeder' (lihat KEPUTUSAN #2).
      final recentPanic =
          _panicSentAt != null &&
          DateTime.now().difference(_panicSentAt!) <=
              const Duration(seconds: 15);
      _handleStop(recentPanic ? 'panic' : 'esp_menghentikan_feeder');
    }

    // REVISI v2: awal/akhir putaran dideteksi dari TEPI relay feeder (act.f),
    // bukan dari kenaikan fd.cnt. Tepi naik = beginRound (state level-putaran
    // di-reset, EMA & referensi sesi TETAP). Tepi turun = pulsa selesai,
    // jendela evaluasi putaran dihitung dari titik ini. Berlaku untuk sesi
    // produksi DAN mode Uji Coba AI (dry-run) -- jalur kodenya sama.
    final feederNow = packet.actuator.feeder;
    final feederPrev = _lastFeederRelay;
    _lastFeederRelay = feederNow;
    if (_trigger != null &&
        (_isFeeding || _isAiTestMode) &&
        feederPrev != null &&
        feederNow != feederPrev) {
      final tNow = DateTime.now();
      if (feederNow) {
        _trigger!.beginRound(tNow);
        _recorder.addEvent(tNow, 'pulse_on', {'cnt': packet.feeder.count});
      } else {
        _trigger!.pulseEnded(tNow);
        _recorder.addEvent(tNow, 'pulse_off', {'cnt': packet.feeder.count});
      }
      _notePhase(tNow);
    }

    _queueTelemetryUpload(packet);
    _syncOverrideGateFromTelemetry(packet);

    if (mounted) setState(() {});
  }

  // 🟢 FIX BUG "tombol OVR (pompa/charger) stuck di 1" (item 1):
  // ESP bisa mengubah cfg.ovr_p / cfg.ovr_c SENDIRI tanpa lewat webapp --
  // pompa auto-mati sesudah durasi `pmax`, tombol fisik T25 (charger) /
  // T27 (pompa), atau auto-kuras saat sensor kotor (lihat FeederLogic.cpp).
  // Momen itu Supabase TIDAK PERNAH diberi tahu, jadi kolom `ovr.p` /
  // `ovr.c` di database nyangkut selamanya di nilai lama. Akibatnya klik
  // tombol berikutnya di webapp yang menulis NILAI YANG SAMA (mis. p:1
  // lagi, karena baris Supabase memang masih "1") tidak pernah dianggap
  // sebagai perubahan -- baik oleh baris Supabase itu sendiri (tidak ada
  // delta value walau row di-UPDATE) MAUPUN oleh gate `_lastOvr` di J2 --
  // sehingga perintah didiamkan. Dev-log cuma menunjukkan "INFO SUPA"
  // tanpa "OUT BT" pernah muncul, dan relay ESP memang tidak pernah
  // menyala, persis seperti yang dilaporkan.
  //
  // Fix: begitu telemetri menunjukkan status FISIK pompa/charger berbeda
  // dari command TERAKHIR yang J2 kirim/ketahui, J2 mengoreksi gate
  // lokalnya DAN menulis balik nilai yang benar ke Supabase (lihat
  // FeederSupabaseService.patchOverride) -- supaya kolom `ovr` selalu
  // mencerminkan kondisi yang BENAR-BENAR TEREKSEKUSI, bukan cuma
  // "perintah terakhir yang pernah ditulis manusia". Debounce lewat
  // `_lastOvrSentAt` mencegah race saat J2 baru saja mengirim command dan
  // telemetri lama (status sebelum command diproses ESP) masih sempat
  // masuk sebelum status barunya terlaporkan.
  void _syncOverrideGateFromTelemetry(TelemetryPacket packet) {
    if (!_remoteBaselineReady) return;

    const debounce = Duration(seconds: 4);
    bool recentlySent(String key) {
      final at = _lastOvrSentAt[key];
      return at != null && DateTime.now().difference(at) < debounce;
    }

    final correction = <String, dynamic>{};

    final actualPump = packet.actuator.pump ? 1 : 0;
    if (_lastOvr['p'] != null &&
        _lastOvr['p'] != actualPump &&
        !recentlySent('p')) {
      _lastOvr['p'] = actualPump;
      correction['p'] = actualPump;
    }

    final actualCharger = packet.actuator.charger ? 1 : 0;
    if (_lastOvr['c'] != null &&
        _lastOvr['c'] != actualCharger &&
        !recentlySent('c')) {
      _lastOvr['c'] = actualCharger;
      correction['c'] = actualCharger;
      // 🟢 REVISI: charger berubah SENDIRI di ESP (timer BT putus / tombol
      // T25 / akhir sesi pakan) -> buang target auto lama supaya cmin/cmax
      // dievaluasi ulang di _maintainChargerFromBattery berikutnya.
      _lastChargerAutoTarget = null;
    }

    if (correction.isNotEmpty) {
      _devLog.add(
        LogDirection.info,
        'SUPA',
        'Sinkron ulang ovr dari status fisik ESP (auto-off / tombol fisik '
            '/ auto-trigger): $correction',
      );
      _supabase.patchOverride(correction);
    }
  }

  /// 🟢 REVISI: sinkron jam RTC ESP dari jam HP, dengan cek drift.
  /// Epoch WAJIB = UTC + 7 jam tetap (WIB), BUKAN timezone HP. Dicek maks
  /// 1x per koneksi BT dan HANYA dari paket lengkap (sysFresh); sync dikirim
  /// cuma kalau drift > 30 detik -- tiap sync membuat ESP memasang ulang latch
  /// jadwal pakan, jadi tidak boleh dikirim tiap connect tanpa cek drift.
  void _maybeSyncEspClock(TelemetryPacket p) {
    if (_syncChecked || !p.sysFresh || !_isBtConnected) return;
    _syncChecked = true; // maksimal 1x pengecekan per koneksi BT
    final s = p.system;
    if (s.rtcError) return; // ESP tidak bisa adjust saat I2C error
    final now = DateTime.now();
    if (now.year < 2025) return; // jam HP sendiri tidak valid -> jangan sync
    final nowWib = now.toUtc().millisecondsSinceEpoch ~/ 1000 + 7 * 3600;
    if (s.espEpoch <= 0 || (s.espEpoch - nowWib).abs() > 30) {
      _btService.sendTimeSync(nowWib);
      _devLog.add(
        LogDirection.outbound,
        'BT',
        'Sync jam ESP (WIB): $nowWib (ESP=${s.espEpoch})',
      );
    }
  }

  void _queueTelemetryUpload(TelemetryPacket packet) {
    _uploadChain = _uploadChain
        .then((_) => _uploadMergedTelemetry(packet))
        .catchError((e) {
          _devLog.add(LogDirection.error, 'SUPA', 'Upload gagal: $e');
        });
  }

  /// Eksekusi ambang baterai cmin/cmax dari cfg (lihat catatan di
  /// deklarasi `_lastChargerAutoTarget` di atas). Hysteresis band: nyalakan
  /// HANYA saat baterai <= cmin, matikan HANYA saat baterai >= cmax --
  /// supaya tidak toggle bolak-balik tiap kali baterai nyeberang satu
  /// angka persis di satu threshold tunggal. Di ANTARA cmin..cmax, target
  /// dibiarkan apa adanya (tidak dipaksa ke arah mana pun).
  void _maintainChargerFromBattery(int battPct) {
    // 🟢 REVISI: BT putus -> jangan evaluasi. Kalau dievaluasi, target ditandai
    // "terkirim" padahal sendOverride gagal (belum konek) dan ovr.c ikut
    // ditulis ke Supabase untuk perintah yang tidak pernah sampai ke ESP.
    if (!_isBtConnected) return;
    if (!_remoteBaselineReady) return; // belum tahu ovr.c yang benar

    final cmin = (_lastCfg['cmin'] as num?)?.toInt();
    final cmax = (_lastCfg['cmax'] as num?)?.toInt();
    if (cmin == null || cmax == null) return; // cfg belum diterima dari ESP

    bool? target;
    if (battPct <= cmin) {
      target = true;
    } else if (battPct >= cmax) {
      target = false;
    }
    if (target == null || target == _lastChargerAutoTarget) return;

    _lastChargerAutoTarget = target;
    if (_lastOvr['c'] == (target ? 1 : 0))
      return; // sudah sesuai, gak perlu kirim ulang

    _lastOvr['c'] = target ? 1 : 0;
    _lastOvrSentAt['c'] = DateTime.now();
    _devLog.add(
      LogDirection.info,
      'HP',
      'Auto charger: baterai $battPct% ${target ? '<= cmin=$cmin -> ON' : '>= cmax=$cmax -> OFF'}',
    );
    _btService.sendOverride(charger: target);
    _supabase.patchOverride({'c': target ? 1 : 0});
  }

  /// Bagian NON-AI dari baris upload: 1 paket telemetri ESP + baterai/
  /// suhu/cpu/status BT J2. Dipisah dari [_aiFields] supaya bisa dipakai
  /// ulang baik oleh upload rutin (_uploadMergedTelemetry, dipicu tiap
  /// paket ESP) maupun oleh snapshot penutup sesi (_uploadFinalAiSnapshot,
  /// dipicu manual di _handleStop) tanpa duplikasi kode baca baterai/dsb.
  Future<Map<String, dynamic>> _buildDeviceRow(TelemetryPacket packet) async {
    int battPct = 0;
    bool charging = false;
    try {
      battPct = await _battery.batteryLevel;
      final st = await _battery.batteryState;
      charging = st == BatteryState.charging || st == BatteryState.full;
    } catch (e) {
      _devLog.add(LogDirection.error, 'HP', 'Gagal baca baterai: $e');
    }

    _maintainChargerFromBattery(battPct);

    return {
      ...packet.toSupabaseRow(),
      'battery_percent': battPct,
      'is_charging': charging,
      'j2_temp_c': _lastTempC,
      'j2_cpu_percent': _lastCpuPercent,
      'j2_ram_mb': _lastRamMb.round(),
      'bt_connected': _isBtConnected,
    };
  }

  /// Bagian AI dari baris upload -- field lengkap untuk kalibrasi, bukan
  /// cuma ema/peak (lihat review chat soal "yg dicek cuma peak atau ada
  /// tren"). Null total kalau sedang TIDAK dalam sesi (bukan 0), biar
  /// webapp bisa beda-in "belum ada aktivitas" vs "memang tidak sedang
  /// dievaluasi sama sekali". [overrideActive]/[overrideStopped]/
  /// [overrideStopReason] dipakai HANYA oleh snapshot penutup sesi, karena
  /// pada saat itu _isFeeding sudah/akan di-set false padahal baris ini
  /// justru representasi momen SESI BERAKHIR (harus tetap ai_active=true),
  /// dan alasan stop yang benar adalah reason yang dioper ke _handleStop
  /// -- BUKAN _trigger.lastStopReason, karena utk reason 'manual_stop' /
  /// 'esp_menghentikan_feeder', trigger lokal sendiri tidak pernah
  /// mutusin stop (lastStopReason-nya tetap null).
  Map<String, dynamic> _aiFields({
    bool? overrideActive,
    bool? overrideStopped,
    String? overrideStopReason,
    bool? overrideTail, // TAIL (rev)
    TelemetryPacket? packet,
  }) {
    // TAIL (rev): sesi masih dianggap "aktif" (menghasilkan baris ai_*)
    // selama tail recording juga -- fase aktif + tail = satu sesi.
    final active =
        overrideActive ?? (_isFeeding || _isAiTestMode || _isTailRecording);
    // TAIL (rev): ai_session_id tetap sama selama tail.
    final sessionId = (_isFeeding || _isTailRecording)
        ? _aiSessionId
        : _trialSessionId;
    // 🧪 Baris telemetri selagi ESP di fase TEST (pulsa manual jog motor
    // feeder, lihat FeederLogic.cpp feedState==9) ikut ditandai is_trial
    // supaya TIDAK mencemari grafik/analitik historis riil -- sama seperti
    // pola _isAiTestMode, biar konsisten difilter di sisi webapp.
    final isFeederTest = packet?.feeder.msg == 'TEST';
    // TAIL (rev): selama tail, aktuator sudah selesai -- default ai_stopped
    // selalu true dan ai_stop_reason = alasan ASLI sesi berakhir
    // (_tailReason), bukan lagi keputusan AI yang masih berjalan.
    final stoppedDefault = _isTailRecording
        ? true
        : (_trigger?.stopped ?? false);
    final stopReasonDefault = _isTailRecording
        ? _tailReason
        // Di mode Uji Coba (dry-run) keputusan STOP tidak pernah dijalankan;
        // kandidatnya ditulis sebagai 'would_ai_...' supaya ikut ke CSV.
        : (_trigger?.lastStopReason ??
              ((_isAiTestMode && _trigger?.wouldStopReason != null)
                  ? 'would_${_trigger!.wouldStopReason}'
                  : null));
    return {
      'ai_active': active,
      'ai_session_id': active ? sessionId : null,
      'ai_ema': active ? _trigger?.ema : null,
      'ai_peak': active ? _trigger?.peakRunning : null,
      'ai_raw': active ? _lastRawScore : null,
      'ai_below_counter': active ? _trigger?.belowCounter : null,
      'ai_peak_reached': active ? _trigger?.peakReached : null,
      'ai_frame_idx': active ? _trigger?.frameIdx : null,
      'ai_stopped': active ? (overrideStopped ?? stoppedDefault) : null,
      'ai_stop_reason': active
          ? (overrideStopReason ?? stopReasonDefault)
          : null,
      // TAIL (rev): true selagi kamera/AI masih merekam pemulihan setelah
      // sesi berakhir (dikonsumsi webapp utk menandai segmen tail di grafik).
      'ai_tail': active ? (overrideTail ?? _isTailRecording) : null,

      'is_trial': _isAiTestMode || isFeederTest,
    };
  }

  /// Gabungkan 1 paket telemetri ESP + baterai/suhu/cpu/status BT J2 +
  /// snapshot AI saat ini jadi SATU baris, SATU kali kirim ke Supabase.
  /// Dipanggil tiap ada paket ESP baru (_onTelemetry) DAN tiap tick
  /// [_aiLogTimer] selama sesi aktif -- lihat _startFeeding.
  Future<void> _uploadMergedTelemetry(TelemetryPacket packet) async {
    final row = <String, dynamic>{
      ...await _buildDeviceRow(packet),
      ..._aiFields(packet: packet),
    };
    await _supabase.uploadTelemetry(row);
  }

  // 🟢 FIX BUG "baris stop gak bawa ema/peak/alasan final": sebelumnya
  // _handleStop cuma updateFeedingStatus(state:'stopped', stopReason)
  // TANPA ema/peak, dan device_telemetry baru ke-update lagi nunggu paket
  // ESP berikutnya -- histori AI kehilangan momen PALING penting (angka
  // persis saat sistem mutusin stop). Sekarang _handleStop ngirim 1 baris
  // PENUTUP eksplisit ke device_telemetry SEBELUM _isFeeding di-set false,
  // supaya ai_stopped=true + ai_stop_reason + ema/peak/below_counter
  // TERAKHIR ikut ke-log dgn tepat, apa pun alasan stop-nya (decay,
  // startup_timeout, manual_stop, atau esp_menghentikan_feeder).
  Future<void> _uploadFinalAiSnapshot(
    String reason, {
    bool? overrideTail, // TAIL (rev)
  }) async {
    final packet = _lastTelemetry;
    if (packet == null)
      return; // belum pernah ada paket ESP -- tidak ada basis baris
    try {
      final row = <String, dynamic>{
        ...await _buildDeviceRow(packet),
        ..._aiFields(
          overrideActive: true,
          overrideStopped: true,
          overrideStopReason: reason,
          overrideTail: overrideTail,
        ),
      };
      _uploadChain = _uploadChain.then((_) => _supabase.uploadTelemetry(row));
      await _uploadChain;
    } catch (e) {
      _devLog.add(
        LogDirection.error,
        'SUPA',
        'Gagal upload snapshot AI penutup sesi: $e',
      );
    }
  }

  // ---------------------------------------------------------------------
  // CONFIG REALTIME DARI SUPABASE (WEBAPP) -> ESP (BT) + KALIBRASI LOKAL J2
  // ---------------------------------------------------------------------

  /// Ambil kondisi awal baris config TANPA mengeksekusi `ovr`/`rst` di
  /// dalamnya. Ini yang bikin app tahan di-hot-reload / restart: nilai
  /// perintah lama yang masih nyangkut di database dianggap "sudah pernah
  /// dijalankan", bukan perintah baru.
  Future<void> _seedRemoteBaseline() async {
    final row = await _supabase.fetchConfigRow();
    if (row == null || _remoteBaselineReady) return;
    _adoptBaseline(row);
    // Torch fisik pasti mati saat app baru start -> samakan kolom flash_on
    // (kalau tidak, event config pertama akan menyalakan flash tanpa diminta).
    // 🟢 REVISI (P1 / SPEC 3.3): bersyarat (eq flash_on=true) + diulang oleh
    // tick resource bila gagal. flash_actual basi (app mati saat torch nyala)
    // juga dikoreksi sekali, bersyarat -- tidak menulis apa pun bila sudah false.
    if (row['flash_on'] == true && !_flashOn) _pushFlashOff();
    _supabase.resetFlashActualIfOn();
    if (_isBtConnected) await _pushFullConfigToEsp();
    // 🟢 REVISI: state 'feeding' yang nyangkut (app mati saat sesi) dikoreksi
    // ke 'stopped'. Cek ULANG setelah await di atas: jangan timpa kalau
    // sesi/uji coba AI sudah aktif (termasuk uji coba yang dilanjut dari
    // baseline remote lewat _adoptBaseline -> _startAiTest).
    // 🟢 REVISI (P1 / SPEC 3.5): update BERSYARAT eq('state','feeding') --
    // 'stopped' dengan alasan asli TIDAK ditimpa 'app_restart'.
    if (!_isFeeding && !_isAiTestMode) {
      _supabase.closeStaleFeeding();
    }
  }

  void _adoptBaseline(Map<String, dynamic> row) {
    final ovr = row['ovr'];
    if (ovr is Map) {
      ovr.forEach((k, v) {
        if (v is num) _lastOvr[k.toString()] = v.toInt();
      });
    }

    final rst = row['rst'];
    _lastRst = rst is num ? rst.toInt() : 0;
    // 🟢 REVISI: rst nyangkut (!= 0) dari sesi sebelumnya TIDAK dikirim ke ESP
    // (ini baseline), tapi dibersihkan di database supaya klik Reset berikutnya
    // dari webapp terdeteksi sebagai perubahan nilai.
    if (_lastRst != 0) _clearRstInDb(_lastRst);

    final lbl = row['label_cmd'];
    if (lbl is Map && lbl['seq'] is num) {
      _lastLabelSeq = (lbl['seq'] as num).toInt();
    }

    final cfg = row['cfg'];
    if (cfg is Map) _lastCfg = Map<String, dynamic>.from(cfg);

    // 🟢 REVISI: simpan mode operasi yang diinginkan webapp (kolom top-level).
    final amBaseline = _parseAutoMode(row['auto_mode']);
    if (amBaseline != null) _desiredAutoMode = amBaseline;

    final calib = row['calib'];
    if (calib is Map) {
      final calibMap = Map<String, dynamic>.from(calib);
      // TAIL (rev): seed dedup seq tail_cancel, pola sama _lastLabelSeq --
      // supaya seq lama yang nyangkut di DB tidak membatalkan tail baru.
      final tc = calibMap['tail_cancel'];
      if (tc is num) _lastTailCancelSeq = tc.toInt();
      // 🟢 REVISI (P1): seed dedup flash_renew (nilai lama bukan perintah baru).
      final fr = calibMap['flash_renew'];
      if (fr is num) _lastFlashRenew = fr.toInt();
      _applyCalib(calibMap);
    }

    final trialActiveBaseline = row['trial_active'];
    if (trialActiveBaseline == true) {
      final startedAt = DateTime.tryParse(
        row['trial_started_at']?.toString() ?? '',
      );
      final mins = row['trial_duration_min'];
      final durMin = mins is num ? mins.toInt() : null;
      final expired =
          startedAt != null &&
          durMin != null &&
          DateTime.now().difference(startedAt) >= Duration(minutes: durMin);
      if (expired) {
        _supabase.updateTrialStatus(status: 'idle', stopReason: 'interrupted');
      } else {
        _startAiTest(durationMin: durMin, fromRemote: true);
      }
    }

    _remoteBaselineReady = true;
    _devLog.add(
      LogDirection.info,
      'SUPA',
      'Baseline perintah dibaca (ovr=$_lastOvr rst=$_lastRst) - tidak dieksekusi',
    );
  }

  /// 🟢 REVISI: kembalikan kolom `rst` di Supabase ke 0 (bersyarat: hanya bila
  /// masih bernilai [value]). Gate `_lastRst` SENGAJA tetap = [value] selama
  /// update berjalan, sehingga event realtime lain yang masih membawa
  /// rst=[value] tidak dianggap perintah baru (anti reset ganda). Gate baru
  /// dilepas ke 0 setelah update berhasil. Kalau gagal, gate tetap = [value]
  /// (aman: tidak akan kirim ulang) dan pembersihan dicoba lagi pada event
  /// config berikutnya.
  void _clearRstInDb(int value) {
    if (_rstClearingValue == value) return;
    _rstClearingValue = value;
    _supabase.resetRstIfEquals(value).then((ok) {
      if (_rstClearingValue == value) _rstClearingValue = 0;
      if (ok && _lastRst == value) _lastRst = 0;
      if (!mounted) return;
      _devLog.add(
        ok ? LogDirection.info : LogDirection.error,
        'SUPA',
        ok
            ? 'Kolom rst (=$value) dikembalikan ke 0'
            : 'Gagal mengembalikan rst ke 0, dicoba lagi saat event config berikutnya',
      );
    });
  }

  /// 🟢 REVISI: normalisasi kolom `auto_mode` (bisa bool ATAU angka,
  /// tergantung skema) ke 1/0; selain itu null. Perilakunya SAMA dengan blok
  /// auto_mode lama di _onRemoteConfigChanged (yang kini memakai helper ini).
  int? _parseAutoMode(dynamic raw) {
    if (raw is bool) return raw ? 1 : 0;
    if (raw is num) return raw == 1 ? 1 : 0;
    return null;
  }

  /// Kirim ulang SELURUH cfg terakhir ke ESP (dipakai saat link BT baru
  /// tersambung, karena ESP kemungkinan besar baru saja restart).
  Future<void> _pushFullConfigToEsp() async {
    // 🟢 REVISI (P1/R9): penanda "push cfg sedang berjalan" untuk syarat idle.
    _cfgPushing++;
    try {
      await _pushFullConfigToEspImpl();
    } finally {
      _cfgPushing--;
    }
  }

  Future<void> _pushFullConfigToEspImpl() async {
    var cfg = _lastCfg;
    Map<String, dynamic>? fetchedRow; // 🟢 REVISI: hindari fetch ganda
    if (cfg.isEmpty) {
      final row = await _supabase.fetchConfigRow();
      fetchedRow = row;
      final c = row?['cfg'];
      if (c is Map) {
        cfg = Map<String, dynamic>.from(c);
        _lastCfg = cfg;
      }
    }
    // 🟢 REVISI: auto_mode adalah kolom TOP-LEVEL (bukan di jsonb cfg), jadi
    // tidak pernah ikut terkirim di sini -> ESP reboot = balik Otomatis walau
    // webapp Manual. Kalau belum diketahui, ambil dari row dulu.
    if (_desiredAutoMode == null) {
      fetchedRow ??= await _supabase.fetchConfigRow();
      final am = _parseAutoMode(fetchedRow?['auto_mode']);
      if (am != null) _desiredAutoMode = am;
    }
    if (cfg.isEmpty && _desiredAutoMode == null) return;
    // Salinan cfg + auto_mode; _lastCfg SENGAJA tidak dimutasi dengan key ini.
    final payload = <String, dynamic>{
      ...cfg,
      if (_desiredAutoMode != null) 'auto_mode': _desiredAutoMode,
    };
    await _btService.sendConfig(payload);
    _restart.markCfgSent(); // 🟢 REVISI (P1/R9): ukur durasi restart
    // Jaga dedup _onRemoteConfigChanged tetap konsisten dengan yang terkirim.
    if (_desiredAutoMode != null) _lastAutoMode = _desiredAutoMode;
    _devLog.add(
      LogDirection.info,
      'BT',
      'Sinkron ulang ${payload.length} field cfg ke ESP (link baru tersambung)',
    );
  }

  void _onRemoteConfigChanged(Map<String, dynamic> row) {
    // Baris pertama yang masuk sebelum seeding selesai hanya dipakai untuk
    // MENGISI baseline -- jangan dieksekusi, isinya bisa saja perintah lama.
    if (!_remoteBaselineReady) {
      _adoptBaseline(row);
      if (_isBtConnected) _pushFullConfigToEsp();
      return;
    }

    // --- cfg: kirim HANYA field yang nilainya benar-benar berubah ---
    final cfg = row['cfg'];
    if (cfg is Map) {
      final next = Map<String, dynamic>.from(cfg);
      final delta = <String, dynamic>{};
      next.forEach((k, v) {
        if (_lastCfg[k] != v) delta[k] = v;
      });
      _lastCfg = next;
      if (delta.isNotEmpty) _btService.sendConfig(delta);
    }

    // 🟢 auto_mode: kolom TOP-LEVEL (bukan bagian jsonb `cfg`), jadi dulu
    // TIDAK PERNAH ikut disalurkan ke ESP lewat blok `cfg` di atas -- toggle
    // "Manual" di ControlPanel.svelte cuma mengubah label UI, ESP tetap
    // menjalankan auto-kuras/jadwal RTC seperti biasa. Sekarang diteruskan
    // eksplisit sebagai field `cfg.auto_mode` (lihat CommsBT.cpp &
    // FeederLogic.cpp), dengan dedup manual karena bukan bagian _lastCfg.
    final autoModeRaw = row['auto_mode'];
    // 🟢 FIX: kolom `auto_mode` di Supabase ternyata bisa bertipe integer
    // (0/1), bukan cuma boolean -- tergantung skema/migrasi yang dipakai.
    // Sebelumnya kode ini HANYA menangani `is bool`, jadi kalau kolomnya
    // integer, autoModeRaw is bool selalu false dan command TIDAK PERNAH
    // terkirim ke ESP sama sekali (bukan salah kirim, tapi diam-diam
    // dilewati). Sekarang dua tipe ditangani, hasilnya dinormalisasi ke
    // int? autoModeInt, lalu logika dedup & kirim SAMA seperti sebelumnya.
    final int? autoModeInt = _parseAutoMode(autoModeRaw); // 🟢 REVISI: helper
    if (autoModeInt != null) {
      _desiredAutoMode =
          autoModeInt; // 🟢 REVISI: tiap row masuk, walau tak berubah
      if (_lastAutoMode != autoModeInt) {
        _lastAutoMode = autoModeInt;
        _btService.sendConfig({'auto_mode': autoModeInt});
        _devLog.add(
          LogDirection.outbound,
          'BT',
          'Mode operasi -> ESP: ${autoModeInt == 1 ? "Otomatis" : "Manual"}',
        );
      }
    }

    // --- ovr: hanya kunci yang BERUBAH yang diteruskan ke ESP ---
    // Inilah perbaikan inti bug "satu tombol menyalakan semua relay".
    //
    // 🟢 FIX BUG "STOP DARURAT tidak berefek apa pun" (item 2): key 'x'
    // (panic stop -- lihat bluetooth_service.dart sendOverride(panic:)
    // dan FeederLogic.cpp cfg.ovr_x, yang KEDUANYA sudah siap) SEBELUMNYA
    // TIDAK ADA di daftar key yang dibaca dari baris Supabase di sini.
    // Akibatnya J2 tidak pernah tahu ada perintah 'x' dari webapp dan
    // tidak pernah meneruskannya ke ESP -- root cause persis seperti yang
    // dilaporkan ("j2 belum membuat kode pengirim"). ESP & BT service
    // firmware/app sendiri sudah benar, cuma jalur pembacaannya di sini
    // yang bolong. Sekarang 'x' ikut diperiksa persis seperti p/f/c.
    final ovr = row['ovr'];
    if (ovr is Map) {
      bool? pump, feeder, charger, panic, feederTest;
      // 🧪 'tf' = pulsa test/jog motor feeder manual (lihat sendOverride).
      for (final key in const ['p', 'f', 'c', 'x', 'tf']) {
        final raw = ovr[key];
        if (raw is! num) continue;
        final value = raw.toInt();
        if (_lastOvr[key] == value) continue; // nilai lama -> JANGAN diulang
        _lastOvr[key] = value;
        _lastOvrSentAt[key] = DateTime.now();
        if (key == 'p') pump = value == 1;
        if (key == 'f') feeder = value == 1;
        if (key == 'c') charger = value == 1;
        if (key == 'x') panic = value == 1;
        if (key == 'tf') feederTest = value == 1;
      }
      if (pump != null ||
          feeder != null ||
          charger != null ||
          panic != null ||
          feederTest != null) {
        final parts = <String>[];
        if (pump != null) parts.add('p=${pump ? 1 : 0}');
        if (feeder != null) parts.add('f=${feeder ? 1 : 0}');
        if (charger != null) parts.add('c=${charger ? 1 : 0}');
        if (panic != null) parts.add('x=${panic ? 1 : 0}');
        if (feederTest != null) parts.add('tf=${feederTest ? 1 : 0}');
        _devLog.add(
          LogDirection.outbound,
          'SUPA',
          'Override berubah -> ESP: ${parts.join(' ')}',
        );
        _btService.sendOverride(
          pump: pump,
          feeder: feeder,
          charger: charger,
          panic: panic,
          feederTest: feederTest,
        );
        // TAIL (rev): catat kapan STOP DARURAT (ovr.x) diteruskan ke ESP --
        // dipakai _onTelemetry utk menandai sessionEnded berikutnya sebagai
        // reason 'panic' (bukan 'esp_menghentikan_feeder'), lihat KEPUTUSAN #2.
        if (panic == true) _panicSentAt = DateTime.now();

        // 🟢 FIX BUG "STOP DARURAT / pemicu pakan stuck di 1": beda dari
        // 'p'/'c' yang statusnya bisa dikonfirmasi balik lewat TELEMETRI
        // (act.p/act.c -- lihat _syncOverrideGateFromTelemetry), 'f' dan
        // 'x' itu PULSA sekali-pakai. ESP melucuti cfg.ovr_f/cfg.ovr_x
        // SENDIRI di siklus berikutnya (lihat FeederLogic.cpp), tapi
        // TIDAK ADA field telemetri yang melaporkan balik "pulsa ini
        // sudah dikonsumsi" -- act.p/act.c cuma merepresentasikan pompa
        // & charger, bukan feeder-trigger atau panic. Kalau kolom
        // `ovr.f`/`ovr.x` di Supabase tidak pernah ditulis balik ke 0,
        // dia nyangkut di "1" SELAMANYA: klik "Picu sesi pakan" / "STOP
        // DARURAT" berikutnya menulis nilai IDENTIK (1 lagi) yang tidak
        // dianggap perubahan oleh Postgres maupun oleh gate `_lastOvr` --
        // persis gejala yang dilaporkan.
        //
        // Karena tidak ada sinyal telemetri utk pulsa ini, J2 reset balik
        // SEGERA sesudah command berhasil diteruskan ke ESP (semantiknya:
        // "sudah dikirim, siap dipicu lagi"), tanpa bergantung ke store.js
        // webapp melakukannya sendiri.
        final pulseReset = <String, dynamic>{};
        if (feeder == true) {
          _lastOvr['f'] = 0;
          pulseReset['f'] = 0;
        }
        if (panic == true) {
          _lastOvr['x'] = 0;
          pulseReset['x'] = 0;
        }
        if (feederTest == true) {
          _lastOvr['tf'] = 0;
          pulseReset['tf'] = 0;
        }
        if (pulseReset.isNotEmpty) {
          _devLog.add(
            LogDirection.info,
            'SUPA',
            'Reset pulsa ovr setelah diteruskan ke ESP: $pulseReset',
          );
          _supabase.patchOverride(pulseReset);
        }
      }
    }

    final trialActive = row['trial_active'];
    if (trialActive is bool) {
      if (trialActive && !_isAiTestMode) {
        final mins = row['trial_duration_min'];
        _startAiTest(
          durationMin: mins is num ? mins.toInt() : null,
          fromRemote: true,
        );
      } else if (!trialActive && _isAiTestMode) {
        _stopAiTest(reason: 'user_stop', fromRemote: true);
      }
    }

    final flashOn = row['flash_on'];
    // 🟢 REVISI (P1): dari web -> TIDAK ditulis balik (DB sudah berisi nilai
    // ini; tulis balik bisa menimpa klik web yang lebih baru).
    if (flashOn is bool && flashOn != _flashOn) {
      _applyFlash(flashOn, fromWeb: true);
    }

    _handleRemoteLabel(row['label_cmd']);

    // --- rst: hanya saat TRANSISI ke nilai non-0 ---
    // Tanpa ini, satu nilai rst=1 yang nyangkut di database bikin ESP
    // restart setiap kali ada perubahan config apa pun.
    final rstRaw = row['rst'];
    final rst = rstRaw is num ? rstRaw.toInt() : 0;
    if (rst != _lastRst) {
      _lastRst = rst;
      if (rst != 0) {
        _devLog.add(
          LogDirection.outbound,
          'SUPA',
          'Perintah reset baru dari webapp (rst=$rst)',
        );
        // 🟢 REVISI: kirim (TANPA await sebelum reset), lalu kembalikan
        // kolom rst ke 0 supaya Soft Reset berikutnya terdeteksi lagi.
        // Reset dilakukan juga bila kirim BT gagal (operator bisa coba
        // lagi); hasil kirim dicatat BluetoothService._sendRaw di log BT.
        // _lastRst DIBIARKAN = rst sampai update ke Supabase berhasil
        // (lihat _clearRstInDb): event lain yang masih membawa rst=$rst
        // tidak memicu kirim ulang, dan event balasan rst=0 hanya
        // menurunkan gate tanpa mengirim apa pun.
        _btService.sendReset(rst);
        _clearRstInDb(rst);
        _devLog.add(
          LogDirection.info,
          'SUPA',
          'rst=$rst diteruskan ke ESP (hasil kirim: lihat log BT); menunggu kolom rst di-reset ke 0',
        );
      }
    } else if (rst != 0) {
      // 🟢 REVISI: rst masih nyangkut di database (reset sebelumnya gagal /
      // belum selesai) -- TIDAK dikirim ulang ke ESP, hanya coba bersihkan.
      _clearRstInDb(rst);
    }

    final calib = row['calib'];
    if (calib is Map) {
      final calibMap = Map<String, dynamic>.from(calib);
      _handleTailCancel(calibMap['tail_cancel']); // TAIL (rev)
      _applyCalib(calibMap);
    }
  }

  /// Label kejadian dari webapp (device_config.label_cmd = {v, seq, wt}).
  ///
  /// Dulu tombol "Tandai: ..." ada di layar HP ini, tapi menyentuh HP yang
  /// sedang merekam menggetarkan kamera dan tercatat sebagai aktivitas palsu
  /// di motion energy. Sekarang label dikirim dari web; J2 hanya mencatat
  /// event 'label' ke recorder (jam J2 sendiri, sama dengan timestamp frame)
  /// lalu menulis balik `label_ack` supaya web tahu label benar-benar masuk.
  void _handleRemoteLabel(dynamic raw) {
    if (raw is! Map) return;
    final seq = (raw['seq'] as num?)?.toInt() ?? 0;
    if (seq <= _lastLabelSeq) return; // sudah diproses / label lama
    _lastLabelSeq = seq;

    final v = raw['v']?.toString() ?? '';
    const allowed = {'habis', 'sisa', 'lesu', 'ditinggal'};
    if (!allowed.contains(v)) {
      _devLog.add(LogDirection.error, 'SUPA', 'Label tidak dikenal: "$v"');
      return;
    }
    if (!(_isFeeding || _isAiTestMode || _isTailRecording)) {
      // TAIL (rev): label diizinkan saat tail juga -- masih sesi yang sama.
      _devLog.add(
        LogDirection.error,
        'SUPA',
        'Label "$v" diabaikan: tidak ada sesi rekam (uji coba/pakan) aktif',
      );
      return; // tanpa ack -> web menandai "tidak tercatat"
    }

    final wt = (raw['wt'] as num?)?.toInt();
    _recorder.addEvent(DateTime.now(), 'label', {
      'v': v,
      'src': 'web',
      if (wt != null) 'wt': wt, // jam browser, hanya info; bisa beda dgn jam J2
    });
    _devLog.add(LogDirection.inbound, 'SUPA', 'Label "$v" dari web dicatat');
    _supabase.ackLabel(seq);
  }

  /// Kalibrasi AI lokal J2 -- BUKAN config ESP, jadi tidak dikirim ke ESP,
  /// cukup diterapkan & disimpan lokal (dipakai sesi feeding berikutnya).
  void _applyCalib(Map<String, dynamic> c) {
    final cfgObj = widget.config;
    var changed = false;

    void applyD(String key, void Function(double) setter) {
      final v = c[key];
      if (v is num) {
        setter(v.toDouble());
        changed = true;
      }
    }

    void applyI(String key, void Function(int) setter) {
      final v = c[key];
      if (v is num) {
        setter(v.toInt());
        changed = true;
      }
    }

    // Kunci lama (decay_ratio, min_peak, debounce_s, startup_timeout_s,
    // round_ratio, activity_floor) sengaja TIDAK diproses lagi -- logika
    // lanjut/stop sekarang berbasis rasio (lihat feeder_trigger.dart).
    applyD('ratio_ok', (v) => cfgObj.ratioOk = v);
    applyD('ratio_hard', (v) => cfgObj.ratioHard = v);
    applyI('strikes_to_stop', (v) => cfgObj.strikesToStop = v < 1 ? 1 : v);
    applyD('snr_min', (v) => cfgObj.snrMin = v);
    applyD('baseline_skip_s', (v) => cfgObj.baselineSkipS = v);
    applyD('baseline_max_s', (v) => cfgObj.baselineMaxS = v);
    applyD('baseline_min_s', (v) => cfgObj.baselineMinS = v);
    applyD('ema_tau_s', (v) => cfgObj.emaTauSeconds = v);
    applyD('round_win_start_s', (v) => cfgObj.roundWinStartS = v);
    applyD('round_win_end_s', (v) => cfgObj.roundWinEndS = v);
    applyI('median_window', (v) => cfgObj.medianWindow = v);
    applyD('processing_fps', (v) => cfgObj.processingFps = v);
    applyD('keepalive_s', (v) => cfgObj.keepAliveSeconds = v);
    applyD('screen_timeout_s', (v) => cfgObj.screenTimeoutSeconds = v);
    // Di-clamp DI SINI juga (bukan cuma di Settings screen J2) -- ini
    // jalur update DARI WEBAPP, jadi input liar dari luar harus tetap
    // gak bisa memaksa J2 ngirim frame live-cam membanjir.
    applyD(
      'live_cam_interval_s',
      (v) =>
          cfgObj.liveCamIntervalSeconds = FeederConfig.clampLiveCamInterval(v),
    );
    // TAIL (rev): calib.tail_record_s, di-clamp sama seperti Settings screen.
    applyD(
      'tail_record_s',
      (v) => cfgObj.tailRecordSeconds = FeederConfig.clampTail(v),
    );

    // 🟢 REVISI (P1 / SPEC 4): kunci opsional flash & live-cam. SENGAJA tidak
    // lewat applyD/applyI: tidak disimpan ke prefs dan _calibVersion TIDAK
    // dinaikkan. Key tidak ada = default J2 (webapp lama aman).
    final ft = c['flash_timeout_s'];
    cfgObj.flashTimeoutSeconds = FeederConfig.clampFlashTimeout(
      ft is num ? ft.toDouble() : FeederConfig.flashTimeoutDefault,
    );
    cfgObj.flashAutoSession = c['flash_auto_session'] == true;
    final lm = c['live_cam_max_min'];
    final lmClamped = FeederConfig.clampLiveCamMaxMin(
      lm is num ? lm.toInt() : FeederConfig.liveCamMaxMinDefault,
    );
    cfgObj.liveCamMaxMinutes = lmClamped;
    _liveCam.maxMinutes = lmClamped;
    // flash_renew (seq naik): reset timer flash manual bila lebih besar dari
    // yang terakhir dilihat.
    final fr = c['flash_renew'];
    if (fr is num && fr.toInt() > _lastFlashRenew) {
      _lastFlashRenew = fr.toInt();
      if (_flashManual) {
        _flashManualSince = DateTime.now();
        _devLog.add(
          LogDirection.info,
          'HP',
          'Timer flash di-renew dari webapp',
        );
      }
    }

    if (!changed) return;

    cfgObj.save();
    // Timeout layar bisa ikut berubah dari webapp -> pasang ulang timer.
    _resetInactivityTimer();
    _devLog.add(
      LogDirection.info,
      'SUPA',
      'Kalibrasi AI lokal J2 diperbarui dari webapp',
    );
    if (mounted) setState(() {});
  }

  /// TAIL (rev): calib.tail_cancel = seq int (naik), dedup seperti pola
  /// _lastLabelSeq -- pembatalan tail dari webapp (tombol di UI webapp).
  void _handleTailCancel(dynamic raw) {
    if (raw is! num) return;
    final seq = raw.toInt();
    if (seq <= _lastTailCancelSeq) return; // seq lama / sudah diproses
    _lastTailCancelSeq = seq;
    if (_isTailRecording) {
      _devLog.add(
        LogDirection.inbound,
        'SUPA',
        'Tail dibatalkan dari webapp (seq=$seq)',
      );
      _endTail('cancelled_web');
    }
  }

  // ---------------------------------------------------------------------
  // RESOURCE MONITOR (suhu/CPU/RAM J2)
  // ---------------------------------------------------------------------

  void _startResourceMonitor() {
    _resourceTimer = Timer.periodic(const Duration(seconds: 10), (_) async {
      if (!mounted) return;
      if (_btStatusDirty) _pushBtStatus(_btStatusLast);
      if (_rebootBacklog.isNotEmpty) _flushRebootBacklog(); // ROOM 2
      // 🟢 REVISI (P1 / SPEC 3.3): timeout flash manual + ulang tulis
      // flash_on=false yang gagal. Numpang tick yang sudah ada (tanpa timer baru).
      _checkFlashTimeout();
      if (_flashOffDirty) {
        if (_flashOn) {
          _flashOffDirty = false; // flash menyala lagi: tidak relevan
        } else {
          _pushFlashOff();
        }
      }
      // 🟢 REVISI (P1/R9 / SPEC 3.6): evaluasi restart aman (numpang tick ini).
      _restart.tick();
      try {
        final tempFile = File('/sys/class/thermal/thermal_zone0/temp');
        if (await tempFile.exists()) {
          final tempRaw = await tempFile.readAsString();
          _lastTempC = int.parse(tempRaw.trim()) / 1000.0;
          _tempText = '${_lastTempC.toStringAsFixed(1)}°C';
        }
        final loadFile = File('/proc/loadavg');
        if (await loadFile.exists()) {
          final loadRaw = await loadFile.readAsString();
          final load1Min = double.parse(loadRaw.split(' ')[0]);
          _lastCpuPercent = ((load1Min / 4.0) * 100).clamp(0, 100).round();
          _cpuText = '$_lastCpuPercent%';
        }
        final rssBytes = ProcessInfo.currentRss;
        _lastRamMb = rssBytes / (1024 * 1024);
        _ramJ2Text = '${_lastRamMb.toStringAsFixed(0)} MB';
      } catch (_) {}
      if (mounted) setState(() {});
    });
  }

  // ---------------------------------------------------------------------
  // KAMERA (🟢 REVISI P1 / Room 5): SEMUA buka/tutup/torch/stream/lock lewat
  // CameraManager (lib/camera_manager.dart). Layar ini HANYA menghitung
  // kebutuhan dari flag yang ada lalu memanggil _reconcileCameraState() ->
  // _cam.apply(...). Antrean, watchdog 2 dtk, dan restart kamera otomatis
  // yang dulu ada di sini DIHAPUS: bukti lapangan -- tutup-buka kamera tidak
  // pernah memulihkan layar hitam (SPEC 2). Watchdog di manager hanya
  // DETEKSI + CATAT; pemulihan = restart app terjadwal saat idle (Room 9).
  // ---------------------------------------------------------------------

  /// Image stream harus jalan (persis logika _ensureImageStreamState lama).
  bool get _needsStream =>
      _isFeeding || _isTailRecording || _isAiTestMode || _isLiveCamActive;

  /// Kamera harus terbuka. Preview manual / flash-saja = terbuka tanpa stream.
  bool get _needsCamera =>
      _needsStream || _sessionStarting || _cameraForcedOn || _flashOn;

  /// 🟢 REVISI (P1): SATU titik pusat. Idempotent; panggilan bertumpuk
  /// digabung di CameraManager (yang dieksekusi = kebutuhan TERBARU).
  /// Future selesai saat kebutuhan terbaru terpenuhi (tidak melempar).
  Future<void> _reconcileCameraState() {
    if (_disposing) return Future<void>.value();
    _logCameraHolders();
    return _cam.apply(_needsCamera, _needsStream, _flashOn);
  }

  String _lastHoldersSig = '\u0000';

  /// Catat ke dev log SETIAP kali daftar penahan kamera berubah, supaya
  /// "kenapa kamera nyala / kenapa tidak nyala" selalu terlihat sebagai [CAM].
  void _logCameraHolders() {
    final sig = _cameraHolders().join(' | ');
    if (sig == _lastHoldersSig) return;
    _lastHoldersSig = sig;
    _devLog.add(
      LogDirection.info,
      'CAM',
      sig.isEmpty ? 'Penahan kamera: (tidak ada)' : 'Penahan kamera: $sig',
    );
  }

  String _ago(DateTime? t) {
    if (t == null) return '?';
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '${d.inSeconds} dtk lalu';
    if (d.inHours < 1) return '${d.inMinutes} mnt lalu';
    return '${d.inHours} jam ${d.inMinutes % 60} mnt lalu';
  }

  /// Daftar siapa yang sekarang membuat kamera tetap terbuka. [detail]=true
  /// menambah keterangan waktu/durasi (untuk snackbar; jangan dipakai untuk log
  /// karena berubah tiap detik).
  List<String> _cameraHolders({bool detail = false}) {
    final h = <String>[];
    if (_isFeeding) h.add('Sesi pakan');
    if (_isTailRecording) h.add('Rekam tail pasca-pakan');
    if (_isAiTestMode) {
      var s = 'Uji Coba AI';
      if (detail) {
        final dur = _trialDurationMin == null
            ? 'tanpa batas waktu'
            : 'durasi $_trialDurationMin mnt';
        s += ' (mulai ${_ago(_trialStartedAt)}, $dur)';
      }
      h.add(s);
    }
    if (_isLiveCamActive) {
      var s = 'Live-cam (ada viewer di channel)';
      if (detail && _liveCamOffTimer != null) {
        s += ' - viewer sudah hilang, menunggu 20 dtk';
      }
      h.add(s);
    }
    if (_flashManual) {
      h.add(
        detail
            ? 'Flash manual (web/tombol J2, nyala ${_ago(_flashManualSince)})'
            : 'Flash manual',
      );
    }
    if (_flashAuto) h.add('Flash otomatis sesi pakan');
    if (_cameraForcedOn) h.add('Override Dev (ketuk kotak kamera)');
    if (_sessionStarting) h.add('Sesi pakan sedang dimulai');
    return h;
  }

  /// 🟢 REVISI (P1/R9 / SPEC 3.6): true = SEMUA idle -> aman restart app.
  /// Tidak feeding/tail/uji coba/live-cam/flash/preview, rantai upload kosong,
  /// push cfg selesai (jadwal pakan dinilai di SafeRestartScheduler).
  Future<bool> _isRestartIdle() async {
    if (_disposing || !mounted) return false;
    if (_isFeeding || _isTailRecording || _isAiTestMode || _isLiveCamActive) {
      return false;
    }
    if (_sessionStarting || _cameraForcedOn || _flashOn) return false;
    if (_cam.isCameraActive || _cam.torchActual) return false;
    if (_cfgPushing > 0) return false;
    if (_rebootBusy || _rebootBacklog.isNotEmpty) return false; // ROOM 2
    if (_diagTimer != null || _diagBusy || _diagBacklog.isNotEmpty) {
      return false;
    }
    final phase = _lastTelemetry?.feeder.msg;
    if (_isBtConnected &&
        phase != null &&
        const {'PREP AI', 'DISPENSE', 'WAIT AI'}.contains(phase)) {
      return false;
    }
    // Rantai upload kosong: future yang sudah selesai menjalankan callback-nya
    // dalam satu putaran microtask.
    var uploadDone = false;
    _uploadChain.then(
      (_) => uploadDone = true,
      onError: (_) => uploadDone = true,
    );
    await Future<void>.microtask(() {});
    await Future<void>.microtask(() {});
    return uploadDone && !_disposing;
  }

  /// Event kamera -> recorder (ai_diag_log). Hanya saat ada rekaman sesi
  /// (atau sesi sedang dimulai) supaya buffer recorder tidak menumpuk di luar sesi.
  void _camEvent(String name, Map<String, dynamic>? data) {
    if (_diagTimer == null && !_sessionStarting) return;
    _recorder.addEvent(DateTime.now(), name, data);
  }

  /// torchActual berubah -> tulis feeder_status.flash_actual (HANYA saat berubah).
  void _onTorchActualChanged(bool actual) {
    if (_disposing) return;
    _supabase.setFlashActual(actual);
  }

  /// Watchdog/init melaporkan masalah. Event cam_black/cam_stall sudah dikirim
  /// manager lewat onEvent (jangan dobel). Di sini: feeder_status.cam_issue +
  /// cam_issue_at SEKALI per jenis per sesi. restartRecommended dipegang manager.
  void _onCamIssue(String kind, Map<String, dynamic> data) {
    if (_disposing) return;
    if (!(_isFeeding || _isTailRecording || _sessionStarting)) return;
    if (!_camIssueReported.add(kind)) return;
    _supabase.setCamIssue(kind, DateTime.now());
  }

  // ----------------------------- FLASH -------------------------------------

  /// Flash dari tombol J2 / webapp (manual). on=false membatalkan manual DAN
  /// auto-sesi (user selalu menang). [fromWeb] = berasal dari device_config.flash_on
  /// (DB sudah berisi nilainya -> tidak ditulis balik).
  Future<void> _applyFlash(bool on, {bool fromWeb = false}) async {
    final before = _flashOn;
    final manualBefore = _flashManual;
    if (on) {
      _flashManual = true;
    } else {
      _flashManual = false;
      _flashAuto = false;
    }
    if (_flashManual && !manualBefore) {
      _flashManualSince = DateTime.now();
      _flashViewerSeen = _isLiveCamActive;
    }
    if (!_flashManual) {
      _flashManualSince = null;
      _flashViewerSeen = false;
    }
    await _afterFlashChange(before, fromWeb: fromWeb);
  }

  /// Flash otomatis selama sesi pakan (+ tail). Hanya dinyalakan bila
  /// calib.flash_auto_session = true (default false, SPEC 4).
  Future<void> _setFlashAuto(bool on) async {
    if (_flashAuto == on) return;
    final before = _flashOn;
    _flashAuto = on;
    await _afterFlashChange(before);
  }

  /// J2 sendiri mematikan flash MANUAL (timeout / viewer hilang). Flash
  /// otomatis sesi (bila ada) tidak ikut dibatalkan.
  void _flashOffManual(String reason) {
    if (!_flashManual) return;
    final before = _flashOn;
    _flashManual = false;
    _flashManualSince = null;
    _flashViewerSeen = false;
    _devLog.add(LogDirection.info, 'HP', 'Flash manual dimatikan J2: $reason');
    _afterFlashChange(before);
  }

  /// Dipanggil dari tick _resourceTimer (10 dtk).
  void _checkFlashTimeout() {
    final since = _flashManualSince;
    if (!_flashManual || since == null) return;
    final limit = Duration(
      milliseconds: (widget.config.flashTimeoutSeconds * 1000).round(),
    );
    if (DateTime.now().difference(since) >= limit) {
      _flashOffManual('timeout ${limit.inSeconds} dtk');
    }
  }

  /// Tulis device_config.flash_on=false BERSYARAT (hanya bila masih true).
  /// Gagal (mis. WiFi mati) -> _flashOffDirty, diulang tick resource.
  Future<void> _pushFlashOff() async {
    final ok = await _supabase.setFlashOffIfOn();
    _flashOffDirty = !ok;
  }

  Future<void> _afterFlashChange(bool before, {bool fromWeb = false}) async {
    if (mounted && !_disposing) setState(() {});
    final changed = before != _flashOn;
    if (changed) {
      _devLog.add(
        LogDirection.info,
        'HP',
        'Flash ${_flashOn ? "ON" : "OFF"} diminta (manual=$_flashManual auto=$_flashAuto)',
      );
    }
    // Torch fisik diatur CameraManager (torchActual dilaporkan lewat onTorchChanged).
    final applied = _reconcileCameraState();
    if (changed && !_disposing) {
      if (fromWeb) {
        _flashOffDirty = false; // DB sudah sama dengan niat
      } else if (_flashOn) {
        _supabase.setFlashOn(true); // cerminkan flash nyala ke webapp
      } else {
        _pushFlashOff(); // bersyarat; bukan menimpa klik web yang lebih baru
      }
    }
    await applied;
  }

  /// Dipanggil LiveCamService HANYA saat status "ada viewer" BENAR-BENAR
  /// berubah. Viewer HILANG ditunda 20 dtk (hysteresis) supaya presence yang
  /// berkedip (reconnect socket) tidak membuat kamera dibuka-tutup berulang.
  void _onLiveCamWatchersChanged(bool active) {
    if (!mounted) return;
    _devLog.add(
      LogDirection.info,
      'CAM',
      active
          ? 'Live-cam: viewer ADA (presence tidak kosong)'
          : 'Live-cam: viewer HILANG (kamera ditutup 20 dtk lagi bila tidak kembali)',
    );
    if (active) {
      _liveCamOffTimer?.cancel();
      _liveCamOffTimer = null;
      if (_isLiveCamActive) return;
      setState(() => _isLiveCamActive = true);
      _lastLiveCamSentAt = null;
      if (_flashManual) _flashViewerSeen = true; // 🟢 REVISI (P1 / SPEC 3.3)
      _reconcileCameraState();
      return;
    }
    if (!_isLiveCamActive) return;
    _liveCamOffTimer?.cancel();
    _liveCamOffTimer = Timer(const Duration(seconds: 20), () {
      _liveCamOffTimer = null;
      if (!mounted || !_isLiveCamActive) return;
      setState(() => _isLiveCamActive = false);
      _lastLiveCamSentAt = null;
      // 🟢 REVISI (P1 / SPEC 3.3): viewer yang tadinya ada lalu hilang
      // (presence leave / ping habis) -> flash manual mati. Batas durasi
      // live-cam (isCapped) BUKAN viewer hilang. Viewer yang tak pernah ada
      // -> hanya timeout/web yang berlaku.
      if (_flashManual && _flashViewerSeen && !_liveCam.isCapped) {
        _flashOffManual('viewer live-cam hilang');
      }
      _reconcileCameraState();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 🟢 REVISI (P1 / SPEC 3.1): cek kesehatan controller saat `resumed`
    // dilakukan CameraManager sendiri (WidgetsBindingObserver di dalamnya).
    // Layar tidak lagi menutup kamera saat `paused` lewat jalur terpisah.
    if (state == AppLifecycleState.resumed) {
      _reconcileCameraState(); // idempotent
    }
  }

  Future<void> _toggleCameraOverride() async {
    setState(() => _cameraForcedOn = !_cameraForcedOn);
    if (_cameraForcedOn) {
      _devLog.add(
        LogDirection.info,
        'HP',
        'Kamera dipaksa nyala manual (dev override)',
      );
    } else {
      _devLog.add(LogDirection.info, 'HP', 'Kamera override dimatikan');
    }
    await _reconcileCameraState();
  }

  void _startDiagUpload() {
    _camLogged = false;
    _diagTimer?.cancel();
    _diagTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _flushDiag(
        // TAIL (rev): tail masih bagian dari sesi _aiSessionId yang sama.
        sessionId: (_isFeeding || _isTailRecording)
            ? _aiSessionId
            : _trialSessionId,
        trial: _isAiTestMode,
      );
    });
    // Kunci fokus & exposure otomatis setelah kamera sempat konvergen,
    // supaya perubahan auto-exposure tidak terbaca sebagai "gerakan".
    _camLockTimer?.cancel();
    _camLockTimer = Timer(const Duration(seconds: 5), _lockCameraAuto);
  }

  Future<void> _stopDiagUpload({int? sessionId, bool trial = false}) async {
    _diagTimer?.cancel();
    _diagTimer = null;
    _camLockTimer?.cancel();
    _camLockTimer = null;
    _cam.unlockAuto(); // 🟢 REVISI (P1): rekaman selesai -> lepas kunci fokus/exposure
    await _flushDiag(sessionId: sessionId, trial: trial, force: true);
  }

  Future<void> _flushDiag({
    int? sessionId,
    bool trial = false,
    bool force = false,
  }) async {
    final diag = _recorder.flush();
    if (diag != null) {
      _diagBacklog.add({
        'session_id': sessionId,
        'is_trial': trial,
        'diag': diag,
      });
      while (_diagBacklog.length > _diagBacklogMax) {
        _diagBacklog.removeAt(0);
      }
    }
    if (_diagBacklog.isEmpty) return;
    if (_diagBusy && !force) return;
    _diagBusy = true;
    final batch = List<Map<String, dynamic>>.from(_diagBacklog);
    try {
      await _supabase.insertAiDiag(batch);
      _diagBacklog.removeRange(0, batch.length);
    } catch (e) {
      _devLog.add(
        LogDirection.error,
        'SUPA',
        'Upload ai_diag gagal (${_diagBacklog.length} paket ditahan): $e',
      );
    } finally {
      _diagBusy = false;
    }
  }

  /// 🟢 REVISI (P1): kunci fokus+exposure dikerjakan CameraManager (tunggu
  /// torch settle 2 dtk, re-lock bila torch berubah). Event `cam_lock` dikirim
  /// manager lewat onEvent -- jangan dobel di sini.
  Future<void> _lockCameraAuto() => _cam.lockAuto();

  /// Catat resolusi frame SEBENARNYA sekali per sesi (preset "medium" itu
  /// perkiraan, ukuran riil bergantung perangkat). Bandingkan antar sesi.
  void _logCamOnce(CameraImage image, DateTime now) {
    if (_camLogged) return;
    _camLogged = true;
    final ps = _cam.previewSize; // 🟢 REVISI (P1)
    _recorder.addEvent(now, 'cam', {
      'w': image.width,
      'h': image.height,
      'fmt': image.format.group.toString(),
      'row_stride': image.planes[0].bytesPerRow,
      'preview': ps == null ? null : '${ps.width.toInt()}x${ps.height.toInt()}',
      'flash': _flashOn,
    });
  }

  /// Fase terakhir yang sudah dicatat (untuk event 'phase' di recorder).
  String? _lastPhase;

  /// Catat perubahan fase trigger ke recorder (idle/baseline/pulse/eval/
  /// continue/stop/no_decision). Hanya menulis saat fase benar-benar berubah.
  void _notePhase(DateTime t) {
    final p = _trigger?.phase;
    if (p == null || p == _lastPhase) return;
    _lastPhase = p;
    _recorder.addEvent(t, 'phase', {'p': p});
  }

  /// Satu keputusan putaran selesai dihitung. Selalu dicatat (recorder +
  /// dev log). Kirim CMD:LANJUT ke ESP HANYA di sesi produksi ([live]) --
  /// di Uji Coba AI tidak ada yang dikirim. STOP ditangani _onFrame lewat
  /// _handleStop (hanya produksi).
  void _handleDecision(RoundDecision d, DateTime t, {required bool live}) {
    _recorder.addEvent(t, 'round', d.toJson());
    final ratio = d.ratio == null ? '-' : d.ratio!.toStringAsFixed(2);
    final resp = d.response == null ? '-' : d.response!.toStringAsFixed(0);
    _devLog.add(
      LogDirection.info,
      'HP',
      '${live ? "" : "(uji) "}Putaran ${d.round}: respon=$resp '
          'acuan=${d.ref.toStringAsFixed(0)} rasio=$ratio strike=${d.strikes} '
          '-> ${d.verdict} / ${d.action}',
    );
    if (live && d.action == 'LANJUT') {
      _btService.sendCommand('LANJUT');
    }
  }

  String _phaseLabel(String? p) {
    switch (p) {
      case 'tail': // TAIL (rev)
        return 'TAIL (merekam pemulihan, tanpa perintah)';
      case 'baseline':
        return 'BASELINE (mengukur kondisi sepi)';
      case 'pulse':
        return 'PULSA PAKAN';
      case 'eval':
        return 'MENGHITUNG respon';
      case 'continue':
        return 'KEPUTUSAN: LANJUT';
      case 'stop':
        return 'KEPUTUSAN: STOP';
      case 'no_decision':
        return 'AI TIDAK MEMUTUSKAN';
      case 'wait':
        return 'MENUNGGU';
      default:
        return 'IDLE';
    }
  }

  FeederTriggerAdaptive _newTrigger({required bool dryRun}) {
    final c = widget.config;
    return FeederTriggerAdaptive(
      tauSeconds: c.emaTauSeconds,
      medianWindow: c.medianWindow,
      roundWinStartS: c.roundWinStartS,
      roundWinEndS: c.roundWinEndS,
      ratioOk: c.ratioOk,
      ratioHard: c.ratioHard,
      strikesToStop: c.strikesToStop,
      snrMin: c.snrMin,
      baselineSkipS: c.baselineSkipS,
      baselineMaxS: c.baselineMaxS,
      baselineMinS: c.baselineMinS,
      dryRun: dryRun,
    );
  }

  /// Konfigurasi yang dipakai sesi ini -- ikut tercatat di ai_diag (flush
  /// pertama) supaya setiap rekaman bisa direproduksi offline.
  Map<String, dynamic> _cfgSnapshot({required bool dryRun}) {
    final c = widget.config;
    return {
      'dry_run': dryRun,
      'algo': 'ratio_v3',
      'ratio_ok': c.ratioOk,
      'ratio_hard': c.ratioHard,
      'strikes_to_stop': c.strikesToStop,
      'snr_min': c.snrMin,
      'baseline_skip_s': c.baselineSkipS,
      'baseline_max_s': c.baselineMaxS,
      'baseline_min_s': c.baselineMinS,
      'ema_tau_s': c.emaTauSeconds,
      'median_window': c.medianWindow,
      'processing_fps': c.processingFps,
      'round_win_start_s': c.roundWinStartS,
      'round_win_end_s': c.roundWinEndS,
      'keepalive_s': c.keepAliveSeconds,
      'cam_preset': 'medium',
    };
  }

  // ---------------------------------------------------------------------
  // SESI FEEDING (AI CV lokal di J2, dipicu telemetri ESP)
  // ---------------------------------------------------------------------

  Future<void> _startFeeding() async {
    // Jembatan: selama transisi (termasuk _endTail('new_session')) kamera &
    // flash TIDAK boleh dimatikan lalu dinyalakan lagi.
    _sessionStarting = true;
    try {
      await _startFeedingImpl();
    } finally {
      _sessionStarting = false;
      _reconcileCameraState();
    }
  }

  Future<void> _startFeedingImpl() async {
    // TAIL (rev): sesi baru memotong tail yang sedang berjalan (KEPUTUSAN
    // #5) -- baik dipicu telemetri ESP maupun tombol "Simulasi Start
    // Manual", keduanya memanggil fungsi ini.
    if (_isTailRecording) await _endTail('new_session');

    // 🟢 REVISI (P1 / SPEC 3.2): sesi baru -> reset penanda masalah kamera
    // (lokal + DB, bersyarat: hanya bila cam_issue sebelumnya tidak null).
    _camIssueReported.clear();
    _cam.clearRestartRecommended();
    _supabase.clearCamIssueIfSet();

    // 🟢 REVISI (P1): recorder di-reset SEBELUM kamera dibuka supaya event
    // cam_open/torch/cam_lock sesi ini ikut terekam (dulu direset sesudahnya).
    _recorder.reset();
    _recorder.setCfg(_cfgSnapshot(dryRun: false));

    // _sessionStarting = true (dari _startFeeding) -> needCamera true.
    await _reconcileCameraState();
    if (!_isCameraActive) {
      _devLog.add(
        LogDirection.error,
        'HP',
        'Gagal mulai feeding: kamera belum siap',
      );
      return;
    }

    // 🟢 REVISI (P1 / SPEC 3.3): flash otomatis sesi HANYA bila
    // calib.flash_auto_session = true (default false). Torch nyala SEBELUM
    // exposure dikunci (lock dipasang _startDiagUpload -> manager).
    await _setFlashAuto(widget.config.flashAutoSession);

    setState(() {
      _isFeeding = true;
      _statusText = 'Feeding...';
      _lastEma = 0; // 🟢 REVISI (P1 / SPEC 3.5): jangan bawa EMA/peak sesi lama
      _lastPeak = 0;
    });

    _supabase
        .updateFeedingStatus(state: 'feeding', stopReason: null)
        .catchError((e) {
          _devLog.add(
            LogDirection.error,
            'SUPA',
            'Gagal update status feeding (start): $e',
          );
        });

    _extractor.reset();
    _trigger = _newTrigger(dryRun: false);
    _lastPhase = null;
    // (🟢 REVISI P1: _recorder.reset()/setCfg dipindah ke atas, sebelum kamera dibuka)
    _startDiagUpload();
    _lastProcessedAt = null;

    // 🟢 ID pengelompokan baris log AI 1 sesi ini (lihat _aiFields) +
    // reset skor mentah dari sesi sebelumnya.
    _aiSessionId = DateTime.now().millisecondsSinceEpoch;
    _lastRawScore = null;

    // REVISI v3: tidak ada lagi keep-alive buta berbasis ambang EMA mutlak.
    // CMD:LANJUT dikirim (1) sekali begitu keputusan putaran = LANJUT
    // (lihat _handleDecision) dan (2) diulang tiap keepAliveSeconds SELAMA
    // keputusan terakhir LANJUT dan putaran berikutnya belum mulai
    // (_trigger.continueGranted). Tanpa keputusan LANJUT (sinyal lemah /
    // baseline tidak valid / STOP) tidak ada kiriman sama sekali, dan sesi
    // berakhir lewat timeout feval / fmax di ESP.
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(
      Duration(milliseconds: (widget.config.keepAliveSeconds * 1000).round()),
      (_) {
        if (!_isFeeding || _trigger == null) return;
        if (_trigger!.continueGranted) {
          _btService.sendCommand('LANJUT');
        }
      },
    );

    // Kirim EMA & peak saat ini ke Supabase secara berkala (dipakai
    // Dashboard webapp) -- pakai timer terpisah dari keep-alive supaya
    // frekuensinya tidak tersandera oleh keputusan "ada aktivitas atau
    // tidak" di atas.
    _metricsTimer?.cancel();
    _metricsTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      // TAIL (rev): tetap kirim selama tail juga, dengan state 'tail'.
      if (!(_isFeeding || _isTailRecording) || _trigger == null) return;
      _supabase
          .updateFeedingStatus(
            state: _isTailRecording ? 'tail' : 'feeding',
            stopReason: null,
            ema: _trigger!.ema,
            peak: _trigger!.peakRunning,
          )
          .catchError((e) {
            _devLog.add(LogDirection.error, 'SUPA', 'Gagal kirim ema/peak: $e');
          });
    });

    // 🟢 LOG AI GRANULAR ke device_telemetry (-> trg_telemetry_hist ->
    // history), SENGAJA dipisah dari _metricsTimer di atas (yang cuma
    // nulis status LIVE ke feeder_status) dan dari _onTelemetry (yang
    // nunggu heartbeat ESP tiap cfg.up detik / event-driven -- terlalu
    // kasar buat lihat kurva decay yang cuma berlangsung beberapa detik).
    // Dasar barisnya tetap _lastTelemetry (paket ESP terakhir yang
    // diketahui) supaya kolom sensor/actuator/system gak ikut ke-nol-kan,
    // cuma field ai_* yang benar-benar fresh tiap tick.
    _aiLogTimer?.cancel();
    _aiLogTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      // TAIL (rev): tetap kirim selama tail juga.
      if (!(_isFeeding || _isTailRecording) || _lastTelemetry == null) return;
      _queueTelemetryUpload(_lastTelemetry!);
    });

    await _reconcileCameraState(); // needStream sekarang true -> stream dinyalakan
    if (!_cam.isStreaming) {
      _showSnack('Gagal akses kamera');
    }
  }

  /// TAIL (rev): durasi efektif tail recording (detik). 0 = tail mati
  /// (config.tailRecordSeconds = 0 -> jalur lama penuh dipakai di
  /// _handleStop). Kalau tail aktif, durasi dipaksa minimal
  /// roundWinEndS + 10 supaya jendela evaluasi putaran terakhir selalu
  /// sempat dituntaskan sebelum tail berakhir (lihat KEPUTUSAN #3).
  double _effectiveTailSeconds() {
    final cfg = widget.config.tailRecordSeconds;
    if (cfg <= 0) return 0;
    return math.max(cfg, widget.config.roundWinEndS + 10);
  }

  Future<void> _handleStop(String reason) async {
    // TAIL (rev): guard pemanggilan ganda -- sesi yang memang sudah tidak
    // berjalan (sudah diproses panggilan _handleStop sebelumnya) diabaikan.
    if (!_isFeeding) return;

    // 🟢 Kirim baris PENUTUP log AI (ema/peak/below_counter TERAKHIR +
    // ai_stop_reason=$reason) SEBELUM _isFeeding di-set false -- lihat
    // catatan di _uploadFinalAiSnapshot soal kenapa ini harus di sini,
    // bukan sesudah setState di bawah.
    await _uploadFinalAiSnapshot(reason);

    setState(() {
      _isFeeding = false;
      _statusText = 'Stopped ($reason)';
    });

    _keepAliveTimer?.cancel();

    // Stop yang diminta USER SECARA MANUAL dari tombol J2 sendiri butuh
    // jeda anti-restart -- lihat catatan di deklarasi
    // _suppressAutoRestartUntil. (STOP DARURAT dari webapp/touch ESP tidak
    // perlu ini: J2 baru tahu sesi berakhir SETELAH ESP benar-benar
    // mengubah fasenya, jadi urutannya sudah aman dengan sendirinya.)
    if (reason == 'manual_stop') {
      _suppressAutoRestartUntil = DateTime.now().add(
        const Duration(seconds: 3),
      );
    }

    // (Image stream TIDAK di-stop manual di sini lagi -- _reconcileCameraState
    // yang memutuskan, supaya kalau live-cam masih ada viewer aktif / tail
    // sedang jalan, stream TETAP jalan walau sesi feeding sudah selesai.)

    // Kirim keputusan AI ke ESP HANYA kalau AI yang memutuskan stop --
    // kalau ESP duluan yang stop, gak perlu kirim balik (hindari loop).
    // TAIL (rev): 'panic' juga TIDAK mengirim CMD:STOP -- STOP DARURAT
    // sudah diteruskan sebagai ovr.x sesaat sebelumnya (lihat
    // _onRemoteConfigChanged / _panicSentAt); kirim CMD:STOP lagi di sini
    // cuma mengulang perintah yang sudah sampai lewat jalur lain.
    if (reason != 'esp_menghentikan_feeder' && reason != 'panic') {
      await _btService.sendCommand('STOP');
    }

    // TAIL (rev): durasi efektif > 0 -> masuk TAIL RECORDING (KEPUTUSAN
    // #1/#3). _stopDiagUpload, _aiLogTimer, _metricsTimer, _trigger, dan
    // _aiSessionId SENGAJA TIDAK dihentikan/di-null di sini -- tetap jalan
    // sampai _endTail() dipanggil nanti (timeout / dibatalkan / sesi baru).
    if (_effectiveTailSeconds() > 0) {
      await _beginTail(reason);
      return;
    }

    // tailRecordSeconds = 0 -> jalur lama PENUH (perilaku sebelum revisi
    // TAIL: semua pembersihan sesi langsung di sini).
    await _stopDiagUpload(sessionId: _aiSessionId, trial: false);
    _metricsTimer?.cancel();
    _aiLogTimer?.cancel();
    _aiSessionId = null;
    _lastRawScore = null;

    try {
      await _supabase.updateFeedingStatus(state: 'stopped', stopReason: reason);
    } catch (e) {
      _devLog.add(LogDirection.error, 'SUPA', 'Gagal sinkron status stop: $e');
      _showSnack('Gagal simpan log ke server!');
    }

    _setFlashAuto(false); // tanpa tail: sesi selesai -> flash otomatis mati
    _reconcileCameraState();
  }

  /// TAIL (rev): mulai tail recording setelah sesi pakan berakhir.
  /// Aktuator sudah selesai (_handleStop sudah mengirim/menahan CMD:STOP
  /// di atas) -- kamera/AI tetap merekam _effectiveTailSeconds() detik
  /// lagi supaya kurva EMA terlihat turun kembali. Timer diag (2s)/ai log
  /// (1s)/metrics (3s) TETAP jalan apa adanya (lihat _startDiagUpload &
  /// _startFeeding); hanya _trigger yang diberi tahu lewat enterTail()
  /// supaya ia tidak pernah lagi mengunci STOP/memicu kiriman ke ESP.
  Future<void> _beginTail(String reason) async {
    final durSeconds = _effectiveTailSeconds();
    _trigger?.enterTail();
    _tailTimer?.cancel();
    final endsAt = DateTime.now().add(
      Duration(milliseconds: (durSeconds * 1000).round()),
    );
    if (mounted) {
      setState(() {
        _isTailRecording = true;
        _tailReason = reason;
        _tailEndsAt = endsAt;
        _statusText = 'Tail recording ($reason)';
      });
    } else {
      _isTailRecording = true;
      _tailReason = reason;
      _tailEndsAt = endsAt;
    }
    _tailTimer = Timer(
      Duration(milliseconds: (durSeconds * 1000).round()),
      () => _endTail('timeout'),
    );
    _recorder.addEvent(DateTime.now(), 'tail_start', {
      'reason': reason,
      'dur_s': durSeconds,
    });
    _devLog.add(
      LogDirection.info,
      'HP',
      'Tail recording dimulai: $reason, durasi ${durSeconds.toStringAsFixed(0)}s',
    );
    try {
      await _supabase.updateFeedingStatus(state: 'tail', stopReason: reason);
    } catch (e) {
      _devLog.add(LogDirection.error, 'SUPA', 'Gagal update status tail: $e');
    }
    _reconcileCameraState();
  }

  /// TAIL (rev): akhiri tail recording. Idempoten -- aman dipanggil lebih
  /// dari sekali atau saat tail sebenarnya tidak sedang aktif. [cause] ∈
  /// timeout | cancelled_user | cancelled_web | new_session | uji_coba_ai |
  /// dispose -- BUKAN alasan sesi berakhir (itu disimpan di _tailReason
  /// sejak _beginTail dan dipakai sebagai stopReason/ai_stop_reason final).
  Future<void> _endTail(String cause) async {
    if (!_isTailRecording) return;
    final reason = _tailReason ?? 'unknown';

    _tailTimer?.cancel();
    _tailTimer = null;

    _recorder.addEvent(DateTime.now(), 'tail_end', {'cause': cause});

    // Snapshot penutup TAIL (bukan snapshot stop yang sudah dikirim di
    // _handleStop) -- ai_tail=true, ai_stop_reason = reason ASLI sesi
    // (bukan `cause` berakhirnya tail).
    await _uploadFinalAiSnapshot(reason, overrideTail: true);

    await _stopDiagUpload(sessionId: _aiSessionId, trial: false);
    _metricsTimer?.cancel();
    _aiLogTimer?.cancel();

    if (mounted) {
      setState(() {
        _isTailRecording = false;
        _tailReason = null;
        _tailEndsAt = null;
        _statusText = 'Idle';
      });
    } else {
      _isTailRecording = false;
      _tailReason = null;
      _tailEndsAt = null;
    }

    _trigger = null;
    _aiSessionId = null;
    _lastRawScore = null;

    try {
      await _supabase.updateFeedingStatus(state: 'stopped', stopReason: reason);
    } catch (e) {
      _devLog.add(
        LogDirection.error,
        'SUPA',
        'Gagal sinkron status akhir tail: $e',
      );
    }

    _devLog.add(
      LogDirection.info,
      'HP',
      'Tail recording selesai ($cause, reason sesi=$reason)',
    );
    // Sesi baru menyambung (new_session) -> flash JANGAN berkedip off/on.
    if (!_sessionStarting) _setFlashAuto(false);
    _reconcileCameraState();
  }

  void _onFrame(CameraImage image) {
    // Live-cam SENGAJA dicek paling atas, sebelum cabang mode manapun --
    // boleh nyala BARENGAN sesi AI/feeding, jadi tidak boleh ikut ke-skip
    // oleh early-return di bawah (kalau diletakkan di dalam salah satu
    // cabang mode, dia hanya akan jalan saat mode itu aktif saja, padahal
    // live-cam harus independen dari sedang feeding/AI test/idle atau tidak).
    _maybeCaptureLiveCamFrame(image);

    // 🟢 REVISI (P1 / SPEC 2 & 3.2): gerbang "frame hitam -> AI diam" DIBUANG.
    // Kamera hitam = kurang pakan (1 putaran), BUKAN overfeeding, jadi tidak
    // perlu penanganan "frame invalid" khusus. Deteksi black/stall dilakukan
    // watchdog CameraManager (hanya mencatat; tanpa restart kamera).

    if (_isAiTestMode) {
      _onAiTestFrame(image);
      return;
    }
    // TAIL (rev): frame tetap diproses selama _isFeeding ATAU
    // _isTailRecording (KEPUTUSAN #4). Guard `_trigger!.stopped` lama
    // dibuang -- trigger sendiri yang menahan diri lewat `inTail` (lihat
    // feeder_trigger.dart), bukan lagi tanggung jawab layar ini.
    if (!(_isFeeding || _isTailRecording) || _trigger == null) return;
    if (_isProcessingFrame) return;

    final now = DateTime.now();
    if (_lastProcessedAt != null &&
        now.difference(_lastProcessedAt!) < _minFrameInterval) {
      return;
    }
    _lastProcessedAt = now;
    _isProcessingFrame = true;
    _logCamOnce(image, now);

    try {
      final sw = Stopwatch()..start();
      final raw = _extractor.processFrame(image);
      sw.stop();
      if (raw == null) return; // frame pertama: belum ada pembanding
      _lastRawScore = raw; // dipakai _aiFields() -> kolom ai_raw
      _recorder.addFrame(now, _extractor.strideScores, sw.elapsedMilliseconds);
      // TAIL (rev): update() selama tail (trigger.inTail) tidak pernah
      // mengembalikan 'STOP' -- stoppedNow otomatis selalu false di sini
      // saat _isTailRecording, tanpa perlu guard tambahan di layar ini.
      final stoppedNow = _trigger!.update(raw, now) == 'STOP';
      final decision = _trigger!.takeDecision();
      // TAIL (rev): live:false saat tail -- jendela evaluasi putaran
      // terakhir tetap dituntaskan & dicatat (recorder + dev log), tapi
      // TIDAK PERNAH mengirim CMD:LANJUT ke ESP.
      if (decision != null) {
        _handleDecision(decision, now, live: !_isTailRecording);
      }
      _notePhase(now);
      final st = _trigger!.state();

      if (mounted) {
        setState(() {
          _lastEma = (st['ema'] as double?) ?? 0;
          _lastPeak = st['peak_running'] as double;
        });
      }

      // TAIL (rev): _handleStop TIDAK PERNAH dipanggil selama tail --
      // dijamin oleh trigger (stoppedNow selalu false saat inTail), guard
      // `!_isTailRecording` dipertahankan sebagai pertahanan berlapis.
      if (stoppedNow && !_isTailRecording) {
        _handleStop(_trigger!.lastStopReason ?? 'unknown');
      }
    } finally {
      _isProcessingFrame = false;
    }
  }

  // ---------------------------------------------------------------------
  // LIVE-CAM: ambil 1 frame sesekali, encode di isolate lain, kirim lewat
  // Realtime Broadcast. Lihat live_cam_service.dart untuk detail & alasan
  // desainnya (kenapa presence, kenapa grayscale, kenapa isolate terpisah).
  // ---------------------------------------------------------------------

  static const int _liveCamTargetWidth = 320;
  static const int _liveCamTargetHeight = 240;
  static const int _liveCamJpegQuality =
      40; // kecil sengaja -- lihat catatan kuota

  void _maybeCaptureLiveCamFrame(CameraImage image) {
    if (!_isLiveCamActive) return;

    // Masih ada 1 frame yang lagi diproses isolate lain -- jangan tumpuk
    // job baru di atasnya. compute() spawn isolate baru tiap panggilan;
    // menumpuk job cuma bikin antrean & tidak mempercepat apa pun.
    if (_isEncodingLiveCamFrame) return;

    final clampedSeconds = FeederConfig.clampLiveCamInterval(
      widget.config.liveCamIntervalSeconds,
    );
    final interval = Duration(milliseconds: (clampedSeconds * 1000).round());
    final now = DateTime.now();
    if (_lastLiveCamSentAt != null &&
        now.difference(_lastLiveCamSentAt!) < interval) {
      return;
    }
    _lastLiveCamSentAt = now;
    _isEncodingLiveCamFrame = true;

    // buildLiveCamJob() men-COPY byte Y-plane SEKARANG JUGA (di dalam
    // callback ini) -- WAJIB, karena buffer asli dari plugin kamera cuma
    // valid selama callback _onFrame berjalan. Setelah ini, job aman
    // dikirim lintas isolate kapan saja.
    final LiveCamFrameJob job;
    try {
      job = buildLiveCamJob(
        image,
        targetWidth: _liveCamTargetWidth,
        targetHeight: _liveCamTargetHeight,
        jpegQuality: _liveCamJpegQuality,
      );
    } catch (e) {
      // Tanpa ini flag encode tersangkut true dan live-cam diam sampai restart.
      _isEncodingLiveCamFrame = false;
      _devLog.add(LogDirection.error, 'CAM', 'Gagal siapkan job live-cam: $e');
      return;
    }

    // 🟢 INI BAGIAN PENTINGNYA: buildLiveCamFrame() jalan di ISOLATE
    // TERPISAH lewat compute(). Encode JPEG (downsample + kompres) TIDAK
    // PERNAH menyentuh main isolate tempat _extractor.processFrame() &
    // _trigger.update() (loop motion energy) berjalan -- jadi walau
    // live-cam nyala BARENG sesi AI/feeding, keputusan lanjut/stop pakan
    // tidak pernah tertunda/tersela oleh kerja encode JPEG ini.
    buildLiveCamFrame(job)
        .timeout(const Duration(seconds: 10))
        .then((jpegBytes) {
          _isEncodingLiveCamFrame = false;
          if (jpegBytes == null || !_isLiveCamActive) return;
          _liveCam.sendFrame(jpegBytes);
        })
        .catchError((e) {
          _isEncodingLiveCamFrame = false;
          _devLog.add(
            LogDirection.error,
            'CAM',
            'Gagal proses frame live-cam: $e',
          );
        });
  }

  // ---------------------------------------------------------------------
  // UJI COBA AI (mode Dev) -- tanpa timeout, tanpa kirim command ke ESP
  // ---------------------------------------------------------------------

  Future<void> _startAiTest({int? durationMin, bool fromRemote = false}) async {
    _sessionStarting = true;
    try {
      await _startAiTestImpl(durationMin: durationMin, fromRemote: fromRemote);
    } finally {
      _sessionStarting = false;
      _reconcileCameraState();
    }
  }

  Future<void> _startAiTestImpl({
    int? durationMin,
    bool fromRemote = false,
  }) async {
    if (_isFeeding) return;
    // TAIL (rev): sesi baru (Uji Coba AI) memotong tail yang sedang
    // berjalan (KEPUTUSAN #5).
    if (_isTailRecording) await _endTail('uji_coba_ai');
    // 🟢 REVISI (P1): recorder di-reset sebelum kamera dibuka (event cam_* ikut terekam).
    _recorder.reset();
    _recorder.setCfg(_cfgSnapshot(dryRun: true));
    await _reconcileCameraState();
    if (!_isCameraActive) {
      _devLog.add(
        LogDirection.error,
        'HP',
        'Gagal mulai uji coba AI: kamera belum siap',
      );
      if (fromRemote) {
        _supabase.updateTrialStatus(status: 'idle', stopReason: 'camera_error');
      }
      return;
    }

    setState(() {
      _isAiTestMode = true;
      _statusText = durationMin != null
          ? 'Uji Coba AI ($durationMin menit)...'
          : 'Uji Coba AI (manual, tanpa timeout)...';
      _lastEma = 0; // 🟢 REVISI (P1 / SPEC 3.5)
      _lastPeak = 0;
    });

    _extractor.reset();
    // REVISI v2: Uji Coba AI memakai FeederTriggerAdaptive yang SAMA dengan
    // produksi, dalam mode dry-run (menghitung semua, tidak pernah STOP).
    _trigger = _newTrigger(dryRun: true);
    _lastPhase = null;
    // (🟢 REVISI P1: _recorder.reset()/setCfg dipindah ke atas, sebelum kamera dibuka)
    _startDiagUpload();
    _lastProcessedAt = null;
    _lastRawScore = null;

    _trialSessionId = DateTime.now().millisecondsSinceEpoch;
    _trialStartedAt = DateTime.now();
    _trialDurationMin = durationMin;

    _trialDurationTimer?.cancel();
    if (durationMin != null) {
      _trialDurationTimer = Timer(
        Duration(minutes: durationMin),
        () => _stopAiTest(reason: 'duration_reached'),
      );
    }

    _trialLogTimer?.cancel();
    _trialLogTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!_isAiTestMode) return;
      _supabase.updateTrialStatus(status: 'running');
      if (_lastTelemetry != null) _queueTelemetryUpload(_lastTelemetry!);
    });

    if (fromRemote) {
      _supabase.updateTrialStatus(
        status: 'running',
        sessionId: _trialSessionId,
        startedAt: _trialStartedAt,
      );
    }

    await _reconcileCameraState();
    _devLog.add(
      LogDirection.info,
      'HP',
      'Uji coba AI dimulai${fromRemote ? " (webapp)" : ""}'
          '${durationMin != null ? ", durasi $durationMin menit" : ", tanpa timeout"}',
    );
  }

  Future<void> _stopAiTest({
    String reason = 'user_stop',
    bool fromRemote = false,
  }) async {
    final diagSession = _trialSessionId;
    setState(() {
      _isAiTestMode = false;
      _statusText = 'Idle';
    });
    await _stopDiagUpload(sessionId: diagSession, trial: true);
    _trialDurationTimer?.cancel();
    _trialLogTimer?.cancel();
    _trigger = null;
    _trialSessionId = null;
    _trialStartedAt = null;
    _trialDurationMin = null;

    _supabase.updateTrialStatus(status: 'idle', stopReason: reason);

    _devLog.add(LogDirection.info, 'HP', 'Uji coba AI selesai ($reason)');
    _reconcileCameraState();
  }

  void _onAiTestFrame(CameraImage image) {
    if (_isProcessingFrame) return;
    final now = DateTime.now();
    if (_lastProcessedAt != null &&
        now.difference(_lastProcessedAt!) < _minFrameInterval)
      return;
    _lastProcessedAt = now;
    _isProcessingFrame = true;
    _logCamOnce(image, now);
    try {
      final sw = Stopwatch()..start();
      final raw = _extractor.processFrame(image);
      sw.stop();
      if (raw == null || _trigger == null) return;
      _lastRawScore = raw; // dipakai _aiFields() -> ai_raw
      _recorder.addFrame(now, _extractor.strideScores, sw.elapsedMilliseconds);
      _trigger!.update(raw, now); // dry-run: tidak pernah mengunci STOP
      final decision = _trigger!.takeDecision();
      if (decision != null) _handleDecision(decision, now, live: false);
      _notePhase(now);
      if (mounted) setState(() {});
    } finally {
      _isProcessingFrame = false;
    }
  }

  // ---------------------------------------------------------------------
  // RESET / FACTORY RESET ESP (murni via paket BT, tidak perlu ubah
  // kode ESP -- firmware sudah menangani doc["rst"] == 1/2)
  // ---------------------------------------------------------------------

  Future<void> _confirmAndSendReset(int code, String label) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Konfirmasi $label'),
        content: Text('Yakin kirim $label ke ESP? Perangkat akan restart.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Ya, Kirim'),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await _btService.sendReset(code);
    }
  }

  // ---------------------------------------------------------------------
  // AUTO-DARK / INACTIVITY (default 15 detik, OFF di Mode Dev)
  // + tombol manual "Hemat Baterai"
  // ---------------------------------------------------------------------

  void _applyBrightness(bool dark) {
    try {
      if (dark) {
        ScreenBrightness().setScreenBrightness(0.0);
      } else {
        ScreenBrightness().resetScreenBrightness();
      }
    } catch (_) {}
  }

  void _setDark(bool dark) {
    if (_isDark == dark) return;
    setState(() => _isDark = dark);
    _applyBrightness(dark);
    if (dark) {
      _inactivityTimer?.cancel();
    } else {
      _lastActivityAt = DateTime.now();
      _resetInactivityTimer();
    }
  }

  /// Timer auto-dark. Di MODE DEV timer ini sengaja TIDAK pernah dipasang
  /// (dibatalkan saja), supaya layar tetap terang selama debugging.
  void _resetInactivityTimer() {
    _inactivityTimer?.cancel();
    if (_isDark) return;
    if (_isDevMode) return; // Mode Dev: hemat daya OFF, layar tetap terang
    final secs = widget.config.screenTimeoutSeconds;
    if (secs <= 0) return; // 0 = fitur auto-dark dimatikan user
    _inactivityTimer = Timer(
      Duration(milliseconds: (secs * 1000).round()),
      () => _setDark(true),
    );
  }

  /// Dipanggil dari Listener (pointer down/move/up) & NotificationListener
  /// (scroll) -- jadi scroll jari pun dihitung sebagai aktivitas user.
  /// [force] = true untuk event diskrit (tap/tombol) yang harus langsung
  /// mereset timer tanpa lewat throttle.
  void _onUserActivity({bool force = false}) {
    if (_isDark) {
      _lastActivityAt = DateTime.now();
      _setDark(false); // sentuh saat gelap -> terang lagi + reset timer
      return;
    }

    final now = DateTime.now();
    if (!force &&
        _lastActivityAt != null &&
        now.difference(_lastActivityAt!) < _activityThrottle) {
      return; // masih dalam jendela throttle, timer belum perlu diperpanjang
    }
    _lastActivityAt = now;
    _resetInactivityTimer(); // masih terang -> perpanjang timer
  }

  void _showSnack(String msg, {Duration? duration}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: duration ?? const Duration(milliseconds: 4000),
      ),
    );
  }

  @override
  void dispose() {
    _disposing = true;
    WidgetsBinding.instance.removeObserver(this);
    _liveCamOffTimer?.cancel();
    _resourceTimer?.cancel();
    _keepAliveTimer?.cancel();
    _metricsTimer?.cancel();
    _aiLogTimer?.cancel();
    _diagTimer?.cancel();
    _camLockTimer?.cancel();
    _inactivityTimer?.cancel();
    _tailTimer?.cancel(); // TAIL (rev)
    if (_isTailRecording) {
      // TAIL (rev): widget dibuang saat tail masih berjalan -- bersihkan
      // timer/state sesi & kirim snapshot penutup sebisanya. Fire-and-
      // forget (dispose() tidak bisa async); setState di dalam _endTail
      // sudah dijaga `mounted`, jadi aman dipanggil di sini.
      _endTail('dispose');
    }
    _restart.dispose(); // 🟢 REVISI (P1/R9)
    _cam.disposeAll(); // 🟢 REVISI (P1): tanpa await; manager menutup kamera tuntas
    _liveCam.dispose();
    _supabase.dispose();
    _btService.dispose();
    _devLog.dispose();
    try {
      ScreenBrightness().resetScreenBrightness();
    } catch (_) {}
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_isDark) return _buildDarkScreen();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Catfish AI'),
        actions: [
          IconButton(
            icon: Icon(
              _isBtConnected
                  ? Icons.bluetooth_connected
                  : Icons.bluetooth_disabled,
              color: _isBtConnected ? Colors.blueAccent : Colors.red,
            ),
            onPressed: _isBtConnected ? null : _connectBT,
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            // TAIL (rev): Settings nonaktif selama _isFeeding || _isTailRecording.
            onPressed: (_isFeeding || _isTailRecording)
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
      // 🟢 FIX BUG SCROLL: Listener menangkap SEMUA pointer event (termasuk
      // drag/scroll jari) tanpa ikut arena gesture, jadi tidak "kalah" dari
      // SingleChildScrollView seperti GestureDetector.onTap sebelumnya.
      // NotificationListener ditambahkan untuk scroll yang dipicu tanpa
      // pointer (fling/inersia, scrollbar, keyboard).
      body: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (_) => _onUserActivity(force: true),
        onPointerMove: (_) => _onUserActivity(),
        onPointerUp: (_) => _onUserActivity(force: true),
        onPointerSignal: (_) => _onUserActivity(),
        child: NotificationListener<ScrollNotification>(
          onNotification: (_) {
            _onUserActivity();
            return false; // jangan konsumsi, biarkan scroll jalan normal
          },
          child: SafeArea(
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              child: Column(
                children: [
                  _buildModeToggle(),
                  _buildCameraArea(),
                  _buildStatusPanel(),
                  if (_isDevMode) _buildDevPanel(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDarkScreen() {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => _onUserActivity(force: true),
        onPointerMove: (_) => _onUserActivity(force: true),
        child: SizedBox.expand(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text(
                '⚡ Layar Gelap (Hemat Daya)',
                style: TextStyle(color: Colors.white54, fontSize: 18),
              ),
              const SizedBox(height: 16),
              Text(
                _isFeeding
                    ? 'AI & komunikasi tetap berjalan di kegelapan...'
                    : 'Idle: komunikasi BT & Supabase tetap berjalan...',
                style: const TextStyle(color: Colors.white30, fontSize: 14),
              ),
              const SizedBox(height: 8),
              const Text(
                'Sentuh layar untuk kembali terang',
                style: TextStyle(color: Colors.white24, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildModeToggle() {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SegmentedButton<bool>(
        segments: const [
          ButtonSegment(
            value: false,
            label: Text('Normal'),
            icon: Icon(Icons.visibility),
          ),
          ButtonSegment(
            value: true,
            label: Text('Dev'),
            icon: Icon(Icons.bug_report),
          ),
        ],
        selected: {_isDevMode},
        onSelectionChanged: (s) {
          final devOn = s.first;
          setState(() => _isDevMode = devOn);
          _devLog.setEnabled(devOn);

          // 🟢 REVISI: pindah ke Normal -> lepas kamera paksa. Kamera mati
          // sendiri bila tak ada yang butuh; sesi AI/live-cam/flash yang
          // aktif tetap menahannya nyala lewat _reconcileCameraState.
          if (!devOn && _cameraForcedOn) {
            setState(() => _cameraForcedOn = false);
            _reconcileCameraState();
            _devLog.add(
              LogDirection.info,
              'HP',
              'Pindah ke Normal: kamera paksa dilepas',
            );
          }

          if (devOn) {
            // Mode Dev: matikan timer hemat daya & pastikan layar terang.
            _inactivityTimer?.cancel();
            if (_isDark) _setDark(false);
            _devLog.add(
              LogDirection.info,
              'HP',
              'Mode Dev aktif (auto-dark dimatikan, layar tetap terang)',
            );
            _restart.logSummary(); // 🟢 REVISI (P1/R9): log hanya saat Dev
          } else {
            // Balik ke Normal: pasang lagi timer auto-dark.
            _onUserActivity(force: true);
          }
        },
      ),
    );
  }

  // 🟢 REVISI: ketukan kotak kamera (hanya Mode Dev) menggantikan tombol
  // 'Nyalakan/Matikan Kamera Paksa'. Logika kamera/AI TIDAK diubah.
  void _onCameraBoxTap() {
    if (!_isDevMode) return; // hanya Mode Dev
    if (_isFeeding || _isAiTestMode || _isLiveCamActive || _flashOn) {
      final holders = _cameraHolders(detail: true);
      _showSnack(
        'Kamera ditahan oleh:\n- ${holders.join('\n- ')}\n'
        '(tidak bisa dimatikan manual selama ada penahan)',
        duration: const Duration(seconds: 8),
      );
      return; // jangan ubah _cameraForcedOn
    }
    if (_cam.isCameraActive && _cameraHolders().isEmpty) {
      // Kamera terbuka tapi TIDAK ada flag penahan -> bug sinkronisasi, bukan
      // "ada yang pakai". Laporkan jelas supaya tidak dikira presence nyangkut.
      _showSnack(
        'Kamera terbuka tapi tidak ada penahan di layar ini '
        '(sinkronisasi CameraManager). Mencoba reconcile ulang.',
        duration: const Duration(seconds: 6),
      );
      _reconcileCameraState();
      return;
    }
    _toggleCameraOverride(); // dipanggil apa adanya
  }

  Widget _buildCameraArea() {
    // 🟢 REVISI (P1): controller dari CameraManager; null saat sedang menutup.
    final camCtrl = _cam.controller;
    return Center(
      child: AspectRatio(
        aspectRatio: 3 / 4,
        // 🟢 REVISI: GestureDetector opaque supaya area hitam ikut menangkap tap.
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _onCameraBoxTap,
          child: Container(
            color: Colors.black,
            margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: camCtrl != null
                // 🟢 REVISI: Stack(expand) menjaga constraint CameraPreview
                // tetap ketat seperti sebelumnya; hanya menambah label kecil.
                ? Stack(
                    fit: StackFit.expand,
                    children: [
                      CameraPreview(camCtrl),
                      if (_isDevMode)
                        const Positioned(
                          right: 6,
                          bottom: 6,
                          child: Text(
                            'ketuk = matikan',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 11,
                            ),
                          ),
                        ),
                    ],
                  )
                : Center(
                    child: Text(
                      _isDevMode
                          ? '📷 Kamera OFF — ketuk untuk menyalakan'
                          : '📷 Kamera OFF (idle)',
                      style: const TextStyle(color: Colors.white54),
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  /// TAIL (rev): sisa detik tail recording, untuk ditampilkan di UI.
  int _tailRemainingSeconds() {
    final ends = _tailEndsAt;
    if (ends == null) return 0;
    final remaining = ends.difference(DateTime.now()).inSeconds;
    return remaining < 0 ? 0 : remaining;
  }

  Widget _buildStatusPanel() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Text('Status: $_statusText', style: const TextStyle(fontSize: 16)),
          Text(
            'EMA: ${_lastEma.toStringAsFixed(1)}  |  Peak: ${_lastPeak.toStringAsFixed(1)}',
          ),
          if (_isFeeding || _isAiTestMode || _isTailRecording) // TAIL (rev)
            Text(
              'Fase AI: ${_phaseLabel(_trigger?.phase)}'
              '${_isAiTestMode ? "  (uji coba, tidak mengirim ke ESP)" : ""}',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: _isAiTestMode ? Colors.deepPurple : Colors.teal,
              ),
            ),
          // TAIL (rev): status + tombol pembatalan tail, tampil di Normal & Dev.
          if (_isTailRecording) ...[
            Text(
              'TAIL REKAMAN: sisa ${_tailRemainingSeconds()} dtk ($_tailReason)',
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.orange,
              ),
            ),
            TextButton(
              onPressed: () => _endTail('cancelled_user'),
              child: const Text('Hentikan Tail'),
            ),
          ],
          if (_isAiTestMode) ...[
            Text(
              'EMA: ${(_trigger?.ema ?? 0).toStringAsFixed(1)}  |  '
              'Baseline: ${_trigger?.baseline?.toStringAsFixed(1) ?? "-"}  |  '
              'Acuan: ${(_trigger?.refLevel ?? 0).toStringAsFixed(0)}',
              style: const TextStyle(fontSize: 12, color: Colors.deepPurple),
            ),
            Text(
              'Putaran #${_trigger?.round ?? 0}  |  frame ${_trigger?.frameIdx ?? 0}  |  '
              'rasio: ${_trigger?.lastDecision?.ratio?.toStringAsFixed(2) ?? "-"}  |  '
              'strike: ${_trigger?.strikes ?? 0}  |  '
              'verdict: ${_trigger?.lastDecision?.verdict ?? "-"}',
              style: const TextStyle(fontSize: 12, color: Colors.deepPurple),
            ),
            const Text(
              'Label kejadian: tandai dari webapp (jangan sentuh HP saat merekam)',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
          if (_lastTelemetry != null) ...[
            const SizedBox(height: 4),
            Text(
              'pH raw: ${_lastTelemetry!.sensor.phRaw}  |  Turb raw: ${_lastTelemetry!.sensor.turbRaw}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            Text(
              'Feeder: ${_lastTelemetry!.feeder.msg} (cnt=${_lastTelemetry!.feeder.count})  |  Pump: ${_lastTelemetry!.actuator.pump ? "ON" : "off"}',
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.thermostat, size: 16, color: Colors.orange),
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
            onPressed: (_isFeeding || _isAiTestMode) ? null : _startFeeding,
            child: Text(
              _isFeeding ? 'AI Sedang Memantau...' : 'Simulasi Start Manual',
            ),
          ),
          if (_isFeeding)
            TextButton(
              onPressed: () => _handleStop('manual_stop'),
              child: const Text('Stop Manual (Kirim CMD:STOP ke ESP)'),
            ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => _applyFlash(!_flashOn),
            icon: Icon(_flashOn ? Icons.flashlight_on : Icons.flashlight_off),
            label: Text(
              _flashOn
                  ? (_flashAuto && !_flashManual
                        ? 'Flash ON (otomatis sesi) - ketuk untuk matikan'
                        : 'Matikan Flash')
                  : 'Nyalakan Flash',
            ),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, 45),
            ),
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: () => _setDark(true),
            icon: const Icon(Icons.power_settings_new),
            label: Text(
              _isDevMode
                  ? '⚡ Hemat Baterai (Auto-dark OFF di Mode Dev)'
                  : '⚡ Hemat Baterai (auto ${widget.config.screenTimeoutSeconds.toStringAsFixed(0)}s)',
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.grey[800],
              foregroundColor: Colors.amber,
              minimumSize: const Size(double.infinity, 45),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDevPanel() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade400),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '🔧 Dev Panel',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          _buildEspValuesGrid(),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              OutlinedButton(
                onPressed: () => _confirmAndSendReset(1, 'Soft Reset'),
                child: const Text('Soft Reset ESP'),
              ),
              OutlinedButton(
                onPressed: () => _confirmAndSendReset(2, 'Factory Reset'),
                style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                child: const Text('Factory Reset ESP'),
              ),
              // 🟢 REVISI: tombol 'Nyalakan/Matikan Kamera Paksa' dihapus;
              // diganti ketukan kotak kamera (_onCameraBoxTap).
              OutlinedButton.icon(
                onPressed: _isFeeding
                    ? null
                    : (_isAiTestMode ? _stopAiTest : _startAiTest),
                icon: Icon(
                  _isAiTestMode ? Icons.stop_circle : Icons.psychology,
                ),
                label: Text(
                  _isAiTestMode ? 'Selesai Uji Coba AI' : 'Uji Coba AI',
                ),
              ),
              // 🟢 REVISI (P1): tombol 'Restart Kamera' dihapus -- tutup-buka
              // kamera tidak pernah memulihkan layar hitam (SPEC 2); pemulihan
              // = restart app terjadwal saat idle (Room 9).
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text(
                '📡 Log Traffic (terbaru di atas)',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Layar penuh + filter',
                    icon: const Icon(Icons.fullscreen),
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => _DevLogFullScreen(devLog: _devLog),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _devLog.clear,
                    child: const Text('Bersihkan'),
                  ),
                ],
              ),
            ],
          ),
          _buildLogPanel(),
        ],
      ),
    );
  }

  Widget _buildEspValuesGrid() {
    final t = _lastTelemetry;
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row('pH trim (ESP)', t?.sensor.phTrim.toString() ?? '-'),
        row('Turbidity trim (ESP)', t?.sensor.turbTrim.toString() ?? '-'),
        row(
          'Turb mosfet (ESP)',
          t == null ? '-' : (t.sensor.mosfet == 1 ? 'ON' : 'OFF'),
        ),
        row(
          'Fase sensor (ESP)',
          t == null ? '-' : _sensorPhaseLabel(t.sensor.state),
        ),
        row(
          'RAM ESP',
          t == null ? '-' : '${t.system.ramFreeKb}/${t.system.ramTotalKb} KB',
        ),
        row(
          'I2C/RTC status (ESP)',
          t == null ? '-' : (t.system.rtcError ? 'LOSS' : 'OK'),
        ),
        row('Jam ESP', _espTimeText(t)),
        row('Suhu RTC (ESP)', _rtcTempText(t)),
        row(
          'Mode ESP (echo am)',
          _lastAutoModeEcho == null
              ? '-'
              : (_lastAutoModeEcho == 1 ? 'Otomatis' : 'Manual'),
        ),
        const Divider(height: 12),
        row('RAM J2 (proses ini)', _ramJ2Text),
        row('CPU J2', _cpuText),
        row('Suhu HP J2', _tempText),
        row('Status BT', _isBtConnected ? 'Terhubung' : 'Terputus'),
        row('Restart app (R9)', _restart.summary),
      ],
    );
  }

  /// Jam RTC ESP (bukan jam HP J2). Null kalau belum ada paket sama
  /// sekali, atau RTC sedang error/loss (I2C putus, dsb).
  String _espTimeText(TelemetryPacket? t) {
    if (t == null) return '-- (belum ada paket)';
    if (t.system.rtcError) return '-- (RTC error/loss)';
    final dt = t.system.espDateTime;
    if (dt == null) return '-- (RTC belum valid)';
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.hour)}:${two(dt.minute)}:${two(dt.second)}';
  }

  /// Suhu sensor internal DS3231 (BUKAN suhu HP J2 -- itu ada di
  /// baris "Suhu HP J2" di bawahnya).
  String _rtcTempText(TelemetryPacket? t) {
    if (t == null) return '-- (belum ada paket)';
    if (t.system.rtcError || t.system.rtcTempC == null) {
      return '-- (RTC error/loss)';
    }
    return '${t.system.rtcTempC!.toStringAsFixed(1)}°C';
  }

  String _sensorPhaseLabel(int state) {
    switch (state) {
      case 1:
        return 'BOOT';
      case 2:
        return 'BACA pH';
      case 3:
        return 'WARMUP TURBIDITY';
      case 4:
        return 'BACA TURBIDITY';
      default:
        return '-';
    }
  }

  Widget _buildLogPanel() {
    return AnimatedBuilder(
      animation: _devLog,
      builder: (context, _) {
        final entries = _devLog.entries;
        return Container(
          height: 180,
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: Colors.black87,
            borderRadius: BorderRadius.circular(6),
          ),
          child: entries.isEmpty
              ? const Center(
                  child: Text(
                    'Belum ada log...',
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                )
              : ListView.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, i) {
                    final e = entries[i];
                    final hh = e.time.hour.toString().padLeft(2, '0');
                    final mm = e.time.minute.toString().padLeft(2, '0');
                    final ss = e.time.second.toString().padLeft(2, '0');
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Text(
                        '$hh:$mm:$ss [${e.directionLabel}][${e.channel}] ${e.message}',
                        style: TextStyle(
                          fontSize: 11,
                          fontFamily: 'monospace',
                          color: _logColor(e.direction),
                        ),
                      ),
                    );
                  },
                ),
        );
      },
    );
  }

  Color _logColor(LogDirection d) {
    switch (d) {
      case LogDirection.inbound:
        return Colors.lightBlueAccent;
      case LogDirection.outbound:
        return Colors.lightGreenAccent;
      case LogDirection.error:
        return Colors.redAccent;
      case LogDirection.info:
        return Colors.white70;
    }
  }
}

// ===========================================================================
// LOG TRAFFIC LAYAR PENUH + FILTER (item 2)
//
// Terpisah dari _buildLogPanel() (yang tetap jadi ringkasan kecil di dalam
// Dev Panel) supaya bisa dibuka sebagai halaman sendiri: lebih banyak baris
// kelihatan sekaligus, dan bisa disaring per channel (BT/SUPA/HP) maupun
// per arah (IN/OUT/ERROR/INFO) -- mis. "aku cuma mau lihat soal BT" atau
// "cuma yang error".
// ===========================================================================
class _DevLogFullScreen extends StatefulWidget {
  final DevLogBuffer devLog;
  const _DevLogFullScreen({required this.devLog});

  @override
  State<_DevLogFullScreen> createState() => _DevLogFullScreenState();
}

class _DevLogFullScreenState extends State<_DevLogFullScreen> {
  String _channelFilter = 'ALL'; // ALL, BT, SUPA, HP
  LogDirection? _directionFilter; // null = semua arah
  String _search = '';

  List<LogEntry> _filtered(List<LogEntry> all) {
    return all.where((e) {
      if (_channelFilter != 'ALL' && e.channel != _channelFilter) return false;
      if (_directionFilter != null && e.direction != _directionFilter) {
        return false;
      }
      if (_search.isNotEmpty &&
          !e.message.toLowerCase().contains(_search.toLowerCase())) {
        return false;
      }
      return true;
    }).toList();
  }

  Color _color(LogDirection d) {
    switch (d) {
      case LogDirection.inbound:
        return Colors.lightBlueAccent;
      case LogDirection.outbound:
        return Colors.lightGreenAccent;
      case LogDirection.error:
        return Colors.redAccent;
      case LogDirection.info:
        return Colors.white70;
    }
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    return Padding(
      padding: EdgeInsets.zero,
      child: ChoiceChip(
        label: Text(label, style: const TextStyle(fontSize: 12)),
        selected: selected,
        onSelected: (_) => onTap(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.devLog,
      builder: (context, _) {
        final all = widget.devLog.entries;
        final channels = <String>{'ALL', ...all.map((e) => e.channel)}.toList();
        final shown = _filtered(all);

        return Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            title: Text('Log Traffic (${shown.length}/${all.length})'),
            actions: [
              IconButton(
                tooltip: 'Salin semua (sesuai filter)',
                icon: const Icon(Icons.copy_all),
                onPressed: shown.isEmpty
                    ? null
                    : () {
                        final text = shown
                            .map(
                              (e) =>
                                  '${e.time.toIso8601String()} [${e.directionLabel}][${e.channel}] ${e.message}',
                            )
                            .join('\n');
                        Clipboard.setData(ClipboardData(text: text));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Log (sesuai filter) disalin'),
                          ),
                        );
                      },
              ),
              IconButton(
                tooltip: 'Bersihkan semua log',
                icon: const Icon(Icons.delete_sweep),
                onPressed: widget.devLog.clear,
              ),
            ],
          ),
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                child: TextField(
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    hintText: 'Cari teks pesan...',
                    hintStyle: TextStyle(color: Colors.white38),
                    prefixIcon: Icon(Icons.search, color: Colors.white38),
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() => _search = v),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final ch in channels)
                      _chip(
                        ch,
                        _channelFilter == ch,
                        () => setState(() => _channelFilter = ch),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    _chip(
                      'Semua arah',
                      _directionFilter == null,
                      () => setState(() => _directionFilter = null),
                    ),
                    _chip(
                      'IN',
                      _directionFilter == LogDirection.inbound,
                      () => setState(
                        () => _directionFilter = LogDirection.inbound,
                      ),
                    ),
                    _chip(
                      'OUT',
                      _directionFilter == LogDirection.outbound,
                      () => setState(
                        () => _directionFilter = LogDirection.outbound,
                      ),
                    ),
                    _chip(
                      'ERROR',
                      _directionFilter == LogDirection.error,
                      () =>
                          setState(() => _directionFilter = LogDirection.error),
                    ),
                    _chip(
                      'INFO',
                      _directionFilter == LogDirection.info,
                      () =>
                          setState(() => _directionFilter = LogDirection.info),
                    ),
                  ],
                ),
              ),
              const Divider(color: Colors.white24, height: 1),
              Expanded(
                child: shown.isEmpty
                    ? const Center(
                        child: Text(
                          'Tidak ada log yang cocok dengan filter ini.',
                          style: TextStyle(color: Colors.white38),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(10),
                        itemCount: shown.length,
                        itemBuilder: (context, i) {
                          final e = shown[i];
                          final hh = e.time.hour.toString().padLeft(2, '0');
                          final mm = e.time.minute.toString().padLeft(2, '0');
                          final ss = e.time.second.toString().padLeft(2, '0');
                          final ms = e.time.millisecond.toString().padLeft(
                            3,
                            '0',
                          );
                          return SelectableText(
                            '$hh:$mm:$ss.$ms [${e.directionLabel}][${e.channel}] ${e.message}',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontFamily: 'monospace',
                              color: _color(e.direction),
                              height: 1.6,
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
