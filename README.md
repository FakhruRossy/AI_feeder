# Fish Feeder App

App Flutter buat kontrol pakan ikan otomatis: kamera HP mendeteksi kapan lele
selesai makan (motion energy dari gerakan air/lele), lalu matiin feeder lewat
relay HTTP dan update status ke Supabase.

Ini port native Dart dari pipeline Python yang ada di `reference_python/`.
Baca `ARCHITECTURE.md` buat paham alur & kenapa didesain begini. File ini
fokus ke "cara jalanin & cara ganti sesuatu".

## Quick start

```bash
git clone <https://github.com/M-SyaifudinZ/catfish_feeder/tree/main>
cd catfish_feeder
flutter pub get
```

> Kalau `android/` dan `ios/` folder **sudah ada** di repo (biasanya iya --
> itu tempat manifest permission kamera/internet yang udah di-setup),
> **jangan** jalanin `flutter create .` lagi, itu bisa nimpa/konflik sama
> config yang udah ada. Cukup `flutter pub get` aja.
>
> Kalau ternyata folder `android/`/`ios/` KETINGGALAN gak ke-commit (cek
> dulu di GitHub ada atau nggak), baru jalanin `flutter create .` buat
> generate ulang, terus tambahin lagi permission-nya (lihat bagian
> "Permission" di bawah) sebelum commit.

Lalu isi permission (lihat bagian di bawah), isi kredensial Supabase & relay
(lihat "Pindah ke Supabase production" & Settings screen di app), baru run.

## Permission (wajib, sekali di awal)

**android/app/src/main/AndroidManifest.xml**, di dalam `<manifest>`, sebelum `<application>`:

```xml
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.INTERNET" />
<uses-feature android:name="android.hardware.camera" android:required="true" />
```

**ios/Runner/Info.plist** (kalau suatu saat build ke iOS juga), di dalam `<dict>`:

```xml
<key>NSCameraUsageDescription</key>
<string>Dipakai buat mantau aktivitas makan lele</string>
```

## Jalanin di HP fisik (USB debugging)

1. **Aktifkan Developer options**: Settings > About phone > tap "Build number"
   7x sampai muncul "You are now a developer".
2. **Aktifkan USB debugging**: Settings > Developer options > toggle "USB
   debugging" ON. Kalau ada toggle "Install via USB" di deket situ,
   aktifin juga (beberapa device Samsung/OEM butuh ini).
3. **Sambung & authorize**: pakai kabel data (bukan charging-only), pilih
   mode "File transfer (MTP)" pas notifikasi USB muncul, lalu tap "Allow"
   di popup "Allow USB debugging?" di layar HP (centang "Always allow from
   this computer").
4. **Cek kedetect**: `adb devices` harus nunjukin device dengan status
   `device` (bukan `unauthorized`/kosong). Windows kadang butuh driver USB
   tambahan dulu (Samsung USB Driver / Google USB Driver via Android Studio
   SDK Manager). `flutter devices` juga harus nunjukin device yang sama.
5. **Run**: `flutter run` di root project. Kalau ada >1 device kedetect,
   tambahin `-d <device_id>`.
6. Selagi jalan: `r` = hot reload, `R` = hot restart (dipakai kalau ubah
   logic di `feeder_trigger.dart`/`motion_energy.dart`, hot reload biasa
   kadang gak cukup buat perubahan state class), `q` = keluar.

**Troubleshooting cepat**: status `unauthorized` -> cabut-colok kabel, tap
Allow lagi. Device sama sekali gak kedetect di Windows -> ganti kabel/port
(banyak kabel cuma charging-only, gak ada pin data). Error minSdkVersion pas
build -> cek versi Android di Settings > About phone, sesuaikan
`minSdkVersion` di `android/app/build.gradle`.

## Troubleshooting: Gradle gagal download dependency

Kalau muncul error kayak:

```
Could not GET 'https://repo.maven.apache.org/maven2/...'
```

Ini masalah jaringan, bukan project. Urutan coba:

1. Buka `https://repo.maven.apache.org` di browser -- kalau gak bisa diakses,
   itu emang masalah koneksi/firewall, bukan Flutter.
2. `flutter clean` lalu `flutter run` lagi (kadang cuma hiccup sesaat).
3. **Paling sering ampuh**: buka `android/gradle.properties`, tambahin
   `-Djava.net.preferIPv4Stack=true` ke baris `org.gradle.jvmargs` (atau
   tambah baris baru kalau belum ada). Banyak ISP punya routing IPv6
   bermasalah yang bikin Gradle timeout nyoba ke Maven Central.
4. Hapus cache Gradle (`~/.gradle/caches` atau
   `C:\Users\<nama>\.gradle\caches`) kalau masih gagal, lalu build ulang.
5. Kalau di jaringan kantor/kampus, cek proxy -- perlu setting
   `systemProp.http.proxyHost` dkk di `gradle.properties`.
6. Coba jaringan lain (hotspot HP) buat isolasi apakah masalahnya di
   jaringan itu spesifik.

## Struktur project

Ringkas -- detail lengkap + diagram alur ada di `ARCHITECTURE.md`.

```
lib/
├── main.dart              entry point, init Supabase, load config
├── config.dart            semua parameter tunable (dibaca semua file lain)
├── feeding_screen.dart    HUB: buka kamera, orkestrasi semuanya
├── settings_screen.dart   UI buat ubah config.dart tanpa rebuild
├── motion_energy.dart     port compute_motion_energy() -> lihat reference_python/
├── feeder_trigger.dart    port FeederTriggerAdaptive -> lihat reference_python/
├── relay_service.dart     HTTP call ke relay (on/off)
└── supabase_service.dart  update state ke table Supabase
reference_python/          source Python ASLI (bukan bagian app, cuma referensi)
```

## Cara ganti / tuning EMA

**Kalau cuma mau ubah kehalusan smoothing (paling umum)**: buka Settings di
app, ubah field `EMA alpha` (default `0.15`, sama kayak di kode Python).
Alpha lebih besar = lebih responsif tapi lebih berisik, lebih kecil = lebih
halus tapi lebih lambat bereaksi. Ini tersimpan otomatis, gak perlu rebuild.

**Kalau mau ganti mekanisme spike-rejection** (median filter sebelum EMA):
juga di Settings, field `median window` (default `5`) dan kalau mau ubah
faktor sensitivitasnya, edit `spikeRejectFactor` di konstruktor
`FeederTriggerAdaptive` di `lib/feeding_screen.dart` (default `3.0`, sama
kayak Python).

**Kalau mau ganti FORMULA EMA-nya sendiri** (bukan cuma alpha) -- misal ganti
ke simple moving average, double EMA, atau Kalman filter -- kodenya cuma
1 baris, di `lib/feeder_trigger.dart` method `update()`:

```dart
ema = ema == null ? filtered : alpha * filtered + (1 - alpha) * ema!;
```

Ganti baris ini (dan tambahin field/buffer state baru kalau smoothing barunya
butuh riwayat lebih dari 1 sample sebelumnya, kayak `_rawBuf` yang udah ada
buat median filter). **PENTING**: kalau ganti formula smoothing, `decayRatio`
& `minPeak` yang udah dikalibrasi jadi gak valid lagi -- reaksi sinyal
terhadap sinyal mentah berubah, jadi threshold-nya perlu di-tune ulang
(observasi `EMA`/`Peak` yang muncul di layar app pas testing, sama kayak
proses kalibrasi awal di `phase_calibration_fixed.py`).

## Pindah ke Supabase production

Default-nya `main.dart` baca `SUPABASE_URL` & `SUPABASE_ANON_KEY` dari
`--dart-define` (bukan hardcode), biar gampang di-swap tanpa ubah kode.

1. Bikin project di [supabase.com](https://supabase.com) (atau pakai yang
   udah ada).
2. Bikin table sesuai skema yang diasumsikan `lib/supabase_service.dart`:
   ```sql
   create table feeder_status (
     id text primary key,
     state text,
     last_stop_reason text,
     updated_at timestamptz
   );
   insert into feeder_status (id, state) values ('1', 'idle');
   ```
   Kalau skema kalian beda nama kolom, edit method `updateStatus()` di
   `supabase_service.dart` biar match.
3. Ambil **Project URL** & **anon public key** dari dashboard Supabase:
   Settings > API.
4. Run/build dengan credential itu, JANGAN taruh langsung di kode:
   ```bash
   flutter run \
     --dart-define=SUPABASE_URL=https://xxxxx.supabase.co \
     --dart-define=SUPABASE_ANON_KEY=xxxxxxxxxxxxxxxx
   ```
   Buat build APK production, tambahin flag yang sama ke
   `flutter build apk --dart-define=...`.
5. **Cek Row Level Security (RLS)**. Project Supabase baru default-nya RLS
   ON, yang berarti anon key gak bisa update apa-apa sampai ada policy yang
   ngizinin. Bikin policy UPDATE buat table `feeder_status` yang ngizinin
   role `anon`. **JANGAN** pakai `service_role` key di app mobile buat
   "jalan pintas" ngelewatin RLS -- key itu bisa di-reverse-engineer dari
   APK dan bakal bypass SEMUA proteksi data kalian.
6. Setelah itu, `relayBaseUrl`/`supabaseTable`/`supabaseRowId` masih bisa
   diubah dari Settings screen di app kalau perlu, gak perlu rebuild lagi.

## Catatan penting sebelum dipakai beneran

1. **Kalibrasi ulang wajib** sebelum dipakai produksi -- `decayRatio=0.217` &
   `minPeak=633.4` itu dari webcam tetap 720p, kamera HP hampir pasti butuh
   angka lain. Nyalain app, kasih makan beneran, catat `EMA`/`Peak` yang
   muncul di layar, tentuin ulang lewat Settings.
2. **Mounting kamera harus rigid, JANGAN dipegang tangan** -- kamera goyang
   kebukti bikin data gak bisa dipakai (lihat riwayat testing video kedua).
   Pasang HP di tripod/bracket tetap, sudut & jarak konsisten.
3. **Failsafe hardware di relay** -- jangan andalkan app doang buat matiin
   relay. Tambahin auto-off timer di firmware relay itu sendiri sebagai
   jaring pengaman kalau HP crash/WiFi putus pas mau matiin.
4. Port Dart di `motion_energy.dart`/`feeder_trigger.dart` **tidak identik
   bit-per-bit** dengan Python (beda cara resize/grayscale) -- lihat
   `ARCHITECTURE.md` bagian "Porting notes" buat detail perbedaannya.

## Checklist khusus device low-end (mis. J2 Prime)

- `processingFps` default `4.0` di config -- ini beban CPU utama. Turunin ke
  2.0-3.0 lewat Settings kalau device lag/panas.
- `ResolutionPreset.low` udah dipasang di `feeding_screen.dart` sengaja,
  gak ada gunanya minta stream resolusi tinggi buat diproses jadi 160x120.
- Test camera plugin di device fisik dari awal development, bukan di akhir
  -- chipset lawas kadang ada isu kompatibilitas Camera2 API.
- Pastikan battery optimization Android buat app ini di-disable (Settings >
  Apps > Battery > Unrestricted), biar gak di-kill OS pas sesi makan lagi
  jalan di background/layar mati.
