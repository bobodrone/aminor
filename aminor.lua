-- aminor
-- v1.0.0 @bobodrone
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
--
-- grid (16x8, optional):
-- row 1    : number of voices
-- row 2    : master amplitude
-- rows 3-8 : octave 1-6 weights
--            (cols 1-5 = 0 1 2 3 5)
-- cols 7-13: note weights a..g#
--            (bottom to top =
--             0 1 2 3 5 8)
-- col 16   : rows 4-6 waveform,
--            row 8 on/off

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

-- grid: the value each cell of a stepped fader stands for, counted from
-- the fader's origin (left end of a row, bottom end of a column).
-- voices get a curve so every low count is reachable; E2 still hits the
-- values in between.
local VOICE_STEPS  = {1, 2, 3, 4, 5, 6, 8, 10, 12, 15, 18, 22, 26, 31, 36, 42}
local OCTAVE_STEPS = {0, 1, 2, 3, 5}
local NOTE_STEPS   = {0, 1, 2, 3, 5, 8}

-- grid: how many cells the (linear) amplitude fader has
local AMP_CELLS = 16

-- grid: led brightness (0-15) for an unlit track cell and a lit cell
local LED_DIM = 3
local LED_ON  = 15

-- grid: redraws per second, and how fast the on/off led pulses while stopping
local GRID_FPS = 30
local PULSE_HZ = 1

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
local target_voices = 1      -- how many voices we want ("voices" param)
local master_amp = 0.5       -- overall level ("amp" param)
local last_note = ""         -- text of the most recently triggered note
local playing  = false       -- generating new notes?
local stopping = false       -- stopped, but notes still fading out
local ended    = false       -- everything has finished ("The End")
local g                      -- the connected grid
local grid_dirty = true      -- grid leds need repainting?

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

-- something changed: repaint the screen and flag the grid for a repaint.
-- (the flag is set here rather than in redraw() because norns swaps
-- redraw() out while the menu is open.)
local function refresh()
  grid_dirty = true
  redraw()
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
    refresh()
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
  refresh()
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
  refresh()
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
  refresh()                      -- keeps showing "stopping.."
  engine.releaseAll(FAST_FADE)   -- tell the engine to fade all notes out
  -- flip to "The End" once the fade has finished
  clock.run(function()
    clock.sleep(FAST_FADE + 0.1)
    if stopping then
      stopping = false
      ended = true
      last_note = ""
      refresh()
    end
  end)
end

-- one button for everything: start when at rest, graceful stop when
-- playing, fast fade-out when already stopping (same as K3 / K2 / K2).
local function toggle_play()
  if playing then
    stop()
  elseif stopping then
    fast_stop()
  else
    start()
  end
end

-- ----------------------------------------------------------------------
-- grid: scaling helpers
-- ----------------------------------------------------------------------

-- linear fader: cell i of n (1-based) -> a value in [lo, hi], and back.
local function cell_to_value(i, n, lo, hi)
  return util.linlin(1, n, lo, hi, i)
end

local function value_to_cell(v, n, lo, hi)
  return util.round(util.linlin(lo, hi, 1, n, v))
end

-- stepped fader: cell i -> steps[i], and back. going back picks the
-- highest step that is <= v, so in-between values (set with an encoder
-- or in the PARAMS menu) show as the step below.
local function step_to_value(steps, i)
  return steps[util.clamp(i, 1, #steps)]
end

local function value_to_step(steps, v)
  local cell = 1
  for i, step in ipairs(steps) do
    if v >= step then cell = i end
  end
  return cell
end

-- ----------------------------------------------------------------------
-- grid: led helpers
-- ----------------------------------------------------------------------

-- a "line" is n cells starting at (x, y) and stepping by (dx, dy), so the
-- same helpers serve rows (dx = 1) and columns (dy = -1 runs upwards).
-- which cell of the line (1-based) sits at grid position (px, py)? nil = none.
local function line_cell(line, px, py)
  for i = 1, line.n do
    if px == line.x + (i - 1) * line.dx and py == line.y + (i - 1) * line.dy then
      return i
    end
  end
end

-- set every cell of a line; level_for(i) gives the brightness of cell i.
local function led_line(line, level_for)
  for i = 1, line.n do
    g:led(line.x + (i - 1) * line.dx, line.y + (i - 1) * line.dy, level_for(i))
  end
end

-- fader look: cells 1..lit bright, the rest of the track dim.
local function led_bar(line, lit)
  led_line(line, function(i) return i <= lit and LED_ON or LED_DIM end)
end

-- selector look: only the selected cell bright, the others dim.
local function led_radio(line, selected)
  led_line(line, function(i) return i == selected and LED_ON or LED_DIM end)
end

-- brightness that swings between dim and bright, for "busy" indication.
local function led_pulse()
  local phase = math.sin(util.time() * 2 * math.pi * PULSE_HZ)
  return util.round(util.linlin(-1, 1, LED_DIM, LED_ON, phase))
end

-- ----------------------------------------------------------------------
-- grid: layout
-- ----------------------------------------------------------------------

-- every control is a line of cells plus:
--   press(i) : cell i of the line was pressed
--   draw()   : light the line's leds from the current state
local controls = {}

local function add_control(x, y, dx, dy, n, press, draw)
  local c = {x = x, y = y, dx = dx, dy = dy, n = n, press = press}
  c.draw = function() draw(c) end
  controls[#controls + 1] = c
end

-- a bar fader over a number param, one cell per entry in `steps`.
local function add_step_fader(x, y, dx, dy, steps, id)
  add_control(x, y, dx, dy, #steps,
    function(i) params:set(id, step_to_value(steps, i)) end,
    function(c) led_bar(c, value_to_step(steps, params:get(id))) end)
end

local function build_controls()
  -- row 1: number of voices
  add_step_fader(1, 1, 1, 0, VOICE_STEPS, "voices")

  -- row 2: master amplitude, 0.0 (left) to 1.0 (right)
  add_control(1, 2, 1, 0, AMP_CELLS,
    function(i) params:set("amp", cell_to_value(i, AMP_CELLS, 0, 1)) end,
    function(c) led_bar(c, value_to_cell(params:get("amp"), AMP_CELLS, 0, 1)) end)

  -- rows 3-8, cols 1-5: one weight fader per octave
  for row, o in ipairs(OCTAVES) do
    add_step_fader(1, 2 + row, 1, 0, OCTAVE_STEPS, "octw_" .. o[1])
  end

  -- cols 7-13: one weight fader per note, running up from row 8
  for col, n in ipairs(NOTES) do
    add_step_fader(6 + col, 8, 0, -1, NOTE_STEPS, "weight_" .. n[2])
  end

  -- col 16, rows 4-6: waveform, listed top to bottom as pulse / saw / sine
  -- (the reverse of WAVES, hence the flip)
  add_control(16, 4, 0, 1, #WAVES,
    function(i) params:set("waveform", #WAVES + 1 - i) end,
    function(c) led_radio(c, #WAVES + 1 - params:get("waveform")) end)

  -- col 16, row 8: on/off. bright = playing, pulsing = stopping, dim = at rest
  add_control(16, 8, 0, 0, 1,
    function() toggle_play() end,
    function(c)
      local level = LED_DIM
      if playing then level = LED_ON elseif stopping then level = led_pulse() end
      led_line(c, function() return level end)
    end)
end

local function grid_redraw()
  g:all(0)
  for _, c in ipairs(controls) do c.draw() end
  g:refresh()
end

-- grid keys: z = 1 pressed / 0 released. find the control under the press.
local function grid_key(x, y, z)
  if z == 0 then return end
  for _, c in ipairs(controls) do
    local i = line_cell(c, x, y)
    if i then
      c.press(i)
      return
    end
  end
end

-- ----------------------------------------------------------------------
-- norns lifecycle callbacks
-- ----------------------------------------------------------------------

function init()
  math.randomseed(os.time())

  -- voice count and master level (also on E2 / E3 and the grid).
  params:add_separator("mix")
  params:add_number("voices", "voices", VOICES_MIN, VOICES_MAX, target_voices)
  params:set_action("voices", function(v)
    target_voices = v
    match_voices()
    refresh()
  end)
  params:add_control("amp", "amp", controlspec.new(0, 1, "lin", 0.01, master_amp))
  params:set_action("amp", function(v)
    master_amp = v
    engine.setAmp(master_amp)
    refresh()
  end)

  -- oscillator waveform (shared by every note).
  params:add_separator("oscillator")
  params:add_option("waveform", "waveform", WAVES, 1)
  params:set_action("waveform", refresh)

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
    params:set_action("weight_" .. id, refresh)
  end

  -- one integer weight per octave (0 = octave never used).
  params:add_separator("octave weights")
  for _, o in ipairs(OCTAVES) do
    local octave, default = table.unpack(o)
    params:add_number("octw_" .. octave, "weight oct " .. octave, 0, 20, default)
    params:set_action("octw_" .. octave, refresh)
  end

  -- grid: connect, lay out the controls, and repaint the leds whenever
  -- something changed (or constantly while the on/off led is pulsing).
  g = grid.connect()
  g.key = grid_key
  grid.add = function() grid_dirty = true end
  build_controls()
  clock.run(function()
    while true do
      clock.sleep(1 / GRID_FPS)
      if grid_dirty or stopping then
        grid_dirty = false
        grid_redraw()
      end
    end
  end)

  -- run every param action once: pushes the starting master amplitude to
  -- the engine and draws the screen
  params:bang()
end

-- called by norns when the script is unloaded: leave the grid dark.
function cleanup()
  g:all(0)
  g:refresh()
end

-- encoders: n = which encoder (1,2,3), d = delta (+/-)
function enc(n, d)
  if n == 2 then
    -- E2: number of simultaneous voices
    params:delta("voices", d)
  elseif n == 3 then
    -- E3: overall amplitude / master mix level
    params:delta("amp", d)
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
