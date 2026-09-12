#!/usr/bin/env python3
"""
Vela Original Notification Sound Generator
Synthesizes quiet, professional developer-tool notifications using Python standard library (wave, math, struct).
No external audio samples, downloaded files, or third-party packages required.

Outputs 16-bit mono 44.1 kHz WAV files to Sources/VelaApp/Resources/Sounds/:
  - vela-approval.wav: Subtle two-note invitation chime (~0.28s, peak <= 0.32)
  - vela-completed.wav: Gentle resolving major tone (~0.32s, peak <= 0.28)
  - vela-error.wav: Soft lower double pulse (~0.35s, peak <= 0.26)
"""

import os
import math
import struct
import wave

SAMPLE_RATE = 44100

def ensure_dir(path):
    os.makedirs(path, exist_ok=True)

def write_wav(filepath, samples):
    ensure_dir(os.path.dirname(filepath))
    with wave.open(filepath, 'w') as wav:
        wav.setnchannels(1)        # mono
        wav.setsampwidth(2)        # 16-bit
        wav.setframerate(SAMPLE_RATE)
        packed = bytearray()
        for s in samples:
            # Bound peak amplitude strictly
            clamped = max(-0.32, min(0.32, s))
            val = int(clamped * 32767.0)
            packed.extend(struct.pack('<h', val))
        wav.writeframes(packed)
    print(f"Generated: {filepath} ({len(samples)} samples, {len(samples)/SAMPLE_RATE:.3f}s)")

def smooth_envelope(t, duration, attack=0.012, release=0.08):
    if t < attack:
        return 0.5 * (1.0 - math.cos(math.pi * t / attack))
    elif t > (duration - release):
        remain = duration - t
        if remain <= 0:
            return 0.0
        return 0.5 * (1.0 - math.cos(math.pi * remain / release))
    return 1.0

def generate_approval():
    # Subtle two-note invitation: Note 1 = 659.25 Hz (E5, 0.11s), Note 2 = 880.0 Hz (A5, 0.17s)
    duration = 0.28
    total_samples = int(SAMPLE_RATE * duration)
    samples = []

    t1 = 0.11
    f1 = 659.25
    f2 = 880.0

    for i in range(total_samples):
        t = i / SAMPLE_RATE
        if t < t1:
            env = smooth_envelope(t, t1, attack=0.008, release=0.04)
            val = 0.24 * math.sin(2.0 * math.pi * f1 * t)
            val += 0.04 * math.sin(4.0 * math.pi * f1 * t) # gentle 2nd harmonic
        else:
            t_rel = t - t1
            dur2 = duration - t1
            env = smooth_envelope(t_rel, dur2, attack=0.006, release=0.10)
            val = 0.28 * math.sin(2.0 * math.pi * f2 * t_rel)
            val += 0.03 * math.sin(4.0 * math.pi * f2 * t_rel)
        samples.append(val * env)
    return samples

def generate_completed():
    # Gentle resolving tone: Root C5 (523.25 Hz) blending into G5 (783.99 Hz) with soft warm decay
    duration = 0.32
    total_samples = int(SAMPLE_RATE * duration)
    samples = []

    f1 = 523.25
    f2 = 783.99
    f3 = 1046.50 # soft bell shimmer

    for i in range(total_samples):
        t = i / SAMPLE_RATE
        env = smooth_envelope(t, duration, attack=0.010, release=0.16)
        # Gentle morphing harmonics
        w1 = math.exp(-t * 8.0)
        w2 = math.exp(-t * 5.0)
        w3 = math.exp(-t * 12.0)
        val = 0.16 * math.sin(2.0 * math.pi * f1 * t) * w1
        val += 0.14 * math.sin(2.0 * math.pi * f2 * t) * w2
        val += 0.03 * math.sin(2.0 * math.pi * f3 * t) * w3
        samples.append(val * env)
    return samples

def generate_error():
    # Soft lower double pulse: 240 Hz and 210 Hz, non-alarming warm feedback
    duration = 0.36
    total_samples = int(SAMPLE_RATE * duration)
    samples = []

    pulse_dur = 0.14
    gap = 0.04

    for i in range(total_samples):
        t = i / SAMPLE_RATE
        if t < pulse_dur:
            env = smooth_envelope(t, pulse_dur, attack=0.012, release=0.05)
            val = 0.22 * math.sin(2.0 * math.pi * 240.0 * t)
            val += 0.04 * math.sin(2.0 * math.pi * 480.0 * t)
            samples.append(val * env)
        elif t < pulse_dur + gap:
            samples.append(0.0)
        else:
            t2 = t - (pulse_dur + gap)
            p2_dur = duration - (pulse_dur + gap)
            env = smooth_envelope(t2, p2_dur, attack=0.012, release=0.07)
            val = 0.20 * math.sin(2.0 * math.pi * 210.0 * t2)
            val += 0.03 * math.sin(2.0 * math.pi * 420.0 * t2)
            samples.append(val * env)
    return samples

def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    # Target: Sources/VelaApp/Resources/Sounds
    target_dir = os.path.abspath(os.path.join(script_dir, "..", "Sounds"))

    print(f"Synthesizing Vela sound effects to {target_dir}...")
    write_wav(os.path.join(target_dir, "vela-approval.wav"), generate_approval())
    write_wav(os.path.join(target_dir, "vela-completed.wav"), generate_completed())
    write_wav(os.path.join(target_dir, "vela-error.wav"), generate_error())
    print("Sound generation complete.")

if __name__ == "__main__":
    main()
