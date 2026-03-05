# ReaMCP

ReaMCP is a Reaper MCP for controlling and editing projects in your DAW. Connect this to agentic editors like Claude Desktop, VS Code or Zed to make use of the querying and editing tools in Reaper.

This project is currently in its alpha stage. Keep a backup your projects and report any issues you find. This is tested using Linux but I'd like to make it compatible with all operating systems.


## How this differs from similar projects

There are a few other REAPER MCP servers. Here's how they compare:

**[dschuler36/reaper-mcp-server](https://github.com/dschuler36/reaper-mcp-server)** — Read-only, file-based. Parses `.rpp` project files directly from disk and does audio analysis on rendered files. No live REAPER connection — REAPER doesn't need to be open. Good for querying existing projects and mix feedback, but can't create or change anything.

**[itsuzef/reaper-mcp](https://github.com/itsuzef/reaper-mcp)** — Live connection via OSC or ReaPy (Python-in-REAPER). OSC is limited to transport and basic fader control; the ReaScript mode is more capable but requires configuring Python inside REAPER. Only a handful of tools (create track, add MIDI note, get project info).

**This project** — Live connection via a persistent Lua bridge script running inside REAPER, communicating over a local TCP socket. No OSC setup, no Python DLL wiring. Exposes the full `reaper.*` Lua API surface, giving a much broader and more reliable toolset: full MIDI editing, FX chain management, automation, sends, markers, media item manipulation, and more.

## What it does

- Read project and track state
- Create, duplicate, and delete tracks and media items
- Move and resize media items on the timeline
- Create MIDI items; read, insert, modify, and delete MIDI notes, CC, pitch bend, and program change events; batch-edit and humanize notes
- Insert audio files onto tracks
- Control transport and cursor position
- Add, list, and remove FX (including on the master track); read/write FX parameters; bypass/enable FX; load presets by name with case-insensitive fallback enumeration
- Read and set tempo/time signature and project parameters
- Save the project and trigger undo
- Add, list, and delete markers and regions
- Open project files by path
- Create, remove, and adjust track sends (volume and pan)
- Set track recording input and input monitoring mode
- Read and insert automation envelope points; clear envelopes; insert beat-aligned points
- Copy and repeat time ranges (duplicate chorus, extend outro, etc.)
- Render a time range to an audio file
- Measure loudness (LUFS integrated, short-term, momentary, true peak) for individual tracks or the master mix via non-destructive dry-run render
- Normalize track volume to a target LUFS level in one call

## Requirements

- REAPER (with [ReaPack](https://reapack.com/))
- Python 3.10+

## Setup

### 1) Install the Python server

```bash
pip install -e . # You can also `uv sync` but it's not supported.
```

### 2) Install `mavriq-lua-sockets` in REAPER and restart

REAPER's embedded Lua cannot load stock LuaSocket builds in this context. Install `mavriq-lua-sockets` via ReaPack:

1. REAPER → **Extensions → ReaPack → Import repositories**
2. Add `https://github.com/mavriq-dev/public-reascripts/raw/master/index.xml`
3. REAPER → **Extensions → ReaPack → Browse packages**
4. Install **mavriq-lua-sockets**
5. Restart REAPER

### 3) Install and run the bridge script via ReaPack

1. REAPER → **Extensions → ReaPack → Import repositories**
2. Add `https://github.com/danielkinahan/ReaMCP/raw/main/index.xml`
3. REAPER → **Extensions → ReaPack → Browse packages**
4. Install **ReaMCP Bridge**
5. Run it once via **Actions → Show action list → ReaMCP Bridge**
6. Confirm REAPER console shows `Listening on 127.0.0.1:9001`
7. Optional: add it to startup actions so it auto-runs on launch

You may also run this manually via **Actions -> ReaScript: Run ReaScript (EEL2 or Lua)...** and selecting the lua script from this repo.

### 4) Start the MCP server

```bash
python -m reaper_mcp
```

Optional environment variables:

| Variable | Default | Description |
|---|---|---|
| `REAPER_BRIDGE_HOST` | `127.0.0.1` | Bridge host |
| `REAPER_BRIDGE_PORT` | `9001` | Bridge port |

## MCP tools

| Tool | Description |
|---|---|
| `ping` | Verify bridge is reachable |
| `get_project_info` | Project metadata/state |
| `get_project_parameters` | Loop range, cursor, loop-enabled |
| `save_project` | Save the current project to disk |
| `undo` | Trigger REAPER undo |
| `open_project` | Open a `.rpp` project file by absolute path |
| `list_tracks` | List all tracks |
| `get_track` | Get one track by 0-based index |
| `create_track` | Insert a track |
| `delete_track` | Delete a track |
| `duplicate_track` | Duplicate a track (inserts copy after original) |
| `set_track_properties` | Set name/volume/pan/mute/solo/arm |
| `set_track_input` | Set recording input (audio channel or MIDI) |
| `set_input_monitoring` | Set input monitoring mode (off/on/not when playing) |
| `move_media_item` | Move a media item to a new timeline position |
| `resize_media_item` | Change the length of a media item |
| `delete_media_item` | Remove a media item from a track |
| `get_item_properties` | Get position, length, pitch, playrate, etc. of an item |
| `duplicate_item` | Duplicate a media item on its track |
| `create_midi_item` | Create a MIDI item with optional pre-populated notes |
| `get_midi_notes` | Read all MIDI notes from a MIDI item |
| `set_midi_note` | Modify an existing MIDI note (pitch, velocity, position, etc.) |
| `delete_midi_note` | Delete a MIDI note by index |
| `insert_midi_event` | Insert a CC, pitch-bend, or program-change event |
| `insert_audio_file` | Insert an audio file at a time position |
| `transport` | `play` / `stop` / `pause` / `record` / `goto_start` / `goto_position` |
| `add_fx` | Add FX/instrument to a track |
| `list_fx` | List FX chain entries on a track |
| `list_available_fx` | List all installed FX plugins; optional `filter` by name/type (e.g. `"fabfilter"`, `"vst"`) |
| `get_fx_params` | List all FX parameters |
| `set_fx_param` | Set FX parameter (normalized `0.0–1.0`) |
| `set_fx_enabled` | Enable or bypass an FX plugin |
| `remove_fx` | Remove an FX from the chain |
| `set_fx_preset` | Load a named FX preset; falls back to index-scan with case-insensitive matching. Use `track_index=-1` for master track |
| `list_fx_presets` | List factory and file-based presets for a plugin already on a track |
| `get_tempo` | Read BPM and time signature |
| `set_tempo` | Set BPM and optional time signature |
| `set_project_parameter` | Set `loop_start`, `loop_end`, `loop_enabled`, `cursor_position`, `playrate` |
| `add_marker` | Add a marker or region |
| `list_markers` | List all markers and regions |
| `delete_marker` | Delete a marker or region by enum index |
| `create_track_send` | Create a send from one track to another |
| `remove_track_send` | Remove a track send |
| `set_track_send` | Set send volume and pan |
| `get_envelope_points` | Read all automation envelope points |
| `insert_envelope_point` | Insert an automation envelope point |
| `clear_envelope_points` | Remove all points from an envelope |
| `insert_envelope_point_at_beat` | Insert an automation point aligned to a musical beat position |
| `get_track_items` | List all media items on a track with position, length, and take info |
| `set_midi_notes` | Batch-edit multiple MIDI notes in one call |
| `nudge_midi_notes` | Humanize all notes in a MIDI item with random timing and velocity offsets |
| `duplicate_time_range` | Copy all items in a time range and paste them N times after the selection |
| `render_time_selection` | Render a time range to an audio file using REAPER's render pipeline |
| `analyze_track_loudness` | Measure integrated loudness (LUFS), short-term/momentary max, and true peak for a single track via non-destructive dry-run render |
| `analyze_master_loudness` | Same as above but for the full master mix |
| `normalize_track` | Measure track loudness and adjust the fader to hit a target LUFS level (default -14 LUFS) |

## Limitations

**Preset loading** — `set_fx_preset` first tries `TrackFX_SetPreset` (works for plugins with a standard VST/CLAP program bank), then falls back to enumerating all presets by index with case-insensitive name matching via `TrackFX_SetPresetByIndex`. This covers most plugins. File-based presets (`.ffp`, `.fxp`) can be loaded by passing the absolute file path as `preset_name`. Use `list_fx_presets` to discover available factory and file presets.

## MCP client configuration

### VS Code (`.vscode/mcp.json`)

```json
{
  "servers": {
    "reaper": {
      "type": "stdio",
      "command": "./.venv/bin/python",
      "args": ["-m", "reaper_mcp"]
    }
  }
}
```

### Claude Desktop (`claude_desktop_config.json`)

```json
{
  "mcpServers": {
    "reaper": {
      "command": "/path/to/venv/bin/python",
      "args": ["-m", "reaper_mcp"]
    }
  }
}
```

Config file location:
- **macOS**: `~/Library/Application Support/Claude/claude_desktop_config.json`
- **Windows**: `%APPDATA%\Claude\claude_desktop_config.json`

### Zed (`~/.config/zed/settings.json`)

```json
{
  "context_servers": {
    "reaper": {
      "command": {
        "path": "./.venv/bin/python",
        "args": ["-m", "reaper_mcp"]
      }
    }
  }
}
```

## ReaPack package in this repo

`index.xml` ships the bridge script (`bridge/reaper_mcp_bridge.lua`) as a ReaPack package so users can install and auto-update it directly from REAPER.

## Architecture

```
MCP client (AI / IDE)
     │  stdio
     ▼
Python MCP server  ──── JSON-RPC over TCP (127.0.0.1:9001) ────►  bridge/reaper_mcp_bridge.lua
(src/reaper_mcp/)                                                     └─ reaper.* Lua API (inside REAPER)
```

The Python process is a standard `mcp` server. REAPER control happens through a persistent Lua bridge script running inside REAPER.