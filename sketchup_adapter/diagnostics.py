# SPDX-License-Identifier: GPL-3.0-or-later
from __future__ import annotations
import json
import logging
from datetime import datetime, timezone
from pathlib import Path
from .registry import atomic_json
log = logging.getLogger(__name__)


class Diagnostics:
    def __init__(self, root: Path):
        self.root = Path(root)
        self.events = []
        self.results = {}
        self.ready = False
        self.write_error = None

    def record(self, message):
        if message.get("op") not in {"extension_loading", "extension_loaded", "extension_error", "error",
                                     "api_gap", "fatal", "ready", "capabilities", "warning"}:
            return
        event = dict(message, time=datetime.now(timezone.utc).isoformat())
        self.events.append(event)
        self.events = self.events[-2000:]
        if message.get("op") in {"extension_loaded", "extension_error"}:
            self.results[message.get("plugin_id") or message.get("loader", "unknown")] = event
        if message.get("op") == "ready":
            self.ready = True
        try:
            self.root.mkdir(parents=True, exist_ok=True)
            with (self.root / "events.jsonl").open("a", encoding="utf-8") as output:
                output.write(json.dumps(event, ensure_ascii=False) + "\n")
            atomic_json(self.root / "last-session.json", {"ready": self.ready, "plugins": self.results,
                                                           "events": self.events})
        except OSError as error:
            # A sync client can briefly lock a diagnostic file on Windows.
            # Keep protocol state in memory and retry the complete session on
            # the next record; optional telemetry must not swallow `ready`.
            detail=str(error)
            if detail!=self.write_error:
                log.warning("Adapter diagnostic file is unavailable: %s", detail)
            self.write_error=detail
        else:
            self.write_error=None
