import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'config.dart';
import 'feeding_screen.dart';

const supabaseUrl = 'https://YOUR_PROJECT.supabase.co'; // GANTI
const supabaseAnonKey = 'YOUR_ANON_KEY'; // GANTI

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
      title: 'Fish Feeder',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: FeedingScreen(config: config),
    );
  }
}
