import 'dart:async';
import 'package:http/http.dart' as http;

class RelayService {
  final String baseUrl;
  final String onPath;
  final String offPath;

  RelayService({
    required this.baseUrl,
    required this.onPath,
    required this.offPath,
  });

  // Method ini berjalan di latar belakang (fire-and-forget).
  // Tidak ada "Future" yang dikembalikan, jadi tidak akan memblokir kode utama.
  // Tambahkan parameter onFailure
  void turnOnPersistent({Function? onFailure}) =>
      _sendWithRetry(onPath, onFailure);
  void turnOffPersistent({Function? onFailure}) =>
      _sendWithRetry(offPath, onFailure);

  Future<void> _sendWithRetry(String path, Function? onFailure) async {
    int maxAttempts = 30;

    for (int i = 1; i <= maxAttempts; i++) {
      try {
        final res = await http
            .get(Uri.parse('$baseUrl$path'))
            .timeout(const Duration(seconds: 2));
        if (res.statusCode >= 200 && res.statusCode < 300) {
          print('SUKSES! Sinyal $path terkirim di percobaan ke-$i');
          return;
        }
      } catch (e) {
        print('Gagal kirim $path (Percobaan $i/$maxAttempts). Mencoba lagi...');
      }
      await Future.delayed(const Duration(seconds: 1));
    }

    print('GAGAL TOTAL: Sinyal $path menyerah setelah 30 percobaan.');

    // Panggil laporan gagal ke layar utama (non-blocking)
    if (onFailure != null) {
      onFailure();
    }
  }
}
