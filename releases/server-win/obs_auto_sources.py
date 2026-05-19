"""
OBS script for Project-O Stream.

Load this file in OBS through Tools > Scripts. It polls the local receiver
state endpoint and keeps one Media Source per connected Project-O camera slot.
"""
from __future__ import annotations

import json
import time
import urllib.error
import urllib.request

try:
    import obspython as obs
except Exception:  # Allows syntax checks outside OBS.
    obs = None  # type: ignore[assignment]


DEFAULT_SERVER_URL = "http://127.0.0.1:7077/state"
DEFAULT_POLL_MS = 1000

_server_url = DEFAULT_SERVER_URL
_poll_ms = DEFAULT_POLL_MS
_remove_on_disconnect = True
_managed: dict[str, str] = {}
_last_log: dict[str, str] = {}
_last_success = 0.0


def script_description() -> str:
    return (
        "Project-O Stream auto sources\n\n"
        "Automatically adds OBS Media Sources for camera slots reported by the "
        "Project-O receiver and removes them when the receiver marks the slot "
        "disconnected."
    )


def script_defaults(settings) -> None:
    obs.obs_data_set_default_string(settings, "server_url", DEFAULT_SERVER_URL)
    obs.obs_data_set_default_int(settings, "poll_ms", DEFAULT_POLL_MS)
    obs.obs_data_set_default_bool(settings, "remove_on_disconnect", True)


def script_properties():
    props = obs.obs_properties_create()
    obs.obs_properties_add_text(
        props,
        "server_url",
        "Receiver state URL",
        obs.OBS_TEXT_DEFAULT,
    )
    obs.obs_properties_add_int(
        props,
        "poll_ms",
        "Poll interval (ms)",
        250,
        10000,
        250,
    )
    obs.obs_properties_add_bool(
        props,
        "remove_on_disconnect",
        "Remove sources when disconnected",
    )
    return props


def script_load(settings) -> None:
    script_update(settings)


def script_unload() -> None:
    obs.timer_remove(_poll_receiver)


def script_update(settings) -> None:
    global _server_url, _poll_ms, _remove_on_disconnect

    _server_url = obs.obs_data_get_string(settings, "server_url") or DEFAULT_SERVER_URL
    _poll_ms = max(250, obs.obs_data_get_int(settings, "poll_ms") or DEFAULT_POLL_MS)
    _remove_on_disconnect = obs.obs_data_get_bool(settings, "remove_on_disconnect")

    obs.timer_remove(_poll_receiver)
    obs.timer_add(_poll_receiver, _poll_ms)


def _log(level: int, key: str, message: str) -> None:
    if obs is None:
        return
    if _last_log.get(key) == message:
        return
    _last_log[key] = message
    obs.script_log(level, message)


def _fetch_state() -> dict:
    request = urllib.request.Request(
        _server_url,
        headers={
            "Accept": "application/json",
            "User-Agent": "Project-O-OBS-Auto-Sources",
        },
    )
    with urllib.request.urlopen(request, timeout=0.8) as response:
        return json.loads(response.read().decode("utf-8"))


def _media_settings(input_url: str):
    settings = obs.obs_data_create()
    obs.obs_data_set_bool(settings, "is_local_file", False)
    obs.obs_data_set_string(settings, "input", input_url)
    obs.obs_data_set_bool(settings, "restart_on_activate", True)
    obs.obs_data_set_bool(settings, "close_when_inactive", True)
    obs.obs_data_set_bool(settings, "clear_on_media_end", True)
    return settings


def _add_source_to_current_scene(source, source_name: str) -> bool:
    scene_source = obs.obs_frontend_get_current_scene()
    if scene_source is None:
        _log(obs.LOG_WARNING, "scene", "Project-O: no active OBS scene for auto source")
        return False

    try:
        scene = obs.obs_scene_from_source(scene_source)
        if scene is None:
            _log(obs.LOG_WARNING, "scene", "Project-O: active OBS source is not a scene")
            return False
        if obs.obs_scene_find_source(scene, source_name) is None:
            obs.obs_scene_add(scene, source)
        return True
    finally:
        obs.obs_source_release(scene_source)


def _ensure_source(source_name: str, input_url: str) -> None:
    settings = _media_settings(input_url)
    source = obs.obs_get_source_by_name(source_name)
    created = False

    try:
        if source is None:
            source = obs.obs_source_create("ffmpeg_source", source_name, settings, None)
            created = True
            if source is None:
                _log(obs.LOG_ERROR, source_name, f"Project-O: failed to create {source_name}")
                return
        else:
            obs.obs_source_update(source, settings)

        if not _add_source_to_current_scene(source, source_name):
            return

        previous_url = _managed.get(source_name)
        _managed[source_name] = input_url
        if created:
            _log(obs.LOG_INFO, source_name, f"Project-O: added {source_name} -> {input_url}")
        elif previous_url and previous_url != input_url:
            _log(obs.LOG_INFO, source_name, f"Project-O: updated {source_name} -> {input_url}")
            if hasattr(obs, "obs_source_media_restart"):
                obs.obs_source_media_restart(source)
    finally:
        obs.obs_data_release(settings)
        if source is not None:
            obs.obs_source_release(source)


def _remove_source_from_scenes(source_name: str) -> None:
    scenes = obs.obs_frontend_get_scenes()
    try:
        for scene_source in scenes:
            scene = obs.obs_scene_from_source(scene_source)
            if scene is None:
                continue
            item = obs.obs_scene_find_source(scene, source_name)
            if item is not None:
                obs.obs_sceneitem_remove(item)
    finally:
        obs.source_list_release(scenes)


def _remove_source(source_name: str) -> None:
    _remove_source_from_scenes(source_name)
    source = obs.obs_get_source_by_name(source_name)
    try:
        if source is not None:
            obs.obs_source_remove(source)
    finally:
        if source is not None:
            obs.obs_source_release(source)

    _managed.pop(source_name, None)
    _log(obs.LOG_INFO, source_name, f"Project-O: removed {source_name}")


def _active_slots(state: dict) -> list[dict]:
    slots = state.get("slots")
    if not isinstance(slots, list):
        return []
    return [
        slot for slot in slots
        if isinstance(slot, dict)
        and slot.get("obsSourcePresent") is True
        and isinstance(slot.get("obsInputUrl") or slot.get("obsInput"), str)
    ]


def _poll_receiver() -> None:
    global _last_success

    try:
        state = _fetch_state()
    except (OSError, urllib.error.URLError, TimeoutError) as error:
        elapsed = time.time() - _last_success if _last_success else 0.0
        suffix = f" ({elapsed:.0f}s since last receiver state)" if elapsed else ""
        _log(obs.LOG_WARNING, "fetch", f"Project-O: receiver state unavailable{suffix}: {error}")
        return
    except Exception as error:
        _log(obs.LOG_WARNING, "fetch", f"Project-O: invalid receiver state: {error}")
        return

    _last_success = time.time()
    active_names: set[str] = set()

    for slot in _active_slots(state):
        source_name = str(slot.get("sourceName") or f"Project-O Cam {slot.get('index', 0)}")
        input_url = str(slot.get("obsInputUrl") or slot.get("obsInput"))
        active_names.add(source_name)
        _ensure_source(source_name, input_url)

    if not _remove_on_disconnect:
        return

    for source_name in list(_managed):
        if source_name not in active_names:
            _remove_source(source_name)
