print("START")
local fs=filesystem
fs.initFileSystem("/dev")
fs.mount("/dev/6D014517486D381F93350594FFD39B23","/")

if not fs.exists("/trips.json") then print("Fichier absent") return end
local ok,f=pcall(function()return fs.open("/trips.json","r")end)
if not ok or not f then print("Erreur open") return end
local ok2,s=pcall(function()return f:read("*a")end)
f:close()
if not ok2 or not s or s=="" then print("Vide") return end

local ok3,fn=pcall(load,"return "..s)
if not ok3 or not fn then print("Parse err: "..tostring(fn)) return end
local ok4,data=pcall(fn)
if not ok4 or not data then print("Exec err") return end

local function fmt(sec)
    return string.format("%d:%02d",math.floor(sec/60),sec%60)
end

for trainName,segs in pairs(data) do
    print("========== "..trainName.." ==========")
    for seg,trips in pairs(segs) do
        print("  --- "..seg.." ("..#trips.." trajets) ---")
        -- Stats du segment
        local dmin,dmax,dsum=math.huge,0,0
        for _,trip in ipairs(trips) do
            dsum=dsum+trip.duration
            if trip.duration<dmin then dmin=trip.duration end
            if trip.duration>dmax then dmax=trip.duration end
        end
        local davg=math.floor(dsum/#trips)
        print(string.format("    Duree: min=%s  moy=%s  max=%s",
            fmt(dmin),fmt(davg),fmt(dmax)))
        -- Dernier trajet
        local last=trips[1]
        print("    Dernier: "..fmt(last.duration).."  wagons="..tostring(last.wagons).."  ts="..tostring(last.ts))
        if last.inv then
            local invLine="    Inventaire:"
            for item,cnt in pairs(last.inv) do
                invLine=invLine.."  "..item.." x"..cnt
            end
            print(invLine)
        end
    end
end
print("END")
