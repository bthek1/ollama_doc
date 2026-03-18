import subprocess
import sys

import httpx
import ollama
from rich import box
from rich.columns import Columns
from rich.console import Console
from rich.live import Live
from rich.panel import Panel
from rich.rule import Rule
from rich.table import Table
from rich.text import Text

console = Console()

QUERY_MODEL = "llama3.2"
SAMPLE_PROMPT = "In two sentences, what is Ollama and why is it useful?"


# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

def check_ollama_running() -> tuple[bool, str]:
    """Return (is_running, version_string)."""
    try:
        r = httpx.get("http://localhost:11434/api/version", timeout=3)
        if r.status_code == 200:
            return True, r.json().get("version", "unknown")
    except Exception:
        pass
    return False, ""


def check_gpu() -> tuple[bool, list[dict]]:
    """Return (gpu_available, list_of_gpu_dicts)."""
    try:
        result = subprocess.run(
            [
                "nvidia-smi",
                "--query-gpu=name,memory.total,memory.free,utilization.gpu",
                "--format=csv,noheader,nounits",
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0 and result.stdout.strip():
            gpus = []
            for line in result.stdout.strip().splitlines():
                parts = [p.strip() for p in line.split(",")]
                if len(parts) >= 4:
                    gpus.append(
                        {
                            "name": parts[0],
                            "mem_total_mb": parts[1],
                            "mem_free_mb": parts[2],
                            "utilization_pct": parts[3],
                        }
                    )
            return bool(gpus), gpus
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    return False, []


# ---------------------------------------------------------------------------
# Display helpers
# ---------------------------------------------------------------------------

def render_server_panel(is_running: bool, version: str) -> Panel:
    status = (
        Text("● RUNNING", style="bold green")
        if is_running
        else Text("● STOPPED", style="bold red")
    )
    lines = Text()
    lines.append("Endpoint : ", style="dim")
    lines.append("http://localhost:11434\n")
    lines.append("Version  : ", style="dim")
    lines.append(version if version else "N/A")
    lines.append("\nStatus   : ", style="dim")
    lines.append_text(status)
    return Panel(lines, title="[bold cyan]Ollama Server[/bold cyan]", expand=False)


def render_gpu_panel(gpu_available: bool, gpus: list[dict]) -> Panel:
    if not gpu_available:
        body = Text("No NVIDIA GPU detected — Ollama will use CPU.", style="yellow")
        return Panel(body, title="[bold cyan]GPU Status[/bold cyan]", expand=False)

    table = Table(box=box.SIMPLE, show_header=True, header_style="bold magenta")
    table.add_column("GPU", style="cyan")
    table.add_column("VRAM (MB)", justify="right")
    table.add_column("Free (MB)", justify="right")
    table.add_column("Utilisation", justify="right")

    for g in gpus:
        util = int(g["utilization_pct"]) if g["utilization_pct"].isdigit() else 0
        bar_filled = util // 10
        bar = "[green]" + "█" * bar_filled + "[/green]" + "░" * (10 - bar_filled)
        table.add_row(
            g["name"],
            g["mem_total_mb"],
            g["mem_free_mb"],
            f"{bar} {util}%",
        )
    return Panel(table, title="[bold cyan]GPU Status[/bold cyan]", expand=False)


def render_models_table(models: list) -> Table:
    table = Table(
        title="Local Ollama Models",
        box=box.ROUNDED,
        show_lines=True,
        header_style="bold magenta",
    )
    table.add_column("#", style="dim", justify="right", width=3)
    table.add_column("Model", style="cyan bold")
    table.add_column("Size", justify="right")
    table.add_column("Modified", style="dim")
    table.add_column("Digest", style="dim")

    for idx, m in enumerate(models, 1):
        size_gb = m.size / 1_073_741_824 if m.size else 0
        size_str = f"{size_gb:.2f} GB" if size_gb >= 1 else f"{m.size / 1_048_576:.0f} MB"
        modified = str(m.modified_at)[:10] if m.modified_at else "—"
        digest = (m.digest or "")[:16] + "…" if m.digest else "—"
        table.add_row(str(idx), m.model, size_str, modified, digest)

    return table


def render_running_table(running: list) -> Table | None:
    if not running:
        return None
    table = Table(
        title="Currently Loaded Models",
        box=box.ROUNDED,
        show_lines=True,
        header_style="bold magenta",
    )
    table.add_column("Model", style="cyan bold")
    table.add_column("Size", justify="right")
    table.add_column("VRAM", justify="right")
    table.add_column("Until (expiry)", style="dim")

    for m in running:
        size_gb = (m.size or 0) / 1_073_741_824
        vram_gb = (m.size_vram or 0) / 1_073_741_824
        expiry = str(m.expires_at)[:19].replace("T", " ") if m.expires_at else "—"
        table.add_row(
            m.model,
            f"{size_gb:.2f} GB",
            f"{vram_gb:.2f} GB" if vram_gb > 0 else "CPU only",
            expiry,
        )
    return table


# ---------------------------------------------------------------------------
# Query
# ---------------------------------------------------------------------------

def run_query(model: str, prompt: str) -> None:
    console.print(
        Panel(
            f"[bold yellow]{prompt}[/bold yellow]",
            title=f"[bold cyan]Query → {model}[/bold cyan]",
            expand=False,
        )
    )

    console.print()
    response_text = Text()

    with Live(
        Panel(response_text, title="[bold green]Response[/bold green]"),
        console=console,
        refresh_per_second=15,
    ) as live:
        for chunk in ollama.chat(
            model=model,
            messages=[{"role": "user", "content": prompt}],
            stream=True,
        ):
            delta = chunk.message.content or ""
            response_text.append(delta)
            live.update(
                Panel(response_text, title="[bold green]Response[/bold green]")
            )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    console.print()
    console.print(
        Panel.fit(
            "[bold white]Ollama Diagnostics[/bold white]",
            style="bold blue",
            padding=(0, 4),
        )
    )
    console.print()

    # --- Server check --------------------------------------------------
    console.print(Rule("[dim]Server[/dim]"))
    is_running, version = check_ollama_running()
    console.print(render_server_panel(is_running, version))

    if not is_running:
        console.print(
            "[bold red]Ollama is not running.[/bold red] "
            "Start it with: [cyan]ollama serve[/cyan]"
        )
        sys.exit(1)

    # --- GPU check -----------------------------------------------------
    console.print()
    console.print(Rule("[dim]GPU[/dim]"))
    gpu_available, gpus = check_gpu()
    console.print(render_gpu_panel(gpu_available, gpus))

    # --- Models --------------------------------------------------------
    console.print()
    console.print(Rule("[dim]Models[/dim]"))
    models = []
    try:
        models = ollama.list().models or []
    except Exception as exc:
        console.print(f"[red]Could not fetch models: {exc}[/red]")

    if models:
        console.print(render_models_table(models))
    else:
        console.print("[yellow]No local models found. Run: ollama pull llama3.2[/yellow]")

    # --- Running / loaded models ---------------------------------------
    console.print()
    running = []
    try:
        running = ollama.ps().models or []
    except Exception:
        pass

    running_table = render_running_table(running)
    if running_table:
        console.print(running_table)
    else:
        console.print(
            Panel(
                "[dim]No models currently loaded in memory.[/dim]",
                title="[bold cyan]Currently Loaded Models[/bold cyan]",
                expand=False,
            )
        )

    # --- Sample query --------------------------------------------------
    console.print()
    console.print(Rule("[dim]Sample Query[/dim]"))

    available_names = [m.model for m in models]
    model_to_use = QUERY_MODEL if QUERY_MODEL in available_names else (available_names[0] if available_names else None)

    if model_to_use is None:
        console.print("[red]No models available to run a query.[/red]")
        sys.exit(1)

    run_query(model_to_use, SAMPLE_PROMPT)

    console.print()
    console.print(Rule("[dim]Done[/dim]"))
    console.print()


if __name__ == "__main__":
    main()

