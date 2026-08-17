import 'package:supabase_flutter/supabase_flutter.dart';

/// Update state di table Supabase. Skema kolom yang diasumsikan di sini:
/// state (text), last_stop_reason (text, nullable), updated_at (timestamptz).
/// SESUAIKAN nama kolom kalau skema table kalian beda.
class FeederSupabaseService {
  final SupabaseClient _client = Supabase.instance.client;
  final String table;
  final String rowId;

  FeederSupabaseService({required this.table, required this.rowId});

  Future<void> updateStatus({
    required String state, // 'idle' | 'feeding' | 'stopped'
    String? stopReason,
  }) async {
    await _client.from(table).update({
      'state': state,
      'last_stop_reason': stopReason,
      'updated_at': DateTime.now().toIso8601String(),
    }).eq('id', rowId);
  }
}
