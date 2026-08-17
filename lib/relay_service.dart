import 'package:http/http.dart' as http;

/// Kontrol relay via HTTP. Asumsi default: endpoint GET simple, gaya
/// Tasmota/Shelly (GET /relay/on, GET /relay/off). SESUAIKAN
/// relayOnPath/relayOffPath (dan ganti ke http.post kalau relay kalian
/// butuh POST/auth token) dengan API firmware relay kalian yang sebenarnya.
class RelayService {
  final String baseUrl;
  final String onPath;
  final String offPath;
  final Duration timeout;

  RelayService({
    required this.baseUrl,
    required this.onPath,
    required this.offPath,
    this.timeout = const Duration(seconds: 5),
  });

  Future<bool> turnOn() => _call(onPath);
  Future<bool> turnOff() => _call(offPath);

  Future<bool> _call(String path) async {
    try {
      final res = await http.get(Uri.parse('$baseUrl$path')).timeout(timeout);
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    }
  }
}
