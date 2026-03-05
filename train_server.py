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


def build_embed():
    """Construit l'embed Discord depuis le cache actuel."""
    trains = _cache.get("trains", [])
    groups = {"stopped": 0, "moving": 0, "docked": 0}
    for t in trains:
        groups[t.get("status", "stopped")] = groups.get(t.get("status", "stopped"), 0) + 1

    total = len(trains)
    embed = discord.Embed(
        title="🚂  TRAIN MONITOR — Satisfactory",
        description=f"**{total}** train{'s' if total != 1 else ''} sur le réseau",
        color=0xff8800
    )
    embed.add_field(name="🔴  À l'arrêt",   value=f"**{groups['stopped']}**", inline=True)
    embed.add_field(name="🟢  En mouvement", value=f"**{groups['moving']}**",  inline=True)
    embed.add_field(name="🔵  À quai",       value=f"**{groups['docked']}**",  inline=True)
    embed.set_footer(text="Mis à jour")
    embed.timestamp = datetime.utcnow()
    return embed


@client.event
async def on_ready():
    global _monitor_msg
    print(f"Bot Discord connecté : {client.user}")

    channel = client.get_channel(config.CHANNEL_ID)
    if not channel:
        print(f"ERREUR Discord : canal {config.CHANNEL_ID} introuvable — vérifie config.py")
        return

    read_web_json()
    _monitor_msg = await channel.send(embed=build_embed())
    print(f"Embed posté (id={_monitor_msg.id}), refresh toutes les {config.DISCORD_UPDATE_INTERVAL}s")
    asyncio.create_task(discord_update_loop())


async def discord_update_loop():
    global _monitor_msg
    while True:
        await asyncio.sleep(config.DISCORD_UPDATE_INTERVAL)
        read_web_json()
        if _monitor_msg:
            try:
                await _monitor_msg.edit(embed=build_embed())
            except discord.NotFound:
                # Message supprimé manuellement → on en reposte un
                channel = client.get_channel(config.CHANNEL_ID)
                if channel:
                    _monitor_msg = await channel.send(embed=build_embed())
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
