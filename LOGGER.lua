-- LOGGER.lua : surveille tous les trains, écrit sur disque + broadcast réseau
local net=computer.getPCIDevices(classes.NetworkCard)[1]
local staList=component.findComponent("GARE_TEST")
if not staList or not staList[1] then print("ERREUR: GARE_TEST non trouvee - verifie le cable reseau") end
local sta=staList and staList[1] and component.proxy(staList[1])
net:open(42)

local fs=filesystem
fs.initFileSystem("/dev")
fs.mount("/dev/6D014517486D381F93350594FFD39B23","/")
local TRIPS_FILE="/trips.json"
local saved={}

-- Serialiseur Lua
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

local function loadSaved()
    if not fs.exists(TRIPS_FILE) then return end
    local ok,f=pcall(function()return fs.open(TRIPS_FILE,"r")end)
    if not ok or not f then return end
    local ok2,s=pcall(function()return f:read("*a")end)
    f:close()
    if not ok2 or not s or s=="" then return end
    local ok3,fn=pcall(load,"return "..s)
    if ok3 and fn then local ok4,d=pcall(fn) if ok4 and d then saved=d end end
end

local function writeDisk()
    local ok,f=pcall(function()return fs.open(TRIPS_FILE,"w")end)
    if not ok or not f then return end
    local ok2,s=pcall(function()return ser(saved)end)
    if ok2 and s then f:write(s) end
    f:close()
end

-- Inventaire d'un train
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

-- Nombre de wagons
local function wagons(t)
    local ok,v=pcall(function()return t:getVehicles()end)
    if not ok or not v then return 0 end
    local n=0 for _ in pairs(v) do n=n+1 end return n
end

-- Enregistrer et diffuser un trajet
-- Structure: saved[trainName][segKey] = { {duration,ts,inv,wagons}, ... } (10 max)
local MAX_PER_SEG=10
local function saveTrip(tn,fr,to,d,ts,it,nv)
    local seg=fr.."->"..to
    if not saved[tn] then saved[tn]={} end
    if not saved[tn][seg] then saved[tn][seg]={} end
    table.insert(saved[tn][seg],1,{duration=d,ts=ts,inv=it,wagons=nv})
    while #saved[tn][seg]>MAX_PER_SEG do table.remove(saved[tn][seg]) end
    writeDisk()
    -- Broadcast réseau
    local ok,invs=pcall(function()return ser(it)end)
    local invStr=ok and invs or "{}"
    pcall(function()net:broadcast(42,tn,fr,to,d,ts,invStr)end)
    local invLog=""
    for item,cnt in pairs(it) do invLog=invLog.." | "..item.." x"..cnt end
    print("LOG: "..tn.." "..seg.." d="..d.."s wagons="..nv..invLog)
end

-- État par train
local la={}         -- {[tn]={from, t}}   : gare + heure d'arrivée
local depart={}     -- {[tn]=inv}          : inventaire capturé au départ
local dk_prev={}

local function tick()
    if not sta then return end
    local ok,trains=pcall(function()return sta:getTrackGraph():getTrains()end)
    if not ok or not trains then return end
    local now=computer.millis()/1000
    for _,t in pairs(trains) do
        local ok2,m=pcall(function()return t:getMaster()end)
        if ok2 and m then
            local tn=t:getName()
            local dk=m.isDocked
            -- Timetable : gare courante
            local cur="?"
            pcall(function()
                local tt=t:getTimeTable()
                local ci=tt:getCurrentStop()
                local st=tt:getStop(ci)
                cur=st.station.name
            end)
            -- Arrivée en gare : enregistre le trajet
            if dk then
                local ls=la[tn]
                if ls and ls.from~=cur then
                    local d=math.floor(now-ls.t)
                    if d>5 and d<7200 then
                        local nv=wagons(t)
                        saveTrip(tn,ls.from,cur,d,math.floor(now),depart[tn] or {},nv)
                    end
                end
                if not la[tn] or la[tn].from~=cur then
                    la[tn]={from=cur,t=now}
                end
            end
            -- Départ de gare : capture l'inventaire après chargement
            if dk_prev[tn]==true and not dk then
                depart[tn]=inv(t)
            end
            dk_prev[tn]=dk
        end
    end
end

loadSaved()
local trainCount=0
if sta then pcall(function()trainCount=#sta:getTrackGraph():getTrains()end) end
print("LOGGER démarré - "..trainCount.." trains détectés")

while true do
    tick()
    event.pull(2)
end
