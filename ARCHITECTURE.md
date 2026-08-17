# Architecture

## Ringkasan

Satu Flutter app, semua logic native di Dart (bukan client buat backend
Python terpisah). Kamera HP -> hitung motion energy -> state machine
adaptif nentuin kapan lele "selesai makan" -> matiin relay + update
Supabase. Alur ini port dari pipeline Python yang ada di
`reference_python/` (lihat "Porting notes" di bawah).

Kenapa native Dart, bukan kirim frame ke backend Python: biar deploy-nya
cuma 1 device (HP) tanpa perlu server/Raspberry Pi terpisah yang harus
selalu nyala & terhubung ke jaringan yang sama. Trade-off-nya: perilaku
deteksi gak 100% identik sama Python (lihat porting notes), dan device-nya
harus cukup kuat buat proses gambar real-time (lihat catatan performa di
README.md).

## Layer & tanggung jawab

```
main.dart (entry point)
    |
    v
feeding_screen.dart  <----->  settings_screen.dart
    |                              |
    |-- motion_energy.dart         |
    |-- feeder_trigger.dart        |
    |-- relay_service.dart         |
    |-- supabase_service.dart      |
    |                              |
    v                              v
              config.dart
   (parameter tunable, persist via SharedPreferences)
```

| File | Tanggung jawab | Tau soal kamera/HTTP? |
|---|---|---|
| `main.dart` | Init Supabase client, load `FeederConfig`, jalanin `FeedingScreen`. | Tidak |
| `feeding_screen.dart` | **Satu-satunya file yang pegang `CameraController`.** Throttle frame, panggil pipeline, panggil relay+Supabase pas STOP. | Ya (semuanya) |
| `settings_screen.dart` | Form edit `FeederConfig`, simpan ke `SharedPreferences`. | Tidak |
| `motion_energy.dart` | `MotionEnergyExtractor` -- 1 frame kamera masuk, 1 angka raw score keluar. Gak tau apa-apa soal trigger/relay/Supabase. | Tidak (murni image processing) |
| `feeder_trigger.dart` | `FeederTriggerAdaptive` -- state machine murni: raw score masuk, "STOP"/null keluar. Gak tau apa-apa soal kamera/HTTP. | Tidak (murni logic, gampang di-unit-test) |
| `relay_service.dart` | 2 method: `turnOn()`/`turnOff()`, HTTP GET ke relay. | Tidak (gak tau soal kamera/trigger) |
| `supabase_service.dart` | 1 method: `updateStatus()`, update row di Supabase. | Tidak |
| `config.dart` | Data class + persist/load `SharedPreferences`. Gak ada logic lain. | Tidak |

Prinsipnya: `feeding_screen.dart` itu satu-satunya "orchestrator" yang
tau semua bagian. File lain sengaja dibikin gak saling kenal satu sama
lain (`motion_energy.dart` gak import `feeder_trigger.dart`, dst) supaya
tiap bagian bisa diganti/ditest sendiri-sendiri tanpa nyenggol yang lain.

## Alur data end-to-end (1 sesi feeding)

1. User tap "Mulai Kasih Makan" di `feeding_screen.dart`.
2. `_trigger` (instance baru `FeederTriggerAdaptive`) dibikin, parameter
   (`decayRatio`, `minPeak`, dst) diambil dari `config`, dikonversi ke
   frame-count pakai `processingFps` (lihat catatan fps di bawah).
3. `RelayService.turnOn()` dipanggil, `SupabaseService.updateStatus(state:
   'feeding')` dipanggil.
4. `_controller.startImageStream(_onFrame)` mulai jalan.
5. Tiap `CameraImage` masuk: **throttle** dulu (skip kalau belum
   `processingFps` detik sejak frame terakhir diproses, atau kalau masih
   proses frame sebelumnya) -> `MotionEnergyExtractor.processFrame()`
   hitung raw score -> `_trigger.update(raw)` -> update `EMA`/`Peak` di
   layar.
6. Kalau `_trigger.update()` return `"STOP"`: `stopImageStream()`,
   `RelayService.turnOff()`, `SupabaseService.updateStatus(state: 'idle',
   stopReason: ...)`.

## Kenapa `processingFps`, bukan fps kamera asli

Pipeline Python-nya (`FeederTriggerAdaptive` di `feeder_trigger_robust.py`)
murni **frame-based**: `debounce_frames`, `startup_timeout_frames` dihitung
dari `get_video_fps()` yang baca fps TETAP dari file video. Kamera live di
HP gak punya fps tetap (jitter, tergantung lighting/device load), jadi kalau
port Dart-nya coba pakai raw camera fps, hitungan debounce/startup_timeout
jadi gak konsisten antar device/kondisi.

Solusinya: `feeding_screen.dart` **men-throttle** pemrosesan frame ke laju
tetap yang KITA tentukan sendiri (`config.processingFps`, default `4.0`),
lalu `debounceSeconds`/`startupTimeoutSeconds` di-convert ke frame count
pakai angka itu -- persis peran `get_video_fps()` di Python, bedanya di
sini kita yang nentuin nilainya, bukan dibaca dari file. Efeknya:
`FeederTriggerAdaptive` versi Dart bisa jadi port 1:1 murni frame-based
tanpa perlu diubah jadi time-based, dan perilakunya predictable.

## Porting notes (Python -> Dart)

| Python (`reference_python/`) | Dart (`lib/`) | Catatan |
|---|---|---|
| `compute_motion_energy()` di `motion_energy_pipeline.py` | `MotionEnergyExtractor.processFrame()` di `motion_energy.dart` | Resize pakai average-pooling manual (bukan `cv2.resize` bilinear atas frame BGR), grayscale langsung dari Y-plane kamera (bukan `cv2.cvtColor(BGR2GRAY)`). Gaussian blur pakai kernel integer 5x5 aproksimasi (bukan `cv2.GaussianBlur` sigma auto). **Hasilnya mendekati, TIDAK identik bit-per-bit.** |
| `apply_ema()` | Inline di `FeederTriggerAdaptive.update()` (baris `ema = alpha * filtered + (1 - alpha) * ema!`) | Formula identik. |
| Class `FeederTriggerAdaptive` di `feeder_trigger_robust.py` | Class `FeederTriggerAdaptive` di `feeder_trigger.dart` | **Port 1:1** -- median spike-reject kondisional (`_filterSample`), hysteresis dual-threshold (`decay_th`/`release_th`), state machine sama persis. Ini bagian yang paling penting match-nya, dan udah dicek struktur logic-nya sama. |
| `get_video_fps()` | Diganti `config.processingFps` (throttle manual) | Lihat penjelasan di atas. |
| `phase_calibration_fixed.py` (STEP 1/2/3) | Tidak di-port -- tetap dijalankan manual/offline di PC | Workflow ini yang dipakai buat NENTUIN nilai `decayRatio`/`minPeak` dari video kalibrasi. Hasilnya (angka) yang jadi default di `config.dart`, bukan kode-nya yang di-port. Kalau kalian rekam ulang video kalibrasi (mis. dari kamera HP yang sama, di-mount rigid), jalanin lagi script ini buat dapetin angka baru. |

## Known limitations

- **1 sesi feeding at a time**, gak ada antrian/multi-relay. Kalau butuh
  kontrol beberapa kolam sekaligus, perlu refactor `feeding_screen.dart`
  jadi bisa pegang multiple `CameraController`+`FeederTriggerAdaptive`
  instance, atau multi-device.
- **Gak ada history/log tersimpan** selain 1 row status "terkini" di
  Supabase. Kalau butuh riwayat tiap sesi (durasi, alasan stop, dst),
  perlu tambah table baru (mis. `feeding_sessions`) dan insert row baru
  tiap sesi, bukan cuma update row yang sama.
- **Gak ada retry logic** kalau HTTP call ke relay/Supabase gagal --
  cuma nampilin `SnackBar` peringatan sekali. Untuk produksi, pertimbangkan
  retry-with-backoff, terutama buat `RelayService.turnOff()` (safety-critical).
- **Image processing masih di main isolate**, belum dipindah ke Isolate
  terpisah. Cukup buat device low-end DENGAN `processingFps` rendah
  (2-4fps), tapi kalau butuh proses lebih cepat/device lebih lemah lagi,
  ini titik optimasi berikutnya.
- **Belum ada scheduling otomatis** -- feeding cuma mulai kalau user tap
  tombol manual. Kalau butuh jadwal otomatis (jam tertentu tiap hari),
  perlu tambah komponen scheduler terpisah (mis. `WorkManager`/`cron` di
  sisi lain, app ini trigger via deep link atau Supabase listen realtime).
