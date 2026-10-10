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
      'ratioOk': TextEditingController(text: c.ratioOk.toString()),
      'ratioHard': TextEditingController(text: c.ratioHard.toString()),
      'strikesToStop': TextEditingController(text: c.strikesToStop.toString()),
      'snrMin': TextEditingController(text: c.snrMin.toString()),
      'baselineSkipS': TextEditingController(text: c.baselineSkipS.toString()),
      'baselineMaxS': TextEditingController(text: c.baselineMaxS.toString()),
      'baselineMinS': TextEditingController(text: c.baselineMinS.toString()),
      'emaTauSeconds': TextEditingController(text: c.emaTauSeconds.toString()),
      'roundWinStartS': TextEditingController(
        text: c.roundWinStartS.toString(),
      ),
      'roundWinEndS': TextEditingController(text: c.roundWinEndS.toString()),
      'medianWindow': TextEditingController(text: c.medianWindow.toString()),
      'processingFps': TextEditingController(text: c.processingFps.toString()),
      'btDeviceName': TextEditingController(text: c.btDeviceName),
      'keepAliveSeconds': TextEditingController(
        text: c.keepAliveSeconds.toString(),
      ),
      'screenTimeoutSeconds': TextEditingController(
        text: c.screenTimeoutSeconds.toString(),
      ),
      'liveCamIntervalSeconds': TextEditingController(
        text: c.liveCamIntervalSeconds.toString(),
      ),
      // TAIL (rev)
      'tailRecordSeconds': TextEditingController(
        text: c.tailRecordSeconds.toString(),
      ),
      'devLogMaxLines': TextEditingController(
        text: c.devLogMaxLines.toString(),
      ),
      'supabaseTelemetryTable': TextEditingController(
        text: c.supabaseTelemetryTable,
      ),
      'supabaseFeedSessionTable': TextEditingController(
        text: c.supabaseFeedSessionTable,
      ),
      'supabaseConfigTable': TextEditingController(text: c.supabaseConfigTable),
      'supabaseRowId': TextEditingController(text: c.supabaseRowId),
    };
  }

  Future<void> _save() async {
    final c = widget.config;
    c.ratioOk = double.tryParse(_c['ratioOk']!.text) ?? c.ratioOk;
    c.ratioHard = double.tryParse(_c['ratioHard']!.text) ?? c.ratioHard;
    c.strikesToStop =
        int.tryParse(_c['strikesToStop']!.text) ?? c.strikesToStop;
    c.snrMin = double.tryParse(_c['snrMin']!.text) ?? c.snrMin;
    c.baselineSkipS =
        double.tryParse(_c['baselineSkipS']!.text) ?? c.baselineSkipS;
    c.baselineMaxS =
        double.tryParse(_c['baselineMaxS']!.text) ?? c.baselineMaxS;
    c.baselineMinS =
        double.tryParse(_c['baselineMinS']!.text) ?? c.baselineMinS;
    c.emaTauSeconds =
        double.tryParse(_c['emaTauSeconds']!.text) ?? c.emaTauSeconds;
    c.roundWinStartS =
        double.tryParse(_c['roundWinStartS']!.text) ?? c.roundWinStartS;
    c.roundWinEndS =
        double.tryParse(_c['roundWinEndS']!.text) ?? c.roundWinEndS;
    c.medianWindow = int.tryParse(_c['medianWindow']!.text) ?? c.medianWindow;
    c.processingFps =
        double.tryParse(_c['processingFps']!.text) ?? c.processingFps;
    c.btDeviceName = _c['btDeviceName']!.text;
    c.keepAliveSeconds =
        double.tryParse(_c['keepAliveSeconds']!.text) ?? c.keepAliveSeconds;
    c.screenTimeoutSeconds =
        double.tryParse(_c['screenTimeoutSeconds']!.text) ??
        c.screenTimeoutSeconds;
    c.liveCamIntervalSeconds = FeederConfig.clampLiveCamInterval(
      double.tryParse(_c['liveCamIntervalSeconds']!.text) ??
          c.liveCamIntervalSeconds,
    );
    // TAIL (rev)
    c.tailRecordSeconds = FeederConfig.clampTail(
      double.tryParse(_c['tailRecordSeconds']!.text) ?? c.tailRecordSeconds,
    );
    c.devLogMaxLines =
        int.tryParse(_c['devLogMaxLines']!.text) ?? c.devLogMaxLines;
    c.supabaseTelemetryTable = _c['supabaseTelemetryTable']!.text;
    c.supabaseFeedSessionTable = _c['supabaseFeedSessionTable']!.text;
    c.supabaseConfigTable = _c['supabaseConfigTable']!.text;
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
          _field(
            'ratioOk',
            'ratio_ok (respon / acuan)',
            helper:
                'Di atas nilai ini = lele masih aktif, LANJUT. Default 0.65. '
                'Berbasis rasio, jadi tidak tergantung skala kamera.',
          ),
          _field(
            'ratioHard',
            'ratio_hard (STOP langsung)',
            helper: 'Di bawah nilai ini = jelas kenyang, STOP seketika.',
          ),
          _field(
            'strikesToStop',
            'strikes_to_stop (putaran lemah berturut-turut)',
            helper:
                'Rasio antara ratio_hard dan ratio_ok dihitung 1 strike. '
                'Setelah N strike berturut-turut -> STOP.',
          ),
          _field(
            'snrMin',
            'snr_min (gerbang sinyal putaran acuan)',
            helper:
                'Rata-rata jendela putaran acuan harus >= snr_min x baseline, '
                'kalau tidak AI diam dan ESP memakai fmax/feval.',
          ),
          _field('baselineSkipS', 'baseline: abaikan N detik pertama'),
          _field(
            'baselineMaxS',
            'baseline: maks detik terakhir sebelum pulsa 1',
          ),
          _field(
            'baselineMinS',
            'baseline: minimal detik data agar valid',
            helper:
                'Butuh waktu persiapan (t_prep) lebih lama dari ini, kalau '
                'tidak baseline tidak valid dan AI tidak memutuskan.',
          ),
          _field(
            'emaTauSeconds',
            'EMA tau (detik)',
            helper:
                'Konstanta waktu EMA. Alpha per frame dihitung otomatis dari '
                'timestamp: a = 1 - exp(-dt/tau).',
          ),
          _field(
            'roundWinStartS',
            'Jendela respon: mulai (detik setelah feeder berhenti)',
          ),
          _field(
            'roundWinEndS',
            'Jendela respon: akhir (detik)',
            helper:
                'Keputusan baru ada pada detik ini. feval di ESP harus lebih '
                'besar (+ margin).',
          ),
          _field('medianWindow', 'median window (spike-rejection)'),
          _field(
            'processingFps',
            'processing fps (virtual)',
            helper:
                'Saat kalibrasi = fps DASAR perekaman (stride 1/2/4/8 -> fps '
                'efektif F, F/2, F/4, F/8). Jangan ubah di tengah sesi rekam.',
          ),
          const Divider(height: 32),
          _field(
            'btDeviceName',
            'Nama device Bluetooth ESP32',
            helper:
                'Harus sama persis dengan SerialBT.begin("...") di firmware.',
          ),
          _field(
            'keepAliveSeconds',
            'Interval keep-alive CMD:LANJUT (detik)',
            helper: 'Dikirim berkala ke ESP selama sesi makan berjalan.',
          ),
          _field(
            'screenTimeoutSeconds',
            'Auto-dark layar (detik)',
            helper:
                'Default 15s. Isi 0 untuk mematikan auto-dark. '
                'Timer ini otomatis NONAKTIF saat Mode Dev.',
          ),
          _field(
            'liveCamIntervalSeconds',
            'Interval live-cam (detik/frame)',
            helper:
                'Dibatasi 1-30 detik otomatis. Timer ini HANYA jalan saat '
                'ada yang buka panel kamera live di webapp -- kalau tidak '
                'ada viewer, tidak ada frame yang dikirim sama sekali.',
          ),
          _field(
            'tailRecordSeconds',
            'Tail recording setelah sesi berakhir (detik)',
            helper:
                '0 = mati; efektif minimal roundWinEndS+10; dibatasi 45-120.',
          ),
          _field(
            'devLogMaxLines',
            'Maks baris log traffic (mode Dev)',
            helper:
                'Semakin kecil semakin hemat RAM. Default 150 -- cukup '
                'untuk layar penuh + filter di Dev Panel.',
          ),
          const Divider(height: 32),
          _field(
            'supabaseTelemetryTable',
            'Tabel telemetry (data ESP + baterai/suhu/cpu J2)',
          ),
          _field('supabaseFeedSessionTable', 'Tabel sesi feeding (AI lokal)'),
          _field(
            'supabaseConfigTable',
            'Tabel config/override/kalibrasi (dari webapp)',
          ),
          _field('supabaseRowId', 'Row id (id perangkat)'),
          const SizedBox(height: 24),
          ElevatedButton(onPressed: _save, child: const Text('Simpan')),
        ],
      ),
    );
  }
}
