/// Model 1:1 dari struktur JSON telemetri yang dikirim ESP32 -> J2 Prime
/// via Bluetooth (lihat CommsBT.cpp -> taskCommsBT() bagian "PENGIRIMAN
/// TELEMETRI"). Field key SENGAJA disingkat sama seperti firmware biar
/// gampang di-cross-check saat debug ("sensor.phTrim" di sini asalnya
/// dari doc["sen"]["p"] di ESP), bukan diterjemahkan jadi nama lain
/// yang bikin bingung waktu bandingin sama Serial log ESP.
library telemetry_packet;

class SensorTelemetry {
  final int phTrim; // sen.p   - nilai trimmed mean pH
  final int turbTrim; // sen.t   - nilai trimmed mean turbidity
  final int phRaw; // sen.pr  - raw ADC pH
  final int turbRaw; // sen.tr  - raw ADC turbidity
  final int state; // sen.st  - fase pembacaan (boot/warmup/ph/trb)
  final int mosfet; // sen.mos - 1 = LED turbidity nyala (warm-up)
  final int
  trbLimitEcho; // sen.trb_lim - echo threshold dari ESP utk verifikasi

  const SensorTelemetry({
    required this.phTrim,
    required this.turbTrim,
    required this.phRaw,
    required this.turbRaw,
    required this.state,
    required this.mosfet,
    required this.trbLimitEcho,
  });

  factory SensorTelemetry.fromJson(Map<String, dynamic>? json) {
    final j = json ?? const {};
    return SensorTelemetry(
      phTrim: (j['p'] as num?)?.toInt() ?? 0,
      turbTrim: (j['t'] as num?)?.toInt() ?? 0,
      phRaw: (j['pr'] as num?)?.toInt() ?? 0,
      turbRaw: (j['tr'] as num?)?.toInt() ?? 0,
      state: (j['st'] as num?)?.toInt() ?? 0,
      mosfet: (j['mos'] as num?)?.toInt() ?? 0,
      trbLimitEcho: (j['trb_lim'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toSupabaseRow() => {
    'ph_trim': phTrim,
    'turb_trim': turbTrim,
    'ph_raw': phRaw,
    'turb_raw': turbRaw,
    'sensor_state': state,
    'turb_mosfet': mosfet,
    'trb_limit_echo': trbLimitEcho,
  };
}

class ActuatorTelemetry {
  final bool pump; // act.p
  final bool feeder; // act.f
  final bool charger; // act.c
  final bool pumpRunning; // act.prun - timer durasi pmax lagi jalan?
  final int pumpCooldownSec; // act.p_cd - detik sejak kuras terakhir

  /// act.p_trig - sumber pemicu pompa TERAKHIR (0=idle, 1=auto air kotor,
  /// 2=auto flush rutin, 3=override webapp, 4=tombol fisik T27). Dipakai
  /// webapp untuk menampilkan "kenapa pompa ini nyala" (item 6).
  final int pumpTrigger;

  const ActuatorTelemetry({
    required this.pump,
    required this.feeder,
    required this.charger,
    required this.pumpRunning,
    required this.pumpCooldownSec,
    required this.pumpTrigger,
  });

  factory ActuatorTelemetry.fromJson(Map<String, dynamic>? json) {
    final j = json ?? const {};
    return ActuatorTelemetry(
      pump: ((j['p'] as num?) ?? 0) == 1,
      feeder: ((j['f'] as num?) ?? 0) == 1,
      charger: ((j['c'] as num?) ?? 0) == 1,
      pumpRunning: ((j['prun'] as num?) ?? 0) == 1,
      pumpCooldownSec: (j['p_cd'] as num?)?.toInt() ?? 0,
      pumpTrigger: (j['p_trig'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toSupabaseRow() => {
    'pump_on': pump,
    'feeder_on': feeder,
    'charger_on': charger,
    'pump_running': pumpRunning,
    'pump_cooldown_sec': pumpCooldownSec,
    'pump_trigger': pumpTrigger,
  };
}

class SystemTelemetry {
  final int ramFreeKb; // sys.ram_f
  final int ramTotalKb; // sys.ram_t
  final bool rtcError; // sys.rtc
  final bool hardwareError; // sys.err
  final int errorStrike; // sys.strike

  /// sys.time - unix epoch (detik) dari RTC DS3231 fisik di ESP, diambil
  /// persis saat paket ini dikirim. 0 kalau rtcError true (RTC sedang
  /// loss/tidak valid) -- jangan ditampilkan sebagai jam asli, lihat
  /// [espDateTime].
  final int espEpoch;

  /// sys.rtc_temp - suhu sensor internal DS3231 (°C), null kalau RTC
  /// sedang error (firmware sengaja kirim JSON null, bukan 0).
  final double? rtcTempC;

  /// sys.am - echo `cfg.auto_mode` yang BENAR-BENAR sedang dijalankan ESP
  /// (1=Otomatis, 0=Manual), bukan cuma command terakhir yang J2 kirim.
  /// Nullable: null kalau paket ini paket mini/lama yang belum membawa
  /// field ini (fallback default TelemetryPacket -- lihat
  /// TelemetryPacket.fromJson(previous:)), jangan ditampilkan sebagai
  /// "Manual" begitu saja.
  final int? autoMode;

  const SystemTelemetry({
    required this.ramFreeKb,
    required this.ramTotalKb,
    required this.rtcError,
    required this.hardwareError,
    required this.errorStrike,
    required this.espEpoch,
    required this.rtcTempC,
    this.autoMode,
  });

  factory SystemTelemetry.fromJson(Map<String, dynamic>? json) {
    final j = json ?? const {};
    final rtcErrorVal = ((j['rtc'] as num?) ?? 0) == 1;
    return SystemTelemetry(
      ramFreeKb: (j['ram_f'] as num?)?.toInt() ?? 0,
      ramTotalKb: (j['ram_t'] as num?)?.toInt() ?? 0,
      rtcError: rtcErrorVal,
      hardwareError: ((j['err'] as num?) ?? 0) == 1,
      errorStrike: (j['strike'] as num?)?.toInt() ?? 0,
      espEpoch: (j['time'] as num?)?.toInt() ?? 0,
      rtcTempC: (j['rtc_temp'] as num?)?.toDouble(),
      autoMode: (j['am'] as num?)?.toInt(),
    );
  }

  /// Jam RTC ESP sebagai DateTime, atau null kalau belum ada paket / RTC
  /// sedang error / epoch belum valid (0).
  ///
  /// 🟢 REVISI: epoch dari ESP sekarang SUDAH jam dinding WIB (J2 mengirim
  /// UTC+7 lewat {"sync": epochWib}, lihat BluetoothService.sendTimeSync).
  /// Karena itu DateTime ini sengaja dibiarkan isUtc:true TANPA .toLocal() --
  /// hour/minute/second-nya langsung = jam WIB yang tampil di ESP. JANGAN
  /// di-toLocal() lagi, nanti jamnya bergeser mengikuti timezone HP.
  DateTime? get espDateTime {
    if (rtcError || espEpoch <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(espEpoch * 1000, isUtc: true);
  }

  Map<String, dynamic> toSupabaseRow() => {
    'ram_free_kb': ramFreeKb,
    'ram_total_kb': ramTotalKb,
    'rtc_error': rtcError,
    'hardware_error': hardwareError,
    'error_strike': errorStrike,
    'esp_epoch': espEpoch,
    'rtc_temp_c': rtcTempC,
    'auto_mode_echo': autoMode,
  };
}

/// fd.trig kode dari firmware: 0=IDLE, 1=RTC, 2=WEB OVR, 3=TOUCH,
/// 4=TEST (pulsa manual jog motor feeder, lihat FeederLogic.cpp feedState==9)
enum FeedTriggerSource { idle, rtc, webOverride, touch, test }

FeedTriggerSource triggerFromCode(int code) {
  switch (code) {
    case 1:
      return FeedTriggerSource.rtc;
    case 2:
      return FeedTriggerSource.webOverride;
    case 3:
      return FeedTriggerSource.touch;
    case 4:
      return FeedTriggerSource.test;
    default:
      return FeedTriggerSource.idle;
  }
}

class FeederTelemetry {
  final FeedTriggerSource trigger; // fd.trig
  final int count; // fd.cnt - jumlah putaran sesi ini
  final String msg; // fd.msg - IDLE/PREP AI/WAIT AI/DISPENSE

  /// fd.lr - alasan SESI/PUTARAN TERAKHIR berakhir menurut ESP (0=belum ada,
  /// 1=fmax tercapai, 2=AI kirim STOP, 3=timeout feval, 4=terkunci error
  /// mekanis, 5=STOP darurat/panic, 6=putaran manual test/jog selesai atau
  /// dihentikan). Beda sumber dari `last_stop_reason`
  /// di feeder_status (itu keputusan AI lokal J2); ini keputusan ESP
  /// sendiri -- keduanya dipakai bareng di webapp untuk item 6.
  final int lastReason;

  const FeederTelemetry({
    required this.trigger,
    required this.count,
    required this.msg,
    required this.lastReason,
  });

  factory FeederTelemetry.fromJson(Map<String, dynamic>? json) {
    final j = json ?? const {};
    return FeederTelemetry(
      trigger: triggerFromCode((j['trig'] as num?)?.toInt() ?? 0),
      count: (j['cnt'] as num?)?.toInt() ?? 0,
      msg: (j['msg'] as String?) ?? 'IDLE',
      lastReason: (j['lr'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toSupabaseRow() => {
    'feed_trigger': trigger.name,
    'feed_count': count,
    'feed_msg': msg,
    'feed_last_reason': lastReason,
  };
}

/// Satu paket telemetri utuh dari ESP32 (heartbeat tiap cfg.up detik,
/// atau event-driven saat force_bt_send).
class TelemetryPacket {
  final SensorTelemetry sensor;
  final ActuatorTelemetry actuator;
  final SystemTelemetry system;
  final FeederTelemetry feeder;
  final DateTime receivedAt;

  /// 🟢 REVISI: true kalau JSON masuk MEMANG membawa key `sys` (paket
  /// lengkap). false = paket mini act-only yang `system`-nya cuma hasil
  /// merge dari `previous` (data lama) -- jangan dipakai untuk keputusan
  /// yang butuh data sistem SEGAR (mis. cek drift jam ESP).
  final bool sysFresh;

  TelemetryPacket({
    required this.sensor,
    required this.actuator,
    required this.system,
    required this.feeder,
    this.sysFresh = false,
    DateTime? receivedAt,
  }) : receivedAt = receivedAt ?? DateTime.now();

  /// [previous] = paket lengkap TERAKHIR yang berhasil di-parse (lihat
  /// bluetooth_service.dart -> _lastPacket).
  ///
  /// 🟢 PENDUKUNG "EVENT CEPAT" DARI ESP (CommsBT.cpp -> force_bt_send_act):
  /// ESP sekarang kadang mengirim paket MINI yang cuma berisi key `act`
  /// (pompa/feeder/charger berubah), TANPA `sen`/`sys`/`fd` -- supaya
  /// perubahan relay sampai ke webapp instan tanpa perlu kirim ulang
  /// sensor/sistem yang belum tentu berubah. Kalau bagian itu diparse
  /// begitu saja lewat `SensorTelemetry.fromJson(null)` dst, hasilnya
  /// SEMUA field sensor/sistem/feeder jadi 0/default -- lalu ikut
  /// ter-upload ke Supabase (lihat feeding_screen.dart ->
  /// _uploadMergedTelemetry, yang mengirim SELURUH toSupabaseRow()) dan
  /// menimpa data asli dengan nilai kosong tiap kali relay berubah.
  ///
  /// Jadi: section yang TIDAK ADA di JSON masuk diisi dari [previous]
  /// (bukan dari default kosong) kalau [previous] tersedia. Section yang
  /// memang ADA di JSON tetap diparse fresh seperti biasa.
  factory TelemetryPacket.fromJson(
    Map<String, dynamic> json, {
    TelemetryPacket? previous,
  }) {
    return TelemetryPacket(
      sensor: json.containsKey('sen')
          ? SensorTelemetry.fromJson(json['sen'] as Map<String, dynamic>?)
          : (previous?.sensor ?? SensorTelemetry.fromJson(null)),
      actuator: json.containsKey('act')
          ? ActuatorTelemetry.fromJson(json['act'] as Map<String, dynamic>?)
          : (previous?.actuator ?? ActuatorTelemetry.fromJson(null)),
      system: json.containsKey('sys')
          ? SystemTelemetry.fromJson(json['sys'] as Map<String, dynamic>?)
          : (previous?.system ?? SystemTelemetry.fromJson(null)),
      feeder: json.containsKey('fd')
          ? FeederTelemetry.fromJson(json['fd'] as Map<String, dynamic>?)
          : (previous?.feeder ?? FeederTelemetry.fromJson(null)),
      sysFresh: json.containsKey('sys'), // 🟢 REVISI
    );
  }

  /// Baris flat siap di-upload ke satu tabel telemetry di Supabase.
  Map<String, dynamic> toSupabaseRow() => {
    ...sensor.toSupabaseRow(),
    ...actuator.toSupabaseRow(),
    ...system.toSupabaseRow(),
    ...feeder.toSupabaseRow(),
    'device_received_at': receivedAt.toIso8601String(),
  };
}
