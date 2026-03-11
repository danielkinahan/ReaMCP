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
    """Check that the bridge is reachable. Returns bridge_version and reaper_version."""
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
def get_track_items(track_index: int) -> dict[str, Any]:
    """List all media items on a track with their position, length, and take info."""
    try:
        return _wrap(adapter.get_track_items(track_index=track_index))
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def set_midi_notes(
    track_index: int,
    item_index: int,
    notes: list[dict[str, Any]],
) -> dict[str, Any]:
    """
    Batch-edit multiple MIDI notes in one call. More efficient than calling
    set_midi_note() repeatedly.
    Each entry in 'notes' must have 'note_index' and any subset of:
      pitch, velocity, start_ppq, end_ppq, channel, selected, muted.
    Omitted fields keep their current values.
    """
    try:
        return _wrap(
            adapter.set_midi_notes(
                track_index=track_index,
                item_index=item_index,
                notes=notes,
            )
        )
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def nudge_midi_notes(
    track_index: int,
    item_index: int,
    timing_range_ppq: float = 0,
    velocity_range: int = 0,
    seed: int | None = None,
) -> dict[str, Any]:
    """
    Humanize all MIDI notes in an item with random timing and/or velocity offsets.
    - timing_range_ppq: maximum ±PPQ timing shift per note (0 = no timing change).
      At 960 PPQ, 20 PPQ ≈ 1/48th note of swing.
    - velocity_range: maximum ±velocity shift per note (0 = no velocity change).
      Velocity is clamped to 1-127.
    - seed: optional integer for reproducible results (omit for random each call).
    Returns the per-note changes applied.
    """
    try:
        return _wrap(
            adapter.nudge_midi_notes(
                track_index=track_index,
                item_index=item_index,
                timing_range_ppq=timing_range_ppq,
                velocity_range=velocity_range,
                seed=seed,
            )
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
    - track_index: 0-based track index, or -1 for the master track
    - fx_name: any string REAPER's FX browser accepts ("ReaComp", "VST: Serum", etc.)
    - input_fx: True to add to the input FX chain
    """
    try:
        return _wrap(adapter.add_fx(track_index=track_index, fx_name=fx_name, input_fx=input_fx))
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def list_fx(track_index: int) -> dict[str, Any]:
    """List all FX plugins on a track (name, fx_index, n_params, enabled).
    Use track_index=-1 for the master track."""
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
    """
    Load a named preset for an FX plugin on a track.
    preset_name can be:
    - A plain preset name or index-based name (for plugins with internal preset banks)
    - A full absolute file path to a .ffp/.fxp/.fxb file (FabFilter and others).
      Use the 'path' field from list_fx_presets() for file-based plugins.
    On failure, returns loaded=false with a failure_reason:
      'preset_name_not_found'   - name not in the plugin's preset list
      'plugin_rejected_state'   - plugin returned false despite the name existing
      'plugin_has_no_presets'   - plugin exposes no preset bank at all
      'file_unreadable'         - path given but file could not be opened
    """
    try:
        return _wrap(
            adapter.set_fx_preset(
                track_index=track_index, fx_index=fx_index, preset_name=preset_name
            )
        )
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def list_fx_presets(
    track_index: int, fx_index: int
) -> dict[str, Any]:
    """
    List available presets for an FX already on a track.
    Returns two lists:
    - factory_presets: presets exposed by the plugin itself (CLAP, VST3, VST2 banks).
      Each entry has {index, name, source='factory'}. These can be loaded by name
      with set_fx_preset().
    - file_presets: .ffp/.fxp files found on disk under standard vendor preset dirs.
      Each entry has {name, category, path, source='file'}. Load via the 'path' field.
    """
    try:
        return _wrap(adapter.list_fx_presets(track_index=track_index, fx_index=fx_index))
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
def render_time_selection(
    output_path: str,
    start_time: float,
    end_time: float,
    sample_rate: int = 0,
    channels: int = 2,
) -> dict[str, Any]:
    """
    Render a time range to an audio file using REAPER's render pipeline.
    - output_path: absolute path including extension (e.g. '/tmp/mix.wav').
      REAPER uses the current render format; set a .wav extension for PCM output.
    - start_time / end_time: seconds
    - sample_rate: 0 = use project rate
    - channels: 1=mono, 2=stereo
    Returns output_path and file_size_bytes so you can verify the file was written.
    After rendering, attach the file to this conversation so the audio can be heard.
    """
    try:
        return _wrap(
            adapter.render_time_selection(
                output_path=output_path,
                start_time=start_time,
                end_time=end_time,
                sample_rate=sample_rate,
                channels=channels,
            )
        )
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def analyze_track_loudness(
    track_index: int,
    start_time: float,
    end_time: float,
) -> dict[str, Any]:
    """
    Measure the loudness of a single track over a time range using a non-destructive
    dry-run render (action 42439). No items, tracks, or files are created —
    project state is completely unchanged after the call.
    Returns:
    - lufs_i: integrated loudness in LUFS
    - lufs_s_max: maximum short-term loudness in LUFS
    - lufs_m_max: maximum momentary loudness in LUFS
    - true_peak_db: true peak in dBTP
    - raw_stats: raw key=value string from REAPER for any additional fields
    """
    try:
        return _wrap(
            adapter.analyze_track_loudness(
                track_index=track_index,
                start_time=start_time,
                end_time=end_time,
            )
        )
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def analyze_master_loudness(
    start_time: float,
    end_time: float,
) -> dict[str, Any]:
    """
    Measure the loudness of the full master mix over a time range using a
    non-destructive dry-run render (action 42441). No tracks or files are created.
    Returns:
    - lufs_i: integrated loudness in LUFS
    - lufs_s_max: maximum short-term loudness in LUFS
    - lufs_m_max: maximum momentary loudness in LUFS
    - true_peak_db: true peak in dBTP
    - raw_stats: raw key=value string from REAPER for any additional fields
    """
    try:
        return _wrap(adapter.analyze_master_loudness(start_time=start_time, end_time=end_time))
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def normalize_track(
    track_index: int,
    start_time: float,
    end_time: float,
    target_lufs: float = -14.0,
) -> dict[str, Any]:
    """
    Normalize a track to a target integrated loudness by measuring its current
    LUFS via a non-destructive dry-run render, then adjusting the track fader.
    - target_lufs: desired integrated loudness in LUFS (default -14.0, streaming standard).
      Use -23.0 for EBU R128 broadcast, -16.0 for podcast.
    Returns measured_lufs_i, gain_applied_db, and old/new fader volumes.
    The change is registered in REAPER's undo history.
    """
    try:
        return _wrap(
            adapter.normalize_track(
                track_index=track_index,
                start_time=start_time,
                end_time=end_time,
                target_lufs=target_lufs,
            )
        )
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def undo() -> dict[str, Any]:
    """Trigger REAPER's undo. Returns the name of the action that was undone."""
    try:
        return _wrap(adapter.undo())
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def add_marker(
    position: float,
    name: str = "",
    is_region: bool = False,
    region_end: float | None = None,
    color: int = 0,
) -> dict[str, Any]:
    """
    Add a marker or region to the project.
    - position: time in seconds
    - is_region: True to create a region; also requires region_end
    - region_end: end time in seconds (only for regions)
    - color: REAPER color integer (0 = default)
    """
    try:
        return _wrap(
            adapter.add_marker(
                position=position,
                name=name,
                is_region=is_region,
                region_end=region_end,
                color=color,
            )
        )
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def list_markers() -> dict[str, Any]:
    """List all markers and regions in the project."""
    try:
        return _wrap(adapter.list_markers())
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def delete_marker(enum_index: int) -> dict[str, Any]:
    """
    Delete a marker or region by its 0-based enumeration index (from list_markers).
    """
    try:
        return _wrap(adapter.delete_marker(enum_index=enum_index))
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def open_project(file_path: str) -> dict[str, Any]:
    """Open a REAPER project file (.rpp) by its absolute path."""
    try:
        return _wrap(adapter.open_project(file_path=file_path))
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def new_project() -> dict[str, Any]:
    """Create a new blank REAPER project (equivalent to File > New Project)."""
    try:
        return _wrap(adapter.new_project())
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def list_available_fx(filter: str | None = None) -> dict[str, Any]:
    """
    List installed FX plugins (VST, VST3, CLAP, and JS/JSFX).
    - filter: optional case-insensitive substring to match against plugin name or type
              e.g. 'fabfilter', 'vst3', 'clap', 'rea', 'comp'
    Returns a list of {name, type} objects and a total count.
    type values: 'VST' (VST2), 'VST3', 'CLAP', 'JS'
    """
    try:
        return _wrap(adapter.list_available_fx(filter=filter))
    except Exception as exc:
        return _err(exc)


# ---------------------------------------------------------------------------
# Routing & sends
# ---------------------------------------------------------------------------


@mcp.tool()
def create_track_send(src_track_index: int, dst_track_index: int) -> dict[str, Any]:
    """Create a send from one track to another. Returns the new send index."""
    try:
        return _wrap(
            adapter.create_track_send(
                src_track_index=src_track_index, dst_track_index=dst_track_index
            )
        )
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def duplicate_time_range(
    start_time: float,
    end_time: float,
    repeat_count: int = 1,
) -> dict[str, Any]:
    """
    Copy all items overlapping [start_time, end_time) and paste them immediately
    after end_time, repeating repeat_count times. Useful for extending song form
    (repeating a chorus, creating an outro).
    - start_time / end_time: seconds
    - repeat_count: how many copies to paste (default 1)
    Returns the new project end time after pasting.
    """
    try:
        return _wrap(
            adapter.duplicate_time_range(
                start_time=start_time,
                end_time=end_time,
                repeat_count=repeat_count,
            )
        )
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def remove_track_send(track_index: int, send_index: int) -> dict[str, Any]:
    """Remove a send from a track by its 0-based send index."""
    try:
        return _wrap(
            adapter.remove_track_send(track_index=track_index, send_index=send_index)
        )
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def set_track_send(
    track_index: int,
    send_index: int,
    volume: float | None = None,
    pan: float | None = None,
) -> dict[str, Any]:
    """
    Set the volume and/or pan of a track send.
    - volume: linear amplitude (1.0 = 0 dB)
    - pan: -1.0 (full left) to 1.0 (full right)
    """
    try:
        return _wrap(
            adapter.set_track_send(
                track_index=track_index,
                send_index=send_index,
                volume=volume,
                pan=pan,
            )
        )
    except Exception as exc:
        return _err(exc)


# ---------------------------------------------------------------------------
# Recording
# ---------------------------------------------------------------------------


@mcp.tool()
def set_track_input(track_index: int, input_index: int) -> dict[str, Any]:
    """
    Set the recording input for a track.
    - For audio: 0-based audio input channel index.
    - For MIDI: use REAPER's I_RECINPUT encoding (e.g. 4096 + channel*32 + device).
    """
    try:
        return _wrap(
            adapter.set_track_input(track_index=track_index, input_index=input_index)
        )
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def set_input_monitoring(track_index: int, mode: int) -> dict[str, Any]:
    """
    Set input monitoring mode for a track.
    - mode: 0 = off, 1 = on, 2 = not when playing
    """
    try:
        return _wrap(
            adapter.set_input_monitoring(track_index=track_index, mode=mode)
        )
    except Exception as exc:
        return _err(exc)


# ---------------------------------------------------------------------------
# Automation
# ---------------------------------------------------------------------------


@mcp.tool()
def get_envelope_points(
    track_index: int,
    envelope_index: int | None = None,
    envelope_name: str | None = None,
) -> dict[str, Any]:
    """
    Read all automation envelope points from a track envelope.
    Identify the envelope by name (e.g. 'Volume', 'Pan', 'Mute') or by
    0-based envelope_index. Using envelope_name is preferred and works even
    if the envelope is not yet visible/armed in the REAPER UI.
    Returns envelope name and list of points with time, value, shape, tension.
    """
    try:
        return _wrap(
            adapter.get_envelope_points(
                track_index=track_index,
                envelope_index=envelope_index,
                envelope_name=envelope_name,
            )
        )
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def insert_envelope_point(
    track_index: int,
    time: float,
    value: float,
    envelope_index: int | None = None,
    envelope_name: str | None = None,
    shape: int = 0,
    tension: float = 0.0,
) -> dict[str, Any]:
    """
    Insert a point into an automation envelope.
    Identify the envelope by name (e.g. 'Volume', 'Pan', 'Mute') or by
    0-based envelope_index. Using envelope_name is preferred and works even
    if the envelope is not yet visible/armed in the REAPER UI.
    - time: position in seconds
    - value: linear amplitude (Volume: 0.0=silence, 1.0=0 dB, 2.0=+6 dB max)
    - shape: 0=linear, 1=square, 2=slow start/end, 3=fast start, 4=fast end, 5=bezier
    - tension: bezier tension (-1.0 to 1.0)
    """
    try:
        return _wrap(
            adapter.insert_envelope_point(
                track_index=track_index,
                envelope_index=envelope_index,
                envelope_name=envelope_name,
                time=time,
                value=value,
                shape=shape,
                tension=tension,
            )
        )
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def insert_envelope_point_at_beat(
    track_index: int,
    bar: int,
    beat: float,
    value: float,
    envelope_index: int | None = None,
    envelope_name: str | None = None,
    shape: int = 0,
    tension: float = 0.0,
) -> dict[str, Any]:
    """
    Insert an automation envelope point aligned to the project beat grid.
    Identify the envelope by name (e.g. 'Volume', 'Pan') or by 0-based envelope_index.
    - bar: 1-based measure number (bar 1 = project start)
    - beat: 1-based beat within the bar, may be fractional (e.g. 2.5 = beat 2 and a half).
      Beat units follow the time-signature denominator (e.g. quarter notes in 4/4, eighth notes in 6/8).
    - value: linear amplitude (Volume: 0.0=silence, 1.0=0 dB, 2.0=+6 dB max)
    - shape: 0=linear, 1=square, 2=slow start/end, 3=fast start, 4=fast end, 5=bezier
    Returns the resolved time in seconds alongside bar/beat for verification.
    """
    try:
        return _wrap(
            adapter.insert_envelope_point_at_beat(
                track_index=track_index,
                envelope_index=envelope_index,
                envelope_name=envelope_name,
                bar=bar,
                beat=beat,
                value=value,
                shape=shape,
                tension=tension,
            )
        )
    except Exception as exc:
        return _err(exc)


@mcp.tool()
def clear_envelope_points(
    track_index: int,
    envelope_index: int | None = None,
    envelope_name: str | None = None,
    t1: float = 0.0,
    t2: float = 1e12,
) -> dict[str, Any]:
    """
    Delete all automation envelope points in the given time range (default: entire timeline).
    Identify the envelope by name (e.g. 'Volume', 'Pan') or by 0-based envelope_index.
    """
    try:
        return _wrap(
            adapter.clear_envelope_points(
                track_index=track_index,
                envelope_index=envelope_index,
                envelope_name=envelope_name,
                t1=t1,
                t2=t2,
            )
        )
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
