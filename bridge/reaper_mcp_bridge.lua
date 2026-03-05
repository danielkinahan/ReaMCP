-- reaper_mcp_bridge.lua
-- Runs inside REAPER as a persistent ReaScript (run once via Actions menu).
-- Listens on TCP localhost:9001, receives JSON-RPC requests, calls reaper.* API,
-- returns JSON responses.
--
-- Requires: mavriq-lua-sockets (install via ReaPack)
--   ReaPack index: https://github.com/mavriq-dev/public-reascripts/raw/master/index.xml
--   Package name:  mavriq-lua-sockets

local HOST = "127.0.0.1"
local PORT = 9001

-- ---------------------------------------------------------------------------
-- Logging
-- ---------------------------------------------------------------------------
local LOG_LEVEL = 'info'  -- 'debug' | 'info' | 'error'
local LEVELS = { debug = 1, info = 2, error = 3 }

local function log(level, msg)
  if (LEVELS[level] or 2) >= (LEVELS[LOG_LEVEL] or 2) then
    local ts = os.date('%H:%M:%S')
    reaper.ShowConsoleMsg(string.format('[MCP %s %s] %s\n', ts, level:upper(), msg))
  end
end

-- ---------------------------------------------------------------------------
-- Minimal JSON encoder / decoder
-- ---------------------------------------------------------------------------
local json = {}

local escape_map = {
  ['"']  = '\\"',
  ['\\'] = '\\\\',
  ['\n'] = '\\n',
  ['\r'] = '\\r',
  ['\t'] = '\\t',
  ['\b'] = '\\b',
  ['\f'] = '\\f',
}

local function esc(s)
  return (s:gsub('.', escape_map))
end

local function is_array(t)
  if type(t) ~= 'table' then return false end
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n == #t
end

function json.encode(val)
  local ty = type(val)
  if val == nil                    then return 'null'
  elseif ty == 'boolean'           then return tostring(val)
  elseif ty == 'number'            then
    if val ~= val then return 'null' end  -- NaN guard
    return string.format('%.14g', val)
  elseif ty == 'string'            then return '"' .. esc(val) .. '"'
  elseif ty == 'table' then
    local parts = {}
    if is_array(val) then
      for i, v in ipairs(val) do parts[i] = json.encode(v) end
      return '[' .. table.concat(parts, ',') .. ']'
    else
      for k, v in pairs(val) do
        table.insert(parts, '"' .. esc(tostring(k)) .. '":' .. json.encode(v))
      end
      return '{' .. table.concat(parts, ',') .. '}'
    end
  end
  return 'null'
end

-- Simple recursive-descent JSON decoder ---------------------------------
local decode_val  -- forward-declared

local function skip(s, i)
  return (s:match('^%s*()', i))
end

local function decode_str(s, i)
  -- i is the position of the opening quote
  i = i + 1
  local out = {}
  while i <= #s do
    local c = s:sub(i, i)
    if c == '"' then return table.concat(out), i + 1 end
    if c == '\\' then
      i = i + 1
      local e = s:sub(i, i)
      local map = { ['"']='"', ['\\']='\\', ['/']='}/', n='\n', r='\r', t='\t', b='\b', f='\f' }
      -- handle \uXXXX as numeric entity for ASCII range only
      if e == 'u' then
        local hex = s:sub(i+1, i+4)
        table.insert(out, string.char(tonumber(hex, 16) or 63))
        i = i + 5
      else
        table.insert(out, map[e] or e)
        i = i + 1
      end
    else
      table.insert(out, c)
      i = i + 1
    end
  end
  error('JSON: unterminated string')
end

local function decode_arr(s, i)
  local arr = {}
  i = skip(s, i + 1)  -- skip '['
  if s:sub(i, i) == ']' then return arr, i + 1 end
  while true do
    local v; v, i = decode_val(s, i)
    table.insert(arr, v)
    i = skip(s, i)
    local c = s:sub(i, i)
    if c == ']' then return arr, i + 1 end
    if c ~= ',' then error('JSON: expected , or ] in array') end
    i = skip(s, i + 1)
  end
end

local function decode_obj(s, i)
  local obj = {}
  i = skip(s, i + 1)  -- skip '{'
  if s:sub(i, i) == '}' then return obj, i + 1 end
  while true do
    if s:sub(i, i) ~= '"' then error('JSON: expected key string') end
    local key; key, i = decode_str(s, i)
    i = skip(s, i)
    if s:sub(i, i) ~= ':' then error('JSON: expected :') end
    i = skip(s, i + 1)
    local val; val, i = decode_val(s, i)
    obj[key] = val
    i = skip(s, i)
    local c = s:sub(i, i)
    if c == '}' then return obj, i + 1 end
    if c ~= ',' then error('JSON: expected , or } in object') end
    i = skip(s, i + 1)
  end
end

decode_val = function(s, i)
  i = skip(s, i)
  local c = s:sub(i, i)
  if c == '"'  then return decode_str(s, i)
  elseif c == '[' then return decode_arr(s, i)
  elseif c == '{' then return decode_obj(s, i)
  elseif s:sub(i, i+3) == 'true'  then return true,  i + 4
  elseif s:sub(i, i+4) == 'false' then return false, i + 5
  elseif s:sub(i, i+3) == 'null'  then return nil,   i + 4
  else
    -- number
    local num_s = s:match('^-?%d+%.?%d*[eE]?[+-]?%d*', i)
    if num_s then return tonumber(num_s), i + #num_s end
    error('JSON: unexpected char ' .. c .. ' at pos ' .. i)
  end
end

function json.decode(s)
  local ok, val = pcall(decode_val, s, 1)
  if not ok then return nil, val end
  return val
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function track_at(idx)
  -- idx is 0-based from the client side
  return reaper.GetTrack(0, idx)
end

local function play_state_str(n)
  if n == 0 then return 'stopped'
  elseif n == 1 then return 'playing'
  elseif n == 2 then return 'paused'
  elseif n == 4 then return 'recording'
  elseif n == 5 then return 'recording_paused'
  else return tostring(n) end
end

local function track_info(track, idx)
  local _, name  = reaper.GetTrackName(track, '')
  local vol  = reaper.GetMediaTrackInfo_Value(track, 'D_VOL')
  local pan  = reaper.GetMediaTrackInfo_Value(track, 'D_PAN')
  local mute = reaper.GetMediaTrackInfo_Value(track, 'B_MUTE')
  local solo = reaper.GetMediaTrackInfo_Value(track, 'I_SOLO')
  local arm  = reaper.GetMediaTrackInfo_Value(track, 'I_RECARM')
  local n_items = reaper.CountTrackMediaItems(track)
  local n_fx    = reaper.TrackFX_GetCount(track)
  return {
    index  = idx,
    name   = name,
    volume = vol,
    pan    = pan,
    mute   = (mute ~= 0),
    solo   = (solo ~= 0),
    arm    = (arm ~= 0),
    n_items = n_items,
    n_fx    = n_fx,
  }
end

-- ---------------------------------------------------------------------------
-- Handlers  (each receives a `params` table and returns a result table)
-- ---------------------------------------------------------------------------
local handlers = {}

-- Connectivity check
handlers.ping = function(_p)
  return { pong = true, reaper_version = reaper.GetAppVersion() }
end

-- Project metadata
handlers.get_project_info = function(_p)
  local _, name     = reaper.GetProjectName(0, '')
  local path        = reaper.GetProjectPath('')
  local bpm, num, denom = reaper.GetTempoTimeSigAtTime(0, 0)
  local play_state  = reaper.GetPlayState()
  local cursor_pos  = reaper.GetCursorPosition()
  local proj_len    = reaper.GetProjectLength(0)
  local n_tracks    = reaper.CountTracks(0)
  return {
    name            = name,
    path            = path,
    bpm             = bpm,
    time_sig_num    = num,
    time_sig_denom  = denom,
    n_tracks        = n_tracks,
    play_state      = play_state_str(play_state),
    cursor_position = cursor_pos,
    length          = proj_len,
  }
end

-- Track listing
handlers.list_tracks = function(_p)
  local tracks = {}
  local n = reaper.CountTracks(0)
  for i = 0, n - 1 do
    local track = reaper.GetTrack(0, i)
    table.insert(tracks, track_info(track, i))
  end
  return tracks
end

-- Single track by index
handlers.get_track = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  return track_info(track, p.track_index)
end

-- Create track
handlers.create_track = function(p)
  local idx = p.index or reaper.CountTracks(0)
  reaper.InsertTrackAtIndex(idx, true)
  local track = reaper.GetTrack(0, idx)
  if p.name then
    reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', p.name, true)
  end
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  return track_info(track, idx)
end

-- Delete a track
handlers.delete_track = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  reaper.DeleteTrack(track)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  return { deleted = true, track_index = p.track_index }
end

-- Modify track properties
handlers.set_track_properties = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  if p.name   ~= nil then reaper.GetSetMediaTrackInfo_String(track, 'P_NAME', p.name, true) end
  if p.volume ~= nil then reaper.SetMediaTrackInfo_Value(track, 'D_VOL',   p.volume) end
  if p.pan    ~= nil then reaper.SetMediaTrackInfo_Value(track, 'D_PAN',   p.pan) end
  if p.mute   ~= nil then reaper.SetMediaTrackInfo_Value(track, 'B_MUTE',  p.mute and 1 or 0) end
  if p.solo   ~= nil then reaper.SetMediaTrackInfo_Value(track, 'I_SOLO',  p.solo and 1 or 0) end
  if p.arm    ~= nil then reaper.SetMediaTrackInfo_Value(track, 'I_RECARM', p.arm and 1 or 0) end
  reaper.UpdateArrange()
  return track_info(track, p.track_index)
end

-- Move a media item to a new timeline position
-- params: track_index, item_index (0-based), position (seconds)
handlers.move_media_item = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  local item = reaper.GetTrackMediaItem(track, p.item_index)
  if not item then error('Item index out of range: ' .. tostring(p.item_index)) end
  reaper.SetMediaItemInfo_Value(item, 'D_POSITION', p.position)
  reaper.UpdateArrange()
  return {
    track_index = p.track_index,
    item_index  = p.item_index,
    position    = reaper.GetMediaItemInfo_Value(item, 'D_POSITION'),
  }
end

-- Resize a media item (change its length)
-- params: track_index, item_index, length (seconds)
handlers.resize_media_item = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  local item = reaper.GetTrackMediaItem(track, p.item_index)
  if not item then error('Item index out of range: ' .. tostring(p.item_index)) end
  reaper.SetMediaItemInfo_Value(item, 'D_LENGTH', p.length)
  reaper.UpdateArrange()
  return {
    track_index = p.track_index,
    item_index  = p.item_index,
    length      = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH'),
  }
end

-- Delete a media item
-- params: track_index, item_index
handlers.delete_media_item = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  local item = reaper.GetTrackMediaItem(track, p.item_index)
  if not item then error('Item index out of range: ' .. tostring(p.item_index)) end
  reaper.DeleteTrackMediaItem(track, item)
  reaper.UpdateArrange()
  return { deleted = true, track_index = p.track_index, item_index = p.item_index }
end

-- Get properties of a media item (position, length, mute, take info)
-- params: track_index, item_index
handlers.get_item_properties = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  local item = reaper.GetTrackMediaItem(track, p.item_index)
  if not item then error('Item index out of range: ' .. tostring(p.item_index)) end
  local position = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
  local length   = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
  local mute     = reaper.GetMediaItemInfo_Value(item, 'B_MUTE')
  local lock     = reaper.GetMediaItemInfo_Value(item, 'C_LOCK')
  local take     = reaper.GetActiveTake(item)
  local take_name, playrate, pitch = '', 1.0, 0.0
  if take then
    take_name = reaper.GetTakeName(take)
    playrate  = reaper.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE')
    pitch     = reaper.GetMediaItemTakeInfo_Value(take, 'D_PITCH')
  end
  return {
    track_index = p.track_index,
    item_index  = p.item_index,
    position    = position,
    length      = length,
    mute        = (mute ~= 0),
    lock        = (lock ~= 0),
    take_name   = take_name,
    playrate    = playrate,
    pitch       = pitch,
  }
end

-- Duplicate a track (inserts copy immediately after)
-- params: track_index
handlers.duplicate_track = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  -- Deselect all tracks, select only target, run Duplicate action
  reaper.Main_OnCommand(40297, 0)  -- Track: Unselect all tracks
  reaper.SetTrackSelected(track, true)
  reaper.Main_OnCommand(40062, 0)  -- Track: Duplicate tracks
  local new_idx = p.track_index + 1
  local new_track = reaper.GetTrack(0, new_idx)
  reaper.UpdateArrange()
  if not new_track then return { duplicated = true, new_track_index = new_idx } end
  return track_info(new_track, new_idx)
end

-- Duplicate a media item (inserts copy immediately after original)
-- params: track_index, item_index
handlers.duplicate_item = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  local item = reaper.GetTrackMediaItem(track, p.item_index)
  if not item then error('Item index out of range: ' .. tostring(p.item_index)) end
  -- Deselect all items, select target, duplicate
  reaper.Main_OnCommand(40289, 0)  -- Item: Unselect all items
  reaper.SetMediaItemSelected(item, true)
  reaper.Main_OnCommand(40698, 0)  -- Item: Duplicate items
  reaper.UpdateArrange()
  -- The duplicate appears after the original at the same position + length
  local n_items = reaper.CountTrackMediaItems(track)
  return { duplicated = true, track_index = p.track_index, n_items = n_items }
end

-- Read all MIDI notes from a take
-- params: track_index, item_index
handlers.get_midi_notes = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  local item = reaper.GetTrackMediaItem(track, p.item_index)
  if not item then error('Item index out of range: ' .. tostring(p.item_index)) end
  local take = reaper.GetActiveTake(item)
  if not take or not reaper.TakeIsMIDI(take) then
    error('Item does not have an active MIDI take')
  end
  local _, note_cnt, _, _ = reaper.MIDI_CountEvts(take)
  local notes = {}
  for i = 0, note_cnt - 1 do
    local _, sel, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
    table.insert(notes, {
      note_index  = i,
      selected    = sel,
      muted       = muted,
      start_ppq   = startppq,
      end_ppq     = endppq,
      channel     = chan,
      pitch       = pitch,
      velocity    = vel,
    })
  end
  return { track_index = p.track_index, item_index = p.item_index, notes = notes }
end

-- Insert a MIDI CC, pitch-bend, or program-change event
-- params: track_index, item_index, event_type ('cc'|'pitch_bend'|'program_change'),
--   ppq, channel (0-based), and type-specific fields:
--   cc:             cc_number (0-127), value (0-127)
--   pitch_bend:     bend (-8192 to 8191, 0 = center)
--   program_change: program (0-127)
handlers.insert_midi_event = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  local item = reaper.GetTrackMediaItem(track, p.item_index)
  if not item then error('Item index out of range: ' .. tostring(p.item_index)) end
  local take = reaper.GetActiveTake(item)
  if not take or not reaper.TakeIsMIDI(take) then
    error('Item does not have an active MIDI take')
  end
  local ppq  = p.ppq     or 0
  local chan  = p.channel or 0
  local sel   = false
  local muted = false
  local ev_type = (p.event_type or ''):lower()
  if ev_type == 'cc' then
    reaper.MIDI_InsertCC(take, sel, muted, ppq, 0xB0, chan, p.cc_number or 0, p.value or 0)
  elseif ev_type == 'pitch_bend' then
    local bend = (p.bend or 0) + 8192  -- shift to 0-16383
    if bend < 0 then bend = 0 elseif bend > 16383 then bend = 16383 end
    local lsb = bend % 128
    local msb = math.floor(bend / 128)
    reaper.MIDI_InsertCC(take, sel, muted, ppq, 0xE0, chan, lsb, msb)
  elseif ev_type == 'program_change' then
    reaper.MIDI_InsertCC(take, sel, muted, ppq, 0xC0, chan, p.program or 0, 0)
  else
    error('Unknown event_type: ' .. tostring(p.event_type))
  end
  reaper.MIDI_Sort(take)
  return { inserted = true, event_type = ev_type, ppq = ppq, channel = chan }
end

-- Delete a MIDI note by its index
-- params: track_index, item_index, note_index
handlers.delete_midi_note = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  local item = reaper.GetTrackMediaItem(track, p.item_index)
  if not item then error('Item index out of range: ' .. tostring(p.item_index)) end
  local take = reaper.GetActiveTake(item)
  if not take or not reaper.TakeIsMIDI(take) then
    error('Item does not have an active MIDI take')
  end
  local ok = reaper.MIDI_DeleteNote(take, p.note_index)
  reaper.MIDI_Sort(take)
  return { deleted = ok, note_index = p.note_index }
end

-- Modify an existing MIDI note
-- params: track_index, item_index, note_index, and any of:
--   start_ppq, end_ppq, pitch, velocity, channel, selected, muted
handlers.set_midi_note = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  local item = reaper.GetTrackMediaItem(track, p.item_index)
  if not item then error('Item index out of range: ' .. tostring(p.item_index)) end
  local take = reaper.GetActiveTake(item)
  if not take or not reaper.TakeIsMIDI(take) then
    error('Item does not have an active MIDI take')
  end
  -- Read existing values so we only overwrite what the caller supplies
  local _, sel, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, p.note_index)
  sel      = (p.selected  ~= nil) and p.selected  or sel
  muted    = (p.muted     ~= nil) and p.muted     or muted
  startppq = p.start_ppq  or startppq
  endppq   = p.end_ppq    or endppq
  chan     = p.channel    or chan
  pitch    = p.pitch      or pitch
  vel      = p.velocity   or vel
  reaper.MIDI_SetNote(take, p.note_index, sel, muted, startppq, endppq, chan, pitch, vel, false)
  reaper.MIDI_Sort(take)
  return {
    note_index = p.note_index,
    start_ppq  = startppq,
    end_ppq    = endppq,
    channel    = chan,
    pitch      = pitch,
    velocity   = vel,
    selected   = sel,
    muted      = muted,
  }
end

-- Create MIDI item (with optional notes)
-- notes: list of {start_ppq, end_ppq, pitch, velocity=100, channel=0}
handlers.create_midi_item = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  local item = reaper.CreateNewMIDIItemInProj(track, p.start, p['end'] or p.end_time)
  local take  = reaper.GetActiveTake(item)
  local inserted = {}
  for _, note in ipairs(p.notes or {}) do
    local vel = note.velocity or 100
    local ch  = note.channel  or 0
    reaper.MIDI_InsertNote(take, false, false,
      note.start_ppq, note.end_ppq,
      ch, note.pitch, vel, false)
    table.insert(inserted, note)
  end
  if #inserted > 0 then reaper.MIDI_Sort(take) end
  reaper.UpdateArrange()
  return {
    track_index    = p.track_index,
    start          = p.start,
    end_time       = p['end'] or p.end_time,
    inserted_notes = inserted,
  }
end

-- Insert audio file at position on track
handlers.insert_audio_file = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  -- Unselect all, select target, move cursor, insert
  reaper.Main_OnCommand(40297, 0)  -- Track: Unselect all
  reaper.SetTrackSelected(track, true)
  reaper.SetEditCurPos(p.position or 0, false, false)
  local ok = reaper.InsertMedia(p.file_path, 0)
  reaper.UpdateArrange()
  return {
    track_index = p.track_index,
    file_path   = p.file_path,
    position    = p.position,
    ok          = (ok ~= 0),
  }
end

-- Transport control
handlers.transport = function(p)
  local action = (p.action or ''):lower()
  if action == 'play' then
    reaper.OnPlayButton()
  elseif action == 'stop' then
    reaper.OnStopButton()
  elseif action == 'pause' then
    reaper.OnPauseButton()
  elseif action == 'record' then
    reaper.OnRecordButton()
  elseif action == 'goto_start' or action == 'start' then
    reaper.SetEditCurPos(0, true, false)
  elseif action == 'goto_position' then
    if p.position == nil then error('goto_position requires position param') end
    reaper.SetEditCurPos(p.position, true, false)
  else
    error('Unknown transport action: ' .. tostring(action))
  end
  return { action = action, play_state = play_state_str(reaper.GetPlayState()) }
end

-- Add FX to track
-- fx_name: any string that VST/AU/etc search accepts (e.g. "ReaComp", "VST: Serum")
handlers.add_fx = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  local input_fx = p.input_fx and true or false
  -- -1 as last argument = add to end; -1000 - desired idx = insert at position
  local fx_idx = reaper.TrackFX_AddByName(track, p.fx_name, input_fx, -1)
  if fx_idx < 0 then error('FX not found: ' .. tostring(p.fx_name)) end
  local _, fx_name_out = reaper.TrackFX_GetFXName(track, fx_idx, '')
  return { track_index = p.track_index, fx_index = fx_idx, fx_name = fx_name_out }
end

-- List FX on a track
handlers.list_fx = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  local n = reaper.TrackFX_GetCount(track)
  local fxs = {}
  for i = 0, n - 1 do
    local _, name = reaper.TrackFX_GetFXName(track, i, '')
    local n_params = reaper.TrackFX_GetNumParams(track, i)
    local enabled = reaper.TrackFX_GetEnabled(track, i)
    table.insert(fxs, { fx_index = i, name = name, n_params = n_params, enabled = enabled })
  end
  return fxs
end

-- Get FX parameters
handlers.get_fx_params = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  local n = reaper.TrackFX_GetNumParams(track, p.fx_index)
  local params = {}
  for i = 0, n - 1 do
    local val, min_val, max_val = reaper.TrackFX_GetParam(track, p.fx_index, i)
    local _, param_name = reaper.TrackFX_GetParamName(track, p.fx_index, i, '')
    local normalized = reaper.TrackFX_GetParamNormalized(track, p.fx_index, i)
    table.insert(params, {
      param_index = i,
      name        = param_name,
      value       = val,
      min_value   = min_val,
      max_value   = max_val,
      normalized  = normalized,
    })
  end
  return params
end

-- Set a single FX parameter (by normalized 0-1 value)
handlers.set_fx_param = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  reaper.TrackFX_SetParamNormalized(track, p.fx_index, p.param_index, p.normalized_value)
  local new_val = reaper.TrackFX_GetParamNormalized(track, p.fx_index, p.param_index)
  return {
    track_index      = p.track_index,
    fx_index         = p.fx_index,
    param_index      = p.param_index,
    normalized_value = new_val,
  }
end

-- Enable or bypass an FX plugin
-- params: track_index, fx_index, enabled (bool)
handlers.set_fx_enabled = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  reaper.TrackFX_SetEnabled(track, p.fx_index, p.enabled)
  local state = reaper.TrackFX_GetEnabled(track, p.fx_index)
  return { track_index = p.track_index, fx_index = p.fx_index, enabled = state }
end

-- Remove an FX from the chain
-- params: track_index, fx_index
handlers.remove_fx = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  local ok = reaper.TrackFX_Delete(track, p.fx_index)
  return { removed = ok, track_index = p.track_index, fx_index = p.fx_index }
end

-- Load an FX preset by name
-- params: track_index, fx_index, preset_name
handlers.set_fx_preset = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  local ok = reaper.TrackFX_SetPreset(track, p.fx_index, p.preset_name)
  local _, current = reaper.TrackFX_GetPreset(track, p.fx_index, '')
  return { loaded = ok, track_index = p.track_index, fx_index = p.fx_index, preset = current }
end

-- Set tempo (and optionally time signature)
handlers.set_tempo = function(p)
  local bpm   = p.bpm
  local n_markers = reaper.CountTempoTimeSigMarkers(0)
  if n_markers == 0 then
    -- Insert a tempo marker at the very start
    local num   = p.time_sig_num   or 4
    local denom = p.time_sig_denom or 4
    reaper.SetTempoTimeSigMarker(0, -1, 0, 0, 0, bpm, num, denom, false)
  else
    -- Update the first existing marker
    local _, _, _, _, _, cur_bpm, cur_num, cur_denom = reaper.GetTempoTimeSigMarker(0, 0)
    local num   = p.time_sig_num   or cur_num
    local denom = p.time_sig_denom or cur_denom
    reaper.SetTempoTimeSigMarker(0, 0, 0, -1, -1, bpm, num, denom, false)
  end
  reaper.UpdateTimeline()
  -- Read back the authoritative values
  local new_bpm, new_num, new_denom = reaper.GetTempoTimeSigAtTime(0, 0)
  return { bpm = new_bpm, time_sig_num = new_num, time_sig_denom = new_denom }
end

-- Get current tempo and time signature
handlers.get_tempo = function(_p)
  local bpm, num, denom = reaper.GetTempoTimeSigAtTime(0, 0)
  return { bpm = bpm, time_sig_num = num, time_sig_denom = denom }
end

-- Generic project parameter setter
-- Supported: loop_start/loop_end, cursor_position, playrate
handlers.set_project_parameter = function(p)
  local param = (p.parameter or ''):lower()
  if param == 'loop_start' or param == 'loop_end' then
    local ls, le = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
    if param == 'loop_start' then ls = p.value else le = p.value end
    reaper.GetSet_LoopTimeRange(true, false, ls, le, false)
  elseif param == 'cursor_position' then
    reaper.SetEditCurPos(p.value, true, false)
  elseif param == 'loop_enabled' then
    -- Toggle loop on/off via the repeat state
    reaper.GetSetRepeat(p.value and 1 or 0)
  elseif param == 'playrate' then
    reaper.CSurf_OnPlayRateChange(p.value)
  else
    error('Unsupported project parameter: ' .. tostring(p.parameter))
  end
  return { parameter = p.parameter, value = p.value }
end

-- Get project parameters
handlers.get_project_parameters = function(_p)
  local ls, le = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  local repeat_state = reaper.GetSetRepeat(-1)
  local cursor_pos   = reaper.GetCursorPosition()
  return {
    loop_start      = ls,
    loop_end        = le,
    loop_enabled    = (repeat_state ~= 0),
    cursor_position = cursor_pos,
  }
end

-- Save the current project
handlers.save_project = function(_p)
  local path = reaper.GetProjectPath('')
  reaper.Main_SaveProject(0, false)
  return { saved = true, path = path }
end

-- Trigger REAPER undo
handlers.undo = function(_p)
  local label = reaper.Undo_CanUndo2(0)
  reaper.Main_OnCommand(40029, 0)  -- Edit: Undo
  return { undone = true, action = tostring(label) }
end

-- Add a marker or region
-- params: name, position, is_region (bool, default false),
--         region_end (required if is_region=true), color (optional, 0=default)
handlers.add_marker = function(p)
  local is_region = p.is_region and true or false
  local color     = p.color or 0
  local rgnend    = p.region_end or p.position
  local idx = reaper.AddProjectMarker2(0, is_region, p.position, rgnend, p.name or '', color)
  return { marker_index = idx, is_region = is_region, position = p.position, name = p.name }
end

-- List all markers and regions
handlers.list_markers = function(_p)
  local n = reaper.CountProjectMarkers(0, nil, nil)
  local markers = {}
  for i = 0, n - 1 do
    local _, isregion, pos, rgnend, name, idx = reaper.EnumProjectMarkers3(0, i)
    table.insert(markers, {
      enum_index = i,
      marker_id  = idx,
      is_region  = isregion,
      position   = pos,
      region_end = rgnend,
      name       = name,
    })
  end
  return markers
end

-- Delete a marker or region by its enumeration index
-- params: enum_index (the 0-based index from list_markers)
handlers.delete_marker = function(p)
  local _, isregion, _, _, _, markrgnidx = reaper.EnumProjectMarkers3(0, p.enum_index)
  local ok = reaper.DeleteProjectMarker(0, markrgnidx, isregion)
  return { deleted = ok, enum_index = p.enum_index }
end

-- Open a project file by its absolute path
handlers.open_project = function(p)
  if not p.file_path or p.file_path == '' then
    error('file_path is required')
  end
  reaper.Main_openProject(p.file_path)
  return { opened = true, file_path = p.file_path }
end

-- ---------------------------------------------------------------------------
-- Routing & sends
-- ---------------------------------------------------------------------------

-- Create a send from one track to another
-- params: src_track_index, dst_track_index
handlers.create_track_send = function(p)
  local src = track_at(p.src_track_index)
  if not src then error('src_track_index out of range') end
  local dst = track_at(p.dst_track_index)
  if not dst then error('dst_track_index out of range') end
  local send_idx = reaper.CreateTrackSend(src, dst)
  local vol = reaper.GetTrackSendInfo_Value(src, 0, send_idx, 'D_VOL')
  local pan = reaper.GetTrackSendInfo_Value(src, 0, send_idx, 'D_PAN')
  return {
    src_track_index = p.src_track_index,
    dst_track_index = p.dst_track_index,
    send_index      = send_idx,
    volume          = vol,
    pan             = pan,
  }
end

-- Remove a track send
-- params: track_index, send_index
handlers.remove_track_send = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  local ok = reaper.RemoveTrackSend(track, 0, p.send_index)
  return { removed = ok, track_index = p.track_index, send_index = p.send_index }
end

-- Set send volume and/or pan
-- params: track_index, send_index, volume (linear), pan (-1 to 1)
handlers.set_track_send = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  if p.volume ~= nil then
    reaper.SetTrackSendInfo_Value(track, 0, p.send_index, 'D_VOL', p.volume)
  end
  if p.pan ~= nil then
    reaper.SetTrackSendInfo_Value(track, 0, p.send_index, 'D_PAN', p.pan)
  end
  local vol = reaper.GetTrackSendInfo_Value(track, 0, p.send_index, 'D_VOL')
  local pan = reaper.GetTrackSendInfo_Value(track, 0, p.send_index, 'D_PAN')
  return { track_index = p.track_index, send_index = p.send_index, volume = vol, pan = pan }
end

-- ---------------------------------------------------------------------------
-- Recording
-- ---------------------------------------------------------------------------

-- Set track recording input
-- params: track_index, input_index
--   Audio inputs: 0-based channel index
--   MIDI: use 4096 + (channel<<5) + device (or pass raw I_RECINPUT int)
handlers.set_track_input = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  reaper.SetMediaTrackInfo_Value(track, 'I_RECINPUT', p.input_index)
  local actual = reaper.GetMediaTrackInfo_Value(track, 'I_RECINPUT')
  return { track_index = p.track_index, input_index = actual }
end

-- Set input monitoring mode
-- params: track_index, mode (0=off, 1=on, 2=not when playing)
handlers.set_input_monitoring = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  reaper.SetMediaTrackInfo_Value(track, 'I_RECMON', p.mode)
  local actual = reaper.GetMediaTrackInfo_Value(track, 'I_RECMON')
  return { track_index = p.track_index, mode = actual }
end

-- ---------------------------------------------------------------------------
-- Automation
-- ---------------------------------------------------------------------------

-- Read all points from a track envelope
-- params: track_index, envelope_index (0-based index of envelope on the track)
handlers.get_envelope_points = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  local env = reaper.GetTrackEnvelope(track, p.envelope_index)
  if not env then error('Envelope index out of range: ' .. tostring(p.envelope_index)) end
  local _, env_name = reaper.GetEnvelopeName(env, '')
  local n = reaper.CountEnvelopePoints(env)
  local points = {}
  for i = 0, n - 1 do
    local _, time, value, shape, tension, selected = reaper.GetEnvelopePoint(env, i)
    table.insert(points, {
      point_index = i,
      time        = time,
      value       = value,
      shape       = shape,
      tension     = tension,
      selected    = selected,
    })
  end
  return {
    track_index    = p.track_index,
    envelope_index = p.envelope_index,
    envelope_name  = env_name,
    points         = points,
  }
end

-- Insert an automation envelope point
-- params: track_index, envelope_index, time, value, shape (0=linear), tension
handlers.insert_envelope_point = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  local env = reaper.GetTrackEnvelope(track, p.envelope_index)
  if not env then error('Envelope index out of range: ' .. tostring(p.envelope_index)) end
  local shape   = p.shape   or 0
  local tension = p.tension or 0.0
  reaper.InsertEnvelopePoint(env, p.time, p.value, shape, tension, false, true)
  reaper.Envelope_SortPoints(env)
  return {
    track_index    = p.track_index,
    envelope_index = p.envelope_index,
    time           = p.time,
    value          = p.value,
    shape          = shape,
    tension        = tension,
  }
end

-- ---------------------------------------------------------------------------
-- JSON-RPC dispatcher
-- ---------------------------------------------------------------------------
local function handle_line(line)
  local req, decode_err = json.decode(line)
  if not req then
    local msg = 'JSON parse error: ' .. tostring(decode_err)
    log('error', msg)
    return json.encode({ id = nil, error = msg })
  end
  local handler = handlers[req.method]
  if not handler then
    local msg = 'Unknown method: ' .. tostring(req.method)
    log('error', msg)
    return json.encode({ id = req.id, error = msg })
  end
  log('debug', 'CALL ' .. tostring(req.method) .. ' (id=' .. tostring(req.id) .. ')')
  local ok, result = pcall(handler, req.params or {})
  if ok then
    log('debug', 'OK   ' .. tostring(req.method))
    return json.encode({ id = req.id, result = result })
  else
    log('error', 'FAIL ' .. tostring(req.method) .. ': ' .. tostring(result))
    return json.encode({ id = req.id, error = tostring(result) })
  end
end

-- ---------------------------------------------------------------------------
-- TCP server (mavriq-lua-sockets, non-blocking defer loop)
-- ---------------------------------------------------------------------------

-- mavriq-lua-sockets is a statically-linked build of luasocket that works
-- inside REAPER's embedded Lua (which is missing lauxlib).
-- Install it via ReaPack: https://github.com/mavriq-dev/public-reascripts/raw/master/index.xml
do
  local res = reaper.GetResourcePath()
  local sep = package.config:sub(1, 1)
  -- ReaPack installs mavriq-lua-sockets here (note: spaces, mixed case)
  local base = res .. sep .. 'Scripts' .. sep
            .. 'Mavriq ReaScript Repository' .. sep
            .. 'Various' .. sep
            .. 'Mavriq-Lua-Sockets' .. sep

  log('info', 'mavriq base: ' .. base)

  -- socket.lua lives at base; socket/core.so is found via cpath '?.so'
  -- because Lua maps 'socket.core' -> 'socket/core.so' automatically
  package.path  = base .. '?.lua;'
               .. base .. '?' .. sep .. 'init.lua;'
               .. package.path
  package.cpath = base .. '?.so;'
               .. base .. '?.dll;'
               .. base .. '?.dylib;'
               .. package.cpath
end

local socket_ok, socket = pcall(require, 'socket')
if not socket_ok then
  reaper.ShowMessageBox(
    'mavriq-lua-sockets could not be loaded. Reaper MCP bridge cannot start.\n\n' ..
    'Install it via ReaPack:\n' ..
    '  1. Extensions -> ReaPack -> Import repositories\n' ..
    '  2. Add: https://github.com/mavriq-dev/public-reascripts/raw/master/index.xml\n' ..
    '  3. Extensions -> ReaPack -> Browse packages\n' ..
    '  4. Find and install "mavriq-lua-sockets"\n' ..
    '  5. Restart REAPER and run this script again.\n\n' ..
    'Raw error: ' .. tostring(socket),
    'Reaper MCP Bridge', 0)
  return
end

local server, bind_err = socket.bind(HOST, PORT)
if not server then
  reaper.ShowMessageBox(
    'Failed to bind to ' .. HOST .. ':' .. PORT .. '\n' .. tostring(bind_err) ..
    '\n\nAnother instance may already be running.',
    'Reaper MCP Bridge', 0)
  return
end
server:settimeout(0)  -- non-blocking

-- Track connected clients as {sock, buf} tables
local clients = {}

local function remove_client(i)
  log('info', 'Client disconnected (slot ' .. i .. ')')
  clients[i].sock:close()
  table.remove(clients, i)
end

-- Service one client; returns true if client should be kept, false to remove
local function service_client(c)
  -- Use select to check if data is actually ready before calling receive.
  -- This avoids mavriq returning 'wantread' / 'timeout' when data is in flight.
  local readable = socket.select({c.sock}, nil, 0)
  if readable and readable[1] then
    local chunk, err, partial = c.sock:receive(4096)
    local data = chunk or partial or ''
    if data ~= '' then
      log('debug', 'Received ' .. #data .. ' bytes')
      c.buf = c.buf .. data
    end
    if err and err ~= 'timeout' and err ~= 'wantread' then
      log('info', 'Client receive error: ' .. tostring(err))
      return false  -- remove
    end
  end

  -- Process all complete newline-delimited messages in the buffer
  local alive = true
  while alive do
    local nl = c.buf:find('\n', 1, true)
    if not nl then break end
    local line = c.buf:sub(1, nl - 1)
    c.buf = c.buf:sub(nl + 1)
    if line ~= '' then
      local response = handle_line(line)
      local send_ok, send_err = c.sock:send(response .. '\n')
      if not send_ok then
        log('error', 'Send failed: ' .. tostring(send_err))
        alive = false
      end
    end
  end
  return alive
end

local function tick()

  -- Accept any new connection
  local new_client, accept_err = server:accept()
  if new_client then
    new_client:settimeout(0)
    table.insert(clients, { sock = new_client, buf = '' })
    log('info', 'Client connected (total=' .. #clients .. ')')
  elseif accept_err and accept_err ~= 'timeout' then
    log('error', 'accept() error: ' .. tostring(accept_err))
  end

  -- Service each connected client
  local i = 1
  while i <= #clients do
    local keep = service_client(clients[i])
    if keep then
      i = i + 1
    else
      remove_client(i)
    end
  end
end

log('info', string.format('Listening on %s:%d', HOST, PORT))

local function protected_tick()
  local ok, err = pcall(tick)
  if not ok then
    -- Use ShowConsoleMsg directly so this can never be swallowed
    reaper.ShowConsoleMsg('[MCP FATAL] Tick crashed: ' .. tostring(err) .. '\n')
  end
  reaper.defer(protected_tick)
end

protected_tick()
