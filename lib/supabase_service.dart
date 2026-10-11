import 'package:supabase_flutter/supabase_flutter.dart';

import 'dev_log.dart';

/// Semua interaksi J2 Prime <-> Supabase.
///
/// Arsitektur komunikasi (comms_03.txt):
///   ESP32 --BT--> J2 Prime --WiFi--> Supabase --> Webapp
///   ESP32 <--BT-- J2 Prime <--WiFi-- Supabase <-- Webapp (realtime)
///
/// CATATAN REVISI: tidak ada lagi timer independen J2 untuk kirim info
/// baterai (dulu tiap 60s). Sekarang J2 hanya mengirim ke Supabase saat
/// TERIMA paket telemetri dari ESP (mengikuti interval `cfg.up` milik
/// ESP, yang juga bisa diubah dari Supabase lewat `cfg.up`) -- baterai,
/// suhu HP, CPU usage, dan status BT digabung ke payload yang SAMA,
/// satu kali kirim (lihat feeding_screen._uploadMergedTelemetry). Class
/// ini jadi cuma nerima Map siap-kirim, gak lagi tau soal TelemetryPacket
/// biar gampang dites terpisah.
class FeederSupabaseService {
  final SupabaseClient _client = Supabase.instance.client;

  final String telemetryTable;
  final String feedSessionTable;
  final String configTable;
  final int rowId;

  final void Function(LogDirection direction, String channel, String message)?
  onLog;

  RealtimeChannel? _configChannel;

  FeederSupabaseService({
    required this.telemetryTable,
    required this.feedSessionTable,
    required this.configTable,
    required this.rowId,
    this.onLog,
  });

  // ---------------------------------------------------------------------
  // UPLOAD: ESP -> (BT) -> J2 -> (WiFi) -> Supabase
  // ---------------------------------------------------------------------

  /// [row] sudah berisi gabungan data telemetri ESP + info device J2
  /// (baterai, suhu, cpu, status BT) -- satu baris, satu kali update.
  /// Fire-and-forget dari sisi caller (jangan di-await di listener BT).
  Future<void> uploadTelemetry(Map<String, dynamic> row) async {
    try {
      await _client
          .from(telemetryTable)
          .update({...row, 'updated_at': DateTime.now().toIso8601String()})
          .eq('id', rowId);
    } catch (e) {
      onLog?.call(LogDirection.error, 'SUPA', 'Gagal upload telemetry: $e');
      rethrow;
    }
  }

  /// Partial update HANYA kolom `bt_connected` (+ `updated_at`) di baris
  /// telemetry -- TIDAK menyentuh kolom sensor/aktuator/sistem lain sama
  /// sekali. Dipanggil J2 sekali saat link BT terputus (lihat
  /// feeding_screen.dart -> onConnectionChanged), supaya Supabase langsung
  /// tahu status putus tanpa menunggu paket telemetri berikutnya (yang
  /// justru tidak akan pernah datang selama link putus). Tidak ada
  /// timer/heartbeat berulang di balik ini -- pemanggilan sekali saja per
  /// event putus/konek.
  ///
  /// 🟢 REVISI: sekarang mengembalikan Future<bool> (true = tertulis). Pemanggil
  /// (feeding_screen._pushBtStatus) menandai "dirty" dan mencoba lagi kalau
  /// gagal, supaya status putus tidak nyangkut "terhubung" di webapp saat
  /// internet ikut putus.
  Future<bool> updateBtStatus(bool connected) async {
    try {
      await _client
          .from(telemetryTable)
          .update({
            'bt_connected': connected,
            'updated_at': DateTime.now().toIso8601String(),
          })
          .eq('id', rowId);
      return true;
    } catch (e) {
      onLog?.call(LogDirection.error, 'SUPA', 'Gagal update status BT: $e');
      return false;
    }
  }

  /// Tulis balik status flash EFEKTIF (manual ATAU otomatis sesi) ke kolom
  /// `flash_on` di baris config, supaya tombol flash di webapp selalu
  /// mencerminkan kondisi torch sebenarnya (termasuk saat dinyalakan dari
  /// tombol di app J2 atau otomatis oleh sesi pakan).
  Future<void> setFlashOn(bool on) async {
    try {
      await _client
          .from(configTable)
          .update({
            'flash_on': on,
            'updated_at': DateTime.now().toIso8601String(),
          })
          .eq('id', rowId);
    } catch (e) {
      onLog?.call(LogDirection.error, 'SUPA', 'Gagal tulis balik flash_on: $e');
    }
  }

  // ---------------------------------------------------------------------
  // 🟢 REVISI (P1 / SPEC 3.2, 3.3, 3.5, 4): kamera & flash J2 stabil.
  // Semua method di bawah HANYA menulis saat ada perubahan (tidak berkala),
  // dan yang bersyarat memakai filter .eq/.not supaya 0 baris cocok = tidak
  // ada tulisan sama sekali (tidak menimpa nilai yang lebih baru).
  // ---------------------------------------------------------------------

  /// device_config.flash_on = false HANYA bila masih true (J2 yang mematikan:
  /// timeout / viewer hilang / app start). true = berhasil (termasuk 0 baris
  /// cocok); false = error jaringan/DB -> pemanggil mengulang.
  Future<bool> setFlashOffIfOn() async {
    try {
      await _client
          .from(configTable)
          .update({
            'flash_on': false,
            'updated_at': DateTime.now().toIso8601String(),
          })
          .eq('id', rowId)
          .eq('flash_on', true);
      return true;
    } catch (e) {
      onLog?.call(LogDirection.error, 'SUPA', 'Gagal tulis flash_on=false: $e');
      return false;
    }
  }

  /// feeder_status.flash_actual = status torch SEBENARNYA. Dipanggil HANYA saat
  /// torchActual berubah. (Kolom baru di feeder_status, bukan device_telemetry:
  /// tabel itu punya trigger history di setiap UPDATE.)
  Future<void> setFlashActual(bool actual) async {
    try {
      await _client
          .from(feedSessionTable)
          .update({'flash_actual': actual})
          .eq('id', rowId);
    } catch (e) {
      onLog?.call(LogDirection.error, 'SUPA', 'Gagal tulis flash_actual: $e');
    }
  }

  /// Koreksi flash_actual basi saat app start (app mati saat torch nyala):
  /// tulis false HANYA bila masih true.
  Future<void> resetFlashActualIfOn() async {
    try {
      await _client
          .from(feedSessionTable)
          .update({'flash_actual': false})
          .eq('id', rowId)
          .eq('flash_actual', true);
    } catch (e) {
      onLog?.call(LogDirection.error, 'SUPA', 'Gagal reset flash_actual: $e');
    }
  }

  /// feeder_status.cam_issue (+ cam_issue_at): black | stall | init_failed.
  /// Pemanggil menjamin sekali per jenis per sesi.
  Future<void> setCamIssue(String kind, DateTime at) async {
    try {
      await _client
          .from(feedSessionTable)
          .update({
            'cam_issue': kind,
            'cam_issue_at': at.toUtc().toIso8601String(),
          })
          .eq('id', rowId);
    } catch (e) {
      onLog?.call(LogDirection.error, 'SUPA', 'Gagal tulis cam_issue: $e');
    }
  }

  /// Reset cam_issue/cam_issue_at ke null saat sesi baru mulai -- HANYA bila
  /// cam_issue sebelumnya tidak null (filter di sisi DB, tanpa baca dulu).
  // TODO verifikasi: .not('cam_issue', 'is', null) di postgrest ^2.x
  // (harus menghasilkan cam_issue=not.is.null).
  Future<void> clearCamIssueIfSet() async {
    try {
      await _client
          .from(feedSessionTable)
          .update({'cam_issue': null, 'cam_issue_at': null})
          .eq('id', rowId)
          .not('cam_issue', 'is', null);
    } catch (e) {
      onLog?.call(LogDirection.error, 'SUPA', 'Gagal reset cam_issue: $e');
    }
  }

  /// Saat app start: state 'feeding' yang nyangkut (app mati saat sesi) ->
  /// 'stopped'/'app_restart' HANYA bila state saat ini 'feeding'. 'stopped'
  /// dengan alasan asli TIDAK ditimpa.
  Future<void> closeStaleFeeding() async {
    try {
      await _client
          .from(feedSessionTable)
          .update({
            'state': 'stopped',
            'last_stop_reason': 'app_restart',
            'updated_at': DateTime.now().toIso8601String(),
          })
          .eq('id', rowId)
          .eq('state', 'feeding');
    } catch (e) {
      onLog?.call(
        LogDirection.error,
        'SUPA',
        'Gagal koreksi feeder_status saat start: $e',
      );
    }
  }

  // ---------------------------------------------------------------------
  // 🟢 FIX BUG "override pompa/charger stuck di 1" (item 1)
  // ---------------------------------------------------------------------

  /// Tulis balik SEBAGIAN isi kolom `ovr` (jsonb) pada baris config.
  ///
  /// Dipakai J2 (lihat feeding_screen.dart ->
  /// _syncOverrideGateFromTelemetry) saat mendeteksi dari telemetri bahwa
  /// suatu bit override sudah berubah SENDIRI di ESP tanpa lewat webapp --
  /// pompa auto-mati sesudah durasi `pmax`, tombol fisik T25/T27, atau
  /// auto-kuras saat sensor kotor (lihat FeederLogic.cpp). Tanpa tulis
  /// balik ini, kolom `ovr.p`/`ovr.c` di Supabase nyangkut SELAMANYA di
  /// nilai lama -- klik tombol berikutnya yang menulis nilai IDENTIK
  /// tidak pernah dianggap sebagai perubahan oleh Postgres (tidak ada
  /// delta value) maupun oleh gate `_lastOvr` di J2, sehingga perintah
  /// didiamkan begitu saja.
  ///
  /// [partialOvr] hanya berisi key yang perlu dikoreksi (mis. {'p': 0}).
  /// Di-merge dengan isi `ovr` yang sudah ada, BUKAN menimpa seluruh
  /// kolom -- supaya key lain (mis. 'f'/'x' yang sedang jadi pulsa
  /// tersendiri) tidak ikut tertimpa balapan.
  Future<void> patchOverride(Map<String, dynamic> partialOvr) async {
    if (partialOvr.isEmpty) return;
    try {
      final current = await _client
          .from(configTable)
          .select('ovr')
          .eq('id', rowId)
          .maybeSingle();
      final existing = current?['ovr'];
      final merged = <String, dynamic>{
        if (existing is Map) ...Map<String, dynamic>.from(existing),
        ...partialOvr,
      };
      await _client
          .from(configTable)
          .update({
            'ovr': merged,
            'updated_at': DateTime.now().toIso8601String(),
          })
          .eq('id', rowId);
    } catch (e) {
      onLog?.call(
        LogDirection.error,
        'SUPA',
        'Gagal tulis balik status ovr: $e',
      );
    }
  }

  // ---------------------------------------------------------------------
  // SESI FEEDING (hasil algoritma AI CV yang jalan lokal di J2)
  // ---------------------------------------------------------------------

  /// [ema]/[peak] opsional -- nilai motion-energy TERKINI dari trigger lokal
  /// (lihat feeder_trigger.dart), dikirim berkala selagi sesi berjalan
  /// supaya webapp bisa menampilkannya (Dashboard, item 5). Kolom
  /// `ema`/`peak` (float8, nullable) perlu ada di tabel [feedSessionTable]
  /// di Supabase -- lihat catatan di README/migrasi.
  Future<void> updateFeedingStatus({
    required String state,
    String? stopReason,
    double? ema,
    double? peak,
  }) async {
    try {
      final row = <String, dynamic>{
        'state': state,
        'last_stop_reason': stopReason,
        'updated_at': DateTime.now().toIso8601String(),
      };
      if (ema != null) row['ema'] = ema;
      if (peak != null) row['peak'] = peak;

      await _client.from(feedSessionTable).update(row).eq('id', rowId);
    } catch (e) {
      onLog?.call(
        LogDirection.error,
        'SUPA',
        'Gagal update status feeding: $e',
      );
      throw Exception('Gagal update status feeding: $e');
    }
  }

  /// Tabel khusus data kalibrasi tingkat-frame. SENGAJA terpisah dari
  /// device_telemetry/telemetry_history: tidak lewat trigger history, tidak
  /// ikut `select('*')` dashboard, dan kalau tabelnya belum ada yang gagal
  /// HANYA upload diag (upload telemetri biasa tetap jalan).
  /// [rows] = list {session_id, is_trial, diag}; device_id diisi di sini.
  /// Lempar exception kalau gagal supaya caller menyimpan backlog.
  Future<void> insertAiDiag(List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return;
    final payload = [
      for (final r in rows) {...r, 'device_id': rowId},
    ];
    await _client.from('ai_diag_log').insert(payload);
  }

  /// Konfirmasi ke webapp bahwa label `label_cmd.seq` sudah masuk recorder.
  /// Hanya menulis kolom `label_ack` (bigint) -- tidak menyentuh kolom lain.
  Future<void> ackLabel(int seq) async {
    try {
      await _client
          .from(configTable)
          .update({'label_ack': seq})
          .eq('id', rowId);
    } catch (err) {
      onLog?.call(LogDirection.error, 'SUPA', 'Gagal ack label: $err');
    }
  }

  /// 🟢 REVISI: reset kolom `rst` ke 0 HANYA kalau nilainya masih sama dengan
  /// [sent] (nilai yang barusan dikirim ke ESP). Kalau operator keburu
  /// menulis nilai lain, tidak ditimpa. Dengan rst kembali 0, Soft Reset
  /// berikutnya (nilai 1 lagi) terdeteksi sebagai perubahan oleh Postgres
  /// maupun gate `_lastRst` di J2.
  ///
  /// 🟢 REVISI: sekarang mengembalikan Future<bool> (true = update berhasil,
  /// termasuk kasus 0 baris cocok karena nilai sudah berubah; false = error
  /// jaringan/DB). Pemanggil memakainya untuk memutuskan kapan gate `_lastRst`
  /// boleh dikembalikan ke 0 (lihat feeding_screen._clearRstInDb).
  Future<bool> resetRstIfEquals(int sent) async {
    try {
      await _client
          .from(configTable)
          .update({
            'rst': 0,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', rowId)
          .eq('rst', sent);
      return true;
    } catch (e) {
      onLog?.call(LogDirection.error, 'SUPA', 'Gagal reset rst: $e');
      return false;
    }
  }

  Future<void> updateTrialStatus({
    required String status,
    int? sessionId,
    DateTime? startedAt,
    String? stopReason,
  }) async {
    try {
      final row = <String, dynamic>{
        'trial_status': status,
        'trial_last_sample': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      };
      if (sessionId != null) row['trial_session_id'] = sessionId;
      if (startedAt != null)
        row['trial_started_at'] = startedAt.toIso8601String();
      if (stopReason != null) row['trial_stop_reason'] = stopReason;
      if (status == 'idle') row['trial_active'] = false;
      await _client.from(configTable).update(row).eq('id', rowId);
    } catch (e) {
      onLog?.call(LogDirection.error, 'SUPA', 'Gagal update status trial: $e');
    }
  }

  // ---------------------------------------------------------------------
  // DOWNLOAD/SUBSCRIBE: Webapp -> Supabase -> J2 -> (BT) -> ESP
  // ---------------------------------------------------------------------

  /// Baca SATU KALI baris config terbaru.
  ///
  /// Dipakai J2 untuk dua hal, dua-duanya krusial:
  /// 1. SEEDING baseline gate perintah saat app start -- supaya nilai
  ///    `ovr`/`rst` lama yang masih nyangkut di database TIDAK ikut
  ///    dieksekusi ulang begitu ada perubahan baris berikutnya.
  /// 2. Mendorong ulang `cfg` ke ESP setiap kali link Bluetooth tersambung
  ///    (ESP kehilangan seluruh config tiap kali restart).
  Future<Map<String, dynamic>?> fetchConfigRow() async {
    try {
      final data = await _client
          .from(configTable)
          .select()
          .eq('id', rowId)
          .maybeSingle();
      return data;
    } catch (e) {
      onLog?.call(LogDirection.error, 'SUPA', 'Gagal baca baris config: $e');
      return null;
    }
  }

  /// Subscribe realtime ke perubahan baris config (tabel [configTable],
  /// id = [rowId]). Diasumsikan tabel ini punya kolom jsonb `cfg` (config
  /// ESP), `ovr` (override ESP), `rst` (int, reset ESP), dan `calib`
  /// (jsonb, kalibrasi AI lokal J2 -- decay_ratio, min_peak, dst).
  ///
  /// Caller (feeding_screen) yang menerjemahkan row baru ini jadi paket
  /// BT ke ESP (`cfg`/`ovr`/`rst`) dan/atau perubahan config lokal J2
  /// (`calib`).
  void subscribeConfig({
    required void Function(Map<String, dynamic> row) onConfigChanged,
  }) {
    _configChannel = _client
        .channel('public:$configTable:row-$rowId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: configTable,
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'id',
            value: rowId,
          ),
          callback: (payload) {
            onLog?.call(
              LogDirection.inbound,
              'SUPA',
              'Perubahan config diterima dari webapp',
            );
            onConfigChanged(payload.newRecord);
          },
        )
        .subscribe();
  }

  void unsubscribeConfig() {
    if (_configChannel != null) {
      _client.removeChannel(_configChannel!);
      _configChannel = null;
    }
  }

  void dispose() {
    unsubscribeConfig();
  }
}
