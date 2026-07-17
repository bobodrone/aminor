-- aminor
-- v1.0.0 @bobodrone
-- llllllll.co/t/22222
--
-- a random sine note generator
--
-- notes drawn from the
-- A harmonic minor scale (weighted):
-- a b c d e f g#
--
-- waveform, envelope min/max and
-- note weights are set in the
-- PARAMS menu.
--
-- E2 : number of voices (1-42)
-- E3 : master amplitude
-- K3 : start
-- K2 : stop (press again while
--      stopping for a fast fade-out)

-- Tell norns which SuperCollider engine to load.
-- This must match the class name Engine_SineNote in Engine_SineNote.sc
engine.name = "SineNote"

-- musicutil gives us helpers like note_num_to_freq()
local musicutil = require "musicutil"
-- controlspec describes a param's range/step/default for the PARAMS menu
local controlspec = require "controlspec"
-- util gives us clamp() etc.
local util = require "util"

-- ----------------------------------------------------------------------
-- configuration
-- ----------------------------------------------------------------------

-- the pitches we can choose from, each with a default selection weight.
-- { display name, param-safe id, default weight }
-- higher weight = picked more often. these need not sum to any total.
-- the actual weight used at runtime comes from the "weight_<id>" param.
local NOTES = {
  {"a",  "a",  5},
  {"b",  "b",  1},
  {"c",  "c",  2},
  {"d",  "d",  2},
  {"e",  "e",  3},
  {"f",  "f",  1},
  {"g#", "gs", 1},
}

-- the oscillator waveforms the "waveform" param can choose between.
-- the index (1-based here) maps to the engine's `wave` arg as index-1.
local WAVES = {"sine", "saw", "pulse"}

-- semitone offset of each note relative to C within one octave
local NOTE_SEMITONE = {
  c  = 0,
  d  = 2,
  e  = 4,
  f  = 5,
  ["g#"] = 8,
  a  = 9,
  b  = 11,
}

-- the octaves we can choose from, each with a default weight.
-- { octave number, default weight }  (weight 0 = octave never used)
-- the runtime weight comes from the "octw_<n>" param.
-- 7 notes x 6 octaves = 42 possible tones.
local OCTAVES = {
  {1, 0},
  {2, 0},
  {3, 1},
  {4, 1},
  {5, 1},
  {6, 1},
}

-- how many voices are allowed at once
local VOICES_MIN = 1
local VOICES_MAX = 42

-- seconds for the "fast fade-out" (second K2 press while stopping)
local FAST_FADE = 1.5

-- the envelope stages we expose as min/max params.
-- { id, display name, spec min, spec max, default min, default max }
local STAGES = {
  {"fade_in",  "fade in",  0, 30, 4,  12},
  {"sustain",  "sustain",  0, 60, 5,  15},
  {"fade_out", "fade out", 0, 30, 3,  8},
  {"pause",    "pause",    0, 30, 2,  8},
}

-- ----------------------------------------------------------------------
-- state
-- ----------------------------------------------------------------------

local voices  = {}           -- clock ids of the active voice loops
local n_live  = 0            -- how many voice loops are still alive
local target_voices = 1      -- how many voices we want (E2)
local master_amp = 0.5       -- overall level (E3)
local last_note = ""         -- text of the most recently triggered note
local playing  = false       -- generating new notes?
local stopping = false       -- stopped, but notes still fading out
local ended    = false       -- everything has finished ("The End")

-- ----------------------------------------------------------------------
-- helpers
-- ----------------------------------------------------------------------

-- turn a note name + octave into a frequency in Hz.
-- MIDI note 60 = C4, so: midi = (octave + 1) * 12 + semitone
local function note_to_freq(name, octave)
  local midi = (octave + 1) * 12 + NOTE_SEMITONE[name]
  return musicutil.note_num_to_freq(midi)
end

-- generic weighted pick over a list of { value=, weight= } entries.
-- roll a number in [0, total) and walk the list subtracting weights.
local function pick_weighted(entries)
  local total = 0
  for _, e in ipairs(entries) do total = total + e.weight end
  if total <= 0 then return entries[1].value end   -- all zeroed: fall back
  local r = math.random() * total
  for _, e in ipairs(entries) do
    r = r - e.weight
    if r <= 0 then return e.value end
  end
  return entries[#entries].value   -- fallback (floating-point safety)
end

-- pick a note name using the live weight params.
local function weighted_note()
  local entries = {}
  for _, n in ipairs(NOTES) do
    entries[#entries + 1] = {value = n[1], weight = params:get("weight_" .. n[2])}
  end
  return pick_weighted(entries)
end

-- pick an octave using the live weight params.
local function weighted_octave()
  local entries = {}
  for _, o in ipairs(OCTAVES) do
    entries[#entries + 1] = {value = o[1], weight = params:get("octw_" .. o[1])}
  end
  return pick_weighted(entries)
end

-- pick a random float between the _min and _max params of a stage.
-- (guarded so it still works if you set min above max)
local function rand_stage(id)
  local a = params:get(id .. "_min")
  local b = params:get(id .. "_max")
  local lo, hi = math.min(a, b), math.max(a, b)
  return lo + math.random() * (hi - lo)
end

-- called when a voice loop has finished (it and its last note are done).
-- when the final voice ends during a stop, flip the display to "The End".
local function voice_ended()
  n_live = n_live - 1
  if stopping and n_live <= 0 then
    stopping = false
    ended = true
    last_note = ""
    voices = {}
    redraw()
  end
end

-- one voice: while playing, picks a note, rolls its envelope, plays it, waits.
-- each voice runs as its own clock coroutine, so voices are independent.
-- when `playing` goes false it finishes the note it is on, then exits, which
-- is exactly when that note's audio ends.
local function voice_loop()
  while playing do
    -- with more than one voice, pause BEFORE the note so the voices
    -- start at different times and drift out of sync with each other.
    if target_voices > 1 then
      clock.sleep(rand_stage("pause"))
      if not playing then break end   -- stopped during the pause: no new note
    end

    -- weighted pitch + weighted octave -> frequency
    local name = weighted_note()
    local octave = weighted_octave()
    local freq = note_to_freq(name, octave)

    -- random duration for each envelope stage
    local fade_in  = rand_stage("fade_in")
    local sustain  = rand_stage("sustain")
    local fade_out = rand_stage("fade_out")

    -- current waveform (param is 1-based; engine wants 0-based)
    local wave = params:get("waveform") - 1

    last_note = name .. octave
    engine.playNote(freq, fade_in, sustain, fade_out, wave)
    redraw()

    -- wait out the whole note (the engine's envelope does the fades).
    -- if stop was pressed we still let THIS note finish, then exit.
    clock.sleep(fade_in + sustain + fade_out)
    if not playing then break end

    -- for a single voice keep the original trailing pause
    if target_voices <= 1 then
      clock.sleep(rand_stage("pause"))
    end
  end
  voice_ended()
end

-- spawn one voice coroutine and track it.
local function spawn_voice()
  n_live = n_live + 1
  table.insert(voices, clock.run(voice_loop))
end

-- start/stop individual voice coroutines so #voices == target_voices.
-- only does anything while playing.
local function match_voices()
  if not playing then return end
  while #voices < target_voices do
    spawn_voice()
  end
  while #voices > target_voices do
    clock.cancel(table.remove(voices))   -- killed: won't call voice_ended
    n_live = n_live - 1
  end
end

local function start()
  if playing then return end
  -- if we were mid-stop, drop any lingering voices and start fresh.
  for _, id in ipairs(voices) do clock.cancel(id) end
  voices = {}
  n_live = 0
  playing = true
  stopping = false
  ended = false
  match_voices()
  redraw()
end

local function stop()
  if not playing then return end
  playing = false
  stopping = true
  ended = false
  -- don't cancel: each voice finishes its current note (letting the audio
  -- fade out naturally) then exits. voice_ended() shows "The End" when the
  -- last one is done. Handle the corner case of no live voices right away.
  if n_live <= 0 then
    stopping = false
    ended = true
    voices = {}
  end
  redraw()
end

-- fast fade-out: cut scheduling immediately and release every sounding note
-- over FAST_FADE seconds, rather than letting notes finish their envelopes.
local function fast_stop()
  if not (playing or stopping) then return end
  playing = false
  -- cancel the voice loops so nothing waits for full envelopes anymore
  for _, id in ipairs(voices) do clock.cancel(id) end
  voices = {}
  n_live = 0
  stopping = true
  ended = false
  redraw()                       -- keeps showing "stopping.."
  engine.releaseAll(FAST_FADE)   -- tell the engine to fade all notes out
  -- flip to "The End" once the fade has finished
  clock.run(function()
    clock.sleep(FAST_FADE + 0.1)
    if stopping then
      stopping = false
      ended = true
      last_note = ""
      redraw()
    end
  end)
end

-- ----------------------------------------------------------------------
-- norns lifecycle callbacks
-- ----------------------------------------------------------------------

function init()
  math.randomseed(os.time())

  -- oscillator waveform (shared by every note).
  params:add_separator("oscillator")
  params:add_option("waveform", "waveform", WAVES, 1)

  -- one min + one max control param per envelope stage.
  -- these show up under PARAMS > EDIT and are saved with the pset.
  params:add_separator("envelope (seconds)")
  for _, s in ipairs(STAGES) do
    local id, name, lo, hi, dmin, dmax = table.unpack(s)
    params:add_control(id .. "_min", name .. " min",
      controlspec.new(lo, hi, "lin", 0.1, dmin, "s"))
    params:add_control(id .. "_max", name .. " max",
      controlspec.new(lo, hi, "lin", 0.1, dmax, "s"))
  end

  -- one integer weight per note (0 = never played).
  params:add_separator("note weights")
  for _, n in ipairs(NOTES) do
    local name, id, default = table.unpack(n)
    params:add_number("weight_" .. id, "weight " .. name, 0, 20, default)
  end

  -- one integer weight per octave (0 = octave never used).
  params:add_separator("octave weights")
  for _, o in ipairs(OCTAVES) do
    local octave, default = table.unpack(o)
    params:add_number("octw_" .. octave, "weight oct " .. octave, 0, 20, default)
  end

  -- push the starting master amplitude to the engine
  engine.setAmp(master_amp)

  redraw()
end

-- encoders: n = which encoder (1,2,3), d = delta (+/-)
function enc(n, d)
  if n == 2 then
    -- E2: number of simultaneous voices
    target_voices = util.clamp(target_voices + d, VOICES_MIN, VOICES_MAX)
    match_voices()
    redraw()
  elseif n == 3 then
    -- E3: overall amplitude / master mix level
    master_amp = util.clamp(master_amp + d * 0.01, 0, 1)
    engine.setAmp(master_amp)
    redraw()
  end
end

-- keys: n = which key (1,2,3), z = 1 pressed / 0 released
function key(n, z)
  if z == 1 then
    if n == 3 then
      start()
    elseif n == 2 then
      -- first K2 press: graceful stop (notes finish their envelopes).
      -- second K2 press (while stopping): fast fade-out.
      if playing then
        stop()
      elseif stopping then
        fast_stop()
      end
    end
  end
end

function redraw()
  screen.clear()

  screen.level(15)
  screen.move(0, 10)
  screen.text("aminor")

  -- status line: playing -> Morendo.. -> The End (or "stopped" at rest)
  local status, bright
  if playing then
    status, bright = "playing  (" .. last_note .. ")", 15
  elseif stopping then
    status, bright = "Morendo..", 8
  elseif ended then
    status, bright = "The End", 15
  else
    status, bright = "stopped", 4
  end
  screen.move(0, 24)
  screen.level(bright)
  screen.text(status)

  screen.level(6)
  screen.move(0, 38)
  screen.text("voices: " .. target_voices .. "   wave: " .. WAVES[params:get("waveform")])
  screen.move(0, 48)
  screen.text(string.format("amp: %.2f", master_amp))

  screen.level(3)
  screen.move(0, 62)
  screen.text("E2 voices  E3 amp  K3 start")

  screen.update()
end
