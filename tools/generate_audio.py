"""Synthesises every sound and music track the game ships with.

Nothing here is sampled or downloaded: each sound is built from noise, sines and filters, so
the audio has no licence to track and can be regenerated, retuned or restyled by editing numbers
in one file. That matters for a project whose other assets are original or procedural too.

The output is Ogg Vorbis under assets/audio/. Loops are made seamless by construction rather
than by trimming: anything that would ring past the end of a loop is wrapped round and mixed
into its start, the way a circular buffer would play it, so the join is inaudible.

Run from the project root:

    python tools/generate_audio.py

Requires numpy, scipy and soundfile (with libsndfile's Vorbis support). Every generator is
seeded, so a rerun reproduces the same files unless a number here changes.
"""

from __future__ import annotations

import os
from typing import Callable

import numpy as np
import soundfile as sf
from scipy import signal

RATE = 44100
OUT = os.path.join(os.path.dirname(__file__), "..", "assets", "audio")


# --------------------------------------------------------------------------------------------
# Building blocks
# --------------------------------------------------------------------------------------------


def seconds(duration: float) -> int:
    return int(round(duration * RATE))


def noise(count: int, rng: np.random.Generator) -> np.ndarray:
    return rng.standard_normal(count)


def pink(count: int, rng: np.random.Generator) -> np.ndarray:
    """Pink noise by spectral shaping: equal energy per octave, which reads as surf, not hiss."""
    spectrum = np.fft.rfft(rng.standard_normal(count))
    freqs = np.fft.rfftfreq(count, 1.0 / RATE)
    freqs[0] = freqs[1]
    spectrum /= np.sqrt(freqs)
    out = np.fft.irfft(spectrum, count)
    return out / (np.max(np.abs(out)) + 1e-9)


def brown(count: int, rng: np.random.Generator) -> np.ndarray:
    spectrum = np.fft.rfft(rng.standard_normal(count))
    freqs = np.fft.rfftfreq(count, 1.0 / RATE)
    freqs[0] = freqs[1]
    spectrum /= freqs
    out = np.fft.irfft(spectrum, count)
    return out / (np.max(np.abs(out)) + 1e-9)


def band(x: np.ndarray, low: float | None, high: float | None, order: int = 4) -> np.ndarray:
    if low and high:
        sos = signal.butter(order, [low, high], btype="band", fs=RATE, output="sos")
    elif low:
        sos = signal.butter(order, low, btype="high", fs=RATE, output="sos")
    else:
        sos = signal.butter(order, high, btype="low", fs=RATE, output="sos")
    return signal.sosfilt(sos, x)


def envelope(count: int, attack: float, decay: float, curve: float = 4.0) -> np.ndarray:
    """A fast-attack, exponential-decay envelope over count samples."""
    t = np.arange(count) / RATE
    rise = np.clip(t / max(attack, 1e-4), 0.0, 1.0)
    fall = np.exp(-np.maximum(t - attack, 0.0) * curve / max(decay, 1e-4))
    return rise * fall


def tail_fade(count: int, fraction: float = 0.3) -> np.ndarray:
    """Ones, easing to exactly zero over the last fraction: a burst must end in silence, or its
    cut is heard as a click and seen as a hard edge in a spectrogram."""
    out = np.ones(count)
    n = max(1, int(count * fraction))
    out[-n:] = np.cos(np.linspace(0.0, np.pi / 2.0, n)) ** 2
    return out


def adsr(count: int, attack: float, release: float) -> np.ndarray:
    t = np.arange(count) / RATE
    total = count / RATE
    rise = np.clip(t / max(attack, 1e-4), 0.0, 1.0)
    fall = np.clip((total - t) / max(release, 1e-4), 0.0, 1.0)
    return np.minimum(rise, fall)


def midi(note: float) -> float:
    return 440.0 * 2.0 ** ((note - 69.0) / 12.0)


def normalise(x: np.ndarray, peak_db: float) -> np.ndarray:
    peak = np.max(np.abs(x)) + 1e-9
    return x / peak * (10.0 ** (peak_db / 20.0))


def mix_at(target: np.ndarray, sound: np.ndarray, start: int, gain: float = 1.0,
           wrap: bool = False) -> None:
    """Adds sound into target at start. With wrap, anything past the end folds to the start."""
    length = target.shape[0]
    end = start + sound.shape[0]
    if not wrap:
        end = min(end, length)
        if start < length:
            target[start:end] += sound[: end - start] * gain
        return
    index = start % length
    remaining = sound
    while remaining.shape[0] > 0:
        take = min(remaining.shape[0], length - index)
        target[index:index + take] += remaining[:take] * gain
        remaining = remaining[take:]
        index = 0


def loop_crossfade(x: np.ndarray, fade: float) -> np.ndarray:
    """Folds the last fade seconds over the start with an equal-power crossfade."""
    n = seconds(fade)
    body = x[:-n].copy()
    tail = x[-n:]
    t = np.linspace(0.0, 1.0, n)
    fade_in = np.sin(t * np.pi / 2.0)
    fade_out = np.cos(t * np.pi / 2.0)
    if body.ndim == 2:
        fade_in = fade_in[:, None]
        fade_out = fade_out[:, None]
    body[:n] = body[:n] * fade_in + tail * fade_out
    return body


def reverb_ir(duration: float, rng: np.random.Generator, stereo: bool = True,
              damping: float = 3500.0) -> np.ndarray:
    """A synthetic hall: exponentially decaying, progressively darker noise."""
    n = seconds(duration)
    t = np.arange(n) / RATE
    channels = []
    for _ in range(2 if stereo else 1):
        tail = rng.standard_normal(n) * np.exp(-t * 6.9 / duration)
        tail = band(tail, None, damping, order=2)
        tail[: seconds(0.012)] *= np.linspace(0.0, 1.0, seconds(0.012))
        channels.append(tail / np.sqrt(np.sum(tail ** 2)))
    return np.stack(channels, axis=1) if stereo else channels[0]


def convolve_wrapped(dry: np.ndarray, ir: np.ndarray) -> np.ndarray:
    """Convolves a loop with an impulse response, wrapping the tail so the loop stays seamless."""
    length = dry.shape[0]
    out = np.zeros((length, ir.shape[1]))
    for channel in range(ir.shape[1]):
        source = dry[:, channel] if dry.ndim == 2 else dry
        wet = signal.fftconvolve(source, ir[:, channel])
        folded = np.zeros(length)
        mix_at(folded, wet, 0, wrap=True)
        out[:, channel] = folded
    return out


def write(name: str, data: np.ndarray) -> None:
    path = os.path.join(OUT, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    clipped = np.clip(data, -1.0, 1.0).astype(np.float32)
    channels = 1 if clipped.ndim == 1 else clipped.shape[1]
    # Written in blocks: libsndfile's Vorbis encoder dies without a word on one large write — a
    # 53 s stereo track came out as a 4 KiB stub and the process simply stopped.
    with sf.SoundFile(path, "w", RATE, channels, format="OGG", subtype="VORBIS") as file:
        for start in range(0, clipped.shape[0], 16384):
            file.write(clipped[start:start + 16384])
    print(f"wrote {name:34s} {clipped.shape[0] / RATE:6.2f} s  "
          f"{'stereo' if clipped.ndim == 2 else 'mono'}  {os.path.getsize(path) // 1024} KiB")


# --------------------------------------------------------------------------------------------
# Instruments
# --------------------------------------------------------------------------------------------


def marimba(freq: float, duration: float, velocity: float = 1.0) -> np.ndarray:
    """A mallet: the tuned bar's fundamental plus its characteristic 4x and 10x partials."""
    n = seconds(duration)
    t = np.arange(n) / RATE
    out = np.zeros(n)
    for ratio, gain, decay in ((1.0, 1.0, 1.1), (3.93, 0.28, 0.25), (9.2, 0.08, 0.08)):
        if freq * ratio > RATE * 0.45:
            continue
        out += np.sin(2 * np.pi * freq * ratio * t) * gain * np.exp(-t / decay)
    click = np.exp(-t / 0.002) * np.sin(2 * np.pi * freq * 6.0 * t) * 0.15
    out += click
    out *= np.clip(t / 0.002, 0.0, 1.0)
    return out * velocity


def bell(freq: float, duration: float, velocity: float = 1.0) -> np.ndarray:
    """A small bell by FM synthesis: an inharmonic ratio and a decaying modulation index."""
    n = seconds(duration)
    t = np.arange(n) / RATE
    index = 3.2 * np.exp(-t / 0.35)
    modulator = np.sin(2 * np.pi * freq * 1.4 * t) * index
    out = np.sin(2 * np.pi * freq * t + modulator) * np.exp(-t / (duration * 0.35))
    out *= np.clip(t / 0.003, 0.0, 1.0)
    return out * velocity


def pad(freqs: list[float], duration: float, rng: np.random.Generator,
        brightness: float = 1400.0) -> np.ndarray:
    """A warm pad: detuned saws per chord tone, low-passed, with a slow swell."""
    n = seconds(duration)
    t = np.arange(n) / RATE
    out = np.zeros((n, 2))
    for freq in freqs:
        for channel in range(2):
            for detune in (-0.07, 0.0, 0.08):
                cents = detune + rng.uniform(-0.02, 0.02)
                f = freq * 2.0 ** (cents / 12.0)
                phase = rng.uniform(0, 1)
                saw = 2.0 * ((f * t + phase) % 1.0) - 1.0
                out[:, channel] += saw
    for channel in range(2):
        out[:, channel] = band(out[:, channel], None, brightness, order=2)
    out *= adsr(n, min(0.9, duration * 0.3), min(1.2, duration * 0.4))[:, None]
    return out / (len(freqs) * 3.0)


def bass(freq: float, duration: float) -> np.ndarray:
    n = seconds(duration)
    t = np.arange(n) / RATE
    tone = np.sin(2 * np.pi * freq * t) + 0.25 * np.sin(4 * np.pi * freq * t)
    return tone * envelope(n, 0.01, duration * 0.9, 2.5)


def flute(freq: float, duration: float, rng: np.random.Generator) -> np.ndarray:
    """A soft breathy lead: a sine with gentle vibrato and a little filtered breath."""
    n = seconds(duration)
    t = np.arange(n) / RATE
    vibrato = 1.0 + 0.004 * np.sin(2 * np.pi * 5.2 * t) * np.clip((t - 0.15) / 0.3, 0.0, 1.0)
    phase = 2 * np.pi * np.cumsum(freq * vibrato) / RATE
    tone = np.sin(phase) + 0.12 * np.sin(2 * phase) + 0.05 * np.sin(3 * phase)
    breath = band(rng.standard_normal(n), freq * 1.5, min(freq * 6.0, 16000.0), order=2) * 0.05
    return (tone + breath) * adsr(n, 0.06, min(0.25, duration * 0.4))


def shaker(duration: float, rng: np.random.Generator) -> np.ndarray:
    n = seconds(duration)
    return band(rng.standard_normal(n), 5000.0, 14000.0, order=2) * envelope(n, 0.004, 0.05, 5.0)


def soft_kick() -> np.ndarray:
    n = seconds(0.35)
    t = np.arange(n) / RATE
    freq = 50.0 + 70.0 * np.exp(-t / 0.04)
    phase = 2 * np.pi * np.cumsum(freq) / RATE
    return np.sin(phase) * envelope(n, 0.003, 0.3, 5.0)


# --------------------------------------------------------------------------------------------
# Ambience
# --------------------------------------------------------------------------------------------


def ocean_loop() -> np.ndarray:
    """Open sea: a low rolling bed with swells, and waves lapping and breaking over it."""
    rng = np.random.default_rng(11)
    length = 24.0
    n = seconds(length + 4.0)
    t = np.arange(n) / RATE
    out = np.zeros((n, 2))
    for channel in range(2):
        bed = band(brown(n, rng), 40.0, 420.0, order=2)
        swell = 0.55 + 0.25 * np.sin(2 * np.pi * t / 7.3 + channel) + \
            0.2 * np.sin(2 * np.pi * t / 11.1 + 1.7 * channel)
        out[:, channel] = bed * swell * 0.9
    # Lapping and breaking: bursts of mid-high noise with a quick rise and a long fizz.
    time = 0.3
    while time < length + 3.0:
        count = seconds(rng.uniform(1.4, 3.2))
        burst = band(pink(count, rng), rng.uniform(350, 700), rng.uniform(2500, 6000), order=2)
        shape = envelope(count, rng.uniform(0.15, 0.45), count / RATE * 0.8, 3.0) * tail_fade(count)
        pan = rng.uniform(0.2, 0.8)
        gain = rng.uniform(0.15, 0.45)
        start = seconds(time)
        mix_at(out[:, 0], burst * shape, start, gain * (1.0 - pan) * 1.4)
        mix_at(out[:, 1], burst * shape, start, gain * pan * 1.4)
        time += rng.uniform(0.8, 2.6)
    return normalise(loop_crossfade(out, 4.0), -4.0)


def wind_loop() -> np.ndarray:
    """Wind over open water: a broadband rush whose colour and strength drift in gusts."""
    rng = np.random.default_rng(23)
    length = 18.0
    n = seconds(length + 3.0)
    t = np.arange(n) / RATE
    out = np.zeros((n, 2))
    gust = 0.6 + 0.25 * np.sin(2 * np.pi * t / 5.3) + 0.15 * np.sin(2 * np.pi * t / 2.1 + 1.0)
    for channel in range(2):
        rush = band(pink(n, rng), 120.0, 2200.0, order=2)
        # A faint whistle: a narrow band that slides slowly between 500 and 900 Hz.
        whistle = np.zeros(n)
        block = seconds(0.05)
        centre = 700.0
        source = rng.standard_normal(n)
        for start in range(0, n, block):
            centre += rng.uniform(-18, 18)
            centre = float(np.clip(centre, 500.0, 900.0))
            chunk = source[start:start + block]
            whistle[start:start + block] = band(chunk, centre * 0.97, centre * 1.03, order=1)
        out[:, channel] = (rush * 0.8 + whistle * 0.35) * gust
    return normalise(loop_crossfade(out, 3.0), -5.0)


def rain_loop() -> np.ndarray:
    """Rain on the sea: a hiss of distant drops and a scatter of near ones."""
    rng = np.random.default_rng(37)
    length = 14.0
    n = seconds(length + 2.0)
    out = np.zeros((n, 2))
    for channel in range(2):
        out[:, channel] = band(pink(n, rng), 1800.0, 12000.0, order=2) * 0.35
    drop_count = int(length * 90)
    for _ in range(drop_count):
        start = int(rng.integers(0, n - seconds(0.05)))
        freq = rng.uniform(2500, 7000)
        count = seconds(rng.uniform(0.008, 0.03))
        t = np.arange(count) / RATE
        drop = np.sin(2 * np.pi * freq * t) * np.exp(-t / 0.006)
        channel = int(rng.integers(0, 2))
        mix_at(out[:, channel], drop, start, rng.uniform(0.05, 0.3))
    return normalise(loop_crossfade(out, 2.0), -6.0)


def shore_loop() -> np.ndarray:
    """Surf on a beach: waves rushing in every few seconds and hissing back out."""
    rng = np.random.default_rng(41)
    length = 21.0
    n = seconds(length + 4.0)
    out = np.zeros((n, 2))
    time = 0.0
    while time < length + 3.0:
        count = seconds(rng.uniform(4.0, 6.0))
        t = np.arange(count) / RATE
        crash = band(pink(count, rng), 200.0, 5000.0, order=2)
        rush = np.clip(t / 0.8, 0.0, 1.0) * np.exp(-np.maximum(t - 0.8, 0.0) / 1.6)
        recede = band(pink(count, rng), 2500.0, 9000.0, order=2) * \
            np.clip((t - 1.5) / 1.0, 0.0, 1.0) * np.exp(-np.maximum(t - 2.5, 0.0) / 1.2) * 0.5
        wave = (crash * rush + recede) * tail_fade(count)
        pan = rng.uniform(0.3, 0.7)
        mix_at(out[:, 0], wave, seconds(time), (1.0 - pan) * 1.3)
        mix_at(out[:, 1], wave, seconds(time), pan * 1.3)
        time += rng.uniform(5.5, 7.5)
    for channel in range(2):
        out[:, channel] += band(brown(n, rng), 50.0, 300.0) * 0.3
    return normalise(loop_crossfade(out, 4.0), -4.0)


# --------------------------------------------------------------------------------------------
# Effects
# --------------------------------------------------------------------------------------------


def paddle(seed: int) -> np.ndarray:
    """One stroke: the blade's catch, the pull through the water, and a few bubbles."""
    rng = np.random.default_rng(seed)
    n = seconds(0.9)
    out = np.zeros(n)
    catch = band(noise(seconds(0.12), rng), 250.0, 2400.0) * envelope(seconds(0.12), 0.004, 0.08)
    mix_at(out, catch, 0, 1.0)
    pull_n = seconds(0.55)
    pull = band(pink(pull_n, rng), rng.uniform(380, 520), rng.uniform(1600, 2200), order=2)
    pull *= np.sin(np.linspace(0, np.pi, pull_n)) ** 1.5
    mix_at(out, pull, seconds(0.05), 0.8)
    for _ in range(int(rng.integers(3, 7))):
        count = seconds(rng.uniform(0.02, 0.05))
        t = np.arange(count) / RATE
        start_f = rng.uniform(350, 700)
        freq = start_f * (1.0 + 1.2 * t / (count / RATE))
        bubble = np.sin(2 * np.pi * np.cumsum(freq) / RATE) * np.exp(-t / 0.012)
        mix_at(out, bubble, seconds(rng.uniform(0.1, 0.5)), rng.uniform(0.1, 0.3))
    return normalise(out, -3.0)


def splash(size: float, seed: int) -> np.ndarray:
    """A body meeting the water: a thump, a spray of white noise, and droplets falling back."""
    rng = np.random.default_rng(seed)
    duration = 0.8 + size * 1.0
    n = seconds(duration)
    t = np.arange(n) / RATE
    thump_freq = 90.0 - 30.0 * size
    thump = np.sin(2 * np.pi * thump_freq * t) * np.exp(-t / (0.08 + 0.05 * size))
    body = band(pink(n, rng), 150.0, 7000.0, order=2) * envelope(n, 0.006, duration * 0.45, 3.0)
    out = thump * (0.6 + 0.4 * size) + body
    for _ in range(int(12 + 30 * size)):
        count = seconds(0.02)
        tt = np.arange(count) / RATE
        droplet = np.sin(2 * np.pi * rng.uniform(1500, 5000) * tt) * np.exp(-tt / 0.005)
        mix_at(out, droplet, seconds(rng.uniform(0.15, duration * 0.85)), rng.uniform(0.05, 0.2))
    return normalise(out, -2.0)


def wood_thud(seed: int) -> np.ndarray:
    """Weight landing on a timber deck: a damped low knock with a papery top."""
    rng = np.random.default_rng(seed)
    n = seconds(0.5)
    t = np.arange(n) / RATE
    out = np.zeros(n)
    for freq, gain, decay in ((95.0, 1.0, 0.09), (190.0, 0.5, 0.06), (420.0, 0.3, 0.03)):
        out += np.sin(2 * np.pi * freq * rng.uniform(0.97, 1.03) * t) * gain * np.exp(-t / decay)
    out += band(noise(n, rng), 600.0, 3000.0) * np.exp(-t / 0.015) * 0.6
    return normalise(out, -3.0)


def creak(seed: int) -> np.ndarray:
    """Timber and rope working in a swell: a slow, rough, wavering rasp."""
    rng = np.random.default_rng(seed)
    duration = rng.uniform(0.6, 1.1)
    n = seconds(duration)
    t = np.arange(n) / RATE
    # Stick-slip friction reads as a train of irregular pulses; their rate is the pitch.
    rate = 120.0 + 60.0 * np.sin(np.pi * t / duration) + rng.uniform(-20, 20)
    rate *= 1.0 + 0.08 * np.sin(2 * np.pi * 7.0 * t)
    phase = np.cumsum(rate) / RATE
    pulses = (np.diff(np.floor(phase), prepend=0.0) > 0).astype(float)
    pulses *= rng.uniform(0.5, 1.0, n)
    tone = band(pulses, 300.0, 2400.0, order=2)
    out = tone * np.sin(np.pi * np.clip(t / duration, 0.0, 1.0)) ** 0.7
    return normalise(out, -6.0)


def push_heave(seed: int) -> np.ndarray:
    """A shove against a grounded hull: timber grinding over sand, then a creak."""
    rng = np.random.default_rng(seed)
    n = seconds(1.1)
    t = np.arange(n) / RATE
    grind = band(brown(n, rng), 60.0, 900.0, order=2) * np.sin(np.pi * np.clip(t / 0.9, 0, 1))
    out = grind * 1.2
    mix_at(out, creak(seed + 1) * 0.6, seconds(0.25))
    return normalise(out, -3.0)


def footstep_sand(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    n = seconds(0.16)
    t = np.arange(n) / RATE
    crunch = band(noise(n, rng), 700.0, 5000.0, order=2)
    grit = (rng.random(n) > 0.985).astype(float) * rng.uniform(-1, 1, n)
    out = (crunch * 0.6 + band(grit, 2000.0, 9000.0) * 0.8) * envelope(n, 0.01, 0.1, 4.0)
    return normalise(out, -6.0)


def footstep_wood(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    n = seconds(0.2)
    t = np.arange(n) / RATE
    knock = np.sin(2 * np.pi * rng.uniform(170, 230) * t) * np.exp(-t / 0.035)
    knock += np.sin(2 * np.pi * rng.uniform(480, 560) * t) * np.exp(-t / 0.015) * 0.4
    knock += band(noise(n, rng), 1500.0, 6000.0) * np.exp(-t / 0.006) * 0.4
    return normalise(knock, -6.0)


def swim_stroke(seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    n = seconds(0.6)
    swish = band(pink(n, rng), 300.0, 2500.0, order=2)
    swish *= np.sin(np.linspace(0, np.pi, n)) ** 2
    return normalise(swish, -6.0)


def gull(seed: int) -> np.ndarray:
    """A herring gull's laughing call: a few falling, nasal 'kyow' notes."""
    rng = np.random.default_rng(seed)
    notes = int(rng.integers(3, 6))
    total = np.zeros(seconds(notes * 0.32 + 0.4))
    time = 0.0
    top = rng.uniform(1900, 2300)
    for index in range(notes):
        duration = rng.uniform(0.18, 0.26)
        n = seconds(duration)
        t = np.arange(n) / RATE
        start = top * (1.0 - 0.06 * index)
        freq = start * (1.0 - 0.35 * (t / duration) ** 0.7)
        phase = 2 * np.pi * np.cumsum(freq) / RATE
        # Nasal: strong upper harmonics, lightly filtered.
        tone = np.sin(phase) + 0.6 * np.sin(2 * phase) + 0.4 * np.sin(3 * phase) + \
            0.25 * np.sin(4 * phase)
        tone *= adsr(n, 0.02, 0.06) * (1.0 - 0.1 * index)
        mix_at(total, tone, seconds(time))
        time += duration + rng.uniform(0.05, 0.1)
    return normalise(band(total, 700.0, 7000.0, order=2), -8.0)


def lighthouse_bell() -> np.ndarray:
    """A bell buoy: two struck tones a little apart, ringing out."""
    out = np.zeros(seconds(5.0))
    mix_at(out, bell(midi(62), 4.5), 0, 1.0)
    mix_at(out, bell(midi(69), 4.0), seconds(0.55), 0.7)
    return normalise(out, -4.0)


def ui_blip(notes: list[float], spacing: float, level: float = -8.0) -> np.ndarray:
    out = np.zeros(seconds(spacing * len(notes) + 0.4))
    for index, note in enumerate(notes):
        mix_at(out, marimba(midi(note), 0.4), seconds(index * spacing))
    return normalise(out, level)


def ui_tick() -> np.ndarray:
    n = seconds(0.06)
    t = np.arange(n) / RATE
    tick = np.sin(2 * np.pi * 2400.0 * t) * np.exp(-t / 0.008)
    return normalise(tick, -16.0)


# --------------------------------------------------------------------------------------------
# Music
# --------------------------------------------------------------------------------------------

# D major, with the progression carrying the "going home" warmth: I - vi - IV - V.
TITLE_CHORDS = [
    [50, 57, 62, 66, 69, 73],   # Dmaj7
    [47, 54, 59, 62, 66, 69],   # Bm7
    [43, 50, 55, 59, 62, 66],   # Gmaj7
    [45, 52, 57, 61, 64, 69],   # A
    [50, 57, 62, 66, 69, 73],   # Dmaj7
    [42, 49, 54, 57, 61, 64],   # F#m7
    [43, 50, 55, 59, 62, 67],   # Gmaj7 (add G)
    [45, 52, 57, 62, 64, 69],   # Asus4
]

# The lead: (bar, beat, midi note, beats held). Bars are two per chord above.
TITLE_MELODY = [
    (4, 0, 78, 1.5), (4, 1.5, 76, 0.5), (4, 2, 74, 2), (5, 0, 73, 1), (5, 1, 74, 1),
    (5, 2, 71, 2), (6, 0, 74, 1.5), (6, 1.5, 76, 0.5), (6, 2, 78, 1), (6, 3, 81, 1),
    (7, 0, 79, 3), (8, 0, 76, 4),
    (12, 0, 78, 1.5), (12, 1.5, 79, 0.5), (12, 2, 81, 2), (13, 0, 78, 1), (13, 1, 76, 1),
    (13, 2, 74, 2), (14, 0, 71, 1.5), (14, 1.5, 73, 0.5), (14, 2, 74, 1), (14, 3, 76, 1),
    (15, 0, 73, 2), (15, 2, 69, 2),
]


def title_theme() -> np.ndarray:
    rng = np.random.default_rng(101)
    bpm = 88.0
    beat = 60.0 / bpm
    bars = 16
    length = seconds(bars * 4 * beat)
    dry = np.zeros((length, 2))

    for bar in range(bars):
        chord = TITLE_CHORDS[(bar // 2) % len(TITLE_CHORDS)]
        start = seconds(bar * 4 * beat)
        if bar % 2 == 0:
            voiced = [midi(n) for n in chord[1:5]]
            chunk = pad(voiced, 8 * beat + 0.8, rng)
            mix_at(dry[:, 0], chunk[:, 0], start, 0.34, wrap=True)
            mix_at(dry[:, 1], chunk[:, 1], start, 0.34, wrap=True)
        # Bass on the root, a dotted pulse that rocks like a hull.
        for offset, held in ((0.0, 1.5), (1.5, 1.0), (2.5, 1.5)):
            note = bass(midi(chord[0] - 12 if chord[0] > 47 else chord[0]), held * beat)
            for channel in range(2):
                mix_at(dry[:, channel], note, start + seconds(offset * beat), 0.32, wrap=True)
        # Marimba arpeggio in eighths, a rolling figure over the chord tones.
        pattern = [1, 3, 2, 3, 4, 3, 2, 3]
        for step, degree in enumerate(pattern):
            note_midi = chord[degree] + (12 if degree < 2 else 0)
            velocity = (0.9 if step % 2 == 0 else 0.6) * rng.uniform(0.85, 1.0)
            hit = marimba(midi(note_midi), 1.2, velocity)
            pan = 0.35 + 0.3 * (step / len(pattern))
            at = start + seconds(step * beat * 0.5)
            mix_at(dry[:, 0], hit, at, 0.2 * (1.0 - pan) * 2.0, wrap=True)
            mix_at(dry[:, 1], hit, at, 0.2 * pan * 2.0, wrap=True)
        # A soft kick on one and three, a shaker on the offbeats: a gentle rowing pulse.
        if bar >= 2:
            for kick_beat in (0.0, 2.0):
                for channel in range(2):
                    mix_at(dry[:, channel], soft_kick(), start + seconds(kick_beat * beat),
                           0.22, wrap=True)
            for eighth in range(8):
                if eighth % 2 == 1:
                    hit = shaker(0.08, rng)
                    mix_at(dry[:, eighth % 2], hit, start + seconds(eighth * beat * 0.5),
                           0.06, wrap=True)

    for bar, at_beat, note, held in TITLE_MELODY:
        tone = flute(midi(note), held * beat + 0.1, rng)
        at = seconds((bar * 4 + at_beat) * beat)
        mix_at(dry[:, 0], tone, at, 0.16, wrap=True)
        mix_at(dry[:, 1], tone, at, 0.16, wrap=True)

    wet = convolve_wrapped(dry, reverb_ir(2.4, rng))
    return normalise(dry * 0.8 + wet * 0.45, -3.0)


VOYAGE_CHORDS = [
    [50, 57, 62, 64, 69],   # Dadd9
    [55, 62, 67, 69, 71],   # G6/add9 (lydian lift)
    [47, 54, 59, 62, 66],   # Bm7
    [45, 52, 57, 59, 64],   # Asus2
]


def voyage_theme() -> np.ndarray:
    """At sea: open, unhurried, mostly pad and scattered mallets, so it sits under the waves."""
    rng = np.random.default_rng(202)
    bpm = 72.0
    beat = 60.0 / bpm
    bars = 16
    length = seconds(bars * 4 * beat)
    dry = np.zeros((length, 2))
    for bar in range(bars):
        chord = VOYAGE_CHORDS[(bar // 2) % len(VOYAGE_CHORDS)]
        start = seconds(bar * 4 * beat)
        if bar % 2 == 0:
            chunk = pad([midi(n) for n in chord[1:]], 8 * beat + 1.0, rng, brightness=1000.0)
            mix_at(dry[:, 0], chunk[:, 0], start, 0.4, wrap=True)
            mix_at(dry[:, 1], chunk[:, 1], start, 0.4, wrap=True)
            note = bass(midi(chord[0] - 12), 7.5 * beat)
            for channel in range(2):
                mix_at(dry[:, channel], note, start, 0.28, wrap=True)
        # Sparse mallets: a few chord tones placed off the grid, like light on the water.
        for _ in range(int(rng.integers(2, 5))):
            degree = int(rng.integers(1, len(chord)))
            at = start + seconds(rng.choice([0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5]) * beat)
            hit = marimba(midi(chord[degree] + 12), 1.6, rng.uniform(0.5, 0.9))
            pan = rng.uniform(0.2, 0.8)
            mix_at(dry[:, 0], hit, at, 0.18 * (1.0 - pan) * 2.0, wrap=True)
            mix_at(dry[:, 1], hit, at, 0.18 * pan * 2.0, wrap=True)
    wet = convolve_wrapped(dry, reverb_ir(3.2, rng, damping=2800.0))
    return normalise(dry * 0.7 + wet * 0.6, -4.0)


def arrival_sting() -> np.ndarray:
    """Landfall: a rising arpeggio that opens into a held D major chord with a bell on top."""
    rng = np.random.default_rng(303)
    length = seconds(6.5)
    dry = np.zeros((length, 2))
    run = [62, 66, 69, 74, 78, 81]
    for index, note in enumerate(run):
        hit = marimba(midi(note), 2.0, 0.8 + 0.04 * index)
        at = seconds(index * 0.11)
        pan = 0.25 + 0.5 * index / len(run)
        mix_at(dry[:, 0], hit, at, 0.5 * (1.0 - pan) * 2.0)
        mix_at(dry[:, 1], hit, at, 0.5 * pan * 2.0)
    chord = pad([midi(n) for n in (62, 66, 69, 74, 78)], 5.5, rng, brightness=2400.0)
    mix_at(dry[:, 0], chord[:, 0], seconds(0.6), 0.55)
    mix_at(dry[:, 1], chord[:, 1], seconds(0.6), 0.55)
    ring = bell(midi(86), 5.0, 0.6)
    mix_at(dry[:, 0], ring, seconds(0.66), 0.35)
    mix_at(dry[:, 1], ring, seconds(0.66), 0.35)
    for channel in range(2):
        mix_at(dry[:, channel], bass(midi(38), 4.0), seconds(0.6), 0.4)
    shimmer_n = seconds(3.0)
    shimmer = band(noise(shimmer_n, rng), 6000.0, 14000.0, order=2)
    shimmer *= np.sin(np.linspace(0, np.pi, shimmer_n)) ** 2
    for channel in range(2):
        mix_at(dry[:, channel], shimmer, seconds(0.5), 0.05)
    ir = reverb_ir(2.8, rng)
    wet = np.stack([signal.fftconvolve(dry[:, c], ir[:, c])[:length] for c in range(2)], axis=1)
    out = dry * 0.8 + wet * 0.5
    out *= adsr(length, 0.001, 1.5)[:, None]
    return normalise(out, -2.0)


def castoff_sting() -> np.ndarray:
    rng = np.random.default_rng(404)
    length = seconds(2.6)
    dry = np.zeros((length, 2))
    for index, note in enumerate((69, 74, 76, 78)):
        hit = marimba(midi(note), 1.6, 0.7)
        for channel in range(2):
            mix_at(dry[:, channel], hit, seconds(index * 0.14), 0.4)
    ir = reverb_ir(1.8, rng)
    wet = np.stack([signal.fftconvolve(dry[:, c], ir[:, c])[:length] for c in range(2)], axis=1)
    out = (dry * 0.8 + wet * 0.4) * adsr(length, 0.001, 0.8)[:, None]
    return normalise(out, -5.0)


# --------------------------------------------------------------------------------------------


GENERATORS: dict[str, Callable[[], np.ndarray]] = {
    "ambience/ocean_loop.ogg": ocean_loop,
    "ambience/wind_loop.ogg": wind_loop,
    "ambience/rain_loop.ogg": rain_loop,
    "ambience/shore_loop.ogg": shore_loop,
    "sfx/paddle_1.ogg": lambda: paddle(1),
    "sfx/paddle_2.ogg": lambda: paddle(2),
    "sfx/paddle_3.ogg": lambda: paddle(3),
    "sfx/splash_small.ogg": lambda: splash(0.2, 5),
    "sfx/splash_big.ogg": lambda: splash(1.0, 6),
    "sfx/wood_thud.ogg": lambda: wood_thud(7),
    "sfx/creak_1.ogg": lambda: creak(8),
    "sfx/creak_2.ogg": lambda: creak(9),
    "sfx/creak_3.ogg": lambda: creak(10),
    "sfx/push.ogg": lambda: push_heave(12),
    "sfx/step_sand_1.ogg": lambda: footstep_sand(14),
    "sfx/step_sand_2.ogg": lambda: footstep_sand(15),
    "sfx/step_sand_3.ogg": lambda: footstep_sand(16),
    "sfx/step_wood_1.ogg": lambda: footstep_wood(17),
    "sfx/step_wood_2.ogg": lambda: footstep_wood(18),
    "sfx/step_wood_3.ogg": lambda: footstep_wood(19),
    "sfx/swim_1.ogg": lambda: swim_stroke(20),
    "sfx/swim_2.ogg": lambda: swim_stroke(21),
    "sfx/gull_1.ogg": lambda: gull(22),
    "sfx/gull_2.ogg": lambda: gull(23),
    "sfx/gull_3.ogg": lambda: gull(24),
    "sfx/bell.ogg": lighthouse_bell,
    "ui/hover.ogg": ui_tick,
    "ui/click.ogg": lambda: ui_blip([74, 81], 0.06),
    "ui/back.ogg": lambda: ui_blip([81, 74], 0.06),
    "ui/toggle.ogg": lambda: ui_blip([78], 0.05, -10.0),
    "ui/start.ogg": lambda: ui_blip([69, 74, 78, 81], 0.07, -6.0),
    "music/title.ogg": title_theme,
    "music/voyage.ogg": voyage_theme,
    "music/arrival.ogg": arrival_sting,
    "music/castoff.ogg": castoff_sting,
}


def main() -> None:
    for name, generate in GENERATORS.items():
        write(name, generate())


if __name__ == "__main__":
    main()
