"""
=====================================================================
 SMART FEEDING STATION - Tier 1 Pipeline: Motion Energy Detector
=====================================================================
Fungsi file ini:
  1. Membaca video (dari file ATAU nanti dari stream kamera J2 Prime)
  2. Menghitung "motion energy" per frame via frame differencing
  3. Menghaluskan sinyal dengan Exponential Moving Average (EMA)
  4. Mengkalibrasi threshold_low / threshold_high dari 4 video kelas Anda
  5. Mensimulasikan logika trigger STOP dengan debounce

CARA PAKAI:
  1. Taruh 4 video Anda di satu folder, misal:
       videos/calm(1).mp4
       videos/weak.mp4
       videos/medium.mp4
       videos/strong.mp4
  2. Edit dict VIDEO_PATHS di bagian bawah file (paling bawah, di __main__)
  3. Jalankan: python3 motion_energy_pipeline.py
  4. Lihat file output "calibration_chart.png" yang dihasilkan -> ini akan
     menunjukkan apakah ke-4 kelas terpisah dengan jelas secara motion energy.
     Kalau terpisah jelas -> Tier 1 saja SUDAH CUKUP untuk MVP, tidak perlu ML.
=====================================================================
"""

import cv2
import numpy as np
import matplotlib.pyplot as plt
from dataclasses import dataclass


def get_video_fps(video_path: str) -> float:
    """Deteksi fps asli video, JANGAN diasumsikan/hardcode -- ini penyebab bug
    debounce yang terlalu pendek pada iterasi sebelumnya (video ternyata ~24-25fps,
    bukan 10fps seperti asumsi awal)."""
    cap = cv2.VideoCapture(video_path)
    fps = cap.get(cv2.CAP_PROP_FPS) or 10.0
    cap.release()
    return fps


# ---------------------------------------------------------------------------
# 1. EKSTRAKSI MOTION ENERGY MENTAH DARI VIDEO
# ---------------------------------------------------------------------------
def compute_motion_energy(video_path: str, resize_dim=(160, 120), diff_threshold: int = 25):
    """
    Membaca video, resize tiap frame (biar ringan, sesuai kemampuan J2 Prime),
    ubah ke grayscale, lalu hitung jumlah piksel yang berubah signifikan
    antar frame berurutan. Ini adalah skor "motion energy" mentah.

    resize_dim kecil (160x120) sengaja dipilih supaya nanti saat deploy
    di edge device, komputasi tetap ringan walau resolusi asli kamera lebih besar.
    """
    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        raise FileNotFoundError(f"Tidak bisa membuka video: {video_path}")

    scores = []
    prev_gray = None

    while True:
        ret, frame = cap.read()
        if not ret:
            break
        frame = cv2.resize(frame, resize_dim)
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        gray = cv2.GaussianBlur(gray, (5, 5), 0)  # kurangi noise sensor kamera lawas

        if prev_gray is not None:
            diff = cv2.absdiff(gray, prev_gray)
            _, thresh = cv2.threshold(diff, diff_threshold, 255, cv2.THRESH_BINARY)
            active_pixels = int(np.count_nonzero(thresh))
            scores.append(active_pixels)
        else:
            scores.append(0)

        prev_gray = gray

    cap.release()
    return scores


# ---------------------------------------------------------------------------
# 2. SMOOTHING DENGAN EXPONENTIAL MOVING AVERAGE (EMA)
# ---------------------------------------------------------------------------
def apply_ema(scores, alpha: float = 0.3):
    """
    alpha lebih besar -> lebih responsif tapi lebih 'berisik'
    alpha lebih kecil -> lebih halus tapi lebih lambat bereaksi
    alpha=0.3 adalah titik awal yang wajar, tapi HARUS dituning
    memakai 4 video Anda (lihat hasil calibration_chart.png).
    """
    ema = np.zeros(len(scores))
    ema[0] = scores[0]
    for i in range(1, len(scores)):
        ema[i] = alpha * scores[i] + (1 - alpha) * ema[i - 1]
    return ema


# ---------------------------------------------------------------------------
# 3. KALIBRASI THRESHOLD DARI 4 VIDEO KELAS
# ---------------------------------------------------------------------------
def calibrate(video_paths: dict, alpha: float = 0.3, out_chart="calibration_chart.png"):
    """
    video_paths: dict {nama_kelas: path_video}
    Menghasilkan grafik perbandingan EMA curve tiap kelas + ringkasan
    statistik (min/mean/max) untuk membantu Anda menentukan threshold_low
    dan threshold_high secara empiris (bukan tebak-tebakan).
    """
    results = {}
    fig, ax = plt.subplots(figsize=(10, 5))

    for label, path in video_paths.items():
        raw = compute_motion_energy(path)
        smoothed = apply_ema(raw, alpha=alpha)
        results[label] = smoothed
        ax.plot(smoothed, label=label)
        print(f"[{label:8s}] mean={smoothed.mean():8.1f}  min={smoothed.min():8.1f}  max={smoothed.max():8.1f}")

    ax.set_xlabel("Frame ke-")
    ax.set_ylabel("Motion Energy (EMA)")
    ax.set_title("Perbandingan Motion Energy antar Kelas Feeding Intensity")
    ax.legend()
    fig.tight_layout()
    fig.savefig(out_chart, dpi=120)
    print(f"\nChart tersimpan di: {out_chart}")
    print("\n>> Cek chart ini: apakah kurva 'none' & 'weak' jelas terpisah dari 'strong'?")
    print(">> Kalau iya, threshold_low bisa diambil di antara mean(weak) dan mean(none).")
    return results


# ---------------------------------------------------------------------------
# 4. LOGIKA TRIGGER STOP (dengan debounce, siap dipakai untuk live stream)
# ---------------------------------------------------------------------------
@dataclass
class FeederTrigger:
    threshold_low: float          # di bawah ini dianggap "tenang" (lele kenyang)
    debounce_frames: int          # berapa frame berturut-turut harus 'tenang' sebelum STOP dikirim
    alpha: float = 0.3

    def __post_init__(self):
        self._ema = None
        self._calm_streak = 0
        self.stopped = False

    def update(self, raw_score: float) -> str:
        """Panggil fungsi ini tiap frame baru datang (dari file ATAU live stream)."""
        self._ema = raw_score if self._ema is None else \
            self.alpha * raw_score + (1 - self.alpha) * self._ema

        if self._ema < self.threshold_low:
            self._calm_streak += 1
        else:
            self._calm_streak = 0

        if self._calm_streak >= self.debounce_frames and not self.stopped:
            self.stopped = True
            return "STOP"
        return "CONTINUE"


def simulate_trigger_on_video(video_path, threshold_low, debounce_seconds=3.0):
    """[LEGACY/naif - lihat catatan di bawah] Simulasi threshold absolut.
    TERBUKTI TIDAK RELIABLE dari data real Anda: karena tidak ada 'warm-up
    guard', video dengan jeda tenang di awal (sebelum frenzy dimulai) akan
    salah STOP lebih dulu. Dipertahankan di sini hanya sebagai pembanding/
    ilustrasi kenapa kita pindah ke FeederTriggerAdaptive."""
    fps = get_video_fps(video_path)
    debounce_frames = max(1, round(debounce_seconds * fps))
    raw_scores = compute_motion_energy(video_path)
    trigger = FeederTrigger(threshold_low=threshold_low, debounce_frames=debounce_frames)

    for i, s in enumerate(raw_scores):
        decision = trigger.update(s)
        if decision == "STOP":
            print(f"  -> STOP terpicu di frame {i} (~detik {i/fps:.1f}s, fps={fps:.1f})")
            return i / fps
    print(f"  -> STOP tidak pernah terpicu selama video (fps={fps:.1f})")
    return None


# ---------------------------------------------------------------------------
# 4b. ADAPTIVE TRIGGER: berbasis penurunan relatif dari PUNCAK sesi
# ---------------------------------------------------------------------------
# Dipakai karena di data real Anda, kelas 'none' vs 'weak' overlap kalau
# pakai threshold absolut -> yang jauh lebih robust adalah mendeteksi
# PENURUNAN dari puncak aktivitas sesi itu sendiri, bukan angka mutlak.
# Ini juga otomatis menyesuaikan ke variasi jumlah pakan/nafsu makan
# yang berbeda tiap sesi, tanpa perlu kalibrasi ulang tiap saat.
@dataclass
class FeederTriggerAdaptive:
    decay_ratio: float = 0.35     # STOP jika EMA turun ke <=35% dari puncak sesi
    min_peak: float = 50.0        # abaikan noise: puncak harus setidaknya sebesar ini dulu
    debounce_frames: int = 30     # berapa frame berturut-turut harus di bawah ambang
    alpha: float = 0.15           # lebih kecil dari versi sebelumnya -> smoothing lebih kuat
    startup_timeout_frames: int = 50  # ~5 detik @10fps: kalau puncak tak pernah tercapai -> STOP juga
    # (menangani kasus "lele sudah kenyang dari awal", tidak ada respon berarti terhadap pakan)

    def __post_init__(self):
        self._ema = None
        self._peak = 0.0
        self._calm_streak = 0
        self.stopped = False
        self._frame_count = 0

    def update(self, raw_score: float) -> str:
        self._frame_count += 1
        self._ema = raw_score if self._ema is None else \
            self.alpha * raw_score + (1 - self.alpha) * self._ema

        self._peak = max(self._peak, self._ema)

        # Kasus edge: dari awal tidak pernah ada aktivitas berarti sama sekali
        # -> anggap lele tidak berminat / sudah kenyang -> STOP juga.
        if self._peak < self.min_peak:
            if self._frame_count >= self.startup_timeout_frames and not self.stopped:
                self.stopped = True
                return "STOP"
            return "CONTINUE"

        threshold = self._peak * self.decay_ratio
        if self._ema <= threshold:
            self._calm_streak += 1
        else:
            self._calm_streak = 0

        if self._calm_streak >= self.debounce_frames and not self.stopped:
            self.stopped = True
            return "STOP"
        return "CONTINUE"


def simulate_adaptive_trigger_on_video(video_path, min_peak, decay_ratio=0.35,
                                        debounce_seconds=3.0, startup_timeout_seconds=5.0,
                                        alpha=0.15):
    """Versi adaptif: fps dideteksi otomatis dari video, semua durasi dalam DETIK
    supaya tidak bergantung pada asumsi fps yang bisa salah (lihat get_video_fps)."""
    fps = get_video_fps(video_path)
    debounce_frames = max(1, round(debounce_seconds * fps))
    startup_timeout_frames = max(1, round(startup_timeout_seconds * fps))

    raw_scores = compute_motion_energy(video_path)
    trigger = FeederTriggerAdaptive(
        decay_ratio=decay_ratio,
        min_peak=min_peak,
        debounce_frames=debounce_frames,
        alpha=alpha,
        startup_timeout_frames=startup_timeout_frames,
    )

    for i, s in enumerate(raw_scores):
        decision = trigger.update(s)
        if decision == "STOP":
            print(f"  -> STOP terpicu di frame {i} (~detik {i/fps:.1f}s, fps={fps:.1f}), puncak EMA sesi={trigger._peak:.1f}")
            return i / fps
    print(f"  -> STOP tidak pernah terpicu (puncak EMA sesi={trigger._peak:.1f}, fps={fps:.1f})")
    return None


def parameter_sweep(video_paths, min_peak, decay_ratios=(0.30, 0.35, 0.40, 0.45, 0.50, 0.55, 0.60),
                     debounce_seconds_list=(1.0, 1.5, 2.0, 2.5, 3.0), alpha=0.15):
    """
    Mencoba banyak kombinasi decay_ratio x debounce_seconds sekaligus, mencari
    kombinasi yang menghasilkan URUTAN waktu STOP yang masuk akal:
        none <= weak <= medium <= strong
    Kalau suatu kelas tidak pernah STOP dalam durasi video, dianggap 'stop
    di akhir video milik dia sendiri' (video_duration) untuk keperluan
    perbandingan urutan saja -- bukan berarti sistem menunggu selamanya.

    Ini menggantikan trial-and-error manual per pesan chat.
    """
    candidates = []
    for dr in decay_ratios:
        for db in debounce_seconds_list:
            stop_times = {}
            for label, path in video_paths.items():
                fps = get_video_fps(path)
                raw_scores = compute_motion_energy(path)
                video_duration = len(raw_scores) / fps
                trigger = FeederTriggerAdaptive(
                    decay_ratio=dr, min_peak=min_peak, alpha=alpha,
                    debounce_frames=max(1, round(db * fps)),
                    startup_timeout_frames=max(1, round(5.0 * fps)),
                )
                t_stop = None
                for i, s in enumerate(raw_scores):
                    if trigger.update(s) == "STOP":
                        t_stop = i / fps
                        break
                stop_times[label] = t_stop if t_stop is not None else video_duration

            order_ok = (stop_times["none"] <= stop_times["weak"] <= stop_times["medium"] <= stop_times["strong"])
            spread = stop_times["strong"] - stop_times["none"]
            candidates.append((order_ok, spread, dr, db, dict(stop_times)))

    candidates.sort(key=lambda c: (-c[0], -c[1]))
    print("\n=== HASIL PARAMETER SWEEP (kombinasi terbaik di atas, 'OK'=urutan benar) ===")
    print(f"{'':4s}{'decay_ratio':>12s}{'debounce':>10s}{'none':>10s}{'weak':>10s}{'medium':>10s}{'strong':>10s}")
    for ok, spread, dr, db, st in candidates[:10]:
        flag = "OK  " if ok else "    "
        print(f"{flag}{dr:>12.2f}{db:>9.1f}s{st['none']:>9.1f}s{st['weak']:>9.1f}s"
              f"{st['medium']:>9.1f}s{st['strong']:>9.1f}s")
    return candidates


def evaluate_session(video_path, phase_boundaries, min_peak, decay_ratio=0.35,
                      debounce_seconds=2.0, alpha=0.15, out_chart="session_chart.png"):
    """
    Evaluasi end-to-end untuk 1 video SESI PENUH (bukan 4 video terpisah per kelas
    seperti sebelumnya). Video berisi rangkaian fase dalam satu timeline, misal:
        tenang (pre-feed) -> makan (frenzy) -> habiskan sisa (tapering) -> tenang (post-feed)

    phase_boundaries: dict {nama_fase: (t_mulai_detik, t_selesai_detik)}, contoh:
        {"calm_pre": (0,2), "makan": (2,5), "sisa": (5,7), "calm_post": (7,9)}
    Fase TERAKHIR di dict ini dianggap sebagai target -> STOP idealnya jatuh di sana.

    Fungsi ini menjalankan FeederTriggerAdaptive di sepanjang video, mencatat detik
    STOP terjadi, mengecek fase mana yang memuatnya, dan menyimpan chart dengan
    area tiap fase diwarnai supaya mudah diinspeksi visual.
    """
    fps = get_video_fps(video_path)
    raw_scores = compute_motion_energy(video_path)
    ema = apply_ema(raw_scores, alpha=alpha)

    trigger = FeederTriggerAdaptive(
        decay_ratio=decay_ratio, min_peak=min_peak, alpha=alpha,
        debounce_frames=max(1, round(debounce_seconds * fps)),
        startup_timeout_frames=max(1, round(5.0 * fps)),
    )
    t_stop = None
    for i, s in enumerate(raw_scores):
        if trigger.update(s) == "STOP":
            t_stop = i / fps
            break

    stop_phase = None
    if t_stop is not None:
        for name, (t0, t1) in phase_boundaries.items():
            if t0 <= t_stop < t1:
                stop_phase = name
                break

    fig, ax = plt.subplots(figsize=(10, 5))
    time_axis = np.arange(len(ema)) / fps
    ax.plot(time_axis, ema, color="black", linewidth=1.5, label="Motion Energy (EMA)")
    colors = plt.cm.Set3(np.linspace(0, 1, len(phase_boundaries)))
    for (name, (t0, t1)), c in zip(phase_boundaries.items(), colors):
        ax.axvspan(t0, t1, alpha=0.3, color=c, label=name)
    if t_stop is not None:
        ax.axvline(t_stop, color="red", linestyle="--", linewidth=2, label=f"STOP @ {t_stop:.1f}s")
    ax.set_xlabel("Waktu (detik)")
    ax.set_ylabel("Motion Energy (EMA)")
    ax.set_title("Evaluasi Sesi Penuh: Tenang -> Makan -> Sisa -> Tenang")
    ax.legend(loc="upper right", fontsize=8)
    fig.tight_layout()
    fig.savefig(out_chart, dpi=120)

    target_phase = list(phase_boundaries.keys())[-1]
    print(f"STOP terpicu di: {t_stop:.2f}s" if t_stop is not None else "STOP tidak pernah terpicu")
    print(f"Fase saat STOP  : {stop_phase}")
    if stop_phase == target_phase:
        print(f"BERHASIL: STOP jatuh di fase target ('{target_phase}')")
    elif t_stop is None:
        print("PERLU TUNING: STOP tidak pernah terjadi, mungkin decay_ratio/debounce terlalu ketat")
    elif list(phase_boundaries.keys()).index(stop_phase) < list(phase_boundaries.keys()).index(target_phase):
        print(f"BAHAYA: STOP terlalu CEPAT (masih fase '{stop_phase}') -> pakan bisa kurang untuk lele")
    print(f"Chart tersimpan: {out_chart}")
    return t_stop, stop_phase


# ---------------------------------------------------------------------------
# MAIN
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    # === SKEMA BARU: 1 video sesi penuh dengan 4 fase dalam satu timeline ===
    SESSION_VIDEO = "D:\FOLDER DOWNLOAD\lele vid\videos\9min_720p.mp4"
    PHASES = {
        "calm_pre": (0, 102),   # sebelum pakan ditebar
        "makan":    (120, 300),   # frenzy, lele menyerbu pakan
        "sisa":     (301, 420),   # menghabiskan sisa pakan, mulai mereda
        "calm_post": (421, 541),  # sudah kenyang -> TARGET: STOP harus jatuh di sini
    }

    # min_peak & decay_ratio: mulai dari hasil kalibrasi/sweep sebelumnya.
    # Kalau belum pernah kalibrasi 'none' terpisah, min_peak bisa diestimasi
    # dari level EMA di fase 'calm_pre' video ini sendiri (lihat catatan di bawah).
    MIN_PEAK = 221.4       # dari kalibrasi 4-video sebelumnya; sesuaikan jika perlu
    DECAY_RATIO = 0.35
    DEBOUNCE_SECONDS = 2.0

    evaluate_session(
        SESSION_VIDEO, PHASES,
        min_peak=MIN_PEAK, decay_ratio=DECAY_RATIO, debounce_seconds=DEBOUNCE_SECONDS,
    )
