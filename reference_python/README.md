# Reference Python

File di folder ini **BUKAN bagian dari app** (gak di-import, gak dijalanin sama
Flutter). Ini source Python asli yang jadi dasar port ke `lib/motion_energy.dart`
dan `lib/feeder_trigger.dart`. Disimpan di sini biar siapapun yang megang project
ini bisa cross-check: kalau ada perilaku Dart yang keliatan aneh, bandingin dulu
ke sini sebelum nebak-nebak.

| File | Peran |
|---|---|
| `motion_energy_pipeline.py` | Sumber asli `compute_motion_energy()` (resize/grayscale/blur/diff/threshold) dan `apply_ema()`. |
| `feeder_trigger_robust.py` | Sumber asli class `FeederTriggerAdaptive` (median spike-reject, hysteresis dual-threshold). Ini yang di-port 1:1 ke `feeder_trigger.dart`. |
| `phase_calibration_fixed.py` | Tool offline (jalan di PC, bukan di HP) buat nentuin `decay_ratio` & `min_peak` dari video kalibrasi. Dipakai ULANG tiap kali kondisi kamera/kolam berubah signifikan -- lihat `../ARCHITECTURE.md` bagian "Kalibrasi ulang". |

Detail pemetaan Python -> Dart (fungsi mana jadi apa, dan apa yang BEDA) ada di
`../ARCHITECTURE.md`, bagian "Porting notes".
