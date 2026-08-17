"""
=====================================================================
 phase_calibration_fixed.py — versi FIX dari phase_calibration.py
=====================================================================
Perubahan dari versi asli:

1. STEP 2 (verify_trigger_lands_in_target_phase) sekarang DIEVALUASI
   MULAI DARI FEEDER ON (awal fase 'makan'), bukan dari detik 0
   rekaman. Di versi asli, 120 detik fase 'calm_start' bikin
   startup_timeout (5s) selalu nembak duluan sebelum decay logic
   sempat dievaluasi -> makanya semua nilai debounce hasilnya sama
   (STOP di ~4.97s, reason sebenarnya startup_timeout). Sekarang
   hasil sweep-nya baru representatif buat milih debounce yang pas.

2. Pakai FeederTriggerAdaptive versi robust (feeder_trigger_robust.py):
   ada spike-rejection (median filter) buat noise sesaat kayak yang
   muncul di t~400s/500s pada video kalian, dan hysteresis debounce
   biar dip sesaat di tengah 'makan' gak langsung dianggap selesai
   makan. Ganti baris import di bawah ini kalau kalian sudah
   nempelin class itu langsung ke motion_energy_pipeline.py.

3. Verdict classifier (TARGET / TERLALU CEPAT / TERLALU LAMBAT) sekarang
   berbasis URUTAN fase (index dalam list PHASES), bukan cocok-cocokan
   string "sisa" seperti sebelumnya -- lebih robust kalau nama fase
   kalian berubah nanti.

4. STEP 2 & 3 sekarang nge-print `reason` (decay / startup_timeout)
   dan full `state()` trigger, biar gampang didiagnosis kalau hasilnya
   masih meleset.

5. [PATCH] STEP 2 (verify_trigger_lands_in_target_phase) sekarang punya
   parameter `startup_timeout_seconds` (dulu hardcode 15.0). Kenapa:
   kalau video ramp-up motion energy-nya lebih lambat (butuh >15s dari
   feeder ON buat nyampe min_peak), startup_timeout bakal nembak duluan
   di SEMUA nilai debounce -> sweep jadi gak informatif (semua baris
   hasilnya sama, reason=startup_timeout, bukan decay). Ini persis bug
   yang sama kayak masalah #1 di atas, cuma titik nembaknya geser.

6. [PATCH] Ditambah fungsi diagnostic `find_time_to_peak()` -- ngukur
   langsung dari video, berapa detik sejak feeder ON sampe EMA motion
   energy pertama kali nyentuh min_peak. Dipakai buat NENTUIN
   startup_timeout_seconds yang masuk akal per-video (bukan nembak
   angka tetap), sebelum jalanin sweep debounce.

VIDEO & FASE kalian (541 detik total, video pertama):
    calm_start    :   0 - 120 s
    makan         : 121 - 300 s   <- feeder ON di sini
    ngabisin_sisa : 301 - 420 s   <- target STOP
    calm_end      : 421 - 541 s
=====================================================================
"""

import numpy as np
import matplotlib.pyplot as plt

from motion_energy_pipeline import compute_motion_energy, apply_ema, get_video_fps
from feeder_trigger_robust import FeederTriggerAdaptive


# ---------------------------------------------------------------------
# STEP 1: analisis & kalibrasi dari video berfase (logic sama spt sebelumnya)
# ---------------------------------------------------------------------
def analyze_phased_video(video_path, phases, alpha=0.15, out_chart="phase_calibration_chart.png"):
    fps = get_video_fps(video_path)
    raw = compute_motion_energy(video_path)
    ema = apply_ema(raw, alpha=alpha)
    t = np.arange(len(ema)) / fps

    print(f"fps video = {fps:.1f}, total durasi = {len(ema)/fps:.1f}s\n")
    stats = {}
    for name, t0, t1 in phases:
        mask = (t >= t0) & (t < t1)
        seg = ema[mask]
        stats[name] = {"mean": seg.mean(), "min": seg.min(), "max": seg.max()}
        print(f"[{name:15s}] {t0:>4.1f}-{t1:<4.1f}s  mean={seg.mean():7.1f}  "
              f"min={seg.min():7.1f}  max={seg.max():7.1f}")

    makan_name = max(stats, key=lambda k: stats[k]["mean"])
    peak_makan = stats[makan_name]["max"]

    target_name = None
    for name, _, _ in phases:
        if "sisa" in name.lower():
            target_name = name
            break
    if target_name is None:
        idx = [p[0] for p in phases].index(makan_name)
        target_name = phases[idx + 1][0] if idx + 1 < len(phases) else phases[-1][0]

    level_target = stats[target_name]["mean"]
    decay_ratio_target = level_target / peak_makan

    print(f"\n>> Fase puncak aktivitas terdeteksi : '{makan_name}' (peak EMA = {peak_makan:.1f})")
    print(f">> Fase target STOP                 : '{target_name}' (mean EMA = {level_target:.1f})")
    print(f">> decay_ratio_target terkalibrasi  : {decay_ratio_target:.3f}")

    fig, ax = plt.subplots(figsize=(11, 5))
    ax.plot(t, ema, color="black", linewidth=1.2, label="Motion Energy (EMA)")
    colors = plt.cm.tab10.colors
    for i, (name, t0, t1) in enumerate(phases):
        ax.axvspan(t0, t1, alpha=0.15, color=colors[i % 10], label=name)
    ax.axhline(decay_ratio_target * peak_makan, color="red", linestyle="--",
               linewidth=1, label=f"target threshold ({decay_ratio_target*peak_makan:.0f})")
    ax.set_xlabel("Waktu (detik)")
    ax.set_ylabel("Motion Energy (EMA)")
    ax.set_title("Kalibrasi Transisi Fase: Makan -> Ngabisin Sisa")
    ax.legend(loc="upper right", fontsize=8)
    fig.tight_layout()
    fig.savefig(out_chart, dpi=120)
    print(f"\nChart tersimpan di: {out_chart}")

    return stats, decay_ratio_target, target_name, makan_name


# ---------------------------------------------------------------------
# Helper: verdict berbasis urutan fase (index), bukan match string
# ---------------------------------------------------------------------
def _make_verdict_fn(phases, target_name):
    order = [p[0] for p in phases]
    target_idx = order.index(target_name)

    def verdict(fase_name):
        if fase_name not in order:
            return "?"
        idx = order.index(fase_name)
        if idx == target_idx:
            return "TARGET!"
        return "TERLALU CEPAT" if idx < target_idx else "TERLALU LAMBAT"

    return verdict


def _phase_at(phases, t_sec):
    for name, t0, t1 in phases:
        if t0 <= t_sec < t1:
            return name
    return phases[-1][0]


# ---------------------------------------------------------------------
# [PATCH] Diagnostic: berapa lama sejak feeder ON sampe EMA nyentuh min_peak
# ---------------------------------------------------------------------
def find_time_to_peak(video_path, phases, feeder_on_phase, min_peak, alpha=0.15):
    """Ngukur langsung dari data video (bukan nembak angka): berapa detik
    sejak feeder ON sampe EMA motion energy PERTAMA KALI >= min_peak.

    Dipakai buat nentuin startup_timeout_seconds yang aman -- kalau
    startup_timeout diset lebih pendek dari angka ini, trigger bakal
    selalu mati duluan karena startup_timeout, dan decay logic gak
    pernah kebagian jalan (semua debounce di sweep hasilnya sama).

    Return None kalau EMA gak pernah nyampe min_peak sepanjang video
    sejak feeder ON -- itu tandanya min_peak KETINGGIAN buat video ini,
    bukan startup_timeout yang harus dinaikin.

    Catatan: ini pakai EMA polos (apply_ema), sedangkan FeederTriggerAdaptive
    aslinya mungkin ada spike-rejection/median filter internal, jadi angka
    ini approximate -- pakai dengan buffer beberapa detik, jangan mepet.
    """
    fps = get_video_fps(video_path)
    raw = compute_motion_energy(video_path)
    ema_full = apply_ema(raw, alpha=alpha)

    t_feeder_on = next(t0 for name, t0, t1 in phases if name == feeder_on_phase)
    start_frame = int(t_feeder_on * fps)
    ema_since_on = ema_full[start_frame:]

    for i, v in enumerate(ema_since_on):
        if v >= min_peak:
            return i / fps
    return None


# ---------------------------------------------------------------------
# STEP 2 (FIXED + PATCHED): sweep debounce, dievaluasi sejak feeder ON,
# startup_timeout_seconds sekarang jadi PARAMETER (dulu hardcode 15.0)
# ---------------------------------------------------------------------
def verify_trigger_lands_in_target_phase(video_path, phases, decay_ratio, min_peak, target_name,
                                          feeder_on_phase,
                                          debounce_seconds_list=(0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 4.0),
                                          alpha=0.15, startup_timeout_seconds=15.0, **trigger_kwargs):
    fps = get_video_fps(video_path)
    raw = compute_motion_energy(video_path)
    verdict = _make_verdict_fn(phases, target_name)

    t_feeder_on = next(t0 for name, t0, t1 in phases if name == feeder_on_phase)
    start_frame = int(t_feeder_on * fps)
    raw_since_on = raw[start_frame:]

    print(f"(startup_timeout_seconds = {startup_timeout_seconds:.1f}s)")
    print(f"\n{'debounce':>10s}  {'stop_at':>8s}  {'fase':>15s}  {'reason':>16s}  {'status':>15s}")
    results = []
    for db in debounce_seconds_list:
        trig = FeederTriggerAdaptive(
            decay_ratio=decay_ratio, min_peak=min_peak, alpha=alpha,
            debounce_frames=max(1, round(db * fps)),
            startup_timeout_frames=max(1, round(startup_timeout_seconds * fps)),
            **trigger_kwargs,
        )
        t_stop = None
        for i, s in enumerate(raw_since_on):
            if trig.update(s) == "STOP":
                t_stop = t_feeder_on + i / fps
                break

        if t_stop is None:
            fase, status, reason = "-", "TIDAK STOP", "-"
        else:
            fase = _phase_at(phases, t_stop)
            status = verdict(fase)
            reason = trig.last_stop_reason

        print(f"{db:>9.2f}s  {str(round(t_stop,2)) if t_stop else '-':>8s}  "
              f"{fase:>15s}  {reason:>16s}  {status:>15s}")
        results.append((db, t_stop, fase, status, reason))
    return results


# ---------------------------------------------------------------------
# STEP 3: simulasi realistis dari feeder ON (+ logging state lengkap)
# ---------------------------------------------------------------------
def simulate_trigger_from_feeder_on(video_path, phases, feeder_on_phase, decay_ratio, min_peak, target_name,
                                     debounce_seconds=2.5, startup_timeout_seconds=15.0, alpha=0.15,
                                     **trigger_kwargs):
    fps = get_video_fps(video_path)
    raw = compute_motion_energy(video_path)
    verdict = _make_verdict_fn(phases, target_name)

    t_feeder_on = next(t0 for name, t0, t1 in phases if name == feeder_on_phase)
    start_frame = int(t_feeder_on * fps)

    trigger = FeederTriggerAdaptive(
        decay_ratio=decay_ratio, min_peak=min_peak, alpha=alpha,
        debounce_frames=max(1, round(debounce_seconds * fps)),
        startup_timeout_frames=max(1, round(startup_timeout_seconds * fps)),
        **trigger_kwargs,
    )

    for i, s in enumerate(raw[start_frame:]):
        t_abs = t_feeder_on + i / fps
        if trigger.update(s) == "STOP":
            fase = _phase_at(phases, t_abs)
            print(f"STOP terpicu di: {t_abs:.2f}s (relatif thd feeder ON: {i/fps:.2f}s)")
            print(f"Fase saat STOP  : {fase}")
            print(f"Alasan STOP     : {trigger.last_stop_reason}")
            print(f"Verdict         : {verdict(fase)}")
            print(f"State lengkap   : {trigger.state()}")
            return t_abs

    print(f"STOP tidak pernah terpicu sepanjang video sejak feeder ON di {t_feeder_on:.1f}s")
    return None


if __name__ == "__main__":
    VIDEO_PATH = r"D:\FOLDER DOWNLOAD\lele vid\videos\9min_720p.mp4"

    PHASES = [
        ("calm_start",    0, 120),
        ("makan",         121, 300),
        ("ngabisin_sisa", 301, 420),
        ("calm_end",      421, 541),
    ]

    print("=== STEP 1: Analisis & kalibrasi dari video berfase ===")
    stats, decay_ratio, target_phase, makan_phase = analyze_phased_video(VIDEO_PATH, PHASES)

    min_peak = stats["calm_start"]["max"] * 1.3
    print(f"\nmin_peak (dari fase calm_start) = {min_peak:.1f}")

    print("\n=== STEP 2 (FIXED): sweep debounce, dievaluasi sejak feeder ON ===")
    verify_trigger_lands_in_target_phase(
        VIDEO_PATH, PHASES, decay_ratio, min_peak, target_phase,
        feeder_on_phase=makan_phase,
    )

    print("\n=== STEP 3: Simulasi realistis -- pilih debounce hasil STEP 2 di sini ===")
    # 4.0s dipilih dari hasil sweep STEP 2 di video 9min_720p.mp4: nilai pertama
    # yang konsisten landing di 'ngabisin_sisa' (debounce <4.0s masih ketarik
    # osilasi transient di akhir fase 'makan', lihat catatan hasil sweep).
    simulate_trigger_from_feeder_on(
        VIDEO_PATH, PHASES, feeder_on_phase=makan_phase,
        decay_ratio=decay_ratio, min_peak=min_peak, target_name=target_phase,
        debounce_seconds=4.0,
    )
