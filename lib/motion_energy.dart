import 'dart:typed_data';
import 'package:camera/camera.dart';

/// Port Dart dari compute_motion_energy() di motion_energy_pipeline.py:
///   1. resize ke 160x120
///   2. grayscale (Y-plane YUV420 kamera = sudah grayscale, gak perlu
///      convert RGB dulu -- ini beda dari cv2 yang resize dulu baru
///      convert BGR2GRAY, tapi hasilnya seharusnya cukup dekat)
///   3. Gaussian blur 5x5
///   4. diff absolut terhadap frame sebelumnya
///   5. threshold biner (diffThreshold) -> hitung piksel yang "aktif"
///
/// CATATAN JUJUR soal fidelity ke versi Python:
/// - Resize: cv2.resize pakai interpolasi bilinear di atas frame BGR,
///   di sini kita average-pooling langsung di atas Y-plane. Mendekati,
///   TIDAK identik bit-per-bit.
/// - Luma dari ISP kamera HP (biasanya BT.601/709) belum tentu identik
///   dengan formula cv2.cvtColor(BGR2GRAY).
/// - Gaussian kernel di bawah ini aproksimasi integer sigma~1 (kernel
///   klasik 1-4-6-4-1), BUKAN cv2.GaussianBlur(ksize=5,sigma=0) yang
///   sigma auto-computed persis 1.1.
/// Karena itu skala raw score dari kamera HP KEMUNGKINAN BESAR beda dari
/// video kalibrasi awal -- min_peak & decay_ratio wajib di-cek ulang
/// pakai data real dari kamera HP (lihat Settings screen / logging).
class MotionEnergyExtractor {
  final int targetWidth;
  final int targetHeight;
  final int diffThreshold;

  MotionEnergyExtractor({
    this.targetWidth = 160,
    this.targetHeight = 120,
    this.diffThreshold = 25,
  });

  static const List<int> _kernel = [
    1, 4, 6, 4, 1,
    4, 16, 24, 16, 4,
    6, 24, 36, 24, 6,
    4, 16, 24, 16, 4,
    1, 4, 6, 4, 1,
  ];
  static const int _kernelSum = 256;

  Uint8List? _prevBlurred;

  /// Return raw motion energy score (jumlah piksel berubah signifikan).
  /// Frame pertama SELALU return 0 -- sama seperti Python (scores.append(0)
  /// waktu prev_gray masih None), bukan null, biar konsisten sama caller.
  double processFrame(CameraImage image) {
    final downsampled = _downsample(image);
    final blurred = _gaussianBlur5x5(downsampled, targetWidth, targetHeight);

    double score = 0;
    final prev = _prevBlurred;
    if (prev != null) {
      int active = 0;
      for (int i = 0; i < blurred.length; i++) {
        if ((blurred[i] - prev[i]).abs() > diffThreshold) active++;
      }
      score = active.toDouble();
    }

    _prevBlurred = blurred;
    return score;
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

  void reset() {
    _prevBlurred = null;
  }
}
