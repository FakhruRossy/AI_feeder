// 🟢 REVISI (P1 / Room 2): tes CameraManager dengan FakeBackend (tanpa plugin
// kamera). Pakai waktu nyata dengan durasi kecil (tidak ada dependency baru).
//
// Jalankan: flutter test test/camera_manager_test.dart

import 'dart:async';
import 'dart:ui' show Size;

import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:catfish/camera_manager.dart';

// ---------------------------------------------------------------------------
// FAKE
// ---------------------------------------------------------------------------

class FakeBackend implements CameraBackend {
  Duration openDelay = const Duration(milliseconds: 30);
  Duration disposeDelay = const Duration(milliseconds: 10);
  int failNext = 0;
  bool failTorchOnNew = false;

  int openCount = 0;
  int live = 0;
  int maxLive = 0;
  final List<DateTime> openTimes = [];
  final List<DateTime> closeTimes = [];
  final List<FakeSession> sessions = [];

  @override
  Future<CameraSession> open() async {
    openCount++;
    openTimes.add(DateTime.now());
    await Future<void>.delayed(openDelay);
    if (failNext > 0) {
      failNext--;
      throw StateError('boom');
    }
    live++;
    if (live > maxLive) maxLive = live;
    final s = FakeSession(this)..failTorch = failTorchOnNew;
    sessions.add(s);
    return s;
  }
}

class FakeSession implements CameraSession {
  FakeSession(this.backend);
  final FakeBackend backend;

  bool streaming = false;
  bool disposed = false;
  bool failTorch = false;
  final List<String> ops = [];
  final List<DateTime> opTimes = [];
  void Function(String)? errListener;

  void _op(String o) {
    ops.add(o);
    opTimes.add(DateTime.now());
  }

  void emitError(String d) => errListener?.call(d);

  @override
  bool get isInitialized => !disposed;
  @override
  bool get isStreaming => streaming;
  @override
  bool get hasError => false;
  @override
  Size? get previewSize => null;
  @override
  Object? get nativeController => null;

  @override
  Future<void> startStream(void Function(CameraImage image) onImage) async {
    _op('startStream');
    streaming = true;
  }

  @override
  Future<void> stopStream() async {
    _op('stopStream');
    streaming = false;
  }

  @override
  Future<void> setTorch(bool on) async {
    _op('torch:$on');
    if (failTorch && on) throw StateError('torch gagal');
  }

  @override
  Future<void> setFocusLocked(bool locked) async => _op('focus:$locked');

  @override
  Future<void> setExposureLocked(bool locked) async => _op('exposure:$locked');

  @override
  void setErrorListener(void Function(String description)? listener) {
    errListener = listener;
  }

  @override
  Future<void> dispose() async {
    await Future<void>.delayed(backend.disposeDelay);
    disposed = true;
    streaming = false;
    backend.live--;
    backend.closeTimes.add(DateTime.now());
    _op('dispose');
  }
}

class Harness {
  Harness({
    Duration reopenGap = const Duration(milliseconds: 100),
    Duration initTimeout = const Duration(milliseconds: 500),
    Duration initRetryGap = const Duration(milliseconds: 150),
    Duration lockSettle = const Duration(milliseconds: 120),
    Duration watchdogPeriod = const Duration(milliseconds: 40),
    Duration watchdogQuiet = const Duration(milliseconds: 40),
    Duration stallAfter = const Duration(milliseconds: 120),
    Duration blackFor = const Duration(milliseconds: 120),
  }) {
    m = CameraManager(
      backend: b,
      onImage: (_) {},
      onLog: (d, c, msg) => logs.add(msg),
      onEvent: (n, d) => events.add({'e': n, 'd': d}),
      onTorchChanged: torchChanges.add,
      onIssue: (k, d) => issues.add(k),
      onRecovered: () => recovered++,
      observeLifecycle: false,
      reopenGap: reopenGap,
      initTimeout: initTimeout,
      initRetryGap: initRetryGap,
      lockSettle: lockSettle,
      watchdogPeriod: watchdogPeriod,
      watchdogQuiet: watchdogQuiet,
      stallAfter: stallAfter,
      blackFor: blackFor,
      uiDetachDelay: Duration.zero,
    );
  }

  final b = FakeBackend();
  late final CameraManager m;
  final logs = <String>[];
  final events = <Map<String, Object?>>[];
  final torchChanges = <bool>[];
  final issues = <String>[];
  int recovered = 0;

  int eventCount(String name, {bool? ok}) => events.where((e) {
    if (e['e'] != name) return false;
    if (ok == null) return true;
    final d = e['d'] as Map?;
    return d?['ok'] == ok;
  }).length;
}

void main() {
  late Harness h;

  setUp(() => h = Harness());

  tearDown(() async {
    await h.m.disposeAll();
    // Invarian global: tidak pernah 2 controller sekaligus, dan tidak ada yatim.
    expect(h.b.maxLive, lessThanOrEqualTo(1));
    expect(h.b.live, 0);
  });

  test('apply(on) lalu apply(off) cepat: digabung, tidak ada kamera yatim', () async {
    final f1 = h.m.apply(true, false, false);
    final f2 = h.m.apply(false, false, false);
    await Future.wait([f1, f2]);
    expect(h.b.openCount, 0); // kebutuhan terbaru = off
    expect(h.m.isCameraActive, isFalse);

    // Varian: off datang saat open sedang berjalan.
    final g1 = h.m.apply(true, false, false);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final g2 = h.m.apply(false, false, false);
    await Future.wait([g1, g2]);
    expect(h.b.openCount, 1);
    expect(h.m.isCameraActive, isFalse);
    expect(
      h.eventCount('cam_open', ok: true),
      h.eventCount('cam_close'),
      reason: 'open/close harus seimbang',
    );
  });

  test('apply ganda bersamaan: hanya kebutuhan terbaru yang dieksekusi', () async {
    await Future.wait([
      h.m.apply(true, false, false),
      h.m.apply(true, true, false),
      h.m.apply(true, true, true),
      h.m.apply(true, false, true),
    ]);
    expect(h.b.openCount, 1);
    final s = h.b.sessions.single;
    expect(s.ops.contains('startStream'), isFalse);
    expect(h.m.torchActual, isTrue);
    expect(h.m.isStreaming, isFalse);
    expect(h.torchChanges, [true]);

    // Idempotent: panggilan sama lagi tidak menambah operasi.
    final before = s.ops.length;
    await h.m.apply(true, false, true);
    expect(s.ops.length, before);
  });

  test('init gagal: issue init_failed, torch mati, percobaan berikut berjarak', () async {
    h.b.failNext = 1;
    await h.m.apply(true, false, true);
    expect(h.issues, ['init_failed']);
    expect(h.m.isCameraActive, isFalse);
    expect(h.m.torchActual, isFalse);
    expect(h.m.restartRecommended, isTrue);

    await h.m.apply(true, false, true);
    expect(h.m.isCameraActive, isTrue);
    expect(h.m.torchActual, isTrue);
    final gap = h.b.openTimes[1].difference(h.b.openTimes[0]);
    // open #1 butuh 30 ms lalu gagal; open #2 harus >= initRetryGap sesudahnya.
    expect(gap.inMilliseconds, greaterThanOrEqualTo(150));
    expect(h.eventCount('cam_open', ok: false), 1);
  });

  test('init timeout: sesi terlambat di-dispose, tidak ada 2 controller', () async {
    h.b.openDelay = const Duration(milliseconds: 700); // > initTimeout 500
    await h.m.apply(true, false, false);
    expect(h.issues, ['init_failed']);
    expect(h.m.isCameraActive, isFalse);

    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(h.b.live, 0, reason: 'sesi terlambat harus di-dispose');

    h.b.openDelay = Duration.zero;
    await h.m.apply(true, false, false);
    expect(h.m.isCameraActive, isTrue);
    expect(h.b.maxLive, 1);
  });

  test('torch gagal: kamera tetap jalan, torchActual false, bisa dicoba lagi', () async {
    h.b.failTorchOnNew = true;
    await h.m.apply(true, false, true);
    expect(h.m.isCameraActive, isTrue);
    expect(h.m.torchActual, isFalse);
    expect(h.torchChanges, isEmpty);
    expect(
      h.events.any((e) => e['e'] == 'torch' && (e['d'] as Map)['ok'] == false),
      isTrue,
    );

    h.b.sessions.single.failTorch = false;
    await h.m.apply(true, false, true);
    expect(h.m.torchActual, isTrue);
    expect(h.torchChanges, [true]);

    await h.m.apply(true, false, false);
    expect(h.m.torchActual, isFalse);
    expect(h.torchChanges, [true, false]);
  });

  test('dispose lalu buka ulang: ada jeda reopenGap dan hanya 1 controller', () async {
    await h.m.apply(true, false, false);
    await h.m.apply(false, false, false);
    expect(h.m.isCameraActive, isFalse);
    expect(h.b.live, 0);
    await h.m.apply(true, false, false);
    expect(h.m.isCameraActive, isTrue);
    expect(h.b.sessions.length, 2);
    final gap = h.b.openTimes[1].difference(h.b.closeTimes[0]);
    expect(gap.inMilliseconds, greaterThanOrEqualTo(95));
    expect(h.b.maxLive, 1);
  });

  test('disposeAll: kamera mati total dan apply sesudahnya tidak membuka lagi', () async {
    await h.m.apply(true, true, true);
    expect(h.m.isStreaming, isTrue);
    await h.m.disposeAll();
    expect(h.b.live, 0);
    expect(h.m.torchActual, isFalse);
    final opens = h.b.openCount;
    await h.m.apply(true, false, false);
    expect(h.b.openCount, opens);
  });

  test('kunci exposure: torch berubah saat terkunci => unlock, tunggu, lock ulang', () async {
    await h.m.apply(true, false, false);
    await h.m.lockAuto();
    final s = h.b.sessions.single;
    expect(s.ops, containsAllInOrder(['focus:true', 'exposure:true']));
    final mark = s.ops.length;

    await h.m.apply(true, false, true);
    final tail = s.ops.sublist(mark);
    expect(tail, [
      'focus:false',
      'exposure:false',
      'torch:true',
      'focus:true',
      'exposure:true',
    ]);
    final tTorch = s.opTimes[mark + 2];
    final tLock = s.opTimes[mark + 3];
    expect(tLock.difference(tTorch).inMilliseconds, greaterThanOrEqualTo(110));
  });

  test('watchdog: stall lalu black dilaporkan sekali, tanpa re-init', () async {
    await h.m.apply(true, true, false);
    expect(h.m.isStreaming, isTrue);

    // Tidak ada frame -> stall.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(h.issues, ['stall']);

    // Frame hitam mengalir -> pulih dari stall, lalu black.
    for (var i = 0; i < 16; i++) {
      h.m.debugIngestFrame(luma: 1, std: 0.5);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(h.issues, ['stall', 'black']);
    expect(h.recovered, 1);

    // Frame normal -> pulih dari black.
    h.m.debugIngestFrame(luma: 90, std: 25);
    expect(h.recovered, 2);
    expect(h.eventCount('cam_stall'), 1);
    expect(h.eventCount('cam_black'), 1);
    expect(h.eventCount('cam_ok'), 2);

    expect(h.b.openCount, 1, reason: 'watchdog tidak boleh re-init');
    expect(h.m.restartRecommended, isTrue);
  });

  test('watchdog tidak aktif saat stream tidak diharapkan', () async {
    await h.m.apply(true, false, false);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(h.issues, isEmpty);
    expect(h.m.restartRecommended, isFalse);
  });

  test('error controller: sesi dibuang dan dibuka ulang lewat gap, tidak pernah 2', () async {
    await h.m.apply(true, false, false);
    h.b.sessions.single.emitError('camera disconnected');
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(h.issues, ['init_failed']);
    expect(h.b.openCount, 2);
    expect(h.m.isCameraActive, isTrue);
    expect(h.b.maxLive, 1);
  });

  test('selfTest: frame mengalir => ok, kamera ditutup sesudahnya', () async {
    final fut = h.m.selfTest(const Duration(milliseconds: 250));
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      h.m.debugIngestFrame(luma: 80, std: 20);
    }
    final r = await fut;
    expect(r.ok, isTrue, reason: '$r');
    expect(r.frames, greaterThanOrEqualTo(3));
    expect(h.m.isCameraActive, isFalse);
    expect(h.b.live, 0);
    expect(h.issues, isEmpty, reason: 'self-test tidak melapor sebagai masalah sesi');
  });

  test('selfTest: black dan no_frames gagal; busy bila kamera dipakai', () async {
    final f1 = h.m.selfTest(const Duration(milliseconds: 200));
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      h.m.debugIngestFrame(luma: 1, std: 0.3);
    }
    final r1 = await f1;
    expect(r1.ok, isFalse);
    expect(r1.reason, 'black');

    final r2 = await h.m.selfTest(const Duration(milliseconds: 100));
    expect(r2.ok, isFalse);
    expect(r2.reason, 'no_frames');

    await h.m.apply(true, false, false);
    final r3 = await h.m.selfTest(const Duration(milliseconds: 50));
    expect(r3.ok, isFalse);
    expect(r3.reason, 'busy');
  });
}
