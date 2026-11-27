"""iDeck 3.0 split the largest Swift files into several. A test that reads one of the
original files by name gets the original and every part split from it, in order, so
checks written before the split still see the code they check. Importing this module
installs the hook (Path.read_text)."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
_original_read_text = Path.read_text


def parts(name):
    """The files split from iDeck/<name>, found by their 'Split from <name>' header."""
    found = []
    for path in sorted((ROOT / "iDeck").rglob("*.swift")):
        try:
            head = _original_read_text(path, encoding="utf-8")[:400]
        except OSError:
            continue
        if f"// Split from {name} (iDeck 3.0" in head:
            found.append(path)
    return found


# iDeck 3.0 moved the Swift side of the Madeira native runtime into iDeck/NativeRuntime/.
MOVED_FOLDERS = ["NativeRuntime"]


def _moved(path):
    """iDeck/<name> that now lives in one of MOVED_FOLDERS, else the path itself."""
    if path.exists() or path.parent != ROOT / "iDeck":
        return path
    for folder in MOVED_FOLDERS:
        candidate = ROOT / "iDeck" / folder / path.name
        if candidate.exists():
            return candidate
    return path


def _read_text(self, *args, **kwargs):
    self = _moved(self)
    text = _original_read_text(self, *args, **kwargs)
    try:
        resolved = self.resolve()
    except OSError:
        return text
    if resolved.parent == (ROOT / "iDeck").resolve() and resolved.suffix == ".swift":
        extra = parts(resolved.name)
        if extra:
            text += "".join("\n" + _original_read_text(p, *args, **kwargs) for p in extra)
    return text


if Path.read_text is not _read_text:
    Path.read_text = _read_text
