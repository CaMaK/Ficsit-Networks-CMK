"""
api_server.py : API multi-joueurs Satisfactory
- Reçoit les données de parties FicsIT Networks via InternetCard
- Stocke par joueur dans api_data/{joueur}.json
- Clés d'authentification dans api_keys.json (gitignored)

Lancer       : python api_server.py
Créer une clé: python api_server.py --genkey "NomJoueur"
"""

from flask import Flask, request, jsonify
import json, os, time, secrets, sys

BASE_DIR  = os.path.dirname(os.path.abspath(__file__))
DATA_DIR  = os.path.join(BASE_DIR, "api_data")
KEYS_FILE = os.path.join(BASE_DIR, "api_keys.json")
PORT      = 8082

os.makedirs(DATA_DIR, exist_ok=True)

app = Flask(__name__)


# ════════════════════════════════════════════════════════════
# GESTION DES CLÉS
# ════════════════════════════════════════════════════════════

def load_keys() -> dict:
    if not os.path.exists(KEYS_FILE):
        return {}
    with open(KEYS_FILE, encoding="utf-8") as f:
        return json.load(f)


def validate_key(key: str):
    """Retourne (valide: bool, nom_joueur: str | None)"""
    entry = load_keys().get(key)
    if not entry or not entry.get("active"):
        return False, None
    return True, entry["name"]


def generate_key(player_name: str) -> str:
    """Génère une clé hex 32 chars et l'enregistre dans api_keys.json"""
    keys = load_keys()
    # Vérifie doublon de nom
    for v in keys.values():
        if v["name"] == player_name:
            print(f"Joueur '{player_name}' existe déjà.")
            return None
    key = secrets.token_hex(16)
    keys[key] = {"name": player_name, "active": True, "created_at": time.time()}
    with open(KEYS_FILE, "w", encoding="utf-8") as f:
        json.dump(keys, f, indent=2, ensure_ascii=False)
    print(f"Clé créée pour '{player_name}' : {key}")
    return key


def revoke_key(player_name: str):
    """Désactive la clé d'un joueur sans la supprimer"""
    keys = load_keys()
    for k, v in keys.items():
        if v["name"] == player_name:
            v["active"] = False
            with open(KEYS_FILE, "w", encoding="utf-8") as f:
                json.dump(keys, f, indent=2, ensure_ascii=False)
            print(f"Clé révoquée pour '{player_name}'")
            return
    print(f"Joueur '{player_name}' non trouvé")


# ════════════════════════════════════════════════════════════
# SCHÉMA NORMALISÉ
# ════════════════════════════════════════════════════════════
# Champs reconnus dans le body POST /submit :
#
# {
#   "world":      "NomDuMonde",            ← optionnel
#   "production": {                         ← items produits/consommés par minute
#     "NomItem": { "produced": 120.5, "consumed": 60.0 }
#   },
#   "power": {                              ← circuit électrique
#     "produced_mw":  5000.0,
#     "consumed_mw":  3200.0,
#     "fuse_blown":   false,
#     "battery_pct":  85.0                  ← 0-100, optionnel
#   },
#   "trains": {                             ← réseau ferroviaire
#     "total": 37, "moving": 29, "stopped": 2, "docked": 6
#   },
#   "extra": { ... }                        ← champs libres extensibles
# }


def normalize(body: dict, player: str) -> dict:
    return {
        "player":      player,
        "received_at": time.time(),
        "world":       body.get("world", "?"),
        "production":  body.get("production", {}),
        "power":       body.get("power", {}),
        "trains":      body.get("trains", {}),
        "extra":       body.get("extra", {}),
    }


# ════════════════════════════════════════════════════════════
# ROUTES
# ════════════════════════════════════════════════════════════

@app.route("/api/v1/submit", methods=["POST"])
def submit():
    """Reçoit les données d'un joueur. Header requis : X-API-Key"""
    key = request.headers.get("X-API-Key", "")
    valid, player = validate_key(key)
    if not valid:
        return jsonify({"error": "Clé API invalide ou inactive"}), 401

    body = request.get_json(silent=True)
    if not body:
        return jsonify({"error": "Body JSON manquant ou malformé"}), 400

    record = normalize(body, player)
    path = os.path.join(DATA_DIR, f"{player}.json")
    with open(path, "w", encoding="utf-8") as f:
        json.dump(record, f, ensure_ascii=False, indent=2)

    return jsonify({"status": "ok", "player": player, "received_at": record["received_at"]})


@app.route("/api/v1/players", methods=["GET"])
def players():
    """Liste tous les joueurs avec leur dernière activité."""
    result = []
    for fname in os.listdir(DATA_DIR):
        if not fname.endswith(".json"):
            continue
        try:
            with open(os.path.join(DATA_DIR, fname), encoding="utf-8") as f:
                rec = json.load(f)
            age = time.time() - rec["received_at"]
            result.append({
                "player":    rec["player"],
                "world":     rec.get("world", "?"),
                "last_seen": rec["received_at"],
                "online":    age < 300,   # actif si données < 5 min
                "age_s":     round(age),
            })
        except Exception:
            pass
    result.sort(key=lambda x: -x["last_seen"])
    return jsonify(result)


@app.route("/api/v1/snapshot", methods=["GET"])
def snapshot():
    """Retourne les dernières données de tous les joueurs."""
    result = {}
    for fname in os.listdir(DATA_DIR):
        if not fname.endswith(".json"):
            continue
        try:
            with open(os.path.join(DATA_DIR, fname), encoding="utf-8") as f:
                rec = json.load(f)
            result[rec["player"]] = rec
        except Exception:
            pass
    return jsonify(result)


@app.route("/api/v1/data/<player_name>", methods=["GET"])
def player_data(player_name):
    """Retourne les dernières données d'un joueur spécifique."""
    path = os.path.join(DATA_DIR, f"{player_name}.json")
    if not os.path.exists(path):
        return jsonify({"error": f"Joueur '{player_name}' non trouvé"}), 404
    with open(path, encoding="utf-8") as f:
        return jsonify(json.load(f))


# ════════════════════════════════════════════════════════════
# POINT D'ENTRÉE
# ════════════════════════════════════════════════════════════

if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--genkey":
        generate_key(sys.argv[2])
    elif len(sys.argv) == 3 and sys.argv[1] == "--revoke":
        revoke_key(sys.argv[2])
    elif len(sys.argv) == 2 and sys.argv[1] == "--list":
        keys = load_keys()
        if not keys:
            print("Aucune clé.")
        for k, v in keys.items():
            status = "✓" if v["active"] else "✗"
            print(f"  {status} {v['name']:20s}  {k}")
    else:
        print(f"API Multi-joueurs sur http://0.0.0.0:{PORT}")
        print(f"  Créer une clé : python api_server.py --genkey \"NomJoueur\"")
        print(f"  Révoquer     : python api_server.py --revoke \"NomJoueur\"")
        print(f"  Lister       : python api_server.py --list")
        app.run(host="0.0.0.0", port=PORT, debug=False)
