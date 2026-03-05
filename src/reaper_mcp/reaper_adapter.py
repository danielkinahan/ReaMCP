"""
reaper_adapter.py
High-level wrappers around BridgeClient calls, mirroring the MCP tool surface.
All heavy work lives in the Lua bridge; this module is a thin translation layer.
"""
from __future__ import annotations

from typing import Any

from .bridge_client import BridgeClient


class ReaperAdapter:
    def __init__(self, host: str = "127.0.0.1", port: int = 9001) -> None:
        self._client = BridgeClient(host=host, port=port)

    # ------------------------------------------------------------------
    # Connectivity
    # ------------------------------------------------------------------

    def ping(self) -> dict[str, Any]:
        return self._client.call("ping")

    # ------------------------------------------------------------------
    # Project info
    # ------------------------------------------------------------------

    def get_project_info(self) -> dict[str, Any]:
        return self._client.call("get_project_info")

    def get_project_parameters(self) -> dict[str, Any]:
        return self._client.call("get_project_parameters")

    # ------------------------------------------------------------------
    # Tracks
    # ------------------------------------------------------------------

    def list_tracks(self) -> list[dict[str, Any]]:
        return self._client.call("list_tracks")

    def get_track(self, track_index: int) -> dict[str, Any]:
        return self._client.call("get_track", track_index=track_index)

    def create_track(
        self,
        name: str | None = None,
        index: int | None = None,
    ) -> dict[str, Any]:
        return self._client.call("create_track", name=name, index=index)

    def delete_track(self, track_index: int) -> dict[str, Any]:
        return self._client.call("delete_track", track_index=track_index)

    def set_track_properties(
        self,
        track_index: int,
        name: str | None = None,
        volume: float | None = None,
        pan: float | None = None,
        mute: bool | None = None,
        solo: bool | None = None,
        arm: bool | None = None,
    ) -> dict[str, Any]:
        return self._client.call(
            "set_track_properties",
            track_index=track_index,
            name=name,
            volume=volume,
            pan=pan,
            mute=mute,
            solo=solo,
            arm=arm,
        )

    # ------------------------------------------------------------------
    # Media items
    # ------------------------------------------------------------------

    def move_media_item(
        self, track_index: int, item_index: int, position: float
    ) -> dict[str, Any]:
        return self._client.call(
            "move_media_item",
            track_index=track_index,
            item_index=item_index,
            position=position,
        )

    def resize_media_item(
        self, track_index: int, item_index: int, length: float
    ) -> dict[str, Any]:
        return self._client.call(
            "resize_media_item",
            track_index=track_index,
            item_index=item_index,
            length=length,
        )

    def delete_media_item(
        self, track_index: int, item_index: int
    ) -> dict[str, Any]:
        return self._client.call(
            "delete_media_item",
            track_index=track_index,
            item_index=item_index,
        )

    def get_item_properties(
        self, track_index: int, item_index: int
    ) -> dict[str, Any]:
        return self._client.call(
            "get_item_properties",
            track_index=track_index,
            item_index=item_index,
        )

    def duplicate_track(self, track_index: int) -> dict[str, Any]:
        return self._client.call("duplicate_track", track_index=track_index)

    def duplicate_item(self, track_index: int, item_index: int) -> dict[str, Any]:
        return self._client.call(
            "duplicate_item",
            track_index=track_index,
            item_index=item_index,
        )

    def create_midi_item(
        self,
        track_index: int,
        start: float,
        end: float,
        notes: list[dict[str, Any]] | None = None,
    ) -> dict[str, Any]:
        return self._client.call(
            "create_midi_item",
            track_index=track_index,
            start=start,
            end=end,
            notes=notes or [],
        )

    def insert_audio_file(
        self,
        track_index: int,
        file_path: str,
        position: float,
    ) -> dict[str, Any]:
        return self._client.call(
            "insert_audio_file",
            track_index=track_index,
            file_path=file_path,
            position=position,
        )

    # ------------------------------------------------------------------
    # Transport
    # ------------------------------------------------------------------

    def transport(self, action: str, position: float | None = None) -> dict[str, Any]:
        return self._client.call("transport", action=action, position=position)

    # ------------------------------------------------------------------
    # FX / Instruments
    # ------------------------------------------------------------------

    def add_fx(
        self,
        track_index: int,
        fx_name: str,
        input_fx: bool = False,
    ) -> dict[str, Any]:
        return self._client.call(
            "add_fx",
            track_index=track_index,
            fx_name=fx_name,
            input_fx=input_fx,
        )

    def list_fx(self, track_index: int) -> list[dict[str, Any]]:
        return self._client.call("list_fx", track_index=track_index)

    def get_fx_params(
        self,
        track_index: int,
        fx_index: int,
    ) -> list[dict[str, Any]]:
        return self._client.call(
            "get_fx_params",
            track_index=track_index,
            fx_index=fx_index,
        )

    def set_fx_param(
        self,
        track_index: int,
        fx_index: int,
        param_index: int,
        normalized_value: float,
    ) -> dict[str, Any]:
        return self._client.call(
            "set_fx_param",
            track_index=track_index,
            fx_index=fx_index,
            param_index=param_index,
            normalized_value=normalized_value,
        )

    # ------------------------------------------------------------------
    # Tempo & project parameters
    # ------------------------------------------------------------------

    def get_tempo(self) -> dict[str, Any]:
        return self._client.call("get_tempo")

    def set_tempo(
        self,
        bpm: float,
        time_sig_num: int | None = None,
        time_sig_denom: int | None = None,
    ) -> dict[str, Any]:
        return self._client.call(
            "set_tempo",
            bpm=bpm,
            time_sig_num=time_sig_num,
            time_sig_denom=time_sig_denom,
        )

    def set_project_parameter(self, parameter: str, value: Any) -> dict[str, Any]:
        return self._client.call(
            "set_project_parameter",
            parameter=parameter,
            value=value,
        )
