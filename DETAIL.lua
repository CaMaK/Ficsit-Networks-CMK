local gpu=computer.getPCIDevices(classes.Build_GPU_T2_C)[1]
local scr=component.proxy(component.findComponent("DETAIL_SCREEN_R")[1])
local sta=component.proxy(component.findComponent("GARE_TEST")[1])
local pan=component.proxy(component.findComponent("DETAIL_PANEL")[1])
local net=computer.getPCIDevices(classes.NetworkCard)[1]
gpu:bindScreen(scr)
local sw,sh=600,900
local BG={r=0,g=0,b=0,a=1}
local OR={r=1,g=0.5,b=0,a=1}
local WH={r=1,g=1,b=1,a=1}
local DI={r=0.4,g=0.4,b=0.4,a=1}
local GR={r=0.2,g=1,b=0.2,a=1}
local RE={r=1,g=0.2,b=0.2,a=1}
local YE={r=1,g=1,b=0.2,a=1}
local BL={r=0.2,g=0.6,b=1,a=1}
local SP={r=0.15,g=0.15,b=0.15,a=1}
local bP=pan:getModule(0,0,0)
local bN=pan:getModule(0,1,0)
event.listen(bP) event.listen(bN) event.listen(net)
net:open(42)
local idx=1 local tl={} local tm={} local la={} local dp={} local dk_prev={}
local saved={} -- {[trainName]=[{from,to,duration,ts,inventory,wagons},...]}

local function ref() tl=sta:getTrackGraph():getTrains() end
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
local function upd(tn,fr,to,d)
    if not tm[tn] then tm[tn]={} end
    local k=fr.."->"..to
    if not tm[tn][k] then tm[tn][k]={t=0,c=0} end
    tm[tn][k].t=tm[tn][k].t+d tm[tn][k].c=tm[tn][k].c+1
end
local function eta(tn,fr,to)
    if not tm[tn] then return nil end
    local k=tm[tn][fr.."->"..to]
    if not k or k.c==0 then return nil end
    return math.floor(k.t/k.c)
end

-- Réception d'un trajet depuis LOGGER
local function onTrip(tn,fr,to,d,ts,invStr)
    if not saved[tn] then saved[tn]={} end
    local it={}
    local ok,fn=pcall(load,"return "..invStr)
    if ok and fn then local ok2,r=pcall(fn) if ok2 and r then it=r end end
    table.insert(saved[tn],1,{from=fr,to=to,duration=d,ts=ts,inventory=it})
    while #saved[tn]>5 do table.remove(saved[tn]) end
    upd(tn,fr,to,d) -- alimente aussi le calcul ETA
end

local function fmt(s) return string.format("%d:%02d",math.floor(s/60),s%60) end
local function sep(y) gpu:drawRect({x=10,y=y},{x=sw-20,y=1},SP,SP,0) end
local function draw()
    if #tl==0 then gpu:drawRect({x=0,y=0},{x=sw,y=sh},BG,BG,0) gpu:drawText({x=20,y=440},"Aucun train",25,RE,false) gpu:flush() return end
    if idx>#tl then idx=1 end if idx<1 then idx=#tl end
    local t=tl[idx] local m=t:getMaster()
    if not m then idx=idx+1 if idx>#tl then idx=1 end return end
    local tn=t:getName()
    local mv=m:getMovement()
    local spd=math.abs(math.floor(mv.speed/100*3.6))
    local mspd=math.abs(math.floor(mv.maxSpeed/100*3.6))
    local dk=m.isDocked
    local veh={} pcall(function()veh=t:getVehicles()end)
    local nv=0 if veh then for _ in pairs(veh) do nv=nv+1 end end
    local ci,sn=tti(t)
    local now=computer.millis()/1000
    if ci and sn and #sn>0 then
        local ns=#sn
        local dn=sn[(ci+1)%ns+1] or "???"
        if dk then
            local cur=sn[ci+1] or "???"
            local ls=la[tn]
            if ls and ls.from~=cur then
                local d=math.floor(now-ls.t)
                if d>5 and d<7200 then upd(tn,ls.from,cur,d) end
            end
            if not la[tn] or la[tn].from~=cur then la[tn]={from=cur,t=now} end
        end
        if dk_prev[tn]==true and not dk then
            local from=la[tn] and la[tn].from or "?"
            local av=eta(tn,from,dn)
            if av then dp[tn]={t=now,to=dn,av=av} end
        end
        dk_prev[tn]=dk
    end
    gpu:drawRect({x=0,y=0},{x=sw,y=sh},BG,BG,0)
    gpu:drawRect({x=0,y=0},{x=sw,y=60},BG,{r=0.08,g=0.08,b=0.08,a=1},0)
    gpu:drawText({x=10,y=14},"<<",30,OR,false)
    gpu:drawText({x=sw-44,y=14},">>",30,OR,false)
    local nx=math.floor(sw/2-#tn*9)
    gpu:drawText({x=nx,y=16},tn,24,WH,false)
    sep(62)
    local y=72
    local sc=spd>100 and GR or (spd>10 and YE or RE)
    gpu:drawText({x=10,y=y},"Vitesse",19,DI,false) gpu:drawText({x=130,y=y},spd.." km/h",19,sc,false) gpu:drawText({x=300,y=y},"max "..mspd,19,DI,false)
    y=y+28
    gpu:drawText({x=10,y=y},"Etat",19,DI,false)
    if dk then gpu:drawText({x=130,y=y},"A QUAI",19,BL,false)
    elseif spd>0 then gpu:drawText({x=130,y=y},"EN ROUTE",19,GR,false)
    else gpu:drawText({x=130,y=y},"ARRETE",19,RE,false) end
    y=y+28
    gpu:drawText({x=10,y=y},"Wagons",19,DI,false) gpu:drawText({x=130,y=y},tostring(nv),19,WH,false)
    y=y+32 sep(y) y=y+10
    gpu:drawText({x=10,y=y},"TIMETABLE",19,OR,false) y=y+26
    if sn and #sn>0 then
        local ns=#sn
        for i,nm in ipairs(sn) do
            if y>sh-160 then gpu:drawText({x=10,y=y},"...",17,DI,false) break end
            local i0=i-1 local isc=(i0==ci) local isp=(i0==(ci-1)%ns)
            local px="  " local pc=DI
            if isc then px="→ " pc=GR elseif isp then px="✓ " pc={r=0.3,g=0.3,b=0.3,a=1} end
            gpu:drawText({x=10,y=y},px..nm,17,pc,false)
            local d=dp[tn]
            if not dk and d and nm==d.to then
                local rem=math.floor(d.av-(now-d.t))
                local ec=rem>=0 and GR or RE
                local rs=rem>=0 and fmt(rem) or "-"..fmt(-rem)
                gpu:drawText({x=sw-120,y=y},rs,17,ec,false)
            elseif isc and not dk then
                local pn=la[tn] and la[tn].from or "?"
                local av=eta(tn,pn,nm)
                if av then gpu:drawText({x=sw-110,y=y},"~"..fmt(av),17,YE,false)
                else gpu:drawText({x=sw-110,y=y},"ETA ?",17,DI,false) end
            end
            y=y+21
        end
    else gpu:drawText({x=10,y=y},"Pas de timetable",17,DI,false) end
    y=y+6 sep(y) y=y+10
    gpu:drawText({x=10,y=y},"INVENTAIRE",19,OR,false) y=y+26
    local it=(saved[tn] and saved[tn][1] and saved[tn][1].inventory) or {}
    local has=false
    for nm,cnt in pairs(it) do
        if y>sh-40 then break end
        gpu:drawText({x=10,y=y},nm.."  x"..cnt,17,WH,false) y=y+21 has=true
    end
    if not has then gpu:drawText({x=10,y=y},"En attente LOGGER...",17,DI,false) end
    gpu:drawRect({x=0,y=sh-35},{x=sw,y=35},BG,BG,0)
    local cnt=idx.." / "..#tl
    local cx=math.floor((sw-#cnt*11)/2)
    gpu:drawText({x=cx,y=sh-28},cnt,22,WH,false)
    gpu:flush()
end
ref()
for _,t in pairs(tl) do
    local ok,m=pcall(function()return t:getMaster()end)
    if ok and m then dk_prev[t:getName()]=m.isDocked end
end
while true do
    draw()
    local e,src,sender,port,tn,fr,to,d,ts,invStr=event.pull(2)
    if e=="Trigger" then
        if src==bN then idx=idx+1 end
        if src==bP then idx=idx-1 end
        if idx>#tl then idx=1 end
        if idx<1 then idx=#tl end
    elseif e=="NetworkMessage" and port==42 then
        onTrip(tn,fr,to,d,ts,invStr)
    end
end
