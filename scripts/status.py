"""Print Ollama server status and currently loaded models."""

import json
import sys
import urllib.request
import urllib.error

HOST = "http://localhost:11434"


def fetch(path: str) -> dict | None:
    try:
        with urllib.request.urlopen(f"{HOST}{path}", timeout=3) as r:
            return json.loads(r.read())
    except Exception:
        return None


def main() -> None:
    version_data = fetch("/api/version")
    if not version_data:
        print("Ollama is NOT running.")
        sys.exit(1)

    print(f"Ollama running — version: {version_data.get('version', '?')}")

    ps_data = fetch("/api/ps")
    models = (ps_data or {}).get("models", [])
    if models:
        for m in models:
            name = m.get("name", "?")
            size = m.get("size", 0)
            size_gb = f"{size / 1e9:.2f} GB" if size else "?"
            expires = m.get("expires_at", "")[:19].replace("T", " ") or "?"
            print(f"  Loaded model : {name}  ({size_gb})  expires {expires}")
    else:
        print("  No models currently loaded in memory.")


if __name__ == "__main__":
    main()
