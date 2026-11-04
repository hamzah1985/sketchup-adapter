"""Bind a verification run to the exact runtime it exercised."""
from pathlib import Path
import hashlib,json

def runtime_files(root):
    root=Path(root)
    return {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted((root/'sketchup_adapter').rglob('*'))
            if p.is_file() and '__pycache__' not in p.parts}

def manifest_hash(files):
    return hashlib.sha256(json.dumps(files,sort_keys=True,separators=(',',':')).encode()).hexdigest()
