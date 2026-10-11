import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'dev_log.dart';

/// ---------------------------------------------------------------------
/// KENAPA PRESENCE, BUKAN BROADCAST "watch:start"/"watch:stop"
/// ---------------------------------------------------------------------
/// Presence Supabase Realtime otomatis "leave" begitu koneksi socket
/// viewer putus (tab ditutup, browser crash, wifi hilang, HP dikunci)
/// TANPA viewer perlu sempat mengirim pesan "stop" apa pun. Kalau kita
/// pakai broadcast start/stop manual, ada skenario bug nyata: viewer
/// buka panel (kirim "start"), lalu koneksinya putus mendadak SEBELUM
/// sempat kirim "stop" -- J2 tidak akan pernah tahu, dan live-cam
/// nyangkut ON selamanya (boros kuota + CPU J2 tanpa ada yang nonton).
/// Presence menghindari kelas bug ini sepenuhnya karena statusnya
/// dikelola server Supabase sendiri berdasarkan koneksi socket, bukan
/// pesan yang bisa "gak sempat terkirim".
///
/// J2 di sini HANYA membaca presence (siapa saja viewer yang nge-`track()`
/// dirinya di channel ini) -- J2 SENDIRI TIDAK ikut track() presence,
/// karena J2 bukan "viewer", J2 publisher.
///
/// 🟢 REVISI (P1 / SPEC 3.4) -- tambahan, API publik lama TIDAK berubah:
///  1. Re-subscribe otomatis saat channel closed/timedOut/channelError
///     (jeda 5 dtk, backoff ganda sampai 60 dtk). Presence dihitung ulang
///     setiap channel kembali `subscribed`.
///  2. Ping viewer OPSIONAL: bila viewer mengirim broadcast event `ping`,
///     viewer dianggap hilang kalau 60 dtk tanpa ping (menangkap tab yang
///     "zombie" tapi socket-nya belum di-leave server). Kalau ping tidak
///     pernah datang (webapp lama) => perilaku presence saja, seperti dulu.
///  3. Batas durasi kirim frame berkelanjutan `maxMinutes` (default 30,
///     0 = tanpa batas, clamp 0..240). Lewat batas: berhenti kirim frame dan
///     onWatchersChanged(false) (channel tetap subscribe); lanjut lagi saat
///     ada presence JOIN baru. Pengecekan dilakukan di sendFrame (sudah
///     periodik) sehingga tidak butuh timer tambahan.
class LiveCamService {
  final SupabaseClient _client = Supabase.instance.client;
  RealtimeChannel? _channel;

  /// Dipanggil setiap kali status "ada viewer aktif" berubah (true/false).
  /// HANYA dipanggil saat nilainya benar-benar berubah (bukan tiap sync
  /// event Presence, yang bisa nembak berkali-kali walau isinya sama --
  /// lihat guard `_lastActive` di [_recompute]).
  final void Function(bool active) onWatchersChanged;

  final void Function(LogDirection direction, String channel, String message)?
  onLog;

  final String channelName;

  // 🟢 REVISI: konstanta SPEC 3.4
  static const Duration kResubscribeMin = Duration(seconds: 5);
  static const Duration kResubscribeMax = Duration(seconds: 60);
  static const Duration kPingTimeout = Duration(seconds: 60);
  static const int kDefaultMaxMinutes = 30;
  static const int kMaxMinutesCeil = 240;

  bool _lastActive = false;
  bool _disposed = false;

  // 🟢 REVISI: re-subscribe
  Timer? _resubTimer;
  Duration _backoff = kResubscribeMin;

  // 🟢 REVISI: ping viewer opsional (timer sekali-jalan yang di-reset tiap
  // ping, bukan polling).
  Timer? _pingTimer;
  bool _pingSeen = false;
  bool _pingFresh = false;

  // 🟢 REVISI: batas durasi kirim
  int _maxMinutes;
  DateTime? _activeSince;
  bool _capped = false;

  LiveCamService({
    required this.channelName,
    required this.onWatchersChanged,
    this.onLog,
    int maxMinutes = kDefaultMaxMinutes,
  }) : _maxMinutes = _clampMax(maxMinutes);

  static int _clampMax(int v) => v.clamp(0, kMaxMinutesCeil).toInt();

  /// Batas menit kirim frame berkelanjutan (0 = tanpa batas). Boleh diubah
  /// kapan saja (mis. dari calib.live_cam_max_min).
  int get maxMinutes => _maxMinutes;
  set maxMinutes(int v) {
    final c = _clampMax(v);
    if (c == _maxMinutes) return;
    _maxMinutes = c;
    // Batas dilonggarkan saat sedang tertahan: hitung ulang.
    if (_capped && (c == 0 || !_isOverLimit())) {
      _capped = false;
      _recompute();
    }
  }

  /// true = frame sedang ditahan karena batas durasi tercapai.
  bool get isCapped => _capped;

  bool _isOverLimit() {
    final since = _activeSince;
    if (_maxMinutes <= 0 || since == null) return false;
    return DateTime.now().difference(since) >= Duration(minutes: _maxMinutes);
  }

  void start() {
    if (_channel != null) return; // sudah jalan
    _createChannel();
  }

  void _createChannel() {
    final ch = _client.channel(channelName);
    _channel = ch;
    ch
      ..onPresenceSync((_) {
        if (identical(_channel, ch)) _recompute();
      })
      ..onPresenceJoin((_) {
        if (identical(_channel, ch)) _recompute(join: true);
      })
      ..onPresenceLeave((_) {
        if (identical(_channel, ch)) _recompute();
      })
      // TODO verifikasi: signature onBroadcast di supabase_flutter ^2.17.2
      // (event: String, callback: void Function(Map<String, dynamic>)).
      ..onBroadcast(
        event: 'ping',
        callback: (_) {
          if (identical(_channel, ch)) _onPing();
        },
      )
      ..subscribe((status, error) => _onStatus(ch, status, error));
  }

  void _onStatus(
    RealtimeChannel ch,
    RealtimeSubscribeStatus status,
    Object? error,
  ) {
    if (_disposed || !identical(_channel, ch)) return;
    if (status == RealtimeSubscribeStatus.subscribed) {
      _backoff = kResubscribeMin;
      _resubTimer?.cancel();
      _resubTimer = null;
      onLog?.call(
        LogDirection.info,
        'CAM',
        'Channel live-cam siap ($channelName)',
      );
      // Presence dihitung ulang setiap (re)subscribe.
      _recompute();
      return;
    }
    if (status == RealtimeSubscribeStatus.closed ||
        status == RealtimeSubscribeStatus.timedOut ||
        status == RealtimeSubscribeStatus.channelError) {
      onLog?.call(
        LogDirection.error,
        'CAM',
        'Channel live-cam $status${error != null ? ' ($error)' : ''}',
      );
      _scheduleResubscribe();
    } else if (error != null) {
      onLog?.call(LogDirection.error, 'CAM', 'Channel live-cam error: $error');
    }
  }

  void _scheduleResubscribe() {
    if (_disposed || _resubTimer != null) return;
    final delay = _backoff;
    _backoff = Duration(
      seconds: math.min(delay.inSeconds * 2, kResubscribeMax.inSeconds),
    );
    onLog?.call(
      LogDirection.info,
      'CAM',
      'Live-cam subscribe ulang dalam ${delay.inSeconds} dtk',
    );
    _resubTimer = Timer(delay, () async {
      _resubTimer = null;
      if (_disposed) return;
      final old = _channel;
      _channel = null; // callback channel lama jadi stale (diabaikan)
      if (old != null) {
        try {
          await _client.removeChannel(old);
        } catch (_) {}
      }
      if (_disposed) return;
      _createChannel();
    });
  }

  void _onPing() {
    if (_disposed) return;
    _pingSeen = true;
    _pingFresh = true;
    _pingTimer?.cancel();
    _pingTimer = Timer(kPingTimeout, () {
      if (_disposed) return;
      _pingFresh = false;
      onLog?.call(
        LogDirection.info,
        'CAM',
        'Viewer live-cam 60 dtk tanpa ping -> dianggap hilang',
      );
      _recompute();
    });
    _recompute(); // pulih bila sebelumnya dianggap hilang
  }

  void _resetPing() {
    _pingTimer?.cancel();
    _pingTimer = null;
    _pingSeen = false;
    _pingFresh = false;
  }

  void _recompute({bool join = false}) {
    if (_disposed) return;
    // presenceState() balikin Map/List tergantung versi supabase_flutter --
    // isNotEmpty ada di keduanya, jadi ini aman lintas versi.
    final state = _channel?.presenceState();
    final present = state != null && state.isNotEmpty;

    if (!present) {
      _resetPing();
      _capped = false;
    }
    if (join) {
      // Viewer baru: ping lama tidak berlaku (viewer lama bisa tanpa ping)
      // dan batas durasi dimulai lagi.
      _resetPing();
      if (present) {
        _capped = false;
        _activeSince = DateTime.now();
      }
    }

    final active = present && (!_pingSeen || _pingFresh) && !_capped;
    if (active == _lastActive) return; // no-op kalau memang gak berubah
    _lastActive = active;
    if (active) {
      _activeSince ??= DateTime.now();
    } else if (!_capped) {
      _activeSince = null;
    }
    onLog?.call(
      LogDirection.info,
      'CAM',
      active
          ? 'Viewer live-cam terdeteksi -> nyala'
          : 'Viewer live-cam habis -> mati',
    );
    onWatchersChanged(active);
  }

  /// Kirim 1 frame JPEG (bytes SUDAH terenkode) ke semua viewer nyambung.
  /// Fire-and-forget dari sisi caller.
  Future<void> sendFrame(Uint8List jpegBytes) async {
    // 🟢 REVISI: batas durasi kirim berkelanjutan.
    if (_capped) return;
    if (_isOverLimit()) {
      _capped = true;
      onLog?.call(
        LogDirection.info,
        'CAM',
        'Batas live-cam $_maxMinutes menit tercapai -> berhenti kirim frame '
        '(buka ulang panel untuk lanjut)',
      );
      _recompute(); // -> active=false -> onWatchersChanged(false)
      return;
    }

    final channel = _channel;
    // 🟢 FIX DIAGNOSTIK: sebelumnya branch ini `return` TOTAL DIAM --
    // kalau start() belum sempat dipanggil / channel sempat null karena
    // race kecil, tidak ada jejak SAMA SEKALI kenapa frame tidak pernah
    // terkirim. Sekarang dicatat, supaya "diam" tidak lagi berarti
    // "entah kenapa".
    if (channel == null || _disposed) {
      onLog?.call(
        LogDirection.error,
        'CAM',
        'Lewati kirim frame -- channel live-cam belum siap (channel=${channel == null ? "null" : "ada"}, disposed=$_disposed)',
      );
      return;
    }
    // Guard ukuran -- payload broadcast Supabase ada batas (default besar,
    // tapi kita jaga jauh di bawahnya). Kalau kejadian, skip 1 frame ini
    // daripada bikin channel error terus2an.
    if (jpegBytes.lengthInBytes > 60 * 1024) {
      onLog?.call(
        LogDirection.error,
        'CAM',
        'Frame live-cam kegedean (${jpegBytes.lengthInBytes}B), di-skip',
      );
      return;
    }
    try {
      await channel.sendBroadcastMessage(
        event: 'frame',
        payload: {
          'jpg': base64Encode(jpegBytes),
          'ts': DateTime.now().millisecondsSinceEpoch,
        },
      );
      // 🟢 FIX DIAGNOSTIK: dulu sukses SENGAJA tidak di-log (biar hemat
      // buffer, sama seperti pola telemetri BT) -- tapi itu bikin kita
      // tidak bisa bedakan "berhasil dikirim tapi tidak sampai di webapp"
      // vs "tidak pernah nyampe sini sama sekali" saat debug. Volume-nya
      // jauh lebih jarang dari heartbeat telemetri (tiap liveCamIntervalSeconds,
      // minimal 1 detik), jadi aman di-log tiap kali.
      onLog?.call(
        LogDirection.outbound,
        'CAM',
        'Frame live-cam terkirim (${jpegBytes.lengthInBytes}B)',
      );
    } catch (e) {
      onLog?.call(LogDirection.error, 'CAM', 'Gagal kirim frame live-cam: $e');
    }
  }

  void dispose() {
    _disposed = true;
    _resubTimer?.cancel();
    _resubTimer = null;
    _pingTimer?.cancel();
    _pingTimer = null;
    final channel = _channel;
    _channel = null;
    if (channel != null) _client.removeChannel(channel);
  }
}

// ===========================================================================
// ENCODE JPEG DI ISOLATE TERPISAH (compute())
// ===========================================================================
//
// SENGAJA dipisah dari isolate/thread yang menjalankan loop motion energy
// (lihat motion_energy.dart -> MotionEnergyExtractor.processFrame, yang
// jalan sinkron di _onFrame / main isolate). Encode JPEG itu kerja CPU
// yang lumayan (downsample + kompres) -- kalau dijalankan di jalur yang
// sama dengan evaluasi decay/peak, dia bisa nyelip/nunda evaluasi
// trigger yang JUSTRU harus presisi waktu. compute() men-spawn isolate
// terpisah untuk 1 pekerjaan ini, jadi loop motion energy di main
// isolate sama sekali tidak tersentuh/tertunda olehnya.
//
// Sengaja HANYA pakai Y-plane (grayscale), BUKAN full-color (YUV->RGB):
// 1) Preview grayscale sudah lebih dari cukup buat "ngecek kondisi kolam"
//    (tujuan aslinya bukan foto bagus).
//  2) Konversi YUV420 -> RGB itu bagian PALING rawan bug lintas merek/versi
//    Android (pixel stride & row stride U/V beda-beda per device) --
//    dengan cuma pakai Y-plane, kelas bug itu dihindari total.
//  3) Lebih ringan -> encode lebih cepat -> isolate selesai lebih cepat.

class LiveCamFrameJob {
  final int width;
  final int height;
  final int bytesPerRow;
  final Uint8List yBytes; // COPY, bukan reference ke buffer asli plugin kamera
  final int targetWidth;
  final int targetHeight;
  final int jpegQuality;

  const LiveCamFrameJob({
    required this.width,
    required this.height,
    required this.bytesPerRow,
    required this.yBytes,
    required this.targetWidth,
    required this.targetHeight,
    required this.jpegQuality,
  });
}

/// HARUS top-level function (bukan method instance) supaya bisa dikirim
/// ke isolate lain lewat compute().
///
/// 🔴 FIX BUG "live-cam diam total, tidak ada log CAM sama sekali":
/// versi sebelumnya membungkus SELURUH badan fungsi ini dengan try/catch
/// yang menelan error apa pun dan cuma `return null` -- kalau constructor
/// `img.Image.fromBytes(...)` di bawah tidak cocok dengan versi package
/// `image` yang terpasang (lihat CATATAN VERSI), setiap frame gagal
/// encode TANPA jejak log sama sekali, karena caller
/// (`_maybeCaptureLiveCamFrame` di feeding_screen.dart) juga cuma
/// `if (jpegBytes == null) return;` tanpa log.
///
/// SEKARANG: error dibiarkan naik apa adanya lewat Future dari
/// `compute()`. Ini AMAN -- panggilan `buildLiveCamFrame()` di
/// feeding_screen.dart bersifat fire-and-forget (`.then().catchError()`),
/// jadi exception di sini TIDAK PERNAH mengganggu/menunda loop motion
/// energy (AI/feeding) yang berjalan terpisah -- ia hanya membuat error
/// akhirnya tercatat ke Dev Log channel CAM lewat `.catchError()` yang
/// SUDAH ADA di sana ('Gagal proses frame live-cam: $e'), alih-alih
/// hilang tanpa jejak seperti sebelumnya.
Uint8List? encodeLiveCamJpeg(LiveCamFrameJob job) {
  final gray = _downsampleY(
    job.yBytes,
    job.width,
    job.height,
    job.bytesPerRow,
    job.targetWidth,
    job.targetHeight,
  );

  // CATATAN VERSI: signature Image.fromBytes ada sedikit perbedaan antar
  // versi major package `image` (v3 vs v4). Ini ditulis untuk `image: ^4.x`.
  // Kalau pubspec.yaml pakai versi lain dan baris di bawah throw, error-nya
  // SEKARANG akan muncul di Dev Log channel CAM (bukan lagi ditelan diam2)
  // -- sesuaikan pemanggilan constructor-nya sesuai versi yang terpasang.
  // 🟢 FIX BUG "frame live-cam merah/ambient tint": numChannels: 1 di
  // package `image` DIPAKSA jadi ChannelOrder.red secara internal --
  // artinya buffer ini dianggap "cuma channel Red", bukan luminance
  // murni. Channel G/B yang tidak ada itu jadi kosong (0) saat
  // encodeJpg menuliskan JPEG, sehingga hasil dekode di browser
  // condong merah/oranye alih-alih abu-abu netral.
  //
  // Fix: duplikasi nilai Y (grayscale) ke 3 channel (R=G=B) SEBELUM
  // encode. Ini aman untuk ukuran file -- karena R=G=B, transformasi
  // YCbCr di dalam encoder menghasilkan channel chroma (Cb/Cr) yang
  // konstan/nyaris nol variasi, jadi kompres JAUH lebih ringan dari
  // JPEG RGB pada umumnya; ukuran akhir tidak jauh beda dari versi
  // 1-channel sebelumnya (masih aman di bawah guard 60KB di
  // LiveCamService.sendFrame maupun CAM_MAX_JPG_B64_LEN di webapp).
  final rgb = Uint8List(gray.length * 3);
  for (int i = 0; i < gray.length; i++) {
    final v = gray[i];
    final o = i * 3;
    rgb[o] = v;
    rgb[o + 1] = v;
    rgb[o + 2] = v;
  }

  final image = img.Image.fromBytes(
    width: job.targetWidth,
    height: job.targetHeight,
    bytes: rgb.buffer,
    numChannels: 3,
  );

  return Uint8List.fromList(img.encodeJpg(image, quality: job.jpegQuality));
}

/// Average-pooling Y-plane -> targetWidth x targetHeight, grayscale 8-bit.
/// Sama persis prinsipnya dengan _downsample di motion_energy.dart, tapi
/// SENGAJA berdiri sendiri (bukan reuse instance MotionEnergyExtractor)
/// karena fungsi ini harus top-level/pure supaya aman dikirim ke isolate.
Uint8List _downsampleY(
  Uint8List bytes,
  int srcW,
  int srcH,
  int rowStride,
  int targetWidth,
  int targetHeight,
) {
  final blockW = (srcW / targetWidth).floor().clamp(1, srcW);
  final blockH = (srcH / targetHeight).floor().clamp(1, srcH);

  final out = Uint8List(targetWidth * targetHeight);
  for (int ty = 0; ty < targetHeight; ty++) {
    final srcYStart = ty * blockH;
    if (srcYStart >= srcH) break;
    final yEnd = (srcYStart + blockH).clamp(0, srcH);
    for (int tx = 0; tx < targetWidth; tx++) {
      final srcXStart = tx * blockW;
      if (srcXStart >= srcW) break;
      final xEnd = (srcXStart + blockW).clamp(0, srcW);

      int sum = 0;
      int count = 0;
      for (int y = srcYStart; y < yEnd; y++) {
        final rowStart = y * rowStride;
        for (int x = srcXStart; x < xEnd; x++) {
          sum += bytes[rowStart + x];
          count++;
        }
      }
      out[ty * targetWidth + tx] = count > 0 ? (sum ~/ count) : 0;
    }
  }
  return out;
}

/// Helper kecil dipanggil dari feeding_screen.dart -- bungkus compute()
/// supaya caller gak perlu import `image` package langsung.
Future<Uint8List?> buildLiveCamFrame(LiveCamFrameJob job) {
  return compute(encodeLiveCamJpeg, job);
}

/// Ambil 1 frame CameraImage (Y-plane saja) jadi LiveCamFrameJob siap
/// dikirim ke isolate. HARUS dipanggil SEGERA di dalam callback _onFrame
/// (bukan ditunda), karena buffer asli plugin kamera cuma valid selama
/// callback tsb berjalan -- makanya di sini langsung di-copy
/// (Uint8List.fromList) sebelum keluar dari fungsi ini.
LiveCamFrameJob buildLiveCamJob(
  CameraImage image, {
  required int targetWidth,
  required int targetHeight,
  required int jpegQuality,
}) {
  final yPlane = image.planes[0];
  return LiveCamFrameJob(
    width: image.width,
    height: image.height,
    bytesPerRow: yPlane.bytesPerRow,
    yBytes: Uint8List.fromList(yPlane.bytes), // COPY -- lihat catatan di atas
    targetWidth: targetWidth,
    targetHeight: targetHeight,
    jpegQuality: jpegQuality,
  );
}
