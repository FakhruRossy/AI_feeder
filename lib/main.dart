import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'config.dart';
import 'feeding_screen.dart';

/// PENTING soal URL:
/// Endpoint REST-nya memang `https://<ref>.supabase.co/rest/v1/`, TAPI
/// `Supabase.initialize()` minta BASE URL (tanpa `/rest/v1/`) karena SDK
/// yang menambahkan sendiri path rest/realtime/storage. Kalau `/rest/v1/`
/// ikut ditulis di sini, realtime (websocket config dari webapp) akan gagal
/// konek. Jadi: base URL di app, `/rest/v1/` cuma buat tes manual curl.
///
/// Key & URL bisa dioverride saat build tanpa ubah kode:
///   flutter build apk --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...
const supabaseUrl = String.fromEnvironment(
  'SUPABASE_URL',
  defaultValue: 'https://fopgswiwteoehsnntsxb.supabase.co',
);

const supabaseAnonKey = String.fromEnvironment(
  'SUPABASE_ANON_KEY',
  defaultValue:
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImZvcGdzd2l3dGVvZWhzbm50c3hiIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODkxMDI0MDcsImV4cCI6MjEwNDY3ODQwN30.xJ2q3qfNrg4Nt5-3YVtPoFf5aLFfLM6Pb-w5iOuTp98',
);

/// Dipakai hanya kalau ada kebutuhan hit REST manual (debug/curl).
const supabaseRestUrl = '$supabaseUrl/rest/v1/';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
  final config = await FeederConfig.load();
  runApp(FishFeederApp(config: config));
}

class FishFeederApp extends StatelessWidget {
  final FeederConfig config;
  const FishFeederApp({super.key, required this.config});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Catfish AI',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: FeedingScreen(config: config),
    );
  }
}
