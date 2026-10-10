import 'package:flutter/foundation.dart';

/// Buffer log ringkas untuk mode Dev: network traffic Bluetooth (IN/OUT)
/// dan Supabase, plus error apa pun yang berguna buat debug.
///
/// - Dibatasi jumlah barisnya (default 10, lihat FeederConfig.devLogMaxLines)
///   supaya gak makan RAM -- entri terlama otomatis dibuang begitu penuh.
/// - Di-gate lewat `enabled`: saat mode Normal, `add()` jadi no-op (gak
///   nyimpen apa pun) biar lebih ringan. Isi buffer TIDAK dihapus saat
///   pindah ke Normal -- cuma berhenti nambah -- supaya kalau user balik
///   ke Dev, histori terakhir masih kelihatan.
/// - Pakai ChangeNotifier + AnimatedBuilder di UI supaya update log gak
///   perlu setState() seluruh layar.
enum LogDirection { inbound, outbound, info, error }

class LogEntry {
  final DateTime time;
  final LogDirection direction;
  final String channel; // 'BT', 'SUPA', atau 'HP'
  final String message;

  LogEntry(this.direction, this.channel, this.message) : time = DateTime.now();

  String get directionLabel {
    switch (direction) {
      case LogDirection.inbound:
        return 'IN';
      case LogDirection.outbound:
        return 'OUT';
      case LogDirection.error:
        return 'ERR';
      case LogDirection.info:
        return 'INFO';
    }
  }
}

class DevLogBuffer extends ChangeNotifier {
  int maxLines;
  bool enabled;
  final List<LogEntry> _entries = [];

  DevLogBuffer({this.maxLines = 10, this.enabled = false});

  List<LogEntry> get entries => List.unmodifiable(_entries);

  void add(LogDirection direction, String channel, String message) {
    if (!enabled) return;
    _entries.insert(0, LogEntry(direction, channel, message));
    while (_entries.length > maxLines) {
      _entries.removeLast();
    }
    notifyListeners();
  }

  void setEnabled(bool value) {
    enabled = value;
    notifyListeners();
  }

  void clear() {
    _entries.clear();
    notifyListeners();
  }
}
