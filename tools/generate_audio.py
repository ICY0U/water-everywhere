"""Synthesises every sound the demo plays into assets/audio/*.wav.

Nothing here is sampled or downloaded, so the sounds carry no licence beyond the project's own,
and they can be regenerated exactly: every random source is seeded. Pure Python (the standard
library only) because the build machine has no numpy; the whole set takes a few seconds.

Run from the project root:
    python3 tools/generate_audio.py

Loops are written a crossfade longer than their period and folded back on themselves, so they
repeat without a click; their .import files ask Godot to loop them.
"""

import math
import random
import struct
import wave
from pathlib import Path

RATE = 22050
OUT = Path(__file__).resolve().parent.parent / "assets" / "audio"


def lowpass(samples, cutoff):
    """One-pole low-pass. Cutoff in Hz."""
    k = 1.0 - math.exp(-2.0 * math.pi * cutoff / RATE)
    out, y = [], 0.0
    for x in samples:
        y += k * (x - y)
        out.append(y)
    return out


def highpass(samples, cutoff):
    low = lowpass(samples, cutoff)
    return [x - l for x, l in zip(samples, low)]


def bandpass(samples, low_hz, high_hz):
    return lowpass(highpass(samples, low_hz), high_hz)


def noise(count, rng):
    return [rng.uniform(-1.0, 1.0) for _ in range(count)]


def normalise(samples, peak=0.7):
    top = max(abs(s) for s in samples) or 1.0
    return [s * peak / top for s in samples]


def fold_loop(samples, period):
    """Crossfades the tail past [period] into the head, so the loop point is seamless."""
    fade = len(samples) - period
    out = samples[:period]
    for i in range(fade):
        t = i / fade
        out[i] = samples[period + i] * (1.0 - t) + out[i] * t
    return out


def write(name, samples, loop=False):
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f"{name}.wav"
    with wave.open(str(path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(RATE)
        handle.writeframes(b"".join(
            struct.pack("<h", int(max(-1.0, min(1.0, s)) * 32767)) for s in samples))
    # Godot keeps the params of an existing .import file on import; only these need stating.
    import_path = path.with_suffix(".wav.import")
    if not import_path.exists():
        import_path.write_text(
            "[remap]\n\nimporter=\"wav\"\ntype=\"AudioStreamWAV\"\n\n"
            "[params]\n\nforce/max_rate=false\nforce/max_rate_hz=44100\nedit/trim=false\n"
            "edit/normalize=false\n"
            f"edit/loop_mode={2 if loop else 0}\nedit/loop_begin=0\nedit/loop_end=-1\n"
            "compress/mode=0\n")
    print(f"{name}: {len(samples) / RATE:.2f} s{' (loop)' if loop else ''}")


def ocean_loop():
    """Surf on open water: a low roar that swells, with foamy hiss riding the peaks."""
    rng = random.Random(11)
    period = RATE * 12
    count = period + RATE
    body = lowpass(lowpass(noise(count, rng), 520), 700)
    rumble = lowpass(lowpass(noise(count, rng), 90), 140)
    hiss = highpass(noise(count, rng), 2400)
    out = []
    for i in range(count):
        t = (i % period) / RATE
        # Periods that divide the loop, so the swell pattern repeats with it.
        swell = (0.5 + 0.5 * math.sin(2 * math.pi * t / 6.0)) * 0.6 + (
            0.5 + 0.5 * math.sin(2 * math.pi * t / 4.0 + 1.3)) * 0.4
        wash = swell ** 3
        out.append(body[i] * (0.45 + 0.55 * swell) + rumble[i] * 1.6 + hiss[i] * 0.18 * wash)
    return normalise(fold_loop(out, period), 0.6)


def wind_loop():
    """Wind over the sea: band-limited rush that gusts."""
    rng = random.Random(23)
    period = RATE * 10
    count = period + RATE
    raw = noise(count, rng)
    low = bandpass(raw, 250, 700)
    high = bandpass(raw, 900, 2200)
    out = []
    for i in range(count):
        t = (i % period) / RATE
        gust = 0.55 + 0.3 * math.sin(2 * math.pi * t / 5.0) + 0.15 * math.sin(
            2 * math.pi * t / 2.0 + 0.7)
        whistle = 0.5 + 0.5 * math.sin(2 * math.pi * t / 10.0 + 2.1)
        out.append(low[i] * gust + high[i] * 0.35 * gust * whistle)
    return normalise(fold_loop(out, period), 0.6)


def rain_loop():
    """Rain on water: a fine hiss and a scatter of droplets."""
    rng = random.Random(37)
    period = RATE * 6
    count = period + RATE // 2
    out = [s * 0.12 for s in highpass(lowpass(noise(count, rng), 6000), 1800)]
    for _ in range(int(count / RATE * 260)):
        start = rng.randrange(count - 200)
        pitch = rng.uniform(1800, 5200)
        level = rng.uniform(0.05, 0.3)
        for j in range(160):
            out[start + j] += level * math.sin(2 * math.pi * pitch * j / RATE) * math.exp(-j / 22.0)
    return normalise(fold_loop(out, period), 0.55)


def splash(seed, seconds, depth):
    """A paddle or body entering water: a bright slap that darkens, then bubbles."""
    rng = random.Random(seed)
    count = int(RATE * seconds)
    raw = noise(count, rng)
    out, y = [], 0.0
    for i in range(count):
        t = i / RATE
        cutoff = 350 + 3200 * math.exp(-t * 7.0)
        k = 1.0 - math.exp(-2.0 * math.pi * cutoff / RATE)
        y += k * (raw[i] - y)
        env = (1.0 - math.exp(-t * 300.0)) * math.exp(-t * (5.5 / depth))
        out.append(y * env)
    # Bubbles: short upward chirps, which is what makes noise read as water.
    for _ in range(int(6 * depth)):
        start = rng.randrange(int(count * 0.05), int(count * 0.6))
        base = rng.uniform(180, 520) / depth
        length = int(RATE * rng.uniform(0.03, 0.08))
        phase = 0.0
        for j in range(min(length, count - start)):
            frequency = base * (1.0 + 1.5 * j / length)
            phase += 2 * math.pi * frequency / RATE
            out[start + j] += 0.25 * math.sin(phase) * math.sin(math.pi * j / length)
    return normalise(out, 0.75)


def ui_click():
    count = int(RATE * 0.06)
    return normalise([
        (math.sin(2 * math.pi * 1250 * i / RATE) * 0.8
         + math.sin(2 * math.pi * 2500 * i / RATE) * 0.2) * math.exp(-i / RATE * 90.0)
        for i in range(count)], 0.5)


def note(frequency, seconds, decay, bright=0.3):
    count = int(RATE * seconds)
    return [(math.sin(2 * math.pi * frequency * i / RATE)
             + bright * math.sin(2 * math.pi * frequency * 4 * i / RATE) * math.exp(-i / RATE * 9)
             ) * math.exp(-i / RATE * decay) * min(1.0, i / (RATE * 0.004))
            for i in range(count)]


def arrival_sting():
    """A rising arpeggio that settles on a chord: made it."""
    out = [0.0] * int(RATE * 3.2)
    for index, frequency in enumerate([523.25, 659.25, 783.99, 1046.5]):
        start = int(RATE * 0.16 * index)
        for j, s in enumerate(note(frequency, 2.6, 2.2)):
            if start + j < len(out):
                out[start + j] += s
    chord_start = int(RATE * 0.7)
    for frequency in [261.63, 392.0, 523.25, 659.25]:
        for j, s in enumerate(note(frequency, 2.4, 1.3, 0.1)):
            if chord_start + j < len(out):
                out[chord_start + j] += 0.5 * s
    return normalise(out, 0.6)


def title_music():
    """A slow, warm pad under the title: Cmaj7, Am7, Fmaj7, G6, six seconds each."""
    chords = [
        [130.81, 196.0, 246.94, 329.63],
        [110.0, 164.81, 196.0, 261.63],
        [87.31, 130.81, 164.81, 220.0],
        [98.0, 146.83, 196.0, 246.94],
    ]
    chord_seconds = 6.0
    period = int(RATE * chord_seconds * len(chords))
    count = period + RATE * 2
    out = [0.0] * count
    rng = random.Random(51)
    for index in range(len(chords) + 1):
        chord = chords[index % len(chords)]
        start = int(RATE * chord_seconds * index)
        length = int(RATE * (chord_seconds + 2.0))
        for frequency in chord:
            detune = [rng.uniform(-0.25, 0.25) for _ in range(3)]
            for j in range(length):
                i = start + j
                if i >= count:
                    break
                t = j / RATE
                env = min(1.0, t / 2.0) * min(1.0, (chord_seconds + 2.0 - t) / 2.0)
                sample = sum(math.sin(2 * math.pi * (frequency + d) * t) for d in detune) / 3.0
                sample += 0.25 * math.sin(2 * math.pi * frequency * 2.0 * t + 0.4)
                out[i] += sample * env * 0.25
    # A slow shimmer: one high note per chord, falling like light on water.
    for index in range(len(chords) + 1):
        start = int(RATE * (chord_seconds * index + 2.5))
        frequency = chords[index % len(chords)][-1] * 2.0
        for j, s in enumerate(note(frequency, 3.0, 1.2, 0.0)):
            if start + j < count:
                out[start + j] += 0.12 * s
    return normalise(fold_loop(lowpass(out, 2400), period), 0.5)


def main():
    write("ocean_loop", ocean_loop(), loop=True)
    write("wind_loop", wind_loop(), loop=True)
    write("rain_loop", rain_loop(), loop=True)
    for index in range(3):
        write(f"paddle_{index + 1}", splash(100 + index, 0.7, 1.0))
    write("splash_big", splash(200, 1.4, 1.8))
    write("ui_click", ui_click())
    write("arrival", arrival_sting())
    write("title_music", title_music(), loop=True)


if __name__ == "__main__":
    main()
