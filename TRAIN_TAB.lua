-- TRAIN_TAB.lua : tableau de bord sur 3 écrans, alimenté par LOGGER via réseau (port 44)
-- Aucun appel direct aux trains — LOGGER collecte et broadcast le snapshot toutes les 2s
-- Écran gauche  (gpuL) : trains À L'ARRÊT
-- Écran centre  (gpuC) : trains EN MOUVEMENT, triés par vitesse
-- Écran droit   (gpuR) : trains À QUAI
-- Prérequis : une NetworkCard installée dans le PC TRAIN_TAB

-- === INITIALISATION MATÉRIEL ===
local net=computer.getPCIDevices(classes.NetworkCard)[1]
local gpus=computer.getPCIDevices(classes.Build_GPU_T2_C)
local scrL=component.proxy(component.findComponent("TAB_SCREEN_L")[1])
local scrC=component.proxy(component.findComponent("TAB_SCREEN_C")[1])
local scrR=component.proxy(component.findComponent("TAB_SCREEN_R")[1])

local gpuL=gpus[1]
local gpuC=gpus[2]
local gpuR=gpus[3]
gpuL:bindScreen(scrL)
gpuC:bindScreen(scrC)
gpuR:bindScreen(scrR)

event.listen(net)
net:open(44)  -- port snapshot LOGGER

-- === CONSTANTES AFFICHAGE ===
local sw,sh=900,1500
local BG={r=0,g=0,b=0,a=1}
local WH={r=1,g=1,b=1,a=1}
local DI={r=0.4,g=0.4,b=0.4,a=1}
local GR={r=0.2,g=1,b=0.2,a=1}
local RE={r=1,g=0.2,b=0.2,a=1}
local YE={r=1,g=1,b=0.2,a=1}
local BL={r=0.2,g=0.6,b=1,a=1}
local ROW_H=68
local START_Y=110

-- Dessine l'en-tête d'un écran
local function drawHeader(gpu,title,count,color,bgColor)
    gpu:drawRect({x=0,y=0},{x=sw,y=sh},BG,BG,0)
    gpu:drawRect({x=0,y=0},{x=sw,y=100},BG,bgColor,0)
    gpu:drawText({x=20,y=22},title,36,color,false)
    gpu:drawText({x=sw-120,y=28},"("..count..")",28,DI,false)
    gpu:drawRect({x=10,y=95},{x=sw-20,y=2},color,color,0)
end

-- Dessine une ligne pour un train
local function drawRow(gpu,y,name,line2,color,altBg)
    if altBg then
        gpu:drawRect({x=0,y=y},{x=sw,y=ROW_H-4},BG,altBg,0)
    end
    gpu:drawRect({x=16,y=y+24},{x=10,y=10},color,color,0)
    gpu:drawText({x=36,y=y+10},name,24,WH,false)
    if line2 then
        gpu:drawText({x=36,y=y+38},line2,20,color,false)
    end
end

-- === ÉTAT COURANT (reçu de LOGGER) ===
local lastState={}

-- === RENDU DEPUIS L'ÉTAT REÇU ===
local function drawAll(state)
    local stopped={}
    local moving={}
    local docked={}

    for _,t in pairs(state) do
        if t.status=="docked" then
            table.insert(docked,t)
        elseif t.status=="moving" then
            table.insert(moving,t)
        else
            table.insert(stopped,t)
        end
    end

    table.sort(moving,function(a,b)return a.speed>b.speed end)

    local bottom=sh-20

    -- === ÉCRAN GAUCHE : TRAINS À L'ARRÊT ===
    drawHeader(gpuL,"A L'ARRET",#stopped,RE,{r=0.1,g=0,b=0,a=1})
    for i,t in ipairs(stopped) do
        local y=bottom-i*ROW_H
        if y<START_Y then break end
        local alt=i%2==0 and {r=0.06,g=0,b=0,a=1} or nil
        drawRow(gpuL,y,t.name,"Arrete",RE,alt)
    end
    gpuL:flush()

    -- === ÉCRAN CENTRE : TRAINS EN MOUVEMENT ===
    drawHeader(gpuC,"EN MOUVEMENT",#moving,GR,{r=0,g=0.1,b=0,a=1})
    for i,t in ipairs(moving) do
        local y=bottom-i*ROW_H
        if y<START_Y then break end
        local color=t.speed>100 and GR or YE
        local alt=i%2==0 and {r=0,g=0.06,b=0,a=1} or nil
        local line2=t.speed.." km/h  -> "..t.station
        drawRow(gpuC,y,t.name,line2,color,alt)
    end
    gpuC:flush()

    -- === ÉCRAN DROIT : TRAINS À QUAI ===
    drawHeader(gpuR,"A QUAI",#docked,BL,{r=0,g=0,b=0.1,a=1})
    for i,t in ipairs(docked) do
        local y=bottom-i*ROW_H
        if y<START_Y then break end
        local alt=i%2==0 and {r=0,g=0,b=0.06,a=1} or nil
        drawRow(gpuR,y,t.name,"-> "..t.station,BL,alt)
    end
    gpuR:flush()
end

-- Affiche un écran d'attente si LOGGER n'a pas encore envoyé de données
local function drawWaiting()
    local msg="En attente de LOGGER..."
    for _,gpu in ipairs({gpuL,gpuC,gpuR}) do
        gpu:drawRect({x=0,y=0},{x=sw,y=sh},BG,BG,0)
        gpu:drawText({x=20,y=sh/2},msg,28,DI,false)
        gpu:flush()
    end
end

-- === BOUCLE PRINCIPALE ===
drawWaiting()
while true do
    -- Attend max 3s un message réseau (LOGGER envoie toutes les 2s)
    local e,_,_,port,stateStr=event.pull(3)
    if e=="NetworkMessage" and port==44 and stateStr then
        local ok,fn=pcall(load,"return "..stateStr)
        if ok and fn then
            local ok2,s=pcall(fn)
            if ok2 and s then lastState=s end
        end
    end
    drawAll(lastState)
end
