"""Replay offline logika lanjut/stop (port 1:1 dari feeder_trigger.dart baru).
Pakai: python3 replay_trigger.py  <folder berisi catfish-trial-diag_*.json>
"""
import json, glob, math, sys, statistics
from dataclasses import dataclass

@dataclass
class P:
    tau: float = 7.0
    median_window: int = 5
    spike: float = 3.0
    win_start: float = 10.0
    win_end: float = 40.0
    ratio_ok: float = 0.65
    ratio_hard: float = 0.50
    strikes_to_stop: int = 2
    snr_min: float = 2.0
    base_skip: float = 10.0
    base_max: float = 180.0
    base_min: float = 20.0
    base_stat: str = 'median'   # median | mean
    net: bool = True            # kurangi baseline dari respon

class Trig:
    def __init__(s, p: P, dry=True):
        s.p = p; s.dry = dry; s.reset()
    def reset(s):
        s.buf = []; s.ema = None; s.last_t = None; s.t_start = None
        s.base_samples = []   # (t, ema) sebelum pulsa pertama
        s.base = None; s.base_valid = False
        s.round = 0; s.ref = 0.0; s.strikes = 0
        s.pulse_end = None; s.win_sum = 0.0; s.win_n = 0; s.evaluated = True
        s.pending = None; s.decisions = []
        s.stopped = False; s.stop_reason = None; s.would_stop = None
    def _filter(s, x):
        s.buf.append(x); s.buf = s.buf[-s.p.median_window:]
        if len(s.buf) < 3: return x
        m = statistics.median(s.buf)
        return m if (m > 0 and x > s.p.spike * m) else x
    def begin_round(s, t):
        if not s.evaluated: s._finish(t)
        if s.round == 0: s._freeze_baseline()
        s.round += 1; s.pulse_end = None; s.evaluated = True
    def pulse_ended(s, t):
        if s.round == 0:
            s._freeze_baseline(); s.round = 1
        s.pulse_end = t; s.win_sum = 0.0; s.win_n = 0; s.evaluated = False
    def _freeze_baseline(s):
        if s.base is not None or s.t_start is None: return
        pts = [(t, e) for t, e in s.base_samples if t >= s.t_start + s.p.base_skip]
        if pts:
            t_end = pts[-1][0]
            pts = [(t, e) for t, e in pts if t >= t_end - s.p.base_max]
        if pts and (pts[-1][0] - pts[0][0]) >= s.p.base_min and len(pts) >= 30:
            v = [e for _, e in pts]
            s.base = statistics.median(v) if s.p.base_stat == 'median' else sum(v) / len(v)
            s.base_valid = s.base > 0
        else:
            s.base = None; s.base_valid = False
    def update(s, raw, t):
        if s.stopped: return 'STOP'
        if s.t_start is None: s.t_start = t
        f = s._filter(raw)
        if s.ema is None or s.last_t is None: s.ema = f
        else:
            dt = min(max(t - s.last_t, 0.02), 10.0)
            a = 1 - math.exp(-dt / s.p.tau); s.ema = a * f + (1 - a) * s.ema
        s.last_t = t
        if s.round == 0: s.base_samples.append((t, s.ema))
        if s.pulse_end is not None and not s.evaluated:
            el = t - s.pulse_end
            if el >= s.p.win_start:
                if el <= s.p.win_end: s.win_sum += s.ema; s.win_n += 1
                else: s._finish(t)
        if s.pending and s.pending['action'] == 'STOP':
            if s.dry:
                if s.would_stop is None: s.would_stop = s.pending['verdict']
            else:
                s.stopped = True; s.stop_reason = s.pending['verdict']; return 'STOP'
        return None
    def _finish(s, t):
        s.evaluated = True
        p = s.p
        d = dict(round=s.round, win_mean=None, resp=None, ref=s.ref, ratio=None, strikes=s.strikes,
                 verdict='', action='NONE', base=s.base)
        if s.win_n == 0:
            d['verdict'] = 'no_data'
        elif not s.base_valid and p.net:
            d['win_mean'] = s.win_sum / s.win_n
            d['verdict'] = 'no_baseline'
        else:
            wm = s.win_sum / s.win_n
            resp = max(0.0, wm - s.base) if (p.net and s.base_valid) else wm
            d['win_mean'] = wm; d['resp'] = resp
            floor = (p.snr_min * s.base) if s.base_valid else 0.0
            if s.ref <= 0:
                if s.base_valid and wm < floor: d['verdict'] = 'weak_signal'
                elif resp <= 0: d['verdict'] = 'weak_signal'
                else:
                    s.ref = resp; d['ref'] = resp; d['ratio'] = 1.0; d['verdict'] = 'anchor'; d['action'] = 'LANJUT'
            else:
                ratio = resp / s.ref; d['ratio'] = ratio
                if ratio >= p.ratio_ok:
                    s.strikes = 0; s.ref = max(s.ref, resp); d['verdict'] = 'active'; d['action'] = 'LANJUT'
                elif ratio < p.ratio_hard:
                    d['verdict'] = 'sated_hard'; d['action'] = 'STOP'
                else:
                    s.strikes += 1
                    if s.strikes >= p.strikes_to_stop: d['verdict'] = 'sated'; d['action'] = 'STOP'
                    else: d['verdict'] = 'weak'; d['action'] = 'LANJUT'
                d['strikes'] = s.strikes
        s.decisions.append(d); s.pending = d

def load(folder):
    out = {}
    for i, j in enumerate(sorted(glob.glob(folder + '/catfish-trial-diag*.json')), 1):
        J = json.load(open(j)); J.sort(key=lambda x: x['created_at'])
        T = []; S1 = []; ev = []
        for x in J:
            d = x['diag']; t0 = d.get('t0')
            if t0 is None: continue
            for n, dt in enumerate(d['dt']): T.append((t0 + dt) / 1000.0); S1.append(max(0, d['s1'][n]))
            ev += d.get('ev', [])
        order = sorted(range(len(T)), key=lambda k: T[k]); seen = set(); T2 = []; S2 = []
        for k in order:
            if T[k] in seen: continue
            seen.add(T[k]); T2.append(T[k]); S2.append(S1[k])
        out[i] = (T2, S2, ev)
    return out

def run(T, S, ev, p, dry=True):
    tr = Trig(p, dry)
    on = sorted(e['t'] / 1000 for e in ev if e['e'] == 'pulse_on')
    off = sorted(e['t'] / 1000 for e in ev if e['e'] == 'pulse_off')
    marks = sorted([(a, 'on') for a in on] + [(b, 'off') for b in off]); mi = 0
    for t, x in zip(T, S):
        while mi < len(marks) and marks[mi][0] <= t:
            (tr.begin_round if marks[mi][1] == 'on' else tr.pulse_ended)(marks[mi][0]); mi += 1
        tr.update(x, t)
    if not tr.evaluated: tr._finish(T[-1])
    return tr

FIRST_SISA = {1: 6, 2: 5, 3: 3}
if __name__ == '__main__':
    folder = sys.argv[1] if len(sys.argv) > 1 else '.'
    data = load(folder)
    p = P()
    for i, (T, S, ev) in data.items():
        tr = run(T, S, ev, p)
        print(f'\n== sesi {i}  baseline={tr.base and round(tr.base)} valid={tr.base_valid}')
        for d in tr.decisions:
            f = lambda v: '-' if v is None else round(v, 2) if isinstance(v, float) and abs(v) < 10 else round(v) if v is not None else '-'
            print(f"  r{d['round']}: win={f(d['win_mean'])} resp={f(d['resp'])} ref={f(d['ref'])} ratio={f(d['ratio'])} strikes={d['strikes']} -> {d['verdict']:11s} {d['action']}")
