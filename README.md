# aminor

A minimal norns script that teaches the SuperCollider ↔ Lua split.

It plays long tones (sine, saw, or pulse) drawn from the **A harmonic minor
scale** (`a b c d e f g#`), each one fading in, sustaining, fading out, then
pausing — forever, until you stop it. You can layer many independent voices
that drift out of sync with each other.

## Controls

- **K3** — start
- **K2** — stop
- **E2** — number of simultaneous voices (**1–42**, starts at 1)
- **E3** — master amplitude / overall mix level (0.00–1.00)

Pressing **K2** stops scheduling new notes but lets any sounding notes finish
their fade-out. While they ring out the screen shows **`stopping..`**, and once
the last note has fully ended it shows **`The End`**.

**Impatient?** Press **K2 again while it's `stopping..`** for a **fast
fade-out** — all sounding notes are released together over ~1.5 s (set by
`FAST_FADE` in `aminor.lua`) instead of finishing their full envelopes.

## Grid

A 16×8 varibright grid is optional. Every control is lit from the current
value, so changes made with the encoders or in the PARAMS menu show up too.

| Cells | Control |
|-------|---------|
| row 1, cols 1–16 | number of voices: `1 2 3 4 5 6 8 10 12 15 18 22 26 31 36 42` |
| row 2, cols 1–16 | master amplitude, 0.0 (left) to 1.0 (right) |
| rows 3–8, cols 1–5 | octave 1–6 weight: `0 1 2 3 5` |
| cols 7–13, rows 8–3 | note weight for `a b c d e f g#`, bottom to top: `0 1 2 3 5 8` |
| col 16, rows 4–6 | waveform: pulse, saw, sine |
| col 16, row 8 | on/off |

Faders light as a bar from their origin (left end of a row, bottom end of a
column) up to the current value. A value between two steps, such as 7 voices
set with E2, shows as the step below.

The on/off button starts when at rest, stops gracefully when playing, and
does the fast fade-out when pressed again while stopping. Its LED is bright
while playing, pulses while notes ring out, and is dim at rest.

The step tables and LED levels are constants at the top of `aminor.lua`
(`VOICE_STEPS`, `OCTAVE_STEPS`, `NOTE_STEPS`, `LED_DIM`, `LED_ON`).

## What one voice does each cycle

1. pick a **weighted** random pitch (see weights below)
2. pick a **weighted** random octave (see octave weights below)
3. fade in from amplitude **0** to **0.5**
4. sustain
5. fade out
6. pause
7. repeat with a fresh pitch + octave

Each envelope stage (fade in, sustain, fade out, pause) is **randomised per
note** between a **min** and **max** you set in the **PARAMS** menu, so no two
notes have the same shape.

## PARAMS menu

Everything below lives under **PARAMS > EDIT** and is saved with the pset:

- **mix > voices / amp** — the same values as E2 and E3.
- **oscillator > waveform** — `sine`, `saw`, or `pulse` (shared by all notes).
- **envelope (seconds)** — a **min** and **max** for each of fade in, sustain,
  fade out, and pause. Set min = max to make a stage fixed.
- **note weights** — an integer weight (0–20) per note; see below.
- **octave weights** — an integer weight (0–20) per octave (1–6); see below.

### Note weights

Pitches are not chosen evenly — each has a weight set under
**PARAMS > note weights**. Defaults:

| note | weight | chance |
|------|--------|--------|
| a    | 5      | ~33%   |
| e    | 3      | 20%    |
| c    | 2      | ~13%   |
| d    | 2      | ~13%   |
| b    | 1      | ~7%    |
| f    | 1      | ~7%    |
| g#   | 1      | ~7%    |

The weights don't need to sum to any particular total — the script totals them
at pick time. Set a weight to **0** to drop that note entirely (if you zero all
of them it falls back to `a`).

### Octave weights

Octaves work exactly like note weights, under **PARAMS > octave weights**.
Octaves **1–6** are available (7 notes × 6 octaves = **42** possible tones);
by default **3, 4, 5, 6** have weight 1 (the original four-octave range) and
the rest are **0** (off). Raise an octave's weight to make it more likely, or
set it to **0** to exclude it.

### Voices (E2)

Each voice is its own independent loop with its own random note and envelope.
With **more than one voice**, a random pause is applied **before** each note
(rather than after) so the voices start at different times and drift apart.
Turning E2 up while playing spawns more voices live; turning it down removes
them.

> Many voices add up. 42 notes each peaking at 0.5 will clip hard — use
> **E3** to pull the master level down as you raise the voice count.

## The two files

| File | Language | Role |
|------|----------|------|
| `Engine_SineNote.sc` | SuperCollider | Makes the sound. Defines the oscillator + envelope `SynthDef` (sine/saw/pulse via `Select.ar`), a shared master-amplitude bus, and a gated release for the fast fade-out. Exposes `playNote(freq, fadeIn, sustain, fadeOut, wave)`, `setAmp(level)`, and `releaseAll(relTime)`. |
| `aminor.lua` | Lua | The interface + logic. Handles keys/encoders/grid, draws the screen, picks weighted notes, runs the voice loops, and calls the engine commands. |

They are linked by two matching names:

- Lua: `engine.name = "SineNote"`
- SC:  `Engine_SineNote : CroneEngine`

### Where the timing lives

The **envelope in the engine** (`EnvGen` / `Env`) does the fade in → sustain →
fade out at audio rate, so the volume is perfectly smooth. `doneAction:
Done.freeSelf` frees each note synth automatically when it finishes.

The **Lua clock coroutines** only handle the *coarse* scheduling: wait for the
note to finish, wait the pause, then trigger the next note. `clock.sleep()`
inside a `clock.run()` is the idiomatic norns way to sequence over time
without blocking the UI — and each voice gets its own coroutine.

### Where the master level lives

**E3** doesn't touch each note in Lua. Instead the engine holds one
**control bus** (`ampBus`); every note synth reads it live with `In.kr` and
multiplies its output by it. So `setAmp` changes the level of notes that are
*already sounding*, not just future ones.

## Install on hardware / a norns install

Copy this whole `aminor` folder into your norns at:

```
~/dust/code/aminor/
```

(e.g. over the WiFi/USB `dust` share, or `scp -r aminor we@norns.local:~/dust/code/`)

Then on the norns: **SELECT > aminor**, and press **K3** to start.

The `.sc` engine is compiled by SuperCollider when the script loads. If you
edit `Engine_SineNote.sc`, you must reload the script (or restart audio) for
SuperCollider to pick up the change — editing only the `.lua` just needs a
script reload.

## Things to try

- Add more waveforms: extend the `Select.ar` array in the engine and the
  `WAVES` table in Lua (e.g. `VarSaw`, `Blip`).
- Randomise the waveform per note instead of using one shared setting.
- Auto-scale the level by voice count (e.g. divide by `sqrt(voices)`) so the
  overall loudness stays roughly constant as you raise E2.
- Make **K3** cut sounding notes immediately by adding a gated envelope in the
  engine and a `stopNote` command (right now K3 stops *scheduling* and any
  current notes finish their fade naturally).
