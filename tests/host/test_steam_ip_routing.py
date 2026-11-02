import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DEPOT = (ROOT / "iDeck/SwiftSteam/Content/DepotDownloader.swift").read_text(encoding="utf-8")
CM = (ROOT / "iDeck/SteamManager.swift").read_text(encoding="utf-8")
FEX = (ROOT / "iDeck/NativeRuntime/FEXRuntime.cpp").read_text(encoding="utf-8")


if __name__ == "__main__":
    unittest.main()
