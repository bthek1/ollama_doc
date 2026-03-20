"""Print Ollama server status and currently loaded models."""

import json
import subprocess
import sys
import urllib.request
import urllib.error

from rich.console import Console
from rich.panel import Panel
from rich.table import Table
from rich.rule import Rule
from rich import box

HOST = "http://localhost:11434"
console = Console()


def fetch(path: str) -> dict | None:
    try:
        with urllib.request.urlopen(f"{HOST}{path}", timeout=3) as r:
            return json.loads(r.read())
    except Exception:
        return None


def greet(model: str) -> str | None:
    payload = json.dumps({"model": model, "prompt": "hi", "stream": False}).encode()
    req = urllib.request.Request(
        f"{HOST}/api/generate",
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read()).get("response", "").strip()
    except Exception:
        return None


def fetch_gpu() -> list[dict] | None:
    """Return GPU stats by querying nvidia-smi inside the ollama container."""
    try:
        result = subprocess.run(
            [
                "docker", "exec", "ollama",
                "nvidia-smi",
                "--query-gpu=name,memory.total,memory.used,memory.free,utilization.gpu,temperature.gpu",
                "--format=csv,noheader,nounits",
            ],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode != 0 or not result.stdout.strip():
            return None
        gpus = []
        for line in result.stdout.strip().splitlines():
            parts = [p.strip() for p in line.split(",")]
            if len(parts) == 6:
                gpus.append({
                    "name": parts[0],
                    "mem_total": parts[1],
                    "mem_used": parts[2],
                    "mem_free": parts[3],
                    "util": parts[4],
                    "temp": parts[5],
                })
        return gpus or None
    except Exception:
        return None


def main() -> None:
    version_data = fetch("/api/version")
    if not version_data:
        console.print(Panel("[bold red]Ollama is NOT running.[/bold red]", expand=False))
        sys.exit(1)

    version = version_data.get("version", "?")
    console.print(Panel(f"[bold green]Ollama running[/bold green] — version: [cyan]{version}[/cyan]", expand=False))

    gpus = fetch_gpu()
    if gpus:
        gpu_table = Table(title="GPU Status", box=box.ROUNDED, show_lines=True)
        gpu_table.add_column("GPU", style="bold white", no_wrap=True)
        gpu_table.add_column("Util %", justify="right", style="green")
        gpu_table.add_column("Temp °C", justify="right", style="yellow")
        gpu_table.add_column("Mem Used", justify="right", style="magenta")
        gpu_table.add_column("Mem Free", justify="right", style="cyan")
        gpu_table.add_column("Mem Total", justify="right", style="dim")
        for g in gpus:
            gpu_table.add_row(
                g["name"],
                g["util"],
                g["temp"],
                f"{g['mem_used']} MB",
                f"{g['mem_free']} MB",
                f"{g['mem_total']} MB",
            )
        console.print(gpu_table)
    else:
        console.print("[dim]No NVIDIA GPU detected inside container.[/dim]")

    ps_data = fetch("/api/ps")
    loaded_models = (ps_data or {}).get("models", [])

    if loaded_models:
        table = Table(title="Loaded Models", box=box.ROUNDED, show_lines=True)
        table.add_column("Model", style="bold cyan", no_wrap=True)
        table.add_column("Size", justify="right", style="magenta")
        table.add_column("Expires At", style="yellow")

        for m in loaded_models:
            name = m.get("name", "?")
            size = m.get("size", 0)
            size_gb = f"{size / 1e9:.2f} GB" if size else "?"
            expires = m.get("expires_at", "")[:19].replace("T", " ") or "?"
            table.add_row(name, size_gb, expires)

        console.print(table)
        greet_names = [m.get("name", "?") for m in loaded_models]
    else:
        console.print("[dim]No models currently loaded in memory.[/dim]")
        tags_data = fetch("/api/tags")
        available = (tags_data or {}).get("models", [])
        if not available:
            console.print("[red]No models available to greet.[/red]")
            return
        greet_names = [available[0].get("name", "?")]

    console.print(Rule("[bold]Greeting models[/bold]"))
    for name in greet_names:
        console.print(f"[bold cyan]>> hi[/bold cyan] → [dim]{name}[/dim]")
        with console.status(f"[dim]Waiting for {name}…[/dim]"):
            reply = greet(name)
        if reply:
            console.print(Panel(reply, title=f"[green]{name}[/green]", expand=False))
        else:
            console.print(f"[red]No response from {name}[/red]")


if __name__ == "__main__":
    main()
