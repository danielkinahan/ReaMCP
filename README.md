# ReaMCP (reaper-mcp)

MCP server for controlling and editing REAPER projects.

This is an early public draft focused on a reliable core toolset.

## What it does

- Read project and track state
- Create, duplicate, and delete tracks and media items
- Move and resize media items on the timeline
- Create MIDI items; read, insert, modify, and delete MIDI notes, CC, pitch bend, and program change events
- Insert audio files onto tracks
- Control transport and cursor position
- Add, list, and remove FX; read/write FX parameters; bypass/enable FX; load FX presets
- Read and set tempo/time signature and project parameters
- Save the project and trigger undo
- Add, list, and delete markers and regions
- Open project files by path
- Create, remove, and adjust track sends (volume and pan)
- Set track recording input and input monitoring mode
- Read and insert automation envelope points

## Requirements

- REAPER (with ReaPack)
- Python 3.10+
- `mavriq-lua-sockets` installed in REAPER

## Setup

### 1) Install the Python server

```bash
pip install -e .
```

### 2) Install `mavriq-lua-sockets` in REAPER and restart

REAPER's embedded Lua cannot load stock LuaSocket builds in this context. Install `mavriq-lua-sockets` via ReaPack:

1. REAPER → **Extensions → ReaPack → Import repositories**
2. Add `https://github.com/mavriq-dev/public-reascripts/raw/master/index.xml`
3. REAPER → **Extensions → ReaPack → Browse packages**
4. Install **mavriq-lua-sockets**
5. Restart REAPER

### 3) Load and run the bridge script in REAPER

1. REAPER → **Actions → Show action list → Load ReaScript**
2. Select `bridge/reaper_mcp_bridge.lua`
3. Run it once
4. Confirm REAPER console shows `Listening on 127.0.0.1:9001`
5. Optional: add it to startup actions so it auto-runs

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
| `set_fx_preset` | Load a named FX preset |
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

## MCP client config (VS Code / stdio)

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

## ReaPack package in this repo

`reapack/index.xml` currently ships a setup helper script for onboarding. The bridge script itself remains in `bridge/reaper_mcp_bridge.lua`.

## Architecture

```
MCP client (AI / IDE)
     │  stdio
     ▼
Python MCP server  ──── JSON-RPC over TCP (127.0.0.1:9001) ────►  bridge/reaper_mcp_bridge.lua
(src/reaper_mcp/)                                                     └─ reaper.* Lua API (inside REAPER)
```

The Python process is a standard `mcp` server. REAPER control happens through a persistent Lua bridge script running inside REAPER.