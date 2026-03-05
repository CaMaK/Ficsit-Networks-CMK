"""
train_server.py : serveur web + bot Discord pour Train Monitor — Satisfactory
- Flask  : dashboard web sur le port 8081
- Discord: embed édité toutes les X secondes dans un canal (pas de notification)

Lancer : python train_server.py
Config  : renseigner config.py (token, channel_id)
"""

from flask import Flask, jsonify, send_from_directory
import json, os, threading
from datetime import datetime

import discord
import asyncio

import config

# ── Chemins ──────────────────────────────────────────────────
DISK     = r"C:\Users\camak\AppData\Local\FactoryGame\Saved\SaveGames\Computers\6D014517486D381F93350594FFD39B23"
WEB_JSON = os.path.join(DISK, "web.json")
BASE_DIR = os.path.dirname(os.path.abspath(__file__))

# ── Cache partagé (Flask + Discord lisent le même) ───────────
_cache = {"trains": [], "trips": {}}


def read_web_json():
    """Lit web.json et met à jour le cache si valide."""
    global _cache
    try:
        with open(WEB_JSON, "r", encoding="utf-8") as f:
            data = json.load(f)
        _cache = data
        return data
    except (json.JSONDecodeError, ValueError):
        return _cache   # race condition : retourne le cache
    except FileNotFoundError:
        return _cache
    except Exception:
        return _cache


# ════════════════════════════════════════════════════════════
# FLASK — dashboard web
# ════════════════════════════════════════════════════════════

app = Flask(__name__)


@app.route("/api/data")
def get_data():
    return jsonify(read_web_json())


@app.route("/")
def index():
    return send_from_directory(BASE_DIR, "index.html")


def run_flask():
    """Lance Flask dans un thread dédié (ne bloque pas le bot Discord)."""
    print("Dashboard disponible sur http://0.0.0.0:8081")
    app.run(host="0.0.0.0", port=8081, debug=False, use_reloader=False)


# ════════════════════════════════════════════════════════════
# DISCORD — embed mis à jour périodiquement
# ════════════════════════════════════════════════════════════

intents = discord.Intents.default()
client  = discord.Client(intents=intents)

_monitor_msg = None  # message Discord à éditer


def build_message():
    """Construit le message texte (code block monospace) depuis le cache actuel."""
    trains = _cache.get("trains", [])
    groups = {"moving": [], "docked": [], "stopped": []}
    for t in trains:
        groups.get(t.get("status", "stopped"), groups["stopped"]).append(t)
    groups["moving"].sort(key=lambda t: -t.get("speed", 0))

    W = 18  # largeur colonne Train
    lines = []

    sections = [
        ("moving",  "EN MOUVEMENT", f"({len(groups['moving'])})"),
        ("docked",  "A QUAI",       f"({len(groups['docked'])})"),
        ("stopped", "A L'ARRET",    f"({len(groups['stopped'])})"),
    ]

    for key, label, count in sections:
        header = f"== {label} {count} "
        lines.append(header.ljust(48, "="))
        if groups[key]:
            for t in groups[key]:
                name    = t.get("name", "?")[:W].ljust(W)
                speed   = f"{t.get('speed', 0)} km/h".rjust(8)
                station = t.get("station", "?")
                lines.append(f"  {name} {speed}   {station}")
        else:
            lines.append("  (aucun)")

    now = datetime.now().strftime("%H:%M:%S")
    total = len(trains)
    lines.append("")
    lines.append(f"  {total} train{'s' if total != 1 else ''} sur le reseau — {now}")

    content = "```\n" + "\n".join(lines) + "\n```"
    if len(content) > 1990:
        content = content[:1987] + "…```"
    return content


@client.event
async def on_ready():
    global _monitor_msg
    print(f"Bot Discord connecté : {client.user}")

    # ── Purge des canaux configurés ──────────────────────────
    channels_to_clean = getattr(config, "CHANNELS_TO_CLEAN", [config.CHANNEL_ID])
    for ch_id in channels_to_clean:
        ch = client.get_channel(ch_id)
        if ch:
            deleted = await ch.purge(limit=None)
            print(f"Canal {ch_id} purgé ({len(deleted)} message(s))")
        else:
            print(f"Avertissement : canal {ch_id} introuvable (purge ignorée)")

    # ── Post initial de l'embed dans le canal principal ──────
    channel = client.get_channel(config.CHANNEL_ID)
    if not channel:
        print(f"ERREUR Discord : canal {config.CHANNEL_ID} introuvable — vérifie config.py")
        return

    read_web_json()
    _monitor_msg = await channel.send(build_message())
    print(f"Message posté (id={_monitor_msg.id}), refresh toutes les {config.DISCORD_UPDATE_INTERVAL}s")
    asyncio.create_task(discord_update_loop())


async def discord_update_loop():
    global _monitor_msg
    while True:
        await asyncio.sleep(config.DISCORD_UPDATE_INTERVAL)
        read_web_json()
        if _monitor_msg:
            try:
                await _monitor_msg.edit(content=build_message())
            except discord.NotFound:
                # Message supprimé manuellement → on en reposte un
                channel = client.get_channel(config.CHANNEL_ID)
                if channel:
                    _monitor_msg = await channel.send(build_message())
            except Exception as e:
                print(f"Erreur Discord : {e}")


# ════════════════════════════════════════════════════════════
# POINT D'ENTRÉE
# ════════════════════════════════════════════════════════════

if __name__ == "__main__":
    print(f"Lecture de : {WEB_JSON}")

    # Flask dans un thread background
    flask_thread = threading.Thread(target=run_flask, daemon=True)
    flask_thread.start()

    # Bot Discord dans le thread principal (asyncio)
    client.run(config.BOT_TOKEN)
