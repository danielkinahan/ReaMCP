# ReaMCP (reaper-mcp)

MCP server for controlling and editing REAPER projects.

This is an early public draft focused on a reliable core toolset.

## What it does

- Read project and track state
- Create tracks and MIDI items
- Insert audio files onto tracks
- Control transport and cursor position
- Add/list FX and read/write FX parameters
- Read and set tempo/time signature and selected project parameters

## Architecture

```
MCP client (AI / IDE)
     │  stdio
     ▼
Python MCP server  ──── JSON-RPC over TCP (127.0.0.1:9001) ────►  bridge/reaper_mcp_bridge.lua
(src/reaper_mcp/)                                                     └─ reaper.* Lua API (inside REAPER)
```

The Python process is a standard `mcp` server. REAPER control happens through a persistent Lua bridge script running inside REAPER.

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
| `list_tracks` | List all tracks |
| `get_track` | Get one track by 0-based index |
| `create_track` | Insert a track |
| `set_track_properties` | Set name/volume/pan/mute/solo/arm |
| `create_midi_item` | Create MIDI item, optional notes |
| `insert_audio_file` | Insert audio file at time position |
| `transport` | `play` / `stop` / `pause` / `record` / `goto_start` / `goto_position` |
| `add_fx` | Add FX/instrument to track |
| `list_fx` | List FX chain entries |
| `get_fx_params` | List all FX parameters |
| `set_fx_param` | Set FX parameter (normalized `0.0-1.0`) |
| `get_tempo` | Read BPM and time signature |
| `set_tempo` | Set BPM and optional time signature |
| `set_project_parameter` | Set `loop_start`, `loop_end`, `loop_enabled`, `cursor_position`, `playrate` |

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
