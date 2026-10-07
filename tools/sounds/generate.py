#!/usr/bin/env python3
"""Generates Sotto's sounds (original, synthesized, dedicated to the public
domain under CC0). Deterministic: running it again gives identical files.

    python3 tools/sounds/generate.py app/assets/sounds

ringtone.wav  incoming call, looped: two soft bell rings, then a pause (4 s)
ringback.wav  outgoing call while the other device rings, looped (4 s)
knock.wav     a guest knocked (two-note chime)
answered.wav  a call was answered automatically (three rising notes)
"""
import math
import struct
import sys
import wave
from pathlib import Path

RATE = 22050


def bell(freq, duration, volume=0.35, decay=3.5):
    """A soft bell: a sine with a gentle octave partial and exponential decay."""
    samples = []
    for i in range(int(RATE * duration)):
        t = i / RATE
        attack = min(1.0, t / 0.01)
        env = attack * math.exp(-decay * t)
        value = math.sin(2 * math.pi * freq * t) + 0.25 * math.sin(4 * math.pi * freq * t)
        samples.append(volume * env * value / 1.25)
    return samples


def tone(freqs, duration, volume=0.18):
    """A steady tone (sum of sines) with 20 ms fades."""
    samples = []
    n = int(RATE * duration)
    fade = int(RATE * 0.02)
    for i in range(n):
        t = i / RATE
        env = min(1.0, i / fade, (n - i) / fade)
        value = sum(math.sin(2 * math.pi * f * t) for f in freqs) / len(freqs)
        samples.append(volume * env * value)
    return samples


def silence(duration):
    return [0.0] * int(RATE * duration)


def mix_at(base, sound, offset):
    start = int(RATE * offset)
    out = base + [0.0] * max(0, start + len(sound) - len(base))
    for i, v in enumerate(sound):
        out[start + i] += v
    return out


def write(path, samples):
    with wave.open(str(path), 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b''.join(
            struct.pack('<h', int(max(-1.0, min(1.0, s)) * 32767)) for s in samples
        ))


def main(out):
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)

    ring = silence(4.0)
    for offset in (0.0, 0.45, 1.2, 1.65):
        ring = mix_at(ring, bell(784 if offset in (0.0, 1.2) else 988, 0.9), offset)
    write(out / 'ringtone.wav', ring[: int(RATE * 4.0)])

    write(out / 'ringback.wav', tone([425], 1.0) + silence(3.0))

    knock = mix_at(bell(1047, 0.8, volume=0.3), bell(1319, 0.9, volume=0.3), 0.18)
    write(out / 'knock.wav', knock)

    answered = silence(0.0)
    for offset, freq in ((0.0, 784), (0.12, 988), (0.24, 1175)):
        answered = mix_at(answered, bell(freq, 0.7, volume=0.28, decay=5), offset)
    write(out / 'answered.wav', answered)


if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else 'app/assets/sounds')
