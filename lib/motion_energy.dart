import 'dart:typed_data';
import 'package:camera/camera.dart';

/// Port Dart dari compute_motion_energy() di motion_energy_pipeline.py:
///   1. resize ke 160x120 (average-pooling di Y-plane)
///   2. Gaussian blur 5x5
///   3. diff absolut terhadap frame sebelumnya
///   4. threshold biner (diffThreshold) -> hitung piksel yang "aktif"
///
/// REVISI KALIBRASI (v2):
/// - EMA & peak yang dulu ada di sini DIHAPUS. Satu-satunya EMA sekarang
///   ada di feeder_trigger.dart, supaya tidak ada dua EMA dengan alpha
///   berbeda (dulu extractor 0.25 vs config 0.15).
/// - Selain skor stride-1 (frame vs frame sebelumnya), extractor menghitung
///   skor STRIDE 2/4/8 (frame vs frame k langkah lalu) pada frame yang SAMA.
///   Tujuannya: dari satu rekaman di fps dasar F, kita bisa menyimulasikan
///   fps efektif F, F/2, F/4, F/8 secara adil (event yang sama, frame yang
///   sama). Skor motion energy bergantung pada jarak waktu antar frame yang
///   dibandingkan, jadi men-subsample deret skor stride-1 TIDAK sama dengan
///   fps yang lebih rendah -- itu sebabnya stride dihitung langsung di sini.
/// - processFrame() mengembalikan null untuk frame pertama (belum ada
///   pembanding), BUKAN 0, supaya tidak meracuni EMA awal.
class MotionEnergyExtractor {
  final int targetWidth;
  final int targetHeight;
  final int diffThreshold;

  /// Stride yang dihitung. Urutan naik; yang terbesar menentukan ukuran
  /// riwayat frame (8 frame x 19.2 KB = ~150 KB, murah).
  static const List<int> strides = [1, 2, 4, 8];

  MotionEnergyExtractor({
    this.targetWidth = 160,
    this.targetHeight = 120,
    this.diffThreshold = 25,
  });

  static const List<int> _kernel = [
    1, 4, 6, 4, 1, //
    4, 16, 24, 16, 4, //
    6, 24, 36, 24, 6, //
    4, 16, 24, 16, 4, //
    1, 4, 6, 4, 1,
  ];
  static const int _kernelSum = 256;

  /// Riwayat frame ter-blur, terlama di depan.
  final List<Uint8List> _hist = <Uint8List>[];

  /// Skor frame TERAKHIR per stride. -1 = belum ada pembanding yang cukup
  /// jauh ke belakang (awal sesi / setelah reset()).
  final Map<int, double> strideScores = {for (final s in strides) s: -1.0};

  /// Return skor stride-1 (jumlah piksel berubah signifikan), atau null
  /// untuk frame pertama setelah reset().
  double? processFrame(CameraImage image) {
    final downsampled = _downsample(image);
    final blurred = _gaussianBlur5x5(downsampled, targetWidth, targetHeight);

    for (final s in strides) {
      if (_hist.length >= s) {
        strideScores[s] = _countActive(
          blurred,
          _hist[_hist.length - s],
        ).toDouble();
      } else {
        strideScores[s] = -1.0;
      }
    }
    final double? result = _hist.isNotEmpty ? strideScores[1] : null;

    _hist.add(blurred);
    while (_hist.length > strides.last) {
      _hist.removeAt(0);
    }
    return result;
  }

  int _countActive(Uint8List a, Uint8List b) {
    int active = 0;
    for (int i = 0; i < a.length; i++) {
      if ((a[i] - b[i]).abs() > diffThreshold) active++;
    }
    return active;
  }

  /// Average-pooling dari Y-plane resolusi asli kamera -> targetWidth x
  /// targetHeight. Aproksimasi dari cv2.resize.
  Uint8List _downsample(CameraImage image) {
    final yPlane = image.planes[0];
    final bytes = yPlane.bytes;
    final srcW = image.width;
    final srcH = image.height;
    final rowStride = yPlane.bytesPerRow;

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

  Uint8List _gaussianBlur5x5(Uint8List src, int w, int h) {
    final out = Uint8List(w * h);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        int sum = 0;
        int ki = 0;
        for (int ky = -2; ky <= 2; ky++) {
          final sy = (y + ky).clamp(0, h - 1);
          for (int kx = -2; kx <= 2; kx++) {
            final sx = (x + kx).clamp(0, w - 1);
            sum += src[sy * w + sx] * _kernel[ki];
            ki++;
          }
        }
        out[y * w + x] = (sum ~/ _kernelSum).clamp(0, 255);
      }
    }
    return out;
  }

  /// Panggil di awal sesi / uji coba. Hanya membuang riwayat frame.
  void reset() {
    _hist.clear();
    for (final s in strides) {
      strideScores[s] = -1.0;
    }
  }
}
