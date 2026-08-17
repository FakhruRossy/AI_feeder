import 'package:flutter/material.dart';
import 'config.dart';

class SettingsScreen extends StatefulWidget {
  final FeederConfig config;
  const SettingsScreen({super.key, required this.config});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final Map<String, TextEditingController> _c;

  @override
  void initState() {
    super.initState();
    final c = widget.config;
    _c = {
      'decayRatio': TextEditingController(text: c.decayRatio.toString()),
      'minPeak': TextEditingController(text: c.minPeak.toString()),
      'debounceSeconds': TextEditingController(text: c.debounceSeconds.toString()),
      'startupTimeoutSeconds': TextEditingController(text: c.startupTimeoutSeconds.toString()),
      'emaAlpha': TextEditingController(text: c.emaAlpha.toString()),
      'medianWindow': TextEditingController(text: c.medianWindow.toString()),
      'processingFps': TextEditingController(text: c.processingFps.toString()),
      'relayBaseUrl': TextEditingController(text: c.relayBaseUrl),
      'relayOnPath': TextEditingController(text: c.relayOnPath),
      'relayOffPath': TextEditingController(text: c.relayOffPath),
      'supabaseTable': TextEditingController(text: c.supabaseTable),
      'supabaseRowId': TextEditingController(text: c.supabaseRowId),
    };
  }

  Future<void> _save() async {
    final c = widget.config;
    c.decayRatio = double.tryParse(_c['decayRatio']!.text) ?? c.decayRatio;
    c.minPeak = double.tryParse(_c['minPeak']!.text) ?? c.minPeak;
    c.debounceSeconds = double.tryParse(_c['debounceSeconds']!.text) ?? c.debounceSeconds;
    c.startupTimeoutSeconds =
        double.tryParse(_c['startupTimeoutSeconds']!.text) ?? c.startupTimeoutSeconds;
    c.emaAlpha = double.tryParse(_c['emaAlpha']!.text) ?? c.emaAlpha;
    c.medianWindow = int.tryParse(_c['medianWindow']!.text) ?? c.medianWindow;
    c.processingFps = double.tryParse(_c['processingFps']!.text) ?? c.processingFps;
    c.relayBaseUrl = _c['relayBaseUrl']!.text;
    c.relayOnPath = _c['relayOnPath']!.text;
    c.relayOffPath = _c['relayOffPath']!.text;
    c.supabaseTable = _c['supabaseTable']!.text;
    c.supabaseRowId = _c['supabaseRowId']!.text;
    await c.save();
    if (mounted) Navigator.pop(context);
  }

  Widget _field(String key, String label, {String? helper}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: TextField(
          controller: _c[key],
          decoration: InputDecoration(
            labelText: label,
            helperText: helper,
            helperMaxLines: 3,
            border: const OutlineInputBorder(),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Kalibrasi & Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _field('decayRatio', 'decay_ratio'),
          _field('minPeak', 'min_peak'),
          _field('debounceSeconds', 'debounce (detik)'),
          _field('startupTimeoutSeconds', 'startup_timeout (detik)'),
          _field('emaAlpha', 'EMA alpha'),
          _field('medianWindow', 'median window (spike-rejection)'),
          _field(
            'processingFps',
            'processing fps (virtual)',
            helper: 'Turunin (misal ke 2-3) kalau device lag/panas -- ini beban CPU utama.',
          ),
          const Divider(height: 32),
          _field('relayBaseUrl', 'Relay base URL'),
          _field('relayOnPath', 'Relay ON path'),
          _field('relayOffPath', 'Relay OFF path'),
          const Divider(height: 32),
          _field('supabaseTable', 'Supabase table'),
          _field('supabaseRowId', 'Supabase row id'),
          const SizedBox(height: 24),
          ElevatedButton(onPressed: _save, child: const Text('Simpan')),
        ],
      ),
    );
  }
}
