from __future__ import annotations

import os
import sys
from typing import Any

from mcp.server.fastmcp import FastMCP

from . import __version__
from .reaper_adapter import ReaperAdapter

_HOST = os.environ.get("REAPER_BRIDGE_HOST", "127.0.0.1")
_PORT = int(os.environ.get("REAPER_BRIDGE_PORT", "9001"))

mcp = FastMCP("reaper-mcp")
adapter = ReaperAdapter(host=_HOST, port=_PORT)

_HINT = (
    "Ensure REAPER is running and reaper_mcp_bridge.lua is active "
    f"(listening on {_HOST}:{_PORT})."
)


def _wrap(result: Any) -> dict[str, Any]:
    return {"ok": True, "result": result}


def _err(exc: Exception) -> dict[str, Any]:
    return {"ok": False, "error": str(exc), "hint": _HINT}


# ---------------------------------------------------------------------------
# Connectivity
# ---------------------------------------------------------------------------


@mcp.tool()
def ping() -> dict[str, Any]:
    """Check that the bridge is reachable and return the REAPER version."""
    try:
        return _wrap(adapter.ping())
    except Exception as exc:
        return _err(exc)


# ---------------------------------------------------------------------------
# Project
# ---------------------------------------------------------------------------


@mcp.tool()
def get_project_info() -> dict[str, Any]:
    """Return metadata about the currently open REAPER project."""
    try:
        return _wrap(adapter.get_project_info())
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def get_project_parameters() -> dict[str, Any]:
    """Return loop range, cursor position, and loop-enabled state."""
    try:
        return _wrap(adapter.get_project_parameters())
    except Exception as exc:
        return _err(exc)


# ---------------------------------------------------------------------------
# Tracks
# ---------------------------------------------------------------------------


@mcp.tool()
def list_tracks() -> dict[str, Any]:
    """List every track in the project with volume, pan, mute, solo, arm state."""
    try:
        return _wrap(adapter.list_tracks())
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def get_track(track_index: int) -> dict[str, Any]:
    """Get detailed info for a single track by 0-based index."""
    try:
        return _wrap(adapter.get_track(track_index=track_index))
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def create_track(name: str | None = None, index: int | None = None) -> dict[str, Any]:
    """
    Insert a new track.
    - name: track name (default "Track N")
    - index: 0-based position (default: append at end)
    """
    try:
        return _wrap(adapter.create_track(name=name, index=index))
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def delete_track(track_index: int) -> dict[str, Any]:
    """Delete a track by 0-based index. This is permanent and undoable via REAPER's undo system."""
    try:
        return _wrap(adapter.delete_track(track_index=track_index))
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def set_track_properties(
    track_index: int,
    name: str | None = None,
    volume: float | None = None,
    pan: float | None = None,
    mute: bool | None = None,
    solo: bool | None = None,
    arm: bool | None = None,
) -> dict[str, Any]:
    """
    Modify one or more properties of a track.
    - volume: linear amplitude (1.0 = 0 dB)
    - pan: -1.0 (full left) to 1.0 (full right)
    """
    try:
        return _wrap(
            adapter.set_track_properties(
                track_index=track_index,
                name=name,
                volume=volume,
                pan=pan,
                mute=mute,
                solo=solo,
                arm=arm,
            )
        )
    except Exception as exc:
        return _err(exc)


# ---------------------------------------------------------------------------
# Media items
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Media items
# ---------------------------------------------------------------------------


@mcp.tool()
def move_media_item(
    track_index: int,
    item_index: int,
    position: float,
) -> dict[str, Any]:
    """Move a media item to a new timeline position (seconds)."""
    try:
        return _wrap(
            adapter.move_media_item(
                track_index=track_index, item_index=item_index, position=position
            )
        )
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def resize_media_item(
    track_index: int,
    item_index: int,
    length: float,
) -> dict[str, Any]:
    """Change the length of a media item (seconds)."""
    try:
        return _wrap(
            adapter.resize_media_item(
                track_index=track_index, item_index=item_index, length=length
            )
        )
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def delete_media_item(track_index: int, item_index: int) -> dict[str, Any]:
    """Delete a media item from a track."""
    try:
        return _wrap(
            adapter.delete_media_item(track_index=track_index, item_index=item_index)
        )
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def get_item_properties(track_index: int, item_index: int) -> dict[str, Any]:
    """
    Return properties of a media item: position, length, mute, lock, take name,
    playrate, and pitch.
    """
    try:
        return _wrap(
            adapter.get_item_properties(track_index=track_index, item_index=item_index)
        )
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def duplicate_track(track_index: int) -> dict[str, Any]:
    """Duplicate a track, inserting the copy immediately after the original."""
    try:
        return _wrap(adapter.duplicate_track(track_index=track_index))
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def duplicate_item(track_index: int, item_index: int) -> dict[str, Any]:
    """Duplicate a media item on its track."""
    try:
        return _wrap(
            adapter.duplicate_item(track_index=track_index, item_index=item_index)
        )
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def insert_midi_event(
    track_index: int,
    item_index: int,
    event_type: str,
    ppq: int,
    channel: int = 0,
    cc_number: int | None = None,
    value: int | None = None,
    bend: int | None = None,
    program: int | None = None,
) -> dict[str, Any]:
    """
    Insert a MIDI CC, pitch-bend, or program-change event into a MIDI item.
    - event_type: 'cc' | 'pitch_bend' | 'program_change'
    - ppq: position in PPQ ticks
    - channel: 0-15
    - cc: provide cc_number (0-127) and value (0-127)
    - pitch_bend: provide bend (-8192 to 8191, 0 = center)
    - program_change: provide program (0-127)
    """
    try:
        return _wrap(
            adapter.insert_midi_event(
                track_index=track_index,
                item_index=item_index,
                event_type=event_type,
                ppq=ppq,
                channel=channel,
                cc_number=cc_number,
                value=value,
                bend=bend,
                program=program,
            )
        )
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def delete_midi_note(
    track_index: int,
    item_index: int,
    note_index: int,
) -> dict[str, Any]:
    """Delete a specific MIDI note from a MIDI item by its 0-based note index."""
    try:
        return _wrap(
            adapter.delete_midi_note(
                track_index=track_index,
                item_index=item_index,
                note_index=note_index,
            )
        )
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def set_midi_note(
    track_index: int,
    item_index: int,
    note_index: int,
    start_ppq: int | None = None,
    end_ppq: int | None = None,
    pitch: int | None = None,
    velocity: int | None = None,
    channel: int | None = None,
    selected: bool | None = None,
    muted: bool | None = None,
) -> dict[str, Any]:
    """
    Modify an existing MIDI note. Only the supplied fields are changed.
    - pitch: MIDI note number (0-127)
    - velocity: 0-127
    - channel: 0-15
    - start_ppq / end_ppq: positions in PPQ ticks
    """
    try:
        return _wrap(
            adapter.set_midi_note(
                track_index=track_index,
                item_index=item_index,
                note_index=note_index,
                start_ppq=start_ppq,
                end_ppq=end_ppq,
                pitch=pitch,
                velocity=velocity,
                channel=channel,
                selected=selected,
                muted=muted,
            )
        )
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def get_midi_notes(track_index: int, item_index: int) -> dict[str, Any]:
    """
    Read all MIDI notes from a media item's active MIDI take.
    Returns a list of notes with start_ppq, end_ppq, pitch, velocity, channel.
    """
    try:
        return _wrap(
            adapter.get_midi_notes(track_index=track_index, item_index=item_index)
        )
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def create_midi_item(
    track_index: int,
    start: float,
    end: float,
    notes: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    """
    Create a MIDI item on a track and optionally pre-populate it with notes.
    - start / end: time in seconds
    - notes: list of {start_ppq, end_ppq, pitch, velocity=100, channel=0}
    """
    try:
        return _wrap(
            adapter.create_midi_item(
                track_index=track_index,
                start=start,
                end=end,
                notes=notes,
            )
        )
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def insert_audio_file(
    track_index: int,
    file_path: str,
    position: float,
) -> dict[str, Any]:
    """Insert an audio file onto a track at the given position (seconds)."""
    try:
        return _wrap(
            adapter.insert_audio_file(
                track_index=track_index,
                file_path=file_path,
                position=position,
            )
        )
    except Exception as exc:
        return _err(exc)


# ---------------------------------------------------------------------------
# Transport
# ---------------------------------------------------------------------------


@mcp.tool()
def transport(action: str, position: float | None = None) -> dict[str, Any]:
    """
    Control REAPER's transport.
    action: play | stop | pause | record | goto_start | goto_position
    position: required when action == goto_position (seconds)
    """
    try:
        return _wrap(adapter.transport(action=action, position=position))
    except Exception as exc:
        return _err(exc)


# ---------------------------------------------------------------------------
# FX / instruments
# ---------------------------------------------------------------------------


@mcp.tool()
def add_fx(
    track_index: int,
    fx_name: str,
    input_fx: bool = False,
) -> dict[str, Any]:
    """
    Add an FX plugin to a track.
    - fx_name: any string REAPER's FX browser accepts ("ReaComp", "VST: Serum", etc.)
    - input_fx: True to add to the input FX chain
    """
    try:
        return _wrap(adapter.add_fx(track_index=track_index, fx_name=fx_name, input_fx=input_fx))
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def list_fx(track_index: int) -> dict[str, Any]:
    """List all FX plugins on a track (name, fx_index, n_params, enabled)."""
    try:
        return _wrap(adapter.list_fx(track_index=track_index))
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def get_fx_params(track_index: int, fx_index: int) -> dict[str, Any]:
    """
    Return all parameters for an FX plugin on a track.
    Each entry includes: param_index, name, value, min_value, max_value, normalized.
    """
    try:
        return _wrap(adapter.get_fx_params(track_index=track_index, fx_index=fx_index))
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def set_fx_param(
    track_index: int,
    fx_index: int,
    param_index: int,
    normalized_value: float,
) -> dict[str, Any]:
    """Set an FX parameter by normalized value (0.0–1.0)."""
    try:
        return _wrap(
            adapter.set_fx_param(
                track_index=track_index,
                fx_index=fx_index,
                param_index=param_index,
                normalized_value=normalized_value,
            )
        )
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def set_fx_enabled(track_index: int, fx_index: int, enabled: bool) -> dict[str, Any]:
    """Enable or bypass (disable) a specific FX plugin on a track."""
    try:
        return _wrap(
            adapter.set_fx_enabled(
                track_index=track_index, fx_index=fx_index, enabled=enabled
            )
        )
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def remove_fx(track_index: int, fx_index: int) -> dict[str, Any]:
    """Remove an FX plugin from a track's FX chain."""
    try:
        return _wrap(adapter.remove_fx(track_index=track_index, fx_index=fx_index))
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def set_fx_preset(track_index: int, fx_index: int, preset_name: str) -> dict[str, Any]:
    """Load a named preset for an FX plugin on a track."""
    try:
        return _wrap(
            adapter.set_fx_preset(
                track_index=track_index, fx_index=fx_index, preset_name=preset_name
            )
        )
    except Exception as exc:
        return _err(exc)


# ---------------------------------------------------------------------------
# Tempo & project parameters
# ---------------------------------------------------------------------------


@mcp.tool()
def get_tempo() -> dict[str, Any]:
    """Return the current BPM and time signature."""
    try:
        return _wrap(adapter.get_tempo())
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def set_tempo(
    bpm: float,
    time_sig_num: int | None = None,
    time_sig_denom: int | None = None,
) -> dict[str, Any]:
    """
    Set the project tempo (and optionally time signature).
    - bpm: beats per minute
    - time_sig_num / time_sig_denom: e.g. 3, 4 for 3/4 time
    """
    try:
        return _wrap(
            adapter.set_tempo(
                bpm=bpm,
                time_sig_num=time_sig_num,
                time_sig_denom=time_sig_denom,
            )
        )
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def set_project_parameter(parameter: str, value: Any) -> dict[str, Any]:
    """
    Set a named project parameter.
    Supported parameters: loop_start, loop_end, loop_enabled, cursor_position, playrate
    """
    try:
        return _wrap(adapter.set_project_parameter(parameter=parameter, value=value))
    except Exception as exc:
        return _err(exc)


# ---------------------------------------------------------------------------
# Project operations
# ---------------------------------------------------------------------------


@mcp.tool()
def save_project() -> dict[str, Any]:
    """Save the current REAPER project to disk."""
    try:
        return _wrap(adapter.save_project())
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def undo() -> dict[str, Any]:
    """Trigger REAPER's undo. Returns the name of the action that was undone."""
    try:
        return _wrap(adapter.undo())
    except Exception as exc:
        return _err(exc)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main() -> None:
    # ALL output here must go to stderr — stdout is the MCP protocol channel.
    print(f"Reaper MCP server v{__version__}", file=sys.stderr)
    print(f"Bridge address: {_HOST}:{_PORT}", file=sys.stderr)
    print("Tip: ensure reaper_mcp_bridge.lua is running in REAPER before using tools.", file=sys.stderr, flush=True)
    mcp.run()


if __name__ == "__main__":
    main()
