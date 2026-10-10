import 'dart:async';
import 'dart:convert';
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
class LiveCamService {
  final SupabaseClient _client = Supabase.instance.client;
  RealtimeChannel? _channel;

  /// Dipanggil setiap kali status "ada viewer aktif" berubah (true/false).
  /// HANYA dipanggil saat nilainya benar-benar berubah (bukan tiap sync
  /// event Presence, yang bisa nembak berkali-kali walau isinya sama --
  /// lihat guard `_lastActive` di [_handlePresenceChange]).
  final void Function(bool active) onWatchersChanged;

  final void Function(LogDirection direction, String channel, String message)?
  onLog;

  final String channelName;

  bool _lastActive = false;
  bool _disposed = false;

  LiveCamService({
    required this.channelName,
    required this.onWatchersChanged,
    this.onLog,
  });

  void start() {
    if (_channel != null) return; // sudah jalan
    _channel = _client.channel(channelName);
    _channel!
      ..onPresenceSync((_) => _handlePresenceChange())
      ..onPresenceJoin((_) => _handlePresenceChange())
      ..onPresenceLeave((_) => _handlePresenceChange())
      ..subscribe((status, error) {
        if (status == RealtimeSubscribeStatus.subscribed) {
          onLog?.call(
            LogDirection.info,
            'CAM',
            'Channel live-cam siap ($channelName)',
          );
        } else if (error != null) {
          onLog?.call(
            LogDirection.error,
            'CAM',
            'Channel live-cam error: $error',
          );
        }
      });
  }

  void _handlePresenceChange() {
    if (_disposed) return;
    // presenceState() balikin Map/List tergantung versi supabase_flutter --
    // isNotEmpty ada di keduanya, jadi ini aman lintas versi.
    final state = _channel?.presenceState();
    final active = state != null && state.isNotEmpty;
    if (active == _lastActive) return; // no-op kalau memang gak berubah
    _lastActive = active;
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
