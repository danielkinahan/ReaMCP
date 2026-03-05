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
local BRIDGE_VERSION = "0.2.0"

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
  -- idx is 0-based from the client side; -1 means the master track
  if idx == -1 then return reaper.GetMasterTrack(0) end
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
-- Helpers  (each receives a `params` table and returns a result table)
-- ---------------------------------------------------------------------------
local handlers = {}

-- Returns bpm, time_sig_num, time_sig_denom for the current project
local function get_tempo_info()
  local bpm   = reaper.Master_GetTempo()
  local num, denom = 4, 4
  local n = reaper.CountTempoTimeSigMarkers(0)
  if n > 0 then
    local _, _, _, _, mk_bpm, mk_num, mk_denom = reaper.GetTempoTimeSigMarker(0, 0)
    if mk_bpm and mk_bpm > 0 then bpm = mk_bpm end
    if mk_num  and mk_num  > 0 then num   = mk_num  end
    if mk_denom and mk_denom > 0 then denom = mk_denom end
  end
  return bpm, num, denom
end

-- Connectivity check
handlers.ping = function(_p)
  return { pong = true, bridge_version = BRIDGE_VERSION, reaper_version = reaper.GetAppVersion() }
end

-- Project metadata
handlers.get_project_info = function(_p)
  local _, name     = reaper.GetProjectName(0, '')
  local path        = reaper.GetProjectPath('')
  local bpm, num, denom = get_tempo_info()
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

-- Trim trailing silence from a media item by scanning samples with the audio accessor.
-- params: track_index, item_index, threshold_db (default -60)
-- Shrinks the item's right edge to just after the last non-silent frame.
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
  local take_name, playrate, pitch, source_length_s, start_offset = '', 1.0, 0.0, nil, 0.0
  if take then
    take_name    = reaper.GetTakeName(take)
    playrate     = reaper.GetMediaItemTakeInfo_Value(take, 'D_PLAYRATE')
    pitch        = reaper.GetMediaItemTakeInfo_Value(take, 'D_PITCH')
    start_offset = reaper.GetMediaItemTakeInfo_Value(take, 'D_STARTOFFS')
    local source = reaper.GetMediaItemTake_Source(take)
    if source then
      -- GetMediaSourceLength: pass false to get length in seconds (not QN)
      local src_len, is_qn = reaper.GetMediaSourceLength(source, false)
      if not is_qn then source_length_s = src_len end
    end
  end
  return {
    track_index      = p.track_index,
    item_index       = p.item_index,
    position         = position,
    length           = length,
    mute             = (mute ~= 0),
    lock             = (lock ~= 0),
    take_name        = take_name,
    playrate         = playrate,
    pitch            = pitch,
    start_offset     = start_offset,      -- source offset (seconds) where take playback starts
    source_length_s  = source_length_s,   -- total source file duration in seconds
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
  -- Strip decorated suffixes that GetFXName appends (e.g. "!!!VSTi", "!!!VST3", "!!!JS")
  -- so that names copied from list_fx work transparently.
  local search_name = tostring(p.fx_name):gsub('!!!%S+$', ''):match('^%s*(.-)%s*$')
  -- -1 as last argument = add to end; -1000 - desired idx = insert at position
  local fx_idx = reaper.TrackFX_AddByName(track, search_name, input_fx, -1)
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

  local n_fx = reaper.TrackFX_GetCount(track)
  if p.fx_index < 0 or p.fx_index >= n_fx then
    error('FX index out of range: ' .. tostring(p.fx_index) .. ' (track has ' .. n_fx .. ' FX)')
  end

  local function get_preset_name()
    local _, name = reaper.TrackFX_GetPreset(track, p.fx_index, '')
    return name or ''
  end

  -- Absolute file path (.ffp / .fxp / .fxb)
  local is_path = p.preset_name:sub(1, 1) == '/' or p.preset_name:match('^%a:\\')
  if is_path then
    local f = io.open(p.preset_name, 'rb')
    if not f then error('Preset file unreadable or not found: ' .. p.preset_name) end
    f:close()
    local ok = reaper.TrackFX_SetNamedConfigParm(track, p.fx_index, 'presetfile', p.preset_name)
    if not ok then ok = reaper.TrackFX_SetPreset(track, p.fx_index, p.preset_name) end
    local result = { loaded = ok, track_index = p.track_index, fx_index = p.fx_index, preset = get_preset_name() }
    if not ok then result.failure_reason = 'plugin_rejected_state' end
    return result
  end

  -- Try direct name match first (fast path — works when the name matches exactly)
  if reaper.TrackFX_SetPreset(track, p.fx_index, p.preset_name) then
    return { loaded = true, track_index = p.track_index, fx_index = p.fx_index, preset = get_preset_name() }
  end

  -- TrackFX_SetPreset failed — enumerate all presets and find by case-insensitive match,
  -- then load via TrackFX_SetPresetByIndex (which is more reliable than name matching).
  local orig_idx, n_presets = reaper.TrackFX_GetPresetIndex(track, p.fx_index)
  if n_presets == 0 then
    return { loaded = false, failure_reason = 'plugin_has_no_presets',
             track_index = p.track_index, fx_index = p.fx_index, preset = get_preset_name() }
  end

  local target = p.preset_name:lower()
  local found_idx = nil
  for i = 0, n_presets - 1 do
    reaper.TrackFX_SetPresetByIndex(track, p.fx_index, i)
    local iname = get_preset_name()
    if iname:lower() == target then
      found_idx = i
      break
    end
  end

  if found_idx then
    -- Already loaded via SetPresetByIndex inside the loop; confirm and return success
    reaper.TrackFX_SetPresetByIndex(track, p.fx_index, found_idx)
    return { loaded = true, track_index = p.track_index, fx_index = p.fx_index, preset = get_preset_name() }
  end

  -- Not found — restore original preset and report failure
  reaper.TrackFX_SetPresetByIndex(track, p.fx_index, orig_idx)
  return { loaded = false, failure_reason = 'preset_name_not_found',
           track_index = p.track_index, fx_index = p.fx_index, preset = get_preset_name() }
end

-- List available presets for a plugin by name.
-- FabFilter (and many others) store presets as files on disk;
-- REAPER's TrackFX_SetPreset() can load them by the filename stem.
-- params: fx_name (e.g. "Twin 3 (FabFilter)" or "Twin 3"), category (optional filter)
handlers.list_fx_presets = function(p)
  if not p or not p.fx_name then error('fx_name required') end

  -- Normalise: strip leading "VST3i: " / "VSTi: " / "CLAP: " etc., trim spaces
  local name = p.fx_name:match('^%S+:%s+(.+)$') or p.fx_name
  name = name:match('^%s*(.-)%s*$')

  -- Also produce a "short" name with the vendor suffix stripped, e.g.
  -- "Twin 3 (FabFilter)" → "Twin 3"
  local short = name:match('^(.-)%s*%([^)]+%)%s*$') or name

  local cat_filter = p.category and p.category:lower() or nil

  -- Directories to search (in priority order).
  -- 1. ~/Documents/{Vendor}/Presets/{PluginName}/   (FabFilter pattern)
  -- 2. ~/Documents/Presets/{PluginName}/            (generic)
  -- 3. {REAPER resource path}/presets/{PluginName}/ (REAPER own store)
  local home = os.getenv('HOME') or ''
  local res  = reaper.GetResourcePath()

  -- Detect vendor from parenthesised suffix, e.g. "(FabFilter)"
  local vendor = name:match('%(([^)]+)%)%s*$') or ''

  local search_dirs = {}
  if vendor ~= '' then
    table.insert(search_dirs, home .. '/Documents/' .. vendor .. '/Presets/' .. short)
    table.insert(search_dirs, home .. '/Documents/' .. vendor .. '/Presets/' .. name)
  end
  table.insert(search_dirs, home .. '/Documents/Presets/' .. short)
  table.insert(search_dirs, home .. '/Documents/Presets/' .. name)
  table.insert(search_dirs, res  .. '/presets/' .. short)
  table.insert(search_dirs, res  .. '/presets/' .. name)

  local results   = {}
  local found_dir = nil

  for _, dir in ipairs(search_dirs) do
    -- Check if the directory exists by attempting to open it
    local test = io.open(dir .. '/.', 'r')  -- works on some systems
    -- More reliable: try listing a known pattern via popen
    local probe = io.popen('ls -1 "' .. dir .. '" 2>/dev/null')
    if probe then
      local listing = probe:read('*a')
      probe:close()
      if listing and listing ~= '' then
        found_dir = dir
        break
      end
    end
  end

  if not found_dir then
    return { fx_name = p.fx_name, presets = results, count = 0,
             note = 'No preset directory found. Searched: ' .. table.concat(search_dirs, ', ') }
  end

  -- Walk the found directory recursively (one level of sub-dirs = categories)
  -- Use find for simplicity
  local cmd = 'find "' .. found_dir .. '" -name "*.ffp" -o -name "*.fxp" 2>/dev/null'
  local pipe = io.popen(cmd)
  if pipe then
    for line in pipe:lines() do
      line = line:match('^%s*(.-)%s*$')
      if line ~= '' then
        -- Category = immediate parent folder name relative to found_dir
        local rel  = line:sub(#found_dir + 2)  -- strip base dir + separator
        local cat, pname = rel:match('^(.*)/([^/]+)$')
        if not cat then
          cat   = ''
          pname = rel
        end
        pname = pname:match('^(.+)%.[^.]+$') or pname  -- strip extension

        local include = true
        if cat_filter then
          include = cat:lower():find(cat_filter, 1, true) ~= nil
        end
        if include then
          table.insert(results, { category = cat, name = pname, path = line })
        end
      end
    end
    pipe:close()
  end

  table.sort(results, function(a, b)
    if a.category ~= b.category then return a.category < b.category end
    return a.name < b.name
  end)

  return { fx_name = p.fx_name, preset_dir = found_dir,
           count = #results, presets = results }
end

-- List available presets for an FX already on a track.
-- Returns both file-based presets (disk scan) and factory presets (via plugin enumeration).
-- params: track_index, fx_index
handlers.list_fx_presets = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  local n_fx = reaper.TrackFX_GetCount(track)
  if p.fx_index < 0 or p.fx_index >= n_fx then
    error('FX index out of range: ' .. tostring(p.fx_index))
  end

  -- TrackFX_GetPresetIndex returns (current_index, numberOfPresets)
  local saved_idx, n_presets = reaper.TrackFX_GetPresetIndex(track, p.fx_index)
  local _, current_preset = reaper.TrackFX_GetPreset(track, p.fx_index, '')
  local factory_presets = {}

  if n_presets > 0 then
    -- Remember which preset is active so we can restore it after enumeration
    for i = 0, n_presets - 1 do
      reaper.TrackFX_SetPresetByIndex(track, p.fx_index, i)
      local _, pname = reaper.TrackFX_GetPreset(track, p.fx_index, '')
      table.insert(factory_presets, { index = i, name = pname, source = 'factory' })
    end
    -- Restore the original preset
    reaper.TrackFX_SetPresetByIndex(track, p.fx_index, saved_idx)
  end

  -- Also scan disk for file-based presets (.ffp / .fxp)
  local _, fx_name_full = reaper.TrackFX_GetFXName(track, p.fx_index, '')
  local fx_name = fx_name_full:gsub('!!!%S+$', ''):match('^%s*(.-)%s*$')
  local short = fx_name:match('^(.-)%s*%([^)]+%)%s*$') or fx_name
  local vendor = fx_name:match('%(([^)]+)%)%s*$') or ''
  local home = os.getenv('HOME') or ''
  local res  = reaper.GetResourcePath()

  local search_dirs = {}
  if vendor ~= '' then
    table.insert(search_dirs, home .. '/Documents/' .. vendor .. '/Presets/' .. short)
    table.insert(search_dirs, home .. '/Documents/' .. vendor .. '/Presets/' .. fx_name)
  end
  table.insert(search_dirs, home .. '/Documents/Presets/' .. short)
  table.insert(search_dirs, home .. '/Documents/Presets/' .. fx_name)
  table.insert(search_dirs, res  .. '/presets/' .. short)
  table.insert(search_dirs, res  .. '/presets/' .. fx_name)

  local file_presets = {}
  for _, dir in ipairs(search_dirs) do
    local probe = io.popen('ls -1 "' .. dir .. '" 2>/dev/null')
    if probe then
      local listing = probe:read('*a')
      probe:close()
      if listing and listing ~= '' then
        local pipe = io.popen('find "' .. dir .. '" \\( -name "*.ffp" -o -name "*.fxp" \\) 2>/dev/null')
        if pipe then
          for line in pipe:lines() do
            line = line:match('^%s*(.-)%s*$')
            local rel  = line:sub(#dir + 2)
            local cat, pname = rel:match('^(.*)/([^/]+)$')
            if not cat then cat = ''; pname = rel end
            pname = pname:match('^(.+)%.[^.]+$') or pname
            table.insert(file_presets, { name = pname, category = cat, path = line, source = 'file' })
          end
          pipe:close()
        end
        break
      end
    end
  end

  table.sort(file_presets, function(a, b)
    if a.category ~= b.category then return a.category < b.category end
    return a.name < b.name
  end)

  return {
    track_index     = p.track_index,
    fx_index        = p.fx_index,
    fx_name         = fx_name_full,
    current_preset  = current_preset,
    factory_count   = #factory_presets,
    factory_presets = factory_presets,
    file_count      = #file_presets,
    file_presets    = file_presets,
  }
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
    local _, _, _, _, cur_bpm, cur_num, cur_denom = reaper.GetTempoTimeSigMarker(0, 0)
    local num   = p.time_sig_num   or cur_num
    local denom = p.time_sig_denom or cur_denom
    reaper.SetTempoTimeSigMarker(0, 0, 0, -1, -1, bpm, num, denom, false)
  end
  reaper.UpdateTimeline()
  -- Read back the authoritative values
  local new_bpm, new_num, new_denom = get_tempo_info()
  return { bpm = new_bpm, time_sig_num = new_num, time_sig_denom = new_denom }
end

-- Get current tempo and time signature
handlers.get_tempo = function(_p)
  local bpm, num, denom = get_tempo_info()
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

-- Render a time range to a file using REAPER's built-in render pipeline.
-- params: output_path (absolute path incl. extension), start_time, end_time,
--         sample_rate (default 0 = project rate), channels (1 or 2, default 2)
-- Returns: output_path, duration, file_size_bytes once render completes.
handlers.render_time_selection = function(p)
  if not p.output_path or p.output_path == '' then error('output_path is required') end
  if not p.start_time or not p.end_time then error('start_time and end_time are required') end
  if p.end_time <= p.start_time then error('end_time must be greater than start_time') end

  -- Set the time selection that RENDER_BOUNDSFLAG=2 will use
  reaper.GetSet_LoopTimeRange(true, false, p.start_time, p.end_time, false)

  -- Configure render settings
  reaper.GetSetProjectInfo_String(0, 'RENDER_FILE', p.output_path, true)
  reaper.GetSetProjectInfo(0, 'RENDER_BOUNDSFLAG', 2, true)   -- 2 = time selection
  reaper.GetSetProjectInfo(0, 'RENDER_ADDTOPROJ',  0, true)   -- don't import result
  if p.sample_rate and p.sample_rate > 0 then
    reaper.GetSetProjectInfo(0, 'RENDER_SRATE', p.sample_rate, true)
  end
  if p.channels then
    reaper.GetSetProjectInfo(0, 'RENDER_CHANNELS', p.channels, true)
  end

  -- Action 41824: "File: Render project, using the most recent render settings"
  -- This blocks until rendering is complete.
  reaper.Main_OnCommand(41824, 0)

  -- Verify output was written
  local f = io.open(p.output_path, 'rb')
  local file_size = 0
  if f then
    file_size = f:seek('end')
    f:close()
  else
    -- REAPER may append an extension; try to detect it
    local alt = p.output_path .. '.wav'
    local f2 = io.open(alt, 'rb')
    if f2 then
      file_size = f2:seek('end')
      f2:close()
      p.output_path = alt
    end
  end

  return {
    output_path  = p.output_path,
    start_time   = p.start_time,
    end_time     = p.end_time,
    duration     = p.end_time - p.start_time,
    file_size_bytes = file_size,
  }
end

-- Analyse audio on a track over a time range.
-- Renders the track to a stereo stem in-place (action 40728) so that VST
-- instrument output is captured, then reads the rendered item with a take
-- Measure loudness of a single track over a time range (non-destructive dry-run).
-- Uses action 42439: "Calculate loudness of selected tracks within time selection via dry run render".
-- params: track_index, start_time, end_time
handlers.analyze_track_loudness = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end

  local t1 = p.start_time or 0
  local t2 = p.end_time   or reaper.GetProjectLength(0)
  if t2 <= t1 then error('end_time must be greater than start_time') end

  -- Select only this track and set the time selection
  reaper.SetOnlyTrackSelected(track)
  reaper.GetSet_LoopTimeRange(true, false, t1, t2, false)

  -- Action 42439: "Calculate loudness of selected tracks within time selection via dry run render"
  -- Runs a silent render pass to measure loudness; no files written, project unchanged.
  reaper.Main_OnCommand(42439, 0)

  -- Read the loudness statistics written by the action into the project
  local _, stats_str = reaper.GetSetProjectInfo_String(0, 'RENDER_STATS', '', false)
  stats_str = stats_str or ''

  -- Parse KEY:VALUE;KEY:VALUE format written by REAPER's loudness actions
  local stats = {}
  for key, val in stats_str:gmatch('([^:;]+):([^;]+)') do
    stats[key:upper():match('^%s*(.-)%s*$')] = tonumber(val) or val
  end

  return {
    track_index       = p.track_index,
    start_time        = t1,
    end_time          = t2,
    duration          = t2 - t1,
    lufs_i            = stats['LUFSI'],
    lufs_s_max        = stats['LUFSSMAX'],
    lufs_m_max        = stats['LUFSMMAX'],
    true_peak_db      = stats['PEAK'],
    raw_stats         = stats_str,
    render_stats_html = '/tmp/render_stats.html',
  }
end


-- Trigger REAPER undo
-- Measure loudness of the full master mix over a time range (non-destructive dry-run).
-- Uses action 42441: "Calculate loudness of master mix within time selection via dry run render".
-- params: start_time, end_time
handlers.analyze_master_loudness = function(p)
  local t1 = p.start_time or 0
  local t2 = p.end_time   or reaper.GetProjectLength(0)
  if t2 <= t1 then error('end_time must be greater than start_time') end

  reaper.GetSet_LoopTimeRange(true, false, t1, t2, false)

  -- Action 42441: "Calculate loudness of master mix within time selection via dry run render"
  reaper.Main_OnCommand(42441, 0)

  local _, stats_str = reaper.GetSetProjectInfo_String(0, 'RENDER_STATS', '', false)
  stats_str = stats_str or ''

  local stats = {}
  for key, val in stats_str:gmatch('([^:;]+):([^;]+)') do
    stats[key:upper():match('^%s*(.-)%s*$')] = tonumber(val) or val
  end

  return {
    start_time        = t1,
    end_time          = t2,
    duration          = t2 - t1,
    lufs_i            = stats['LUFSI'],
    lufs_s_max        = stats['LUFSSMAX'],
    lufs_m_max        = stats['LUFSMMAX'],
    true_peak_db      = stats['PEAK'],
    raw_stats         = stats_str,
    render_stats_html = '/tmp/render_stats.html',
  }
end

-- Normalize a track to a target integrated loudness level over a time range.
-- Measures current LUFS via dry-run render (42439), calculates the required
-- gain adjustment, and applies it to the track fader.
-- params: track_index, start_time, end_time, target_lufs (default -14.0)
handlers.normalize_track = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end

  local t1          = p.start_time or 0
  local t2          = p.end_time   or reaper.GetProjectLength(0)
  local target_lufs = p.target_lufs or -14.0
  if t2 <= t1 then error('end_time must be greater than start_time') end

  reaper.SetOnlyTrackSelected(track)
  reaper.GetSet_LoopTimeRange(true, false, t1, t2, false)
  reaper.Main_OnCommand(42439, 0)  -- dry-run loudness of selected tracks

  local _, stats_str = reaper.GetSetProjectInfo_String(0, 'RENDER_STATS', '', false)
  stats_str = stats_str or ''
  local stats = {}
  for key, val in stats_str:gmatch('([^:;]+):([^;]+)') do
    stats[key:upper():match('^%s*(.-)%s*$')] = tonumber(val) or val
  end

  local lufs_i = stats['LUFSI']
  if not lufs_i then
    error('Could not read integrated loudness. raw_stats="' .. stats_str .. '"')
  end

  local gain_db        = target_lufs - lufs_i
  local old_vol        = reaper.GetMediaTrackInfo_Value(track, 'D_VOL')
  local gain_linear    = 10 ^ (gain_db / 20)
  local new_vol        = old_vol * gain_linear

  reaper.SetMediaTrackInfo_Value(track, 'D_VOL', new_vol)
  reaper.Undo_OnStateChangeEx2(0, 'Normalize track ' .. tostring(p.track_index), -1, -1)

  return {
    track_index       = p.track_index,
    start_time        = t1,
    end_time          = t2,
    measured_lufs_i   = lufs_i,
    target_lufs       = target_lufs,
    gain_applied_db   = math.floor(gain_db * 100 + 0.5) / 100,
    old_volume_linear = old_vol,
    new_volume_linear = new_vol,
    render_stats_html = '/tmp/render_stats.html',
  }
end

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
  local idx = reaper.AddProjectMarker2(0, is_region, p.position, rgnend, p.name or '', -1, color)
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

-- Create a new blank project (equivalent to File > New Project)
handlers.new_project = function(_p)
  reaper.Main_OnCommand(40023, 0)  -- File: New project
  return { ok = true }
end

-- List installed FX with optional name/category filter
-- params: filter (optional string, case-insensitive substring match on name or type)
-- Sources:  reaper-vstplugins64.ini  (VSTs)  +  built-in ReaPlugs
handlers.list_available_fx = function(p)
  local filter = p and p.filter and p.filter:lower() or nil
  local results = {}
  local res = reaper.GetResourcePath()

  local function add(name, fxtype)
    if name and name ~= '' then
      name = name:match('^%s*(.-)%s*$')  -- trim whitespace
      local key = (name .. ' ' .. fxtype):lower()
      if not filter or key:find(filter, 1, true) then
        table.insert(results, { name = name, type = fxtype })
      end
    end
  end

  -- 1. JS/JSFX: parse reaper-jsfx.ini
  --    Format:  NAME path/to/fx "JS: Display Name (Vendor)"
  local jf = io.open(res .. '/reaper-jsfx.ini', 'r')
  if jf then
    for line in jf:lines() do
      local name = line:match('^NAME%s+%S+%s+"(.+)"%s*$')
      add(name, 'JS')
    end
    jf:close()
  end

  -- 2. VST2 / VST3: parse reaper-vstplugins64.ini
  --    Format:  PluginFile.vst[3]=timestamp,GUID,Display Name[!!!VSTi]
  --    Detect VST3 by ".vst3" in the key (filename before "=").
  local vf = io.open(res .. '/reaper-vstplugins64.ini', 'r')
  if vf then
    for line in vf:lines() do
      if line ~= '' and line:sub(1, 1) ~= '[' then
        local key_part, val = line:match('^([^=]+)=(.+)$')
        if key_part and val then
          local fxtype = key_part:lower():match('%.vst3$') and 'VST3' or 'VST'
          -- name is the 3rd comma-separated field
          local n, name = 0, nil
          for field in (val .. ','):gmatch('([^,]*),') do
            n = n + 1
            if n == 3 then name = field; break end
          end
          add(name, fxtype)
        end
      end
    end
    vf:close()
  end

  -- 3. CLAP: filename is platform-specific (e.g. reaper-clap-linux-x86_64.ini)
  --    Format:  [Plugin.clap] section headers, then
  --             someId=count|Display Name  lines (skip _=timestamp lines)
  local clap_candidates = {
    res .. '/reaper-clap-linux-x86_64.ini',
    res .. '/reaper-clap-linux-aarch64.ini',
    res .. '/reaper-clap-macos-arm64.ini',
    res .. '/reaper-clap-macos-x86_64.ini',
    res .. '/reaper-clapplugins.ini',  -- Windows / legacy
  }
  for _, clap_path in ipairs(clap_candidates) do
    local cf = io.open(clap_path, 'r')
    if cf then
      for line in cf:lines() do
        -- skip blank lines, [section] headers, and _=timestamp lines
        if line ~= '' and line:sub(1,1) ~= '[' and not line:match('^_=') then
          local name = line:match('|(.+)$')  -- take everything after the first '|'
          add(name, 'CLAP')
        end
      end
      cf:close()
      break  -- found the file for this platform, stop looking
    end
  end

  return { filter = p and p.filter or nil, count = #results, fx = results }
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

-- Built-in envelope action IDs (toggle visible = create if not in chunk)
local BUILTIN_ENV_ACTIONS = {
  Volume = 40406, Pan = 40407,
}

-- Return the named envelope, creating it via action if necessary.
local function get_or_create_track_envelope(track, env_name)
  local env = reaper.GetTrackEnvelopeByName(track, env_name)
  if env then return env end

  local action_id = BUILTIN_ENV_ACTIONS[env_name]
  if not action_id then return nil end

  -- Select only this track, run the "toggle visible" action (creates if absent),
  -- then restore the previous selection.
  local n_sel = reaper.CountSelectedTracks(0)
  local prev_sel = {}
  for i = 0, n_sel - 1 do prev_sel[i] = reaper.GetSelectedTrack(0, i) end

  reaper.SetOnlyTrackSelected(track)
  reaper.Main_OnCommandEx(action_id, 0, 0)  -- creates + shows the envelope

  -- Restore selection
  if n_sel == 0 then
    reaper.SetTrackSelected(track, false)
  else
    reaper.SetOnlyTrackSelected(prev_sel[0])
    for i = 1, n_sel - 1 do reaper.SetTrackSelected(prev_sel[i], true) end
  end

  return reaper.GetTrackEnvelopeByName(track, env_name)
end

-- Temporary debug: expose the raw track state chunk
handlers.get_track_chunk = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  local ok, chunk = reaper.GetTrackStateChunk(track, '', false)
  return { ok = ok, chunk = chunk }
end

-- Read all points from a track envelope
-- params: track_index, envelope_name (e.g. 'Volume', 'Pan') OR envelope_index (0-based)
handlers.get_envelope_points = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  local env
  if p.envelope_name then
    env = reaper.GetTrackEnvelopeByName(track, p.envelope_name)
    if not env then error('Envelope not found: ' .. tostring(p.envelope_name)) end
  else
    env = reaper.GetTrackEnvelope(track, p.envelope_index)
    if not env then error('Envelope index out of range: ' .. tostring(p.envelope_index)) end
  end
  local _, env_name = reaper.GetEnvelopeName(env, '')
  local scaling_mode = reaper.GetEnvelopeScalingMode(env)
  local n = reaper.CountEnvelopePoints(env)
  local points = {}
  for i = 0, n - 1 do
    local _, time, raw_value, shape, tension, selected = reaper.GetEnvelopePoint(env, i)
    -- ScaleFromEnvelopeMode converts raw internal value → normalized (fader pos 0-1 for Volume)
    local value = reaper.ScaleFromEnvelopeMode(scaling_mode, raw_value)
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
    scaling_mode   = scaling_mode,  -- 0=no scaling, 1=fader scaling
    points         = points,
  }
end

-- Clear all automation envelope points in a time range (default: entire timeline)
-- params: track_index, envelope_name OR envelope_index, t1 (default 0), t2 (default 1e12)
handlers.clear_envelope_points = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  local env
  if p.envelope_name then
    env = reaper.GetTrackEnvelopeByName(track, p.envelope_name)
    if not env then error('Envelope not found: ' .. tostring(p.envelope_name)) end
  else
    env = reaper.GetTrackEnvelope(track, p.envelope_index)
    if not env then error('Envelope index out of range: ' .. tostring(p.envelope_index)) end
  end
  local t1 = p.t1 or 0
  local t2 = p.t2 or 1e12
  local n_before = reaper.CountEnvelopePoints(env)
  reaper.DeleteEnvelopePointRange(env, t1, t2)
  local n_after = reaper.CountEnvelopePoints(env)
  return { deleted = n_before - n_after, remaining = n_after }
end

-- Insert an automation envelope point
-- params: track_index, envelope_name (e.g. 'Volume', 'Pan') OR envelope_index, time, value, shape (0=linear), tension
-- value is linear amplitude: 0.0=silence, 1.0=0dB, 2.0=+6dB (max) for Volume envelope
handlers.insert_envelope_point = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  local env
  if p.envelope_name then
    env = get_or_create_track_envelope(track, p.envelope_name)
    if not env then error('Envelope not found or could not be created: ' .. tostring(p.envelope_name)) end
  else
    env = reaper.GetTrackEnvelope(track, p.envelope_index)
    if not env then error('Envelope index out of range: ' .. tostring(p.envelope_index)) end
  end
  local shape   = p.shape   or 0
  local tension = p.tension or 0.0
  -- ScaleToEnvelopeMode converts normalized (fader pos 0-1) → raw internal value
  local scaling_mode = reaper.GetEnvelopeScalingMode(env)
  local raw_value = reaper.ScaleToEnvelopeMode(scaling_mode, p.value)
  reaper.InsertEnvelopePoint(env, p.time, raw_value, shape, tension, false, true)
  reaper.Envelope_SortPoints(env)
  return {
    track_index    = p.track_index,
    envelope_index = p.envelope_index,
    time           = p.time,
    value          = p.value,  -- echo back the normalized input
    raw_value      = raw_value,
    shape          = shape,
    tension        = tension,
  }
end

-- Insert an automation envelope point aligned to the project beat grid.
-- params: track_index, envelope_name OR envelope_index, bar (1-based), beat (1-based, may be fractional),
--         value, shape (0=linear), tension
-- bar=1 beat=1 is the project start. beat is counted in the time-sig denominator units of that bar.
handlers.insert_envelope_point_at_beat = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  local env
  if p.envelope_name then
    env = get_or_create_track_envelope(track, p.envelope_name)
    if not env then error('Envelope not found or could not be created: ' .. tostring(p.envelope_name)) end
  else
    env = reaper.GetTrackEnvelope(track, p.envelope_index)
    if not env then error('Envelope index out of range: ' .. tostring(p.envelope_index)) end
  end

  -- Convert bar+beat → QN position → time in seconds
  local measure     = (p.bar or 1) - 1   -- TimeMap_GetMeasureInfo uses 0-based measures
  local beat_in_bar = (p.beat or 1) - 1  -- 0-based within bar

  -- Returns: retval, qn_start, qn_end, timesig_num, timesig_denom, tempo
  local _, qn_start, _, timesig_num, timesig_denom, tempo =
    reaper.TimeMap_GetMeasureInfo(0, measure)

  -- Each beat is (4 / timesig_denom) quarter notes (e.g. 1.0 in 4/4, 0.5 in 6/8)
  local qn_per_beat = 4.0 / timesig_denom
  local qn_pos      = qn_start + beat_in_bar * qn_per_beat
  local time        = reaper.TimeMap2_QNToTime(0, qn_pos)

  local shape   = p.shape   or 0
  local tension = p.tension or 0.0
  local scaling_mode = reaper.GetEnvelopeScalingMode(env)
  local raw_value    = reaper.ScaleToEnvelopeMode(scaling_mode, p.value)
  reaper.InsertEnvelopePoint(env, time, raw_value, shape, tension, false, true)
  reaper.Envelope_SortPoints(env)
  return {
    track_index   = p.track_index,
    bar           = p.bar,
    beat          = p.beat,
    time          = time,
    value         = p.value,
    raw_value     = raw_value,
    shape         = shape,
    tension       = tension,
    tempo         = tempo,
    timesig_num   = timesig_num,
    timesig_denom = timesig_denom,
  }
end

-- List all media items on a track
-- params: track_index
handlers.get_track_items = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  local n = reaper.CountTrackMediaItems(track)
  local items = {}
  for i = 0, n - 1 do
    local item     = reaper.GetTrackMediaItem(track, i)
    local position = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
    local length   = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
    local mute     = reaper.GetMediaItemInfo_Value(item, 'B_MUTE') ~= 0
    local take     = reaper.GetActiveTake(item)
    local take_name, is_midi = '', false
    if take then
      take_name = reaper.GetTakeName(take)
      is_midi   = reaper.TakeIsMIDI(take)
    end
    table.insert(items, {
      item_index = i,
      position   = position,
      length     = length,
      mute       = mute,
      take_name  = take_name,
      is_midi    = is_midi,
    })
  end
  return { track_index = p.track_index, count = n, items = items }
end

-- Batch-edit multiple MIDI notes in one call.
-- params: track_index, item_index,
--   notes: list of { note_index, and any of: pitch, velocity, start_ppq, end_ppq, channel, selected, muted }
-- Only supplied fields are changed; omitted fields keep their current values.
handlers.set_midi_notes = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  local item = reaper.GetTrackMediaItem(track, p.item_index)
  if not item then error('Item index out of range: ' .. tostring(p.item_index)) end
  local take = reaper.GetActiveTake(item)
  if not take or not reaper.TakeIsMIDI(take) then
    error('Item does not have an active MIDI take')
  end
  local updated = {}
  for _, n in ipairs(p.notes or {}) do
    local _, sel, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, n.note_index)
    sel      = (n.selected  ~= nil) and n.selected  or sel
    muted    = (n.muted     ~= nil) and n.muted     or muted
    startppq = n.start_ppq  ~= nil and n.start_ppq  or startppq
    endppq   = n.end_ppq    ~= nil and n.end_ppq    or endppq
    chan     = n.channel    ~= nil and n.channel    or chan
    pitch    = n.pitch      ~= nil and n.pitch      or pitch
    vel      = n.velocity   ~= nil and n.velocity   or vel
    reaper.MIDI_SetNote(take, n.note_index, sel, muted, startppq, endppq, chan, pitch, vel, false)
    table.insert(updated, { note_index = n.note_index, pitch = pitch, velocity = vel,
                             start_ppq = startppq, end_ppq = endppq })
  end
  reaper.MIDI_Sort(take)
  return { track_index = p.track_index, item_index = p.item_index, updated = updated, count = #updated }
end

-- Humanize MIDI notes with random timing and/or velocity nudges.
-- params: track_index, item_index,
--   timing_range_ppq  (max ± PPQ offset per note, default 0)
--   velocity_range    (max ± velocity offset per note, default 0)
--   seed              (optional integer for reproducible results)
handlers.nudge_midi_notes = function(p)
  local track = track_at(p.track_index)
  if not track then error('Track index out of range: ' .. tostring(p.track_index)) end
  local item = reaper.GetTrackMediaItem(track, p.item_index)
  if not item then error('Item index out of range: ' .. tostring(p.item_index)) end
  local take = reaper.GetActiveTake(item)
  if not take or not reaper.TakeIsMIDI(take) then
    error('Item does not have an active MIDI take')
  end

  local timing_range = p.timing_range_ppq or 0
  local vel_range    = p.velocity_range   or 0
  if timing_range == 0 and vel_range == 0 then
    error('At least one of timing_range_ppq or velocity_range must be non-zero')
  end

  -- Seed the Lua RNG if requested
  if p.seed then math.randomseed(p.seed) else math.randomseed(os.time()) end

  local _, note_cnt, _, _ = reaper.MIDI_CountEvts(take)
  local changes = {}
  for i = 0, note_cnt - 1 do
    local _, sel, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
    local new_start = startppq
    local new_end   = endppq
    local new_vel   = vel

    if timing_range ~= 0 then
      local delta = math.floor((math.random() * 2 - 1) * timing_range + 0.5)
      new_start = math.max(0, startppq + delta)
      new_end   = math.max(new_start + 1, endppq + delta)  -- preserve note length
    end
    if vel_range ~= 0 then
      local delta = math.floor((math.random() * 2 - 1) * vel_range + 0.5)
      new_vel = math.max(1, math.min(127, vel + delta))
    end

    reaper.MIDI_SetNote(take, i, sel, muted, new_start, new_end, chan, pitch, new_vel, false)
    table.insert(changes, { note_index = i, start_ppq = new_start, end_ppq = new_end, velocity = new_vel })
  end
  reaper.MIDI_Sort(take)
  return { track_index = p.track_index, item_index = p.item_index,
           count = note_cnt, changes = changes }
end

-- Copy a time range of items and paste it immediately after the range end.
-- Useful for extending song form (repeat a chorus, add an outro).
-- params: start_time, end_time, repeat_count (default 1)
handlers.duplicate_time_range = function(p)
  if not p.start_time or not p.end_time then error('start_time and end_time required') end
  local t1 = p.start_time
  local t2 = p.end_time
  if t2 <= t1 then error('end_time must be greater than start_time') end
  local repeats = p.repeat_count or 1

  -- Use REAPER's built-in time selection + duplicate loop action
  reaper.GetSet_LoopTimeRange(true, false, t1, t2, false)  -- set time selection
  -- Action 41311: "Item: Copy loop of selected area of items"
  -- Action 40060: "Edit: Copy items/tracks/envelope points (depending on focus) within time selection"
  -- We use the time-selection-based duplicate: select all items in range, copy, paste at end
  reaper.Main_OnCommand(40289, 0)  -- unselect all items
  -- Select all items that overlap the time range on all tracks
  local n_tracks = reaper.CountTracks(0)
  local copied_items = 0
  for ti = 0, n_tracks - 1 do
    local tr = reaper.GetTrack(0, ti)
    for ii = 0, reaper.CountTrackMediaItems(tr) - 1 do
      local item = reaper.GetTrackMediaItem(tr, ii)
      local ipos = reaper.GetMediaItemInfo_Value(item, 'D_POSITION')
      local ilen = reaper.GetMediaItemInfo_Value(item, 'D_LENGTH')
      -- Include if item overlaps [t1, t2)
      if ipos < t2 and (ipos + ilen) > t1 then
        reaper.SetMediaItemSelected(item, true)
        copied_items = copied_items + 1
      end
    end
  end

  local duration = t2 - t1
  local paste_pos = t2
  for r = 1, repeats do
    -- Move edit cursor to paste position and duplicate selected items there
    reaper.SetEditCurPos(paste_pos, false, false)
    reaper.Main_OnCommand(40698, 0)  -- Item: Duplicate items
    paste_pos = paste_pos + duration
  end

  reaper.UpdateArrange()
  return {
    start_time    = t1,
    end_time      = t2,
    duration      = duration,
    repeat_count  = repeats,
    items_in_range = copied_items,
    new_end_time  = paste_pos,
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
