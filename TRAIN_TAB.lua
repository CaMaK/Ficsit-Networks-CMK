-- TRAIN_TAB.lua : tableau de bord sur 3 écrans pour tous les trains du réseau
-- Écran gauche  (gpuL) : trains À L'ARRÊT  (vitesse ≤ 10 km/h, non dockés)
-- Écran centre  (gpuC) : trains EN MOUVEMENT (vitesse > 10 km/h), triés par vitesse
-- Écran droit   (gpuR) : trains À QUAI (isDocked = true)
-- Rafraîchissement toutes les 2 secondes

-- === INITIALISATION MATÉRIEL ===
local gpus=computer.getPCIDevices(classes.Build_GPU_T2_C)
local scrL=component.proxy(component.findComponent("SCREEN_L")[1])
local scrC=component.proxy(component.findComponent("SCREEN_C")[1])
local scrR=component.proxy(component.findComponent("SCREEN_R")[1])
local sta=component.proxy(component.findComponent("GARE_TEST")[1])

-- Associe chaque GPU à son écran
local gpuL=gpus[1]
local gpuC=gpus[2]
local gpuR=gpus[3]
gpuL:bindScreen(scrL)
gpuC:bindScreen(scrC)
gpuR:bindScreen(scrR)

-- === CONSTANTES AFFICHAGE ===
local sw,sh=900,1500  -- dimensions des écrans en pixels
local BG={r=0,g=0,b=0,a=1}    -- noir (fond)
local WH={r=1,g=1,b=1,a=1}    -- blanc (nom du train)
local DI={r=0.4,g=0.4,b=0.4,a=1} -- gris (compteur)
local GR={r=0.2,g=1,b=0.2,a=1}   -- vert (mouvement rapide)
local RE={r=1,g=0.2,b=0.2,a=1}   -- rouge (arrêt)
local YE={r=1,g=1,b=0.2,a=1}     -- jaune (mouvement lent)
local BL={r=0.2,g=0.6,b=1,a=1}   -- bleu (à quai)
local SP={r=0.2,g=0.2,b=0.2,a=1} -- gris (non utilisé ici)
local ROW_H=68    -- hauteur d'une ligne de train en pixels
local START_Y=110 -- y minimum pour les lignes (sous l'en-tête)

-- Retourne le nom de la gare actuelle d'un train (via son timetable)
local function getDestination(train)
    local ok,tt=pcall(function()return train:getTimeTable()end)
    if not ok or not tt then return "???" end
    local ok2,ci=pcall(function()return tt:getCurrentStop()end)
    if not ok2 then return "???" end
    local ok3,stop=pcall(function()return tt:getStop(ci)end)
    if not ok3 or not stop then return "???" end
    local ok4,nm=pcall(function()return stop.station.name end)
    return ok4 and nm or "???"
end

-- Dessine l'en-tête d'un écran : fond dégradé, titre, compteur, ligne de séparation
local function drawHeader(gpu,title,count,color,bgColor)
    gpu:drawRect({x=0,y=0},{x=sw,y=sh},BG,BG,0)        -- efface l'écran
    gpu:drawRect({x=0,y=0},{x=sw,y=100},BG,bgColor,0)   -- fond coloré de l'en-tête
    gpu:drawText({x=20,y=22},title,36,color,false)       -- titre (ex: "EN MOUVEMENT")
    gpu:drawText({x=sw-120,y=28},"("..count..")",28,DI,false) -- nombre de trains
    gpu:drawRect({x=10,y=95},{x=sw-20,y=2},color,color,0)    -- ligne séparatrice
end

-- Dessine une ligne pour un train : carré coloré + nom + sous-ligne (vitesse ou gare)
local function drawRow(gpu,y,name,line2,color,altBg)
    if altBg then
        -- Fond alterné pour faciliter la lecture (lignes paires légèrement teintées)
        gpu:drawRect({x=0,y=y},{x=sw,y=ROW_H-4},BG,altBg,0)
    end
    gpu:drawRect({x=16,y=y+24},{x=10,y=10},color,color,0)  -- indicateur coloré
    gpu:drawText({x=36,y=y+10},name,24,WH,false)            -- nom du train
    if line2 then
        gpu:drawText({x=36,y=y+38},line2,20,color,false)   -- info secondaire
    end
end

-- === FONCTION DE DESSIN PRINCIPAL ===
local function drawAll()
    local tg=sta:getTrackGraph()
    local trains=tg:getTrains()

    -- Tri des trains en 3 catégories
    local stopped={}  -- arrêtés (spd ≤ 10, non dockés)
    local moving={}   -- en mouvement (spd > 10)
    local docked={}   -- à quai (isDocked = true)

    for _,train in pairs(trains) do
        local master=train:getMaster()
        if master then
            local spd=math.abs(math.floor(master:getMovement().speed/100*3.6))
            if master.isDocked then
                table.insert(docked,{train=train,spd=spd})
            elseif spd>10 then
                table.insert(moving,{train=train,spd=spd})
            else
                table.insert(stopped,{train=train,spd=spd})
            end
        end
    end

    -- Trie les trains en mouvement du plus rapide au plus lent
    table.sort(moving,function(a,b)return a.spd>b.spd end)

    -- Les trains s'affichent de bas en haut (dernier=bas, premier=haut)
    local bottom=sh-20

    -- === ÉCRAN GAUCHE : TRAINS À L'ARRÊT ===
    drawHeader(gpuL,"A L'ARRET",#stopped,RE,{r=0.1,g=0,b=0,a=1})
    for i,e in ipairs(stopped) do
        local y=bottom-i*ROW_H
        if y<START_Y then break end  -- stop si plus de place
        local alt=i%2==0 and {r=0.06,g=0,b=0,a=1} or nil
        drawRow(gpuL,y,e.train:getName(),"Arrêté",RE,alt)
    end
    gpuL:flush()

    -- === ÉCRAN CENTRE : TRAINS EN MOUVEMENT ===
    drawHeader(gpuC,"EN MOUVEMENT",#moving,GR,{r=0,g=0.1,b=0,a=1})
    for i,e in ipairs(moving) do
        local y=bottom-i*ROW_H
        if y<START_Y then break end
        local color=e.spd>100 and GR or YE  -- vert si >100 km/h, jaune sinon
        local alt=i%2==0 and {r=0,g=0.06,b=0,a=1} or nil
        local dest=getDestination(e.train)
        local line2=e.spd.." km/h  → "..dest
        drawRow(gpuC,y,e.train:getName(),line2,color,alt)
    end
    gpuC:flush()

    -- === ÉCRAN DROIT : TRAINS À QUAI ===
    drawHeader(gpuR,"A QUAI",#docked,BL,{r=0,g=0,b=0.1,a=1})
    for i,e in ipairs(docked) do
        local y=bottom-i*ROW_H
        if y<START_Y then break end
        local alt=i%2==0 and {r=0,g=0,b=0.06,a=1} or nil
        local dest=getDestination(e.train)
        drawRow(gpuR,y,e.train:getName(),"→ "..dest,BL,alt)
    end
    gpuR:flush()
end

-- === BOUCLE PRINCIPALE ===
while true do
    drawAll()
    event.pull(2)  -- attend 2 secondes avant le prochain rafraîchissement
end
