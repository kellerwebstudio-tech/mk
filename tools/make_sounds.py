#!/usr/bin/env python3
"""Generates original placeholder sound effects (WAV, 44.1 kHz mono) for Delivery Dash City.

Upload the files in assets/audio/ through the Roblox Creator Dashboard and paste the resulting
rbxassetid:// ids into src/shared/Config/AudioConfig.luau (same keys). Everything here is
synthesized from scratch (no samples), so there are no licensing concerns.
"""
import math, os, struct, wave
import numpy as np

SR = 44100
OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "audio")

def write(name, data, gain=0.8):
    data = np.asarray(data, dtype=np.float64)
    peak = np.max(np.abs(data)) or 1.0
    data = data / peak * gain
    pcm = (np.clip(data, -1, 1) * 32767).astype(np.int16)
    path = os.path.join(OUT, name)
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    return path

def t(seconds):
    return np.arange(int(SR * seconds)) / SR

def env(n, attack=0.005, release=0.1):
    e = np.ones(n)
    a = int(SR * attack); r = int(SR * release)
    if a: e[:a] = np.linspace(0, 1, a)
    if r: e[-r:] = np.linspace(1, 0, r)
    return e

def tone(freq, seconds, kind="sine", attack=0.005, release=0.1):
    x = t(seconds)
    if kind == "sine": y = np.sin(2 * math.pi * freq * x)
    elif kind == "square": y = np.sign(np.sin(2 * math.pi * freq * x))
    elif kind == "saw": y = 2 * ((x * freq) % 1) - 1
    elif kind == "tri": y = 2 * np.abs(2 * ((x * freq) % 1) - 1) - 1
    else: raise ValueError(kind)
    return y * env(len(x), attack, release)

def noise(seconds, attack=0.005, release=0.1, seed=1):
    rng = np.random.default_rng(seed)
    y = rng.uniform(-1, 1, int(SR * seconds))
    return y * env(len(y), attack, release)

def lowpass(y, alpha):
    out = np.zeros_like(y); acc = 0.0
    for i, v in enumerate(y):
        acc += alpha * (v - acc); out[i] = acc
    return out

def concat(*parts):
    return np.concatenate(parts)

def silence(seconds):
    return np.zeros(int(SR * seconds))

os.makedirs(OUT, exist_ok=True)
made = []

# UI click: short filtered noise tick
made.append(write("ui_click.wav", lowpass(noise(0.05, 0.001, 0.04), 0.3)))
# Order accepted: rising two-note ping
made.append(write("order_accepted.wav", concat(tone(660, 0.09, "sine", 0.003, 0.05), tone(990, 0.16, "sine", 0.003, 0.12))))
# Pickup: zip + soft thump
made.append(write("pickup.wav", concat(lowpass(noise(0.08, 0.001, 0.06, 3), 0.5), tone(180, 0.12, "sine", 0.002, 0.1))))
# Doorbell: classic two-tone ding-dong
made.append(write("doorbell.wav", concat(tone(784, 0.35, "sine", 0.004, 0.3), tone(659, 0.55, "sine", 0.004, 0.5))))
# Payment: cash-register style triad arpeggio
made.append(write("payment.wav", concat(tone(523, 0.08, "tri", 0.002, 0.05), tone(659, 0.08, "tri", 0.002, 0.05), tone(784, 0.08, "tri", 0.002, 0.05), tone(1047, 0.3, "tri", 0.002, 0.25))))
# New record: fanfare
made.append(write("new_record.wav", concat(tone(784, 0.12, "square", 0.002, 0.05) * 0.4, tone(988, 0.12, "square", 0.002, 0.05) * 0.4, tone(1175, 0.12, "square", 0.002, 0.05) * 0.4, tone(1568, 0.45, "square", 0.002, 0.4) * 0.4)))
# Error: low buzz
made.append(write("error.wav", tone(140, 0.25, "square", 0.003, 0.2) * 0.5 + tone(147, 0.25, "square", 0.003, 0.2) * 0.5))
# Purchase: coin-like double ping
made.append(write("purchase.wav", concat(tone(1319, 0.07, "sine", 0.002, 0.04), silence(0.02), tone(1760, 0.2, "sine", 0.002, 0.18))))
# Notify: soft blip
made.append(write("notify.wav", tone(880, 0.12, "sine", 0.003, 0.1)))
# Bell: bicycle bell (two quick metallic partials)
bell = tone(2200, 0.4, "sine", 0.001, 0.38) * 0.6 + tone(3300, 0.4, "sine", 0.001, 0.3) * 0.3 + tone(4400, 0.4, "sine", 0.001, 0.2) * 0.1
made.append(write("bell.wav", concat(bell, silence(0.05), bell)))
# Horn: van horn chord
made.append(write("horn.wav", tone(392, 0.5, "saw", 0.01, 0.1) * 0.5 + tone(494, 0.5, "saw", 0.01, 0.1) * 0.5))
# Brake: filtered noise squeal with pitch drop
x = t(0.5)
sweep = np.sin(2 * math.pi * (1800 - 900 * x / 0.5) * x) * env(len(x), 0.01, 0.3)
made.append(write("brake.wav", sweep * 0.5 + lowpass(noise(0.5, 0.01, 0.3, 5), 0.2) * 0.5))
# Bump: low thud
made.append(write("bump.wav", tone(90, 0.18, "sine", 0.001, 0.16) + lowpass(noise(0.18, 0.001, 0.08, 7), 0.15) * 0.4))
# Mount: cloth rustle + click
made.append(write("mount.wav", concat(lowpass(noise(0.15, 0.01, 0.12, 9), 0.25), lowpass(noise(0.03, 0.001, 0.02, 11), 0.5))))
# Engine loops (seamless): scooter (higher), van (lower); amplitude-modulated saw + sub
def engine_loop(base, seconds=2.0, seed=13):
    x = t(seconds)
    cycles = round(base * seconds)  # integer cycles -> seamless loop
    f = cycles / seconds
    y = tone(f, seconds, "saw", 0, 0) * 0.5 + tone(f / 2, seconds, "sine", 0, 0) * 0.5
    y = lowpass(y, 0.08)
    wob = 1 + 0.05 * np.sin(2 * math.pi * 7 * x)
    return y * wob
made.append(write("scooter_engine_loop.wav", engine_loop(110), 0.6))
made.append(write("van_engine_loop.wav", engine_loop(55), 0.65))
# Bicycle chain tick loop (seamless 1 s, 6 ticks)
y = silence(1.0)
for i in range(6):
    start = int(SR * i / 6)
    tick = lowpass(noise(0.02, 0.0005, 0.015, 20 + i), 0.6) * 0.7
    y[start:start + len(tick)] += tick
made.append(write("bicycle_chain_loop.wav", y, 0.5))
# Tire hum loop (seamless 1 s filtered noise)
made.append(write("bicycle_tires_loop.wav", lowpass(noise(1.0, 0, 0, 31), 0.05), 0.5))
# Ambience loops (4 s, seamless-ish by symmetric crossfade)
def ambience(seed, cutoff, seconds=4.0):
    y = lowpass(noise(seconds, 0, 0, seed), cutoff)
    n = len(y); f = int(SR * 0.3)
    ramp = np.linspace(0, 1, f)
    y[:f] = y[:f] * ramp + y[-f:] * (1 - ramp)
    return y[: n - f]
made.append(write("city_ambience_loop.wav", ambience(41, 0.03), 0.4))
made.append(write("restaurant_ambience_loop.wav", ambience(43, 0.06) + tone(60, 4.0 - 0.3, "sine", 0, 0) * 0.1, 0.4))
made.append(write("park_ambience_loop.wav", ambience(47, 0.02), 0.35))
made.append(write("industrial_ambience_loop.wav", ambience(53, 0.015) + tone(50, 4.0 - 0.3, "square", 0, 0) * 0.05, 0.4))

for p in made:
    print(os.path.relpath(p, os.path.join(os.path.dirname(__file__), "..")))
