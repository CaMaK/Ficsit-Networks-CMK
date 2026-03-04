-- DETAIL.lua : affichage détaillé d'un train sur écran 600x900
-- Navigue entre les trains via boutons du panel (bP=précédent, bN=suivant)
-- Reçoit les données d'inventaire et de trajet depuis LOGGER via réseau (port 42)

-- === INITIALISATION MATÉRIEL ===
local gpu=computer.getPCIDevices(classes.Build_GPU_T2_C)[1]
local scr=component.proxy(component.findComponent("DETAIL_SCREEN_R")[1])
local sta=component.proxy(component.findComponent("GARE_TEST")[1])
local pan=component.proxy(component.findComponent("DETAIL_PANEL")[1])
local net=computer.getPCIDevices(classes.NetworkCard)[1]
gpu:bindScreen(scr)

-- === CONSTANTES AFFICHAGE ===
local sw,sh=600,900          -- largeur, hauteur de l'écran en pixels
local BG={r=0,g=0,b=0,a=1}  -- noir (fond)
local OR={r=1,g=0.5,b=0,a=1} -- orange (titres de section)
local WH={r=1,g=1,b=1,a=1}  -- blanc (valeurs)
local DI={r=0.4,g=0.4,b=0.4,a=1} -- gris (labels)
local GR={r=0.2,g=1,b=0.2,a=1}  -- vert (ok / en route)
local RE={r=1,g=0.2,b=0.2,a=1}  -- rouge (arrêt / retard)
local YE={r=1,g=1,b=0.2,a=1}    -- jaune (ETA estimé)
local BL={r=0.2,g=0.6,b=1,a=1}  -- bleu (à quai)
local SP={r=0.15,g=0.15,b=0.15,a=1} -- gris foncé (séparateur)

-- === BOUTONS DU PANEL ===
local bP=pan:getModule(0,0,0)  -- bouton précédent (slot 0,0)
local bN=pan:getModule(0,1,0)  -- bouton suivant  (slot 0,1)
event.listen(bP) event.listen(bN) event.listen(net)
net:open(42)  -- écoute les broadcasts LOGGER sur port 42

-- === ÉTAT GLOBAL ===
local idx=1       -- index du train affiché dans la liste tl
local tl={}       -- liste de tous les trains du réseau ferroviaire
local tm={}       -- stats de durée par segment: tm[tn]["A->B"]={t=total,c=count}
local la={}       -- dernière arrivée: la[tn]={from="GareX", t=timestamp}
local dp={}       -- prédiction de départ: dp[tn]={t=now, to="GareY", av=duréeMoy}
local dk_prev={}  -- état isDocked du tick précédent (pour détecter les départs)
local saved={}    -- derniers trajets reçus: saved[tn][1..5]={from,to,duration,ts,inventory}

-- Rafraîchit la liste des trains depuis le réseau ferroviaire
local function ref() tl=sta:getTrackGraph():getTrains() end

-- Récupère le timetable d'un train : retourne (indexGareCourante, {noms des gares})
local function tti(t)
    local ok,tt=pcall(function()return t:getTimeTable()end)
    if not ok or not tt then return nil,nil end
    local ok2,ci=pcall(function()return tt:getCurrentStop()end)
    if not ok2 then return nil,nil end
    local ok3,st=pcall(function()return tt:getStops()end)
    if not ok3 or not st then return nil,nil end
    local n={}
    for _,s in pairs(st) do
        local ok4,nm=pcall(function()return s.station.name end)
        table.insert(n,ok4 and nm or "???")
    end
    return ci,n
end

-- Enregistre une durée de trajet dans les stats (pour le calcul d'ETA moyen)
local function upd(tn,fr,to,d)
    if not tm[tn] then tm[tn]={} end
    local k=fr.."->"..to
    if not tm[tn][k] then tm[tn][k]={t=0,c=0} end
    tm[tn][k].t=tm[tn][k].t+d tm[tn][k].c=tm[tn][k].c+1
end

-- Retourne la durée moyenne (en sec) pour un segment, ou nil si inconnu
local function eta(tn,fr,to)
    if not tm[tn] then return nil end
    local k=tm[tn][fr.."->"..to]
    if not k or k.c==0 then return nil end
    return math.floor(k.t/k.c)
end

-- Reçoit un trajet broadcasté par LOGGER (port 42) et met à jour saved + stats ETA
local function onTrip(tn,fr,to,d,ts,invStr)
    if not saved[tn] then saved[tn]={} end
    local it={}
    -- Désérialise l'inventaire (chaîne Lua → table)
    local ok,fn=pcall(load,"return "..invStr)
    if ok and fn then local ok2,r=pcall(fn) if ok2 and r then it=r end end
    table.insert(saved[tn],1,{from=fr,to=to,duration=d,ts=ts,inventory=it})
    while #saved[tn]>5 do table.remove(saved[tn]) end  -- garde 5 trajets max
    upd(tn,fr,to,d)
end

-- Formate des secondes en "MM:SS"
local function fmt(s) return string.format("%d:%02d",math.floor(s/60),s%60) end
-- Dessine une ligne séparatrice horizontale à la position y
local function sep(y) gpu:drawRect({x=10,y=y},{x=sw-20,y=1},SP,SP,0) end

-- === FONCTION DE DESSIN PRINCIPAL ===
local function draw()
    -- Cas vide : aucun train détecté
    if #tl==0 then gpu:drawRect({x=0,y=0},{x=sw,y=sh},BG,BG,0) gpu:drawText({x=20,y=440},"Aucun train",25,RE,false) gpu:flush() return end
    if idx>#tl then idx=1 end if idx<1 then idx=#tl end
    local t=tl[idx] local m=t:getMaster()
    if not m then idx=idx+1 if idx>#tl then idx=1 end return end

    -- Récupération des données du train courant
    local tn=t:getName()
    local mv=m:getMovement()
    local spd=math.abs(math.floor(mv.speed/100*3.6))     -- vitesse en km/h
    local mspd=math.abs(math.floor(mv.maxSpeed/100*3.6)) -- vitesse max en km/h
    local dk=m.isDocked   -- true = à quai
    local veh={} pcall(function()veh=t:getVehicles()end)
    local nv=0 if veh then for _ in pairs(veh) do nv=nv+1 end end  -- nb wagons
    local ci,sn=tti(t)   -- index gare courante + liste des gares
    local now=computer.millis()/1000

    -- Mise à jour des stats ETA en temps réel (depuis les arrivées observées)
    if ci and sn and #sn>0 then
        local ns=#sn
        local dn=sn[(ci+1)%ns+1] or "???"  -- prochaine gare
        if dk then
            local cur=sn[ci+1] or "???"
            local ls=la[tn]
            -- Si arrivée dans une nouvelle gare : calcule et enregistre la durée
            if ls and ls.from~=cur then
                local d=math.floor(now-ls.t)
                if d>5 and d<7200 then upd(tn,ls.from,cur,d) end
            end
            if not la[tn] or la[tn].from~=cur then la[tn]={from=cur,t=now} end
        end
        -- Départ détecté (isDocked: true→false) : calcule l'ETA pour la prochaine gare
        if dk_prev[tn]==true and not dk then
            local from=la[tn] and la[tn].from or "?"
            local av=eta(tn,from,dn)
            if av then dp[tn]={t=now,to=dn,av=av} end
        end
        dk_prev[tn]=dk
    end

    -- === DESSIN DE L'ÉCRAN ===
    gpu:drawRect({x=0,y=0},{x=sw,y=sh},BG,BG,0)
    -- En-tête : nom du train + boutons navigation
    gpu:drawRect({x=0,y=0},{x=sw,y=60},BG,{r=0.08,g=0.08,b=0.08,a=1},0)
    gpu:drawText({x=10,y=14},"<<",30,OR,false)
    gpu:drawText({x=sw-44,y=14},">>",30,OR,false)
    local nx=math.floor(sw/2-#tn*9)
    gpu:drawText({x=nx,y=16},tn,24,WH,false)
    sep(62)

    -- Section vitesse + état + wagons
    local y=72
    local sc=spd>100 and GR or (spd>10 and YE or RE)  -- couleur selon vitesse
    gpu:drawText({x=10,y=y},"Vitesse",19,DI,false) gpu:drawText({x=130,y=y},spd.." km/h",19,sc,false) gpu:drawText({x=300,y=y},"max "..mspd,19,DI,false)
    y=y+28
    gpu:drawText({x=10,y=y},"Etat",19,DI,false)
    if dk then gpu:drawText({x=130,y=y},"A QUAI",19,BL,false)
    elseif spd>0 then gpu:drawText({x=130,y=y},"EN ROUTE",19,GR,false)
    else gpu:drawText({x=130,y=y},"ARRETE",19,RE,false) end
    y=y+28
    gpu:drawText({x=10,y=y},"Wagons",19,DI,false) gpu:drawText({x=130,y=y},tostring(nv),19,WH,false)
    y=y+32 sep(y) y=y+10

    -- Section timetable : liste les gares avec marqueurs et ETA
    gpu:drawText({x=10,y=y},"TIMETABLE",19,OR,false) y=y+26
    if sn and #sn>0 then
        local ns=#sn
        for i,nm in ipairs(sn) do
            if y>sh-160 then gpu:drawText({x=10,y=y},"...",17,DI,false) break end
            local i0=i-1 local isc=(i0==ci) local isp=(i0==(ci-1)%ns)
            -- Marqueur : "→" = gare courante, "✓" = gare précédente
            local px="  " local pc=DI
            if isc then px="→ " pc=GR elseif isp then px="✓ " pc={r=0.3,g=0.3,b=0.3,a=1} end
            gpu:drawText({x=10,y=y},px..nm,17,pc,false)
            -- Affichage ETA : temps restant (depuis dp) ou durée moyenne (~)
            local d=dp[tn]
            if not dk and d and nm==d.to then
                -- Temps restant calculé depuis le départ
                local rem=math.floor(d.av-(now-d.t))
                local ec=rem>=0 and GR or RE
                local rs=rem>=0 and fmt(rem) or "-"..fmt(-rem)
                gpu:drawText({x=sw-120,y=y},rs,17,ec,false)
            elseif isc and not dk then
                -- ETA moyen depuis les trajets historiques
                local pn=la[tn] and la[tn].from or "?"
                local av=eta(tn,pn,nm)
                if av then gpu:drawText({x=sw-110,y=y},"~"..fmt(av),17,YE,false)
                else gpu:drawText({x=sw-110,y=y},"ETA ?",17,DI,false) end
            end
            y=y+21
        end
    else gpu:drawText({x=10,y=y},"Pas de timetable",17,DI,false) end

    -- Section inventaire : derniers items transportés (reçus via LOGGER)
    y=y+6 sep(y) y=y+10
    gpu:drawText({x=10,y=y},"INVENTAIRE",19,OR,false) y=y+26
    local it=(saved[tn] and saved[tn][1] and saved[tn][1].inventory) or {}
    local has=false
    for nm,cnt in pairs(it) do
        if y>sh-40 then break end
        gpu:drawText({x=10,y=y},nm.."  x"..cnt,17,WH,false) y=y+21 has=true
    end
    if not has then gpu:drawText({x=10,y=y},"En attente LOGGER...",17,DI,false) end

    -- Pied de page : indicateur de navigation (ex: "2 / 5")
    gpu:drawRect({x=0,y=sh-35},{x=sw,y=35},BG,BG,0)
    local cnt=idx.." / "..#tl
    local cx=math.floor((sw-#cnt*11)/2)
    gpu:drawText({x=cx,y=sh-28},cnt,22,WH,false)
    gpu:flush()
end

-- === DÉMARRAGE ===
ref()  -- charge la liste des trains
-- Initialise dk_prev pour éviter de faux départs au lancement
for _,t in pairs(tl) do
    local ok,m=pcall(function()return t:getMaster()end)
    if ok and m then dk_prev[t:getName()]=m.isDocked end
end

-- === BOUCLE PRINCIPALE ===
while true do
    draw()
    -- Attend max 2s : soit un bouton panel, soit un message réseau LOGGER
    local e,src,sender,port,tn,fr,to,d,ts,invStr=event.pull(2)
    if e=="Trigger" then
        -- Navigation entre les trains via les boutons
        if src==bN then idx=idx+1 end
        if src==bP then idx=idx-1 end
        if idx>#tl then idx=1 end
        if idx<1 then idx=#tl end
    elseif e=="NetworkMessage" and port==42 then
        -- Réception d'un trajet complet depuis LOGGER
        onTrip(tn,fr,to,d,ts,invStr)
    end
end
