import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';

import 'telemetry_packet.dart';
import 'dev_log.dart';

/// Service komunikasi Bluetooth Classic (SPP) J2 Prime <-> ESP32.
///
/// PROTOKOL (harus match persis dengan CommsBT.cpp firmware):
/// - Semua paket dibungkus '<' ... '>' lalu diakhiri '\n'.
/// - ESP -> J2 : HANYA telemetri JSON heartbeat:
///     <{"sen":{...},"act":{...},"sys":{...},"fd":{...}}>
///   dikirim tiap cfg.up detik, atau seketika saat force_bt_send.
///   ESP TIDAK PERNAH mengirim sinyal/command lain ke J2.
/// - J2 -> ESP : dua jenis paket
///     1. Fast command (AI CV): <CMD:LANJUT> / <CMD:STOP>
///     2. Config/override/reset JSON: <{"cfg":{...}}> / <{"ovr":{...}}> / <{"rst":1}>
///        ovr keys: p=pompa, f=picu sesi pakan penuh (AI), c=charger,
///        x=STOP DARURAT, tf=pulsa test/jog motor feeder manual (1 putaran,
///        tanpa AI -- lihat sendOverride(feederTest:)).
///
/// Auto-reconnect: kalau belum/tidak lagi terhubung, service ini mencoba
/// konek ulang tiap 15 detik secara non-blocking (Timer.periodic, tanpa
/// nge-block UI/BT thread manapun). Tap manual ikon BT tetap langsung
/// memicu 1x percobaan instan (initAndConnect tanpa menunggu siklus 15s).
class BluetoothService {
  BluetoothConnection? _connection;
  StreamSubscription<Uint8List>? _inputSub;
  String _rxBuffer = '';

  Timer? _reconnectTimer;
  bool _isConnecting = false;

  // 🟢 Dipakai untuk merge paket MINI (event cepat act-only dari ESP, lihat
  // CommsBT.cpp -> force_bt_send_act) dengan sensor/sistem/feeder TERAKHIR
  // yang diketahui -- lihat TelemetryPacket.fromJson(previous:).
  TelemetryPacket? _lastPacket;

  static const Duration _reconnectInterval = Duration(seconds: 15);

  /// Dipanggil setiap 1 paket telemetri JSON utuh berhasil di-parse.
  final void Function(TelemetryPacket packet)? onTelemetry;

  /// Dipanggil kalau ada payload yang gagal di-parse.
  final void Function(String rawPayload)? onUnknownPayload;

  final void Function(bool connected)? onConnectionChanged;

  /// Log ringkas untuk panel Dev (koneksi, command keluar, error).
  /// Sukses terima telemetri SENGAJA tidak di-log di sini -- itu
  /// dirangkum & di-log oleh caller (feeding_screen) dalam format yang
  /// lebih ringkas/mudah dibaca, biar gak dobel makan slot buffer.
  final void Function(LogDirection direction, String channel, String message)?
  onLog;

  /// HARUS sama persis dengan `SerialBT.begin("...")` di firmware.
  final String targetDeviceName;

  BluetoothService({
    this.onTelemetry,
    this.onUnknownPayload,
    this.onConnectionChanged,
    this.onLog,
    this.targetDeviceName = 'ESP32_Aquaponics',
  });

  bool get isConnected => _connection != null && _connection!.isConnected;

  /// [auto] = true kalau dipanggil dari siklus reconnect otomatis
  /// (cuma mempengaruhi teks log, bukan logikanya).
  Future<bool> initAndConnect({bool auto = false}) async {
    if (_isConnecting) return false; // cegah percobaan tumpang tindih
    if (isConnected) return true;

    _isConnecting = true;
    onLog?.call(
      LogDirection.info,
      'BT',
      auto
          ? 'Auto-reconnect: mencoba konek ulang ke $targetDeviceName...'
          : 'Mencoba konek ke $targetDeviceName...',
    );

    try {
      final bondedDevices = await FlutterBluetoothSerial.instance
          .getBondedDevices();
      BluetoothDevice? targetDevice;
      for (final d in bondedDevices) {
        if (d.name == targetDeviceName) {
          targetDevice = d;
          break;
        }
      }

      if (targetDevice == null) {
        onLog?.call(
          LogDirection.error,
          'BT',
          '"$targetDeviceName" belum di-pairing di HP ini!',
        );
        onConnectionChanged?.call(false);
        _scheduleReconnect();
        return false;
      }

      _connection = await BluetoothConnection.toAddress(targetDevice.address);
      onLog?.call(LogDirection.info, 'BT', 'Terhubung ke $targetDeviceName');
      onConnectionChanged?.call(true);
      _cancelReconnectTimer();

      _rxBuffer = '';
      _inputSub = _connection!.input!.listen(
        _onRawData,
        onDone: _handleDisconnected,
      );

      return true;
    } catch (e) {
      onLog?.call(LogDirection.error, 'BT', 'Error konek: $e');
      onConnectionChanged?.call(false);
      _scheduleReconnect();
      return false;
    } finally {
      _isConnecting = false;
    }
  }

  void _handleDisconnected() {
    // 🟢 REVISI: bersihkan koneksi LAMA sebelum di-null-kan supaya socket/
    // listener tidak bocor tiap kali putus. Dibungkus try/catch karena
    // plugin bisa melempar kalau socket sudah tertutup. Setelah ini
    // _connection & _inputSub null, jadi dispose() service tidak akan
    // men-dispose dua kali, dan initAndConnect membuat listener baru.
    try {
      _inputSub?.cancel();
    } catch (_) {}
    _inputSub = null;
    try {
      _connection?.dispose();
    } catch (_) {}
    _connection = null;
    onLog?.call(
      LogDirection.error,
      'BT',
      'Koneksi terputus. Auto-reconnect tiap 15 detik diaktifkan.',
    );
    onConnectionChanged?.call(false);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer.periodic(
      _reconnectInterval,
      (_) => initAndConnect(auto: true),
    );
  }

  void _cancelReconnectTimer() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  void _onRawData(Uint8List data) {
    final chunk = utf8.decode(data, allowMalformed: true);

    for (var i = 0; i < chunk.length; i++) {
      final ch = chunk[i];

      if (ch == '<') {
        _rxBuffer = '<';
        continue;
      }

      if (ch == '>') {
        if (_rxBuffer.isEmpty || _rxBuffer[0] != '<') {
          _rxBuffer = '';
          continue;
        }
        _rxBuffer += ch;
        final payload = _rxBuffer.substring(1, _rxBuffer.length - 1);
        _handlePayload(payload);
        _rxBuffer = '';
        continue;
      }

      if (_rxBuffer.isNotEmpty) {
        _rxBuffer += ch;
        if (_rxBuffer.length > 2048) {
          _rxBuffer = ''; // antisipasi memory leak paket yang gak ketutup
        }
      }
    }
  }

  void _handlePayload(String payload) {
    if (payload.startsWith('{')) {
      try {
        final map = jsonDecode(payload) as Map<String, dynamic>;
        final packet = TelemetryPacket.fromJson(map, previous: _lastPacket);
        _lastPacket = packet;
        onTelemetry?.call(packet);
      } catch (e) {
        onLog?.call(
          LogDirection.error,
          'BT',
          'Gagal parse JSON telemetri: $e | payload: $payload',
        );
        onUnknownPayload?.call(payload);
      }
    } else {
      onLog?.call(LogDirection.error, 'BT', 'Payload tidak dikenal: $payload');
      onUnknownPayload?.call(payload);
    }
  }

  /// Kirim fast command ke ESP: "LANJUT" atau "STOP".
  Future<void> sendCommand(String cmd) async {
    await _sendRaw('<CMD:$cmd>');
  }

  /// Kirim update config parsial (field yang tidak dikirim dipertahankan
  /// nilainya di ESP, sesuai pola `doc["cfg"]["x"] | cfg.x`).
  Future<void> sendConfig(Map<String, dynamic> cfg) {
    // 🟢 REVISI: ANTREAN KHUSUS cfg. Paket cfg yang dipecah butuh beberapa
    // ratus ms; tanpa antrean, cfg baru (delta) bisa menyelip di tengah dan
    // paket sisa dari snapshot LAMA menimpanya di ESP. Dengan antrean, cfg
    // diproses berurutan sesuai urutan pemanggilan, jadi yang terakhir
    // diterima ESP selalu data terbaru.
    // - Antrean KOSONG (kasus normal): langsung jalan saat itu juga (sinkron
    //   sampai write pertama), perilaku identik dengan sebelumnya.
    // - Hanya menahan sesama sendConfig; sendOverride/sendCommand/sendReset
    //   (perintah pulsa) TIDAK ikut antre dan tidak pernah dikirim ulang.
    final prev = _cfgTail;
    final Future<void> run = prev == null
        ? _sendConfigNow(cfg)
        : prev.then((_) => _sendConfigNow(cfg));
    late final Future<void> tail;
    tail = run.catchError((_) {}).whenComplete(() {
      if (identical(_cfgTail, tail)) _cfgTail = null; // antrean kembali kosong
    });
    _cfgTail = tail;
    return run;
  }

  /// 🟢 REVISI: ekor antrean cfg. null = tidak ada pengiriman cfg berjalan.
  Future<void>? _cfgTail;

  Future<void> _sendConfigNow(Map<String, dynamic> cfg) async {
    // 🟢 REVISI: buffer terima ESP = 1024 karakter (kelebihan dibuang diam-
    // diam). Paket cfg > 800 karakter dipecah PER KEY (bukan potong string)
    // jadi beberapa paket utuh. Paket <= 800 dikirim 1x persis seperti dulu.
    final fullLen = _cfgPacketLen(cfg);
    if (fullLen <= _cfgMaxPacketLen) {
      await _sendJson({'cfg': cfg});
      return;
    }

    // 🟢 REVISI: ESP memvalidasi pasangan cmin<cmax dan ph_min<ph_max SEKALIGUS
    // (kalau tidak lolos, KEDUA nilai ditolak). Pasangan ini WAJIB satu paket;
    // kalau terpisah, perubahan ke rentang baru bisa ditolak sebagian.
    const pairs = <String, String>{
      'cmin': 'cmax',
      'cmax': 'cmin',
      'ph_min': 'ph_max',
      'ph_max': 'ph_min',
    };
    final units = <Map<String, dynamic>>[];
    final used = <String>{};
    for (final e in cfg.entries) {
      if (used.contains(e.key)) continue;
      used.add(e.key);
      final unit = <String, dynamic>{e.key: e.value};
      final partner = pairs[e.key];
      if (partner != null &&
          cfg.containsKey(partner) &&
          !used.contains(partner)) {
        unit[partner] = cfg[partner];
        used.add(partner);
      }
      units.add(unit);
    }

    // Greedy: tambah unit (1 key, atau 1 pasangan) selama paket hasil encode <= batas.
    final groups = <Map<String, dynamic>>[];
    var cur = <String, dynamic>{};
    for (final unit in units) {
      final trial = <String, dynamic>{...cur, ...unit};
      if (_cfgPacketLen(trial) <= _cfgMaxPacketLen) {
        cur = trial;
        continue;
      }
      if (cur.isNotEmpty) groups.add(cur);
      cur = <String, dynamic>{...unit};
      final soloLen = _cfgPacketLen(cur);
      if (soloLen > _cfgMaxPacketLen) {
        // Satu unit sendirian sudah kebesaran: kirim apa adanya + catat error.
        onLog?.call(
          LogDirection.error,
          'BT',
          'Key cfg "${unit.keys.join(",")}" sendirian $soloLen karakter (> $_cfgMaxPacketLen), dikirim apa adanya',
        );
      }
    }
    if (cur.isNotEmpty) groups.add(cur);

    onLog?.call(
      LogDirection.info,
      'BT',
      'Config $fullLen karakter dipecah jadi ${groups.length} paket '
          '(tiap paket cfg memicu 1 beep ACK di ESP)',
    );

    for (var i = 0; i < groups.length; i++) {
      await _sendJson({'cfg': groups[i]});
      if (i < groups.length - 1) {
        await Future.delayed(const Duration(milliseconds: 200));
      }
    }
  }

  /// 🟢 REVISI: batas aman paket cfg (ESP membuang diam-diam di atas 1024).
  static const int _cfgMaxPacketLen = 800;

  /// 🟢 REVISI: panjang paket penuh `<{"cfg":...}>` dalam BYTE UTF-8
  /// (ESP menghitung byte, bukan code unit Dart).
  static int _cfgPacketLen(Map<String, dynamic> cfg) =>
      utf8.encode('<${jsonEncode({'cfg': cfg})}>').length;

  /// Kirim override manual pompa/feeder/charger/STOP DARURAT.
  ///
  /// 🟢 FIX BUG "Stop Darurat gak pernah nyampe ESP": sebelumnya method ini
  /// cuma punya parameter pump/feeder/charger -- field `x` (STOP DARURAT,
  /// lihat FeederLogic.cpp & doc["ovr"]["x"] di CommsBT.cpp) TIDAK PERNAH
  /// ikut dikirim sama sekali, walau ESP sudah siap menerimanya. Akibatnya
  /// dev-log J2 cuma nunjukin "IN SUPA" (config diterima dari webapp) tapi
  /// gak pernah ada "OUT BT" utk panic stop -- bukan soal koneksi/timing,
  /// tapi memang gak ada kode yang menyusun & mengirim field itu.
  /// Tambahan parameter [panic] di bawah ini mengisi field "x" tsb.
  Future<void> sendOverride({
    bool? pump,
    bool? feeder,
    bool? charger,
    bool? panic,
    // 🧪 Pulsa test/jog motor feeder manual -- SATU putaran, TANPA sesi AI.
    // Field terpisah dari [feeder] (yang memicu sesi PENUH via cfg.ovr_f).
    // Lihat FeederLogic.cpp (cfg.ovr_tf, feedState==9) & CommsBT.cpp.
    bool? feederTest,
  }) async {
    final ovr = <String, dynamic>{};
    if (pump != null) ovr['p'] = pump ? 1 : 0;
    if (feeder != null) ovr['f'] = feeder ? 1 : 0;
    if (charger != null) ovr['c'] = charger ? 1 : 0;
    if (panic != null) ovr['x'] = panic ? 1 : 0;
    if (feederTest != null) ovr['tf'] = feederTest ? 1 : 0;
    if (ovr.isEmpty) return;
    await _sendJson({'ovr': ovr});
  }

  /// rst = 1 (soft reset) atau 2 (factory reset NVS). ESP akan langsung
  /// ESP.restart() begitu paket ini diterima -- tidak perlu ubah kode
  /// ESP sama sekali, firmware sudah menangani ini (lihat CommsBT.cpp).
  Future<void> sendReset(int rst) async {
    await _sendJson({'rst': rst});
  }

  /// 🟢 REVISI: sinkronisasi jam RTC ESP. [epochWib] = detik sejak epoch
  /// dengan offset WIB (UTC+7) SUDAH ditambahkan (bukan timezone HP) --
  /// ESP memakainya apa adanya di rtc.adjust() dan jadwal pakannya berbasis
  /// WIB. Jangan dipanggil sembarangan: ESP memasang ulang latch jadwal
  /// pakan tiap kali menerima ini (lihat feeding_screen._maybeSyncEspClock).
  Future<void> sendTimeSync(int epochWib) async {
    await _sendJson({'sync': epochWib});
  }

  // 🟢 REVISI: meneruskan hasil kirim (true = terkirim).
  Future<bool> _sendJson(Map<String, dynamic> body) async {
    return _sendRaw('<${jsonEncode(body)}>');
  }

  // 🟢 REVISI: TIDAK PERNAH melempar exception. Gagal (termasuk belum
  // konek) => log error + return false. SENGAJA tanpa retry/antrian:
  // perintah pulsa (f, x, tf, rst) yang gagal tidak boleh dikirim ulang.
  Future<bool> _sendRaw(String wrapped) async {
    if (!isConnected) {
      onLog?.call(
        LogDirection.error,
        'BT',
        'Gagal kirim (belum konek): $wrapped',
      );
      return false;
    }
    try {
      _connection!.output.add(utf8.encode('$wrapped\n'));
      await _connection!.output.allSent;
      onLog?.call(LogDirection.outbound, 'BT', wrapped);
      return true;
    } catch (e) {
      onLog?.call(LogDirection.error, 'BT', 'Gagal kirim ($e): $wrapped');
      return false;
    }
  }

  void dispose() {
    _cancelReconnectTimer();
    _inputSub?.cancel();
    _connection?.dispose();
  }
}
