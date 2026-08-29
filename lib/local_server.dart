import 'dart:io';
import 'dart:async';

class LocalServer {
  HttpServer? _server;
  final Function onMulai;
  final Function onBerhenti;

  LocalServer({required this.onMulai, required this.onBerhenti});

  Future<void> start() async {
    // Membuka port 8080 untuk menerima tamu (ESP)
    _server = await HttpServer.bind(InternetAddress.anyIPv4, 8080);
    print('Server Listener J2 Aktif di Port 8080');

    _server!.listen((HttpRequest request) {
      if (request.uri.path == '/mulai') {
        // Balas 200 OK ke ESP
        request.response
          ..statusCode = HttpStatus.ok
          ..write('OK Mulai');
        request.response.close();
        onMulai(); // Jalankan kamera
      } else if (request.uri.path == '/berhenti') {
        // Balas 200 OK ke ESP
        request.response
          ..statusCode = HttpStatus.ok
          ..write('OK Berhenti');
        request.response.close();
        onBerhenti(); // Hentikan kamera
      } else {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write('Not Found');
        request.response.close();
      }
    });
  }

  void stop() {
    _server?.close();
  }
}
