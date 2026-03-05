-- FIN_CLIENT.lua : client API multi-joueurs Satisfactory
-- Envoie les données de ta partie, peut lire celles des autres joueurs
-- Requiert : InternetCard (obligatoire)
-- Optionnel : NetworkCard + GARE_TEST pour données trains
--             Bâtiment nommé "POWER_POLE" pour données électriques
--
-- Ficsit Networks : coller ce script dans l'EEPROM de ton PC dédié

-- ════════════════════════════════════════════════
-- CONFIGURATION (à modifier)
-- ════════════════════════════════════════════════
local API_URL  = "http://TON_SERVEUR_IP:8082"  -- adresse IP du serveur
local API_KEY  = "TA_CLE_ICI"                   -- clé fournie par l'hôte
local PLAYER   = "TonNom"                        -- ton nom (doit correspondre à la clé)
local WORLD    = "TonMonde"                      -- nom de ta partie
local INTERVAL = 30                              -- secondes entre chaque envoi

-- ════════════════════════════════════════════════
-- INITIALISATION MATÉRIEL
-- ════════════════════════════════════════════════
local inet = computer.getPCIDevices(classes.InternetCard)[1]
if not inet then error("InternetCard non trouvée - installe une carte réseau Internet") end

-- Station train (optionnel — retire si pas de réseau ferroviaire)
local sta = nil
pcall(function()
    local sl = component.findComponent("GARE_TEST")
    if sl and sl[1] then sta = component.proxy(sl[1]) end
end)

-- ════════════════════════════════════════════════
-- COLLECTE DONNÉES TRAINS
-- ════════════════════════════════════════════════
local function getTrains()
    if not sta then return nil end
    local ok, trains = pcall(function() return sta:getTrackGraph():getTrains() end)
    if not ok or not trains then return nil end
    local total, moving, stopped, docked = 0, 0, 0, 0
    for _, t in pairs(trains) do
        total = total + 1
        local ok2, m = pcall(function() return t:getMaster() end)
        if ok2 and m then
            if m.isDocked then
                docked = docked + 1
            else
                local spd = 0
                pcall(function() spd = math.abs(math.floor(m:getMovement().speed/100*3.6)) end)
                if spd > 10 then moving = moving + 1 else stopped = stopped + 1 end
            end
        end
    end
    return {total=total, moving=moving, stopped=stopped, docked=docked}
end

-- ════════════════════════════════════════════════
-- COLLECTE DONNÉES ÉLECTRIQUES
-- Adapte le nom du composant selon ton installation
-- ════════════════════════════════════════════════
local function getPower()
    local gen = nil
    pcall(function()
        local l = component.findComponent("POWER_POLE")
        if l and l[1] then gen = component.proxy(l[1]) end
    end)
    if not gen then return nil end
    local ok, circuit = pcall(function()
        return gen:getPowerConnectors()[1]:getCircuit()
    end)
    if not ok or not circuit then return nil end
    return {
        produced_mw = circuit.production,
        consumed_mw = circuit.consumption,
        fuse_blown  = circuit.isFuseTriggered,
    }
end

-- ════════════════════════════════════════════════
-- COLLECTE DONNÉES PRODUCTION
-- Exemple : décommenter et adapter selon tes bâtiments
-- ════════════════════════════════════════════════
local function getProduction()
    local prod = {}
    -- Exemple : lire un constructeur nommé "IRON_FOUNDRY"
    -- pcall(function()
    --     local l = component.findComponent("IRON_FOUNDRY")
    --     if not l or not l[1] then return end
    --     local b = component.proxy(l[1])
    --     local recipe = b:getRecipe()
    --     if recipe then
    --         for _, out in pairs(recipe:getProducts()) do
    --             local name = out.type.name
    --             prod[name] = {
    --                 produced = out.amount * (b.productivity / 100) * 60,
    --                 consumed = 0
    --             }
    --         end
    --     end
    -- end)
    return prod  -- retourne {} si rien de configuré
end

-- ════════════════════════════════════════════════
-- SÉRIALISEUR JSON
-- ════════════════════════════════════════════════
local function toJson(v)
    local t = type(v)
    if t == "string"  then return '"'..v:gsub('\\','\\\\'):gsub('"','\\"')..'"'
    elseif t == "number"  then return tostring(v)
    elseif t == "boolean" then return tostring(v)
    elseif t == "nil"     then return "null"
    elseif t == "table"   then
        local n = 0 for _ in pairs(v) do n = n+1 end
        if n > 0 and n == #v then
            local p = {} for _, val in ipairs(v) do table.insert(p, toJson(val)) end
            return "["..table.concat(p,",").."]"
        else
            local p = {} for k, val in pairs(v) do
                table.insert(p, '"'..tostring(k)..'":'..toJson(val))
            end
            return "{"..table.concat(p,",").."}"
        end
    end
    return "null"
end

-- ════════════════════════════════════════════════
-- ENVOI DES DONNÉES VERS L'API
-- ════════════════════════════════════════════════
local function submit()
    local payload = {
        world      = WORLD,
        trains     = getTrains(),
        power      = getPower(),
        production = getProduction(),
    }
    local body = toJson(payload)
    local headers = {
        ["Content-Type"] = "application/json",
        ["X-API-Key"]    = API_KEY,
    }
    local ok, req = pcall(function()
        return inet:request(API_URL.."/api/v1/submit", "POST", body, headers)
    end)
    if not ok or not req then print("[API] Erreur connexion submit") return end
    local ok2, code = pcall(function() return req:await() end)
    if ok2 then
        if code == 200 then print("[API] Données envoyées OK")
        else print("[API] Erreur HTTP "..tostring(code)) end
    end
end

-- ════════════════════════════════════════════════
-- LECTURE DES DONNÉES DES AUTRES JOUEURS
-- ════════════════════════════════════════════════
local function fetchPlayers()
    local ok, req = pcall(function()
        return inet:request(API_URL.."/api/v1/players", "GET", "", {})
    end)
    if not ok or not req then print("[API] Erreur connexion players") return end
    local ok2, code, resp = pcall(function() return req:await() end)
    if not ok2 or code ~= 200 then return end
    print("[API] Joueurs connectés :")
    -- resp est une chaîne JSON — afficher brut ou parser selon besoin
    print(resp)
end

local function fetchSnapshot()
    local ok, req = pcall(function()
        return inet:request(API_URL.."/api/v1/snapshot", "GET", "", {})
    end)
    if not ok or not req then return nil end
    local ok2, code, resp = pcall(function() return req:await() end)
    if ok2 and code == 200 then return resp end
    return nil
end

-- ════════════════════════════════════════════════
-- BOUCLE PRINCIPALE
-- ════════════════════════════════════════════════
print("[FIN_CLIENT] Démarré — envoi toutes les "..INTERVAL.."s vers "..API_URL)
local ticks = 0
while true do
    submit()
    ticks = ticks + 1
    -- Toutes les 10 soumissions (~5 min), affiche les joueurs actifs
    if ticks % 10 == 0 then
        fetchPlayers()
    end
    event.pull(INTERVAL)
end
