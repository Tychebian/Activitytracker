#!/usr/bin/env python3
"""User-configurable category list, persisted to ~/.activity_tracker/config.json."""

__version__ = "1.0.4"
import json
from pathlib import Path

CONFIG_PATH = Path.home() / ".activity_tracker" / "config.json"

# Slayers-inspired spell palette
PALETTE = [
    "#c8320a", "#1a5fa3", "#6b1a8a", "#b07a10", "#c83264",
    "#2a8a50", "#c87820", "#1a7a8a", "#8a3a10", "#5a1a6b",
    "#a05010", "#105a8a", "#8a104a", "#4a8a10", "#c84820",
]

_DEFAULTS = [
    {"name": "工作",         "color": "#c8320a"},  # Fireball
    {"name": "学习",         "color": "#1a5fa3"},  # Freeze Arrow
    {"name": "浪费时间",     "color": "#6b1a8a"},  # Shadow Web
    {"name": "运动",         "color": "#b07a10"},  # Thunder
    {"name": "和11妹在一起", "color": "#c83264"},  # Elmekia Lance
]


def _load() -> dict:
    if CONFIG_PATH.exists():
        try:
            return json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
        except Exception:
            pass
    return {"categories": [c.copy() for c in _DEFAULTS]}


def _save(cfg: dict):
    CONFIG_PATH.parent.mkdir(exist_ok=True)
    CONFIG_PATH.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")


def get_categories() -> list:
    return _load().get("categories", [c.copy() for c in _DEFAULTS])


def get_names() -> list:
    return [c["name"] for c in get_categories()]


def get_colors() -> dict:
    return {c["name"]: c["color"] for c in get_categories()}


def _next_color(used: list) -> str:
    for c in PALETTE:
        if c not in used:
            return c
    return PALETTE[len(used) % len(PALETTE)]


def add_category(name: str, color: str = "") -> dict:
    cfg = _load()
    cats = cfg.setdefault("categories", [])
    if any(c["name"] == name for c in cats):
        raise ValueError(f"category '{name}' already exists")
    if not color:
        color = _next_color([c["color"] for c in cats])
    entry = {"name": name, "color": color}
    cats.append(entry)
    _save(cfg)
    return entry


def update_category(old_name: str, new_name: str = "", new_color: str = "") -> str:
    cfg = _load()
    for cat in cfg.get("categories", []):
        if cat["name"] == old_name:
            if new_name and new_name != old_name:
                cat["name"] = new_name
            if new_color:
                cat["color"] = new_color
            _save(cfg)
            return new_name or old_name
    raise KeyError(f"category '{old_name}' not found")


def delete_category(name: str):
    cfg = _load()
    remaining = [c for c in cfg.get("categories", []) if c["name"] != name]
    if not remaining:
        raise ValueError("cannot delete the last category")
    cfg["categories"] = remaining
    _save(cfg)


def get_interval() -> int:
    """Return popup interval in minutes (default 20)."""
    return int(_load().get("interval", 20))


def set_interval(minutes: int) -> None:
    if not (5 <= minutes <= 120):
        raise ValueError("interval must be 5–120 minutes")
    cfg = _load()
    cfg["interval"] = minutes
    _save(cfg)


def get_auto_popup() -> bool:
    return bool(_load().get("auto_popup", True))


def set_auto_popup(enabled: bool) -> None:
    cfg = _load()
    cfg["auto_popup"] = bool(enabled)
    _save(cfg)
