"""Bande-son de la vidéo, synthétisée de zéro : libre de droits par construction.

Nappe lente en la mineur, basse douce et quelques notes de piano, calées sur
la durée de la vidéo. Dépend seulement de numpy.

    python music.py 33       écrit ../out/musique.wav (durée en secondes)
"""

import sys
import wave
from pathlib import Path

import numpy as np

SR = 44100
DURATION = float(sys.argv[1]) if len(sys.argv) > 1 else 33.0
N = int(SR * DURATION)
t = np.arange(N) / SR
rng = np.random.default_rng(3)


def hz(midi):
    return 440.0 * 2 ** ((midi - 69) / 12)


def lowpass(x, cutoff):
    spec = np.fft.rfft(x)
    f = np.fft.rfftfreq(len(x), 1 / SR)
    return np.fft.irfft(spec / np.sqrt(1 + (f / cutoff) ** 4), len(x))


def reverb(x, seconds=3.5, mix=0.4):
    n = int(seconds * SR)
    ir = lowpass(rng.standard_normal(n) * np.exp(-np.arange(n) / (SR * seconds / 6)), 4500)
    ir /= np.sqrt(np.sum(ir**2))
    size = 1 << int(np.ceil(np.log2(len(x) + n)))
    wet = np.fft.irfft(np.fft.rfft(x, size) * np.fft.rfft(ir, size), size)[: len(x)]
    return (1 - mix) * x + mix * wet


# La mineur, fa, do, sol : un accord toutes les 4 secondes.
CHORDS = [[57, 60, 64], [53, 57, 60], [48, 52, 55], [55, 59, 62]]
LEN = 4.0

pad = np.zeros(N)
bass = np.zeros(N)
keys = np.zeros(N)
for k in range(int(DURATION / LEN) + 1):
    start = k * LEN
    notes = CHORDS[k % len(CHORDS)]
    i0, i1 = int(start * SR), min(N, int((start + LEN + 1.5) * SR))
    x = t[i0:i1] - start
    env = np.minimum(1, x / 1.2) * np.clip((LEN + 1.5 - x) / 1.5, 0, 1)
    for m in notes:
        for detune in (-0.06, 0.06):
            f = hz(m + detune)
            pad[i0:i1] += sum(np.sin(2 * np.pi * f * h * x + h) / h**1.8 for h in range(1, 6)) * env * 0.06
    bass[i0:i1] += np.sin(2 * np.pi * hz(notes[0] - 24) * x) * env * 0.22
    if start >= 4:
        for j, m in enumerate([notes[2] + 12, notes[1] + 12, notes[0] + 24]):
            s = start + j * 1.0
            a, b = int(s * SR), min(N, int((s + 3) * SR))
            y = t[a:b] - s
            keys[a:b] += (np.sin(2 * np.pi * hz(m) * y) + 0.25 * np.sin(4 * np.pi * hz(m) * y)) * np.exp(-y * 2.2) * 0.07

mix = lowpass(pad, 1600) + bass + keys
left = reverb(mix + 0.02 * keys)
right = reverb(mix - 0.02 * keys)
master = np.minimum(1, t / 2.0) * np.clip((DURATION - t) / 3.0, 0, 1)
stereo = np.stack([left, right], axis=1) * master[:, None]
stereo *= 0.6 / np.max(np.abs(stereo))

out = Path(__file__).resolve().parent.parent / "out" / "musique.wav"
out.parent.mkdir(exist_ok=True)
with wave.open(str(out), "wb") as w:
    w.setnchannels(2)
    w.setsampwidth(2)
    w.setframerate(SR)
    w.writeframes((stereo * 32767).astype("<i2").tobytes())
print(out)
