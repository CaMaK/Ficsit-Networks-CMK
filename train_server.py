"""
train_server.py : serveur web Flask pour le dashboard Satisfactory Train Monitor
Lit web.json écrit par LOGGER.lua sur le disque FicsIT Networks
Lancer : python train_server.py
Dashboard : http://localhost:5000
"""

from flask import Flask, jsonify, send_from_directory
import json, os

app = Flask(__name__)

# Chemin vers le disque virtuel FicsIT Networks (UUID du HDD dans LOGGER.lua)
DISK = r"C:\Users\camak\AppData\Local\FactoryGame\Saved\SaveGames\Computers\6D014517486D381F93350594FFD39B23"
WEB_JSON = os.path.join(DISK, "web.json")

# Répertoire contenant ce script (pour servir index.html)
BASE_DIR = os.path.dirname(os.path.abspath(__file__))

# Cache : dernière donnée valide lue — évite les pages blanches lors des écritures Lua
_cache = {"trains": [], "trips": {}}


@app.route("/api/data")
def get_data():
    """Retourne web.json tel que LOGGER l'a écrit (trains + trips).
    En cas de lecture pendant une écriture Lua (JSON tronqué), retourne le cache."""
    global _cache
    try:
        with open(WEB_JSON, "r", encoding="utf-8") as f:
            data = json.load(f)
        _cache = data  # mise à jour du cache uniquement si JSON valide
        return jsonify(data)
    except FileNotFoundError:
        return jsonify({**_cache, "error": "web.json introuvable — LOGGER tourne ?"}), 200
    except (json.JSONDecodeError, ValueError):
        # Race condition : Lua écrit pendant qu'on lit → on retourne le cache
        return jsonify(_cache), 200
    except Exception as e:
        return jsonify({**_cache, "error": str(e)}), 200


@app.route("/")
def index():
    """Sert le dashboard HTML."""
    return send_from_directory(BASE_DIR, "index.html")


if __name__ == "__main__":
    print(f"Lecture de : {WEB_JSON}")
    print("Dashboard disponible sur http://localhost:8081")
    app.run(host="0.0.0.0", port=8081, debug=False)
