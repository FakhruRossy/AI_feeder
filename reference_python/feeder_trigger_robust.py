"""
=====================================================================
 feeder_trigger_robust.py — versi FIX dari FeederTriggerAdaptive
=====================================================================
Dua masalah yang ini fix:

1) NOISE SPIKE (contoh di data kalian: ~1402 di t~400s saat fase
   'ngabisin_sisa', ~2492 di t~505s saat fase 'calm_end').
   -> Ditangani dengan median pre-filter + relative-spike clamp
      SEBELUM sample masuk ke EMA. Jadi 1-2 frame outlier ekstrem
      tidak ikut membentuk EMA ataupun menaikkan peak_running
      (yang kalau kebawa, bisa menaikkan decay threshold dan bikin
      STOP jadi telat/gagal di deployment jangka panjang).

2) STOP PREMATUR di tengah fase 'makan' (dip sesaat, min=45.1 di
   data kalian) -> Ditangani dengan hysteresis dual-threshold:
   counter below_threshold cuma naik kalau EMA < decay_th, dan cuma
   di-reset kalau EMA naik balik MELEWATI release_th (lebih tinggi
   dari decay_th). Di zona antara decay_th..release_th, counter
   dibiarkan apa adanya -> fluktuasi kecil di sekitar garis
   threshold tidak bikin logic "ragu-ragu" naik-turun terus.

DROP-IN COMPATIBLE: constructor & .update() kwargs/contract sama
dengan versi lama kalian (decay_ratio, min_peak, alpha,
debounce_frames, startup_timeout_frames). Parameter baru semuanya
punya default, jadi kode existing (phase_calibration.py) tetap jalan
tanpa perlu diubah selain baris import.

CARA PAKAI (2 opsi):
  A) Ganti isi class FeederTriggerAdaptive di motion_energy_pipeline.py
     dengan class di file ini.
  B) Simpan file ini sejajar dengan motion_energy_pipeline.py, lalu di
     phase_calibration.py ganti baris:
         from motion_energy_pipeline import (..., FeederTriggerAdaptive)
     jadi:
         from motion_energy_pipeline import compute_motion_energy, apply_ema, get_video_fps
         from feeder_trigger_robust import FeederTriggerAdaptive
=====================================================================
"""

from collections import deque
from typing import Optional


class FeederTriggerAdaptive:
    def __init__(
        self,
        decay_ratio: float,
        min_peak: float,
        alpha: float = 0.15,
        debounce_frames: int = 30,
        startup_timeout_frames: int = 150,
        median_window: int = 5,
        spike_reject_factor: float = 3.0,
        release_margin: float = 1.15,
    ):
        self.decay_ratio = decay_ratio
        self.min_peak = min_peak
        self.alpha = alpha
        self.debounce_frames = debounce_frames
        self.startup_timeout_frames = startup_timeout_frames
        self.median_window = median_window
        self.spike_reject_factor = spike_reject_factor
        self.release_margin = release_margin
        self.reset()

    def reset(self):
        """Panggil ini tiap mulai sesi feeding baru (feeder ON)."""
        self._raw_buf = deque(maxlen=self.median_window)
        self.ema = None
        self.peak_running = 0.0
        self.peak_reached = False
        self.below_counter = 0
        self.frame_idx = 0
        self.last_stop_reason = None
        self.stopped = False

    # ---- internal: spike rejection ------------------------------------
    def _median(self):
        buf = sorted(self._raw_buf)
        n = len(buf)
        mid = n // 2
        return buf[mid] if n % 2 else 0.5 * (buf[mid - 1] + buf[mid])

    def _filter_sample(self, raw: float) -> float:
        self._raw_buf.append(raw)
        if len(self._raw_buf) < 3:
            return raw
        med = self._median()
        # raw jauh di atas median lokal -> outlier sesaat, pakai median
        if med > 0 and raw > self.spike_reject_factor * med:
            return med
        return raw

    # ---- main API -------------------------------------------------------
    def update(self, raw_sample: float) -> Optional[str]:
        if self.stopped:
            return "STOP"

        self.frame_idx += 1
        filtered = self._filter_sample(raw_sample)

        self.ema = filtered if self.ema is None else (
            self.alpha * filtered + (1 - self.alpha) * self.ema
        )

        # peak HANYA dihitung dari sinyal yang sudah difilter -> spike
        # ekstrem gak ikut menaikkan referensi peak
        if self.ema > self.peak_running:
            self.peak_running = self.ema
        if not self.peak_reached and self.peak_running >= self.min_peak:
            self.peak_reached = True

        if not self.peak_reached:
            if self.frame_idx >= self.startup_timeout_frames:
                self.stopped = True
                self.last_stop_reason = "startup_timeout"
                return "STOP"
            return None

        decay_th = self.decay_ratio * self.peak_running
        release_th = decay_th * self.release_margin

        if self.ema < decay_th:
            self.below_counter += 1
        elif self.ema > release_th:
            self.below_counter = 0
        # else: di zona hysteresis -> counter dibiarkan (gak naik gak reset)

        if self.below_counter >= self.debounce_frames:
            self.stopped = True
            self.last_stop_reason = "decay"
            return "STOP"

        return None

    def state(self) -> dict:
        """Buat logging real-time di lapangan (print/kirim ke MQTT/serial)."""
        return {
            "frame": self.frame_idx,
            "ema": round(self.ema, 1) if self.ema is not None else None,
            "peak_running": round(self.peak_running, 1),
            "peak_reached": self.peak_reached,
            "below_counter": self.below_counter,
            "stopped": self.stopped,
            "reason": self.last_stop_reason,
        }


# =====================================================================
# SELF-TEST sintetis -- gak butuh video, cuma buat validasi logic cepat
# sebelum kalian re-run di STEP 2/3 pakai video asli.
# Skenario dibikin mirip data kalian:
#   - baseline noise rendah (calm_start)
#   - naik ke plateau aktif (makan) DENGAN 1 dip sesaat di tengah
#   - turun ke plateau lebih rendah (ngabisin_sisa) + 1 spike outlier
#     mirip kejadian t~400s
#   - baseline rendah (calm_end) + 1 spike outlier ekstrem mirip t~505s
# =====================================================================
if __name__ == "__main__":
    import random

    random.seed(0)
    fps = 30

    def noisy(base, n, spread):
        return [max(0, base + random.uniform(-spread, spread)) for _ in range(n)]

    calm_start = noisy(50, 60 * fps, 40)                    # calm_start 60s
    makan = noisy(500, 90 * fps, 250)
    dip_start = 40 * fps
    for i in range(dip_start, dip_start + int(1.2 * fps)):  # dip sesaat 1.2s
        makan[i] = random.uniform(20, 60)
    sisa = noisy(190, 60 * fps, 60)
    sisa[20 * fps] = 1400                                   # spike ~t400s
    calm_end = noisy(90, 40 * fps, 50)
    calm_end[10 * fps] = 2492                                # spike ~t505s

    signal = calm_start + makan + sisa + calm_end

    # min_peak dihitung dari calm_start, PERSIS spt workflow kalibrasi kalian
    min_peak = max(calm_start) * 1.3

    # PENTING: sama seperti STEP 3 di phase_calibration.py -- trigger baru
    # aktif SEJAK FEEDER ON (awal fase 'makan'), bukan dari detik 0 rekaman.
    feeder_on_frame = 60 * fps
    signal_since_feeder_on = signal[feeder_on_frame:]

    trigger = FeederTriggerAdaptive(
        decay_ratio=0.217, min_peak=min_peak, alpha=0.15,
        debounce_frames=int(2.5 * fps),       # dinaikkan dari 1.0s -> 2.5s
        startup_timeout_frames=int(15 * fps), # relatif thd feeder ON
    )

    t_stop = None
    for i, s in enumerate(signal_since_feeder_on):
        if trigger.update(s) == "STOP":
            t_stop = i / fps  # detik relatif thd feeder ON
            break

    print("Hasil self-test (sintetis, dievaluasi sejak feeder ON):")
    if t_stop:
        print(f"  STOP di t={t_stop:.2f}s relatif thd feeder ON")
    else:
        print("  STOP tidak pernah terpicu")
    print(f"  reason = {trigger.last_stop_reason}")
    print(f"  state  = {trigger.state()}")
    print("\nYang divalidasi di sini (bukan timing presisi -- itu urusan re-kalibrasi")
    print("decay_ratio pakai video asli lewat STEP 2/3 kalian):")
    print("  1) reason='decay' (bukan 'startup_timeout') -> peak_running berhasil kebentuk")
    print("  2) TIDAK stop selama dip sesaat di 'makan' (~t40-41s relatif feeder ON)")
    print("  3) peak_running TIDAK ikut melonjak gara-gara spike outlier 1400/2492")
    print(f"     (peak_running={trigger.peak_running:.1f}, jauh di bawah nilai spike)")
