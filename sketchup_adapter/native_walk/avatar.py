"""Alex: baked poses of the Model Viewer 2 character, drawn as textured
triangles. A port of Model Viewer 2's walkthrough/avatar.rb.

The assets are the SAME files the SketchUp plugin ships: ``alex.json.gz``
(mesh topology, per-vertex UVs, clip table) and one ``<Clip>.bin.gz`` per
animation holding every frame's vertex positions as int16 millimetres.
Nothing is added to the model: the viewport draws the figure as a tool
preview, so it cannot be selected, saved or undone."""
from __future__ import annotations

import gzip
import json
import math
from pathlib import Path

import numpy as np

ASSETS = Path(__file__).resolve().parent / "assets"


class Avatar:
    def __init__(self, directory: Path = ASSETS) -> None:
        self._dir = Path(directory)
        with gzip.open(self._dir / "alex.json.gz", "rb") as f:
            self.manifest = json.loads(f.read())
        if self.manifest.get("encoding") != "int16-le":
            raise ValueError("unsupported Alex encoding "
                             f"{self.manifest.get('encoding')!r}")
        self._vertex_count = int(self.manifest["vertexCount"])
        # One draw run per texture image: meshes sharing an image are merged.
        # Each run is the global vertex index of every triangle corner and the
        # UV that corner carries (UVs are per vertex, expanded per corner).
        by_tex: dict[str, tuple[list, list]] = {}
        for mesh in self.manifest["meshes"]:
            offset = int(mesh["offset"])
            uv = mesh["uv"]
            idx, uvs = by_tex.setdefault(str(self._dir / mesh["texture"]),
                                         ([], []))
            for i in mesh["indices"]:
                idx.append(offset + i)
                uvs.append(uv[i])
        self._runs = [(path, np.asarray(idx, dtype=np.int64),
                       np.asarray(uvs, dtype=np.float32))
                      for path, (idx, uvs) in by_tex.items()]
        self._clips: dict[str, bytes] = {}
        self._key = None
        self._tris: dict = {}

    @property
    def height(self) -> float:
        """Standing height in metres."""
        return float(self.manifest.get("height", 1740)) / 1000.0

    def _clip_bytes(self, name: str) -> bytes:
        data = self._clips.get(name)
        if data is None:
            clip = self.manifest["clips"][name]
            with gzip.open(self._dir / clip["file"], "rb") as f:
                data = self._clips[name] = f.read()
        return data

    def update(self, clip_name: str, time: float, position, yaw: float) -> None:
        """Pose Alex: ``clip_name`` at ``time`` seconds, feet at ``position``
        (x, y, z metres), turned ``yaw`` radians about +Z."""
        clip = self.manifest["clips"][clip_name]
        duration = float(clip["duration"])
        frames = int(clip["frames"])
        index = min(frames - 1, int((time % duration) / duration * frames))
        px, py, pz = (float(position[0]), float(position[1]),
                      float(position[2]))
        key = (clip_name, index, round(px, 5), round(py, 5), round(pz, 5),
               round(yaw, 5))
        if key == self._key:
            return
        self._key = key
        data = self._clip_bytes(clip_name)
        stride = self._vertex_count * 6
        raw = np.frombuffer(data, dtype="<i2", count=self._vertex_count * 3,
                            offset=index * stride)
        v = raw.reshape(-1, 3).astype(np.float32) / 1000.0
        c, s = math.cos(yaw), math.sin(yaw)
        pts = np.empty_like(v)
        pts[:, 0] = px + v[:, 0] * c - v[:, 1] * s
        pts[:, 1] = py + v[:, 0] * s + v[:, 1] * c
        pts[:, 2] = pz + v[:, 2]
        tris = {}
        for path, idx, uv in self._runs:
            buf = np.empty((len(idx), 5), dtype=np.float32)
            buf[:, :3] = pts[idx]
            buf[:, 3:] = uv
            tris[path] = buf.ravel()
        self._tris = tris

    def triangles(self) -> dict:
        """``{image path: float32 pos(3)+uv(2) per corner}`` for the pose."""
        return self._tris

    def clear(self) -> None:
        self._key = None
        self._tris = {}
