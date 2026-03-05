-- LOGGER.lua : surveille tous les trains, écrit sur disque + broadcast réseau
-- Tourne sur un PC dédié connecté à GARE_TEST, un disque dur et une NetworkCard
-- Détecte chaque arrivée/départ, enregistre durée + inventaire, diffuse sur port 42

-- === INITIALISATION MATÉRIEL ===
local net=computer.getPCIDevices(classes.NetworkCard)[1]
local staList=component.findComponent("GARE_TEST")
if not staList or not staList[1] then pcall(function()net:broadcast(43,"LOGGER","ERREUR: GARE_TEST non trouvee")end) print("ERREUR: GARE_TEST non trouvee - verifie le cable reseau") end
local sta=staList and staList[1] and component.proxy(staList[1])
net:open(42)  -- port de broadcast vers DETAIL et autres scripts

-- Fonction log : affiche localement ET diffuse sur port 43 (LOG_SCREEN)
local function log(msg)
    print(msg)
    pcall(function()net:broadcast(43,"LOGGER",msg)end)
end

-- === DISQUE DUR ===
local fs=filesystem
fs.initFileSystem("/dev")
fs.mount("/dev/6D014517486D381F93350594FFD39B23","/")  -- UUID du disque dur
local TRIPS_FILE="/trips.json"
local saved={}  -- données en mémoire (miroir du disque)

-- === SÉRIALISEURS ===
-- ser() : format Lua pour lecture/écriture interne (trips.json)
-- toJson() : format JSON valide pour lecture par Python (web.json)
local function ser(v)
    local t=type(v)
    if t=="string" then return string.format("%q",v)
    elseif t=="number" then return tostring(v)
    elseif t=="boolean" then return tostring(v)
    elseif t=="table" then
        local p={}
        for k,val in pairs(v) do
            local ks=type(k)=="string" and string.format("[%q]",k) or "["..k.."]"
            table.insert(p,ks.."="..ser(val))
        end
        return "{"..table.concat(p,",").."}"
    end
    return "nil"
end

-- Convertit une valeur Lua en JSON valide (pour web.json lisible par Python)
local function toJson(v)
    local t=type(v)
    if t=="string" then return '"'..v:gsub('\\','\\\\'):gsub('"','\\"')..'"'
    elseif t=="number" then return tostring(v)
    elseif t=="boolean" then return tostring(v)
    elseif t=="table" then
        local n=0 for _ in pairs(v) do n=n+1 end
        if n>0 and n==#v then  -- tableau séquentiel → array JSON
            local p={} for _,val in ipairs(v) do table.insert(p,toJson(val)) end
            return "["..table.concat(p,",").."]"
        else  -- clés mixtes → objet JSON
            local p={} for k,val in pairs(v) do table.insert(p,'"'..tostring(k)..'":'..toJson(val)) end
            return "{"..table.concat(p,",").."}"
        end
    end
    return "null"
end

-- Charge les données sauvegardées depuis le disque au démarrage
local function loadSaved()
    if not fs.exists(TRIPS_FILE) then return end
    local ok,f=pcall(function()return fs.open(TRIPS_FILE,"r")end)
    if not ok or not f then return end
    local ok2,s=pcall(function()return f:read("*a")end)
    f:close()
    if not ok2 or not s or s=="" then return end
    -- Désérialise : évalue la chaîne Lua comme expression de retour
    local ok3,fn=pcall(load,"return "..s)
    if ok3 and fn then local ok4,d=pcall(fn) if ok4 and d then saved=d end end
end

-- Écrit la table `saved` sur le disque au format Lua (écrase le fichier existant)
local function writeDisk()
    local ok,f=pcall(function()return fs.open(TRIPS_FILE,"w")end)
    if not ok or not f then return end
    local ok2,s=pcall(function()return ser(saved)end)
    if ok2 and s then f:write(s) end
    f:close()
end

-- Écrit le snapshot temps réel + historique en JSON pour le serveur web Python
-- Fichier : /web.json (même disque que trips.json)
local state={}  -- {[tn]={name,speed,status,station,wagons}} — mis à jour chaque tick
local function writeWeb()
    local trainArr={} for _,s in pairs(state) do table.insert(trainArr,s) end
    local ok,f=pcall(function()return fs.open("/web.json","w")end)
    if not ok or not f then return end
    local ok2,s=pcall(function()
        return toJson({trains=trainArr,trips=saved})
    end)
    if ok2 and s then f:write(s) end
    f:close()
end

-- === LECTURE DE L'INVENTAIRE D'UN TRAIN ===
-- Parcourt tous les wagons → toutes les inventaires → tous les slots
-- Retourne une table {[nomItem]=quantité}
local function inv(t)
    local it={}
    local ok,v=pcall(function()return t:getVehicles()end)
    if not ok or not v then return it end
    for vi=1,#v do
        local vh=v[vi]
        local ok2,iv=pcall(function()return vh:getInventories()end)
        if ok2 and iv then
            for ji=1,#iv do
                local i=iv[ji]
                if i and i.itemCount>0 then
                    for si=0,i.size-1 do
                        local ok3,x=pcall(function()return i:getStack(si)end)
                        if ok3 and x and x.count>0 then
                            local ok4,nm=pcall(function()return x.item.type.name end)
                            local n=ok4 and nm or "???"
                            it[n]=(it[n] or 0)+x.count
                        end
                    end
                end
            end
        end
    end
    return it
end

-- Compte le nombre de wagons (véhicules) dans un train
local function wagons(t)
    local ok,v=pcall(function()return t:getVehicles()end)
    if not ok or not v then return 0 end
    local n=0 for _ in pairs(v) do n=n+1 end return n
end

-- === ENREGISTREMENT ET DIFFUSION D'UN TRAJET ===
-- Structure disque: saved[trainName][segKey] = { {duration,ts,inv,wagons}, ... } (10 max)
-- segKey = "GareA->GareB"
local MAX_PER_SEG=10
local function saveTrip(tn,fr,to,d,ts,it,nv)
    local seg=fr.."->"..to
    if not saved[tn] then saved[tn]={} end
    if not saved[tn][seg] then saved[tn][seg]={} end
    -- Insère en tête (le plus récent en [1])
    table.insert(saved[tn][seg],1,{duration=d,ts=ts,inv=it,wagons=nv})
    while #saved[tn][seg]>MAX_PER_SEG do table.remove(saved[tn][seg]) end
    writeDisk()
    -- Broadcast réseau vers DETAIL (et autres scripts abonnés au port 42)
    local ok,invs=pcall(function()return ser(it)end)
    local invStr=ok and invs or "{}"
    pcall(function()net:broadcast(42,tn,fr,to,d,ts,invStr)end)
    local invLog=""
    for item,cnt in pairs(it) do invLog=invLog.." | "..item.." x"..cnt end
    log("LOG: "..tn.." "..seg.." d="..d.."s wagons="..nv..invLog)
end

-- === ÉTAT PAR TRAIN (mis à jour à chaque tick) ===
local la={}         -- {[tn]={from, t}}   : dernière gare + timestamp d'arrivée
local depart={}     -- {[tn]=inv}          : inventaire capturé au moment du départ
local dk_prev={}    -- {[tn]=bool}         : état isDocked du tick précédent

-- === BOUCLE DE SURVEILLANCE (appelée toutes les 2s) ===
local function tick()
    if not sta then return end
    local ok,trains=pcall(function()return sta:getTrackGraph():getTrains()end)
    if not ok or not trains then return end
    local now=computer.millis()/1000
    state={}  -- reset snapshot temps réel à chaque tick
    for _,t in pairs(trains) do
        local ok2,m=pcall(function()return t:getMaster()end)
        if ok2 and m then
            local tn=t:getName()
            local dk=m.isDocked

            -- Récupère le nom de la gare courante via le timetable
            local cur="?"
            pcall(function()
                local tt=t:getTimeTable()
                local ci=tt:getCurrentStop()
                local st=tt:getStop(ci)
                cur=st.station.name
            end)

            -- Collecte l'état temps réel du train pour web.json
            local spd=0
            pcall(function()spd=math.abs(math.floor(m:getMovement().speed/100*3.6))end)
            local nv=wagons(t)
            local st=dk and "docked" or (spd>10 and "moving" or "stopped")
            state[tn]={name=tn,speed=spd,status=st,station=cur,wagons=nv}

            -- Arrivée détectée : le train est à quai dans une nouvelle gare
            if dk then
                local ls=la[tn]
                if ls and ls.from~=cur then
                    local d=math.floor(now-ls.t)
                    -- Filtre les trajets aberrants (<5s ou >2h)
                    if d>5 and d<7200 then
                        local nv=wagons(t)
                        saveTrip(tn,ls.from,cur,d,math.floor(now),depart[tn] or {},nv)
                    end
                end
                -- Mémorise cette gare comme point de départ du prochain trajet
                if not la[tn] or la[tn].from~=cur then
                    la[tn]={from=cur,t=now}
                end
            end

            -- Départ détecté (isDocked: true→false) : capture l'inventaire après chargement
            if dk_prev[tn]==true and not dk then
                depart[tn]=inv(t)
            end

            dk_prev[tn]=dk
        end
    end
    writeWeb()  -- écrit web.json après chaque tick
end

-- Re-diffuse tous les derniers trajets connus sur le réseau
-- Permet à DETAIL de se synchroniser même s'il a démarré après LOGGER
local function broadcastAll()
    for tn,segs in pairs(saved) do
        for seg,trips in pairs(segs) do
            if trips and trips[1] then
                local trip=trips[1]
                local fr,to=seg:match("^(.+)->(.+)$")
                if fr and to then
                    local ok,invs=pcall(function()return ser(trip.inv or {})end)
                    local invStr=ok and invs or "{}"
                    pcall(function()net:broadcast(42,tn,fr,to,trip.duration,trip.ts,invStr)end)
                end
            end
        end
    end
end

-- === DÉMARRAGE ===
loadSaved()  -- restaure les données précédentes depuis le disque
broadcastAll()  -- envoie immédiatement les données aux clients déjà connectés
local trainCount=0
if sta then pcall(function()trainCount=#sta:getTrackGraph():getTrains()end) end
log("LOGGER démarré - "..trainCount.." trains détectés")

-- === BOUCLE PRINCIPALE ===
local ticks=0
while true do
    tick()
    ticks=ticks+1
    if ticks>=30 then  -- toutes les 60s (30 × 2s), re-diffuse pour les nouveaux clients
        ticks=0
        broadcastAll()
    end
    event.pull(2)
end
zd