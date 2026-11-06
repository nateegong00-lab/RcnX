-- RAYCITY X V6.9 - AUTO FAIL RECOVERY + V6.8 SYSTEMS
-- V6.9: after an authoritative failed quest result, cancel the old PASS route,
-- wait for server idle, return to Derix, and pick a new playable green R1-R4.
-- Optional, persisted AUTO FAIL RETRY toggle (ON by default); bounded retries.
-- Only the game's QuestUI.hideResult may dismiss a verified failed result.
-- Never auto-activate unrelated reward/Continue buttons or fake completion.
-- Based on V6.7. Retains all V6.7 speed, quest, channel and save controls.
-- V6.8: optional client-only NPC traffic pair-hook disable, OFF by default.
-- NPC traffic collision is simulated by shared.RCDrivePairHooks.traffic.
-- Does not affect other players, map walls, checkpoint or server authority.
-- Native road navigation may still avoid traffic even when collision hook is off.
-- Restores original traffic hook when disabled / GUI closed.
-- Green R1-R4 buttons are included in the random pool; gray ones are excluded.
-- A fresh round is chosen only when the NPC offers playable missions.
-- Uses the game's existing RaycityUi.AutoDrive. No vehicle PivotTo, raw velocity,
-- custom steering physics, or spoofed Quest/Remote completion.
-- Reviewed against ReplicatedStorage.RaycityUi.AutoDrive and RBRCQuest client source.
-- LANE DIAGNOSTIC: experimental navigation waypoints; OFF by default.
-- Reports real lateral movement, not just whether the quest resumed.
-- Does NOT modify RCDrive steering, warp the vehicle, or promise lane changes.
-- V6.2: hazard slide now OFF by default; advanced road + traffic validation;
-- unbiased LEFT/RIGHT scoring; no slide during NPC return.
-- V6.4: removed V6.2 150-stud early-brake gate, which stalled cars at
-- 137 studs. Uses a progressive approach cruise cap, final-range parking,
-- and retains speed-confirmed NPC talk. No change to quest random selection.
-- QuestFix/RandomQuest/BoostFix retained. Results depend on game client authority.
-- V6.3: optional reverse-and-steer recovery during native J cooldown; key input
-- requires VirtualInputManager or executor keyboard API; no Physics/PivotTo hacks.
-- Escape OFF by default; short bounded attempts, collision/road checks,
-- server mission state preserved; when input unavailable resume native quest.
-- Original QuestFix logic retained; test in a private/controlled session first.
-- V6.7: dynamic native turn caps while speed target changes; bounded higher-speed
-- approach envelope for drive-through checkpoints; NPC stop tuning unchanged.
-- Adds live throttle/brake and native corner/route limit diagnostics.
-- V6.6: current channel and player counts from channel.list, optional one-shot
-- random among least populated eligible channels; no repeated hop loop.
-- V6.5: uses the game's SysKit channel.list/channel.move for explicit
-- channel selection, never during active quest. Config saves only through
-- optional executor readfile/writefile; session-only fallback if unavailable.
-- No automatic script execution after a server teleport is promised.

local Players = game:GetService('Players')
local RS = game:GetService('ReplicatedStorage')
local RunService = game:GetService('RunService')
local WS = game:GetService('Workspace')
local UIS = game:GetService('UserInputService')
local player = Players.LocalPlayer
if not player then return end
local pg = player:WaitForChild('PlayerGui', 10)
if not pg then return end

local NAME = 'RayCityXFullV69'
local V66={}
-- Derix RoadFightData: slots 1..4. Selection is a REQUEST; server checks unlock/level.
local DERIX_ROUND_QUESTS = {
    [1] = 'R1676',
    [2] = 'R1678',
    [3] = 'R1679',
    [4] = 'R1680',
}
local DEFAULT_ROUND = 3
local START_NPC_ID = 'roadfight:1676'
-- Shutdown existing speed controls before creating one unified controller.
for _,oldKey in ipairs({'RayCityX_V6','RaycitySpeedTestUI_V2','RaycitySpeedTestUI_V1'}) do
    pcall(function()
        local entry=shared[oldKey]
        if type(entry)=='table' and type(entry.close)=='function' then entry.close() end
    end)
end
-- Close prior native UI. The old native driver's Destroying handler stops it.
for _,previousName in ipairs({'RayCityNativeCruiseV41', 'RayCityNativeCruiseV42', 'RayCityNativeCruiseV43', 'RayCityNativeCruiseV44', 'RayCityNativeCruiseV45', 'RayCityNativeCruiseV46', 'RayCityNativeCruiseV47', 'RayCityX_V6', 'RayCityXFullV6', 'RayCityXFullV62', 'RayCityXFullV63', 'RayCityXFullV64', 'RayCityXFullV65', 'RayCityXFullV66', 'RayCityXFullV67', 'RayCityXFullV68', NAME}) do
    local oldGui = pg:FindFirstChild(previousName)
    if oldGui then oldGui:Destroy() end
end

local bridge = {alive=true, owns=false, armed=false, autoNext=true, selectedIndex=nil,
    selectedGoal=nil, goalSource='-', lastQuestToken=nil, note='READY',
    lastRequestAt=0, lastPosition=nil, stagnantSince=nil, requestedPass=nil,
    autoBoost=true, lastBoostTry=0, boostCount=0, lastBoosting=false,
    maxKmh=100, passDepth=0, passSource='-', boostNote='-', lastRetune=0,
    activeDest=nil, lastSpeedCap=0, passInside=false, lastNativeBrake=0,
    autoQuickStart=true, lastQuickStartTry=0, quickStartCount=0, quickNote='-',
    autoEvade=false, jumpFallback=false, lastEvadeTry=0, lastJumpTry=0,
    slideSide=0, slideSafeNote='DEFAULT OFF: ROAD EDGE NOT PROVEN',
    hazard=nil, hazardDistance=nil, hazardTtc=nil, evadeNote='OFF',
    spNow=nil, spMax=nil, boostNeed=nil, lastRadarAt=0, radarModels=0, sideWhy='-', slideCheck='-', lastSlideRequest=nil, lastSlideRequestAt=0}

-- Experimental lane change controller. One detour at a time, then restore
-- the original quest target. Only genuine, short, forward NAV routes qualify.
local lane = {
    enabled=false, manual=false, active=false, inTransition=false,
    period=30, timeout=12, lastAttempt=-1e6, lastFinish=-1e6,
    lastSide=0, chosenSide=0, waypoint=nil, startedAt=0,
    originalGoal=nil, originalSource=nil, originalObjective=nil,
    originalToken=nil, originalPass=nil, originalIdx=nil,
    tries=0, successes=0, note='OFF', lastReason='-',
    origin=nil, sideAxis=nil, shiftNow=0, maxShift=0, acceptedRoutes=0,
    failureLeft='-', failureRight='-', routeNote='-',
}

local cycle -- forward declaration for NPC parking and quest controller
-- Auto Unstuck uses the game's J/resetKey action, NOT PivotTo or direct teleport.
-- Detect only while the native driver is actively travelling to a target.
local unstuck = {
    enabled=true, thresholdKmh=5, triggerSeconds=3.0, cooldownSeconds=16,
    checkPeriod=0.20, lowSince=nil, lastCheck=0, lastRequest=-1e6,
    pending=false, pendingAt=0, savedGoal=nil, savedSource=nil,
    savedObjective=nil, ignoreWarpUntil=0, lastNativeWarps=0,
    streak=0, healthySince=nil, attempts=0, successes=0,
    note='MONITOR', speed=0, eta=0, lastPosition=nil,
}

-- V6.3: manual keyboard fallback ONLY after the native J reset has been
-- requested and remains on cooldown. No direct velocity/position modifications.
local escape = {
    enabled=false, active=false, handoff=false, inputMode='ARROWS',
    phase='IDLE', phaseAt=0, attempts=0, successes=0, perReset=0, maxPerReset=2,
    lastAttempt=-1e6, inputDriver=nil, held={},
    side=0, lastSide=0, startPos=nil, startForward=nil, startYaw=nil,
    savedGoal=nil, savedSource=nil, savedObjective=nil, savedStage=nil,
    note='OFF: ENABLE TO TEST', moved=0, turned=0, ui={},
}


local function sharedCandidate()
    local items, seen = {}, {}
    local function add(v)
        if type(v)=='table' and not seen[v] then
            seen[v]=true; items[#items+1]=v
        end
    end
    add(shared)
    if type(getrenv)=='function' then
        local ok,e=pcall(getrenv)
        if ok and type(e)=='table' then add(rawget(e,'shared')) end
    end
    if type(getgenv)=='function' then
        local ok,e=pcall(getgenv)
        if ok and type(e)=='table' then add(rawget(e,'shared')) end
    end
    return items
end

local function gameService(key)
    for _,env in ipairs(sharedCandidate()) do
        local item = rawget(env,key)
        if type(item)=='table' then return item end
    end
end

local function requireModule(group, name)
    local parent=RS:FindFirstChild(group)
    local m=parent and parent:FindFirstChild(name)
    if not m or not m:IsA('ModuleScript') then return nil end
    local ok, result=pcall(require,m)
    if ok and type(result)=='table' then return result end
    return nil
end

local AUTO = gameService('RaycityAutoDrive') or requireModule('RaycityUi','AutoDrive')
local NAV = gameService('RaycityNavigation') or requireModule('RaycityUi','Navigation')
local function refreshServices()
    AUTO = gameService('RaycityAutoDrive') or AUTO or requireModule('RaycityUi','AutoDrive')
    NAV = gameService('RaycityNavigation') or NAV or requireModule('RaycityUi','Navigation')
end

local function carRoot()
    local car=WS:FindFirstChild('MyCar')
    local root=car and (car:FindFirstChild('Root') or car.PrimaryPart)
    if root and root:IsA('BasePart') then return car, root end
    return nil,nil
end

local function rawQuestState()
    local quest=gameService('RBRCQuest')
    if quest and type(quest.state)=='function' then
        local ok,s=pcall(quest.state)
        if ok and type(s)=='table' then return s end
    end
    return nil
end

local function questState()
    local s=rawQuestState()
    if s and s.state=='running' then return s end
    return nil
end

local function liveDestinations(s)
    local out={}
    if not s or type(s.q)~='table' or type(s.q.objectives)~='table' then return out end
    for _,o in ipairs(s.q.objectives) do
        local rt=s.objectives and (s.objectives[o.idx] or s.objectives[tostring(o.idx)]) or nil
        if (o.cls=='Dest' or o.cls=='PhotoDest' or o.cls=='Return')
            and o.passive~=true and (o.step==s.step or o.step==0)
            and not (type(rt)=='table' and rt.done==true) then
            local dest=o.dest
            if o.cls=='Return' and type(s.retPoly)=='table' and type(s.retPoly[o.idx])=='table' then
                local verts=s.retPoly[o.idx]
                local sum,n=Vector3.zero,0
                for _,v in ipairs(verts) do
                    if typeof(v)=='Vector3' then sum+=v; n+=1 end
                end
                if n>0 then dest={target=sum/n,poly=verts,center=sum/n,stop=true} end
            end
            if type(dest)=='table' and typeof(dest.target)=='Vector3' then
                out[#out+1]={id=o.idx,dest=dest,cls=o.cls,rt=rt}
            end
        end
    end
    return out
end

local function xz(v) return Vector2.new(v.X,v.Z) end
-- NPC parking hold: preserve local AutoCmd attributes where possible, and
-- never leave throttle/brake overrides after quest travel, manual STOP or exit.
-- The game's client may ignore AutoBrake when AutoDrive is stopped; this is
-- an additional hold and NOT a replacement for early native braking.
local npcParking={active=false,car=nil,oldGas=nil,oldBrake=nil,heldAt=0,note='IDLE'}
local function releaseNpcParking()
    if npcParking.active and npcParking.car and npcParking.car.Parent then
        local car=npcParking.car
        pcall(function()
            if car:GetAttribute('AutoThrottle')==0 then car:SetAttribute('AutoThrottle',npcParking.oldGas) end
            if car:GetAttribute('AutoBrake')==1 then car:SetAttribute('AutoBrake',npcParking.oldBrake) end
        end)
    end
    npcParking.active=false; npcParking.car=nil
    npcParking.note='RELEASED'
end
local function setNpcParking(car,now)
    if not car then return end
    if npcParking.active and npcParking.car~=car then releaseNpcParking() end
    if not npcParking.active then
        npcParking.oldGas=car:GetAttribute('AutoThrottle')
        npcParking.oldBrake=car:GetAttribute('AutoBrake')
        npcParking.car=car
        npcParking.heldAt=now or os.clock()
        npcParking.active=true
    end
    pcall(function()
        car:SetAttribute('AutoThrottle',0)
        car:SetAttribute('AutoBrake',1)
    end)
    npcParking.note='NPC HOLD REQUEST'
end
local function npcParkingTick(now)
    if not bridge.alive or not cycle or not cycle.enabled then
        if npcParking.active then releaseNpcParking() end
        return
    end
    local stage=cycle.stage
    local c,r=carRoot()
    local dist=(r and cycle.npcPos) and (xz(r.Position)-xz(cycle.npcPos)).Magnitude or math.huge
    local stopRadius=math.max(5,(cycle.npcRange or 10)-2)
    -- This final brake begins ONLY once physically inside the NPC talk
    -- corridor. Do not hold brake during the long-distance approach.
    if stage=='RETURN_NPC' then
        if c and dist<=stopRadius and (bridge.owns or npcParking.active) then
            setNpcParking(c,now)
        elseif npcParking.active then
            releaseNpcParking()
        end
        return
    end
    if not npcParking.active then return end
    -- Once parked, keep brake held during NPC conversation and server start.
    if stage~='TALK' and stage~='WAIT_QUEST'
       and stage~='RETRY_WAIT' and stage~='NEED_NPC' then
        releaseNpcParking()
        return
    end
    if c~=npcParking.car or not r or dist>(cycle.npcRange or 10)+5 then
        releaseNpcParking()
        return
    end
    setNpcParking(c,now)
end


local function pointInPolygon(point, poly)
    if type(poly)~='table' or #poly<3 then return false end
    local x,z=point.X,point.Z
    local inside=false
    for i=1,#poly do
        local a,b=poly[i],poly[(i%#poly)+1]
        if typeof(a)~='Vector3' or typeof(b)~='Vector3' then return false end
        if (a.Z>z)~=(b.Z>z) then
            local crossing=a.X+(z-a.Z)*(b.X-a.X)/(b.Z-a.Z)
            if x<crossing then inside=not inside end
        end
    end
    return inside
end

-- Choose a road position well INSIDE the real PASS polygon, not the first
-- point at the border. Interrogate existing lane paths to target AND centre.
-- Never direct-steer across medians or pivot the car.
local function polyCentre(poly)
    local sum,n=Vector3.zero,0
    for _,p in ipairs(poly) do
        if typeof(p)=='Vector3' then sum+=p;n+=1 end
    end
    return n>2 and sum/n or nil
end
local function edgeClearance(p, poly)
    local best=math.huge
    local pp=xz(p)
    for i=1,#poly do
        local a,b=poly[i],poly[(i%#poly)+1]
        if typeof(a)~='Vector3' or typeof(b)~='Vector3' then return 0 end
        local x,y=xz(a),xz(b)
        local v=y-x
        local t=math.clamp((pp-x):Dot(v)/math.max(v:Dot(v),0.000001),0,1)
        local d=(pp-(x+v*t)).Magnitude
        if d<best then best=d end
    end
    return best
end
local function roadPointInPass(from, dest)
    if type(dest.poly)~='table' or #dest.poly<3
        or not NAV or type(NAV.routeLanes)~='function' then return nil,0 end
    local centre=typeof(dest.center)=='Vector3' and dest.center or polyCentre(dest.poly)
    if not centre then return nil,0 end
    local trials={dest.target}
    if (xz(dest.target)-xz(centre)).Magnitude>3 then
        trials[#trials+1]=centre
    end
    local choices={}
    for _,goal in ipairs(trials) do
      -- endOnLane=false may reveal an approach deeper into the PASS polygon;
      -- true supplies a conservative road-centre alternative.
      for _,endOnLane in ipairs({false,true}) do
        local ok,path=pcall(NAV.routeLanes,from,goal,{
            startFallback=true,forwardLanes=true,endOnLane=endOnLane})
        if ok and type(path)=='table' and #path>=2 and #path<=3000 then
            local function addCandidate(p)
                if typeof(p)~='Vector3' or not pointInPolygon(p,dest.poly)
                   or math.abs(p.Y-centre.Y)>18 then return end
                local clearance=edgeClearance(p,dest.poly)
                choices[#choices+1]={pos=p, clear=clearance,
                    score=clearance*2-(xz(p)-xz(centre)).Magnitude*0.20}
            end
            for i=1,#path-1 do
                local a,b=path[i],path[i+1]
                if typeof(a)=='Vector3' and typeof(b)=='Vector3' then
                    local dist=(xz(b)-xz(a)).Magnitude
                    local n=math.max(1,math.ceil(dist/4))
                    for k=0,n do addCandidate(a:Lerp(b,k/n)) end
                end
            end
            -- Continue along last road tangent, if the path stops at near edge.
            local a,b=path[#path-1],path[#path]
            if typeof(a)=='Vector3' and typeof(b)=='Vector3' then
                local dir=xz(b)-xz(a)
                if dir.Magnitude>1 then
                    for d=4,24,4 do
                        addCandidate(b+Vector3.new(dir.Unit.X*d,0,dir.Unit.Y*d))
                    end
                end
            end
        end
      end
    end
    -- The supplied quest target is a candidate only if INSIDE the true
    -- polygon; road validity is checked together with all other candidates.
    for _,q in ipairs({dest.target, centre}) do
        if typeof(q)=='Vector3' and pointInPolygon(q,dest.poly)
            and math.abs(q.Y-centre.Y)<18 then
            local clear=edgeClearance(q,dest.poly)
            choices[#choices+1]={pos=q,clear=clear,
                score=clear*2-(xz(q)-xz(centre)).Magnitude*0.20}
        end
    end
    table.sort(choices,function(a,b) return a.score>b.score end)
    for i=1,math.min(45,#choices) do
        local pick=choices[i]
        local roadOK=true
        if type(NAV.perceptionRoad)=='function' then
            local ok,road=pcall(NAV.perceptionRoad,pick.pos)
            roadOK=ok and road~=nil and road~=false
        end
        if roadOK then return pick.pos,pick.clear end
    end
    return nil,0
end

local function chooseDestination()
    refreshServices()
    local _,root=carRoot()
    if not root then return nil,'NO CAR',nil end
    local s=questState()
    local objs=liveDestinations(s)
    if #objs>0 then
        local best,bestScore=nil,math.huge
        for _,o in ipairs(objs) do
            local d=(xz(o.dest.target)-xz(root.Position)).Magnitude
            if bridge.selectedIndex and bridge.selectedIndex==o.id then d-=250 end
            if d<bestScore then best,bestScore=o,d end
        end
        if best then
            local roadGoal,depth=roadPointInPass(root.Position,best.dest)
            bridge.passDepth=depth or 0
            bridge.passSource=roadGoal and 'DEEP ROAD' or 'GAME TARGET'
            return roadGoal or best.dest.target,
                (roadGoal and 'DEEP ROAD PASS #' or 'QUEST TARGET #')..tostring(best.id),
                {idx=best.id, quest=s, dest=best.dest, roadInside=(roadGoal~=nil)}
        end
    end
    if NAV and type(NAV.getGuide)=='function' then
        local ok,g=pcall(NAV.getGuide)
        if ok and type(g)=='table' then
            local target=typeof(g.goal)=='Vector3' and g.goal or g.target
            if typeof(target)=='Vector3' then
                return target,'GAME GPS '..tostring(g.source or ''),nil
            end
        end
    end
    return nil,'NO QUEST / GPS TARGET',nil
end

local original = {auto=nil, options=nil, values=nil}
-- Forward declaration: the native driver also needs the NORMAL speed target,
-- not the temporarily raised physics ceiling during a Boost.
local speedV6
local function boostVmaxKmh()
    -- Headroom is a ceiling, not an imposed acceleration or a guaranteed speed.
    -- 150 km/h normal -> 250 km/h maximum while native Boost is active.
    return math.min(500,math.max(speedV6.targetKmh+100,speedV6.targetKmh*1.50))
end
local SPEED_KEYS={'maxSpeed','cap1','cap2','cap3','lookAhead',
    'arriveNearM','arriveSlowM','arriveSlowerM','arriveKmh',
    'nearDestM','quickStopKmh','timeoutFarMs','timeoutMidMs','timeoutNearMs','stuckGraceMs'}
local function livePhysics()
    local drive=gameService('RCDrive')
    local p=drive and drive.phys
    if type(p)=='table' then return p end
    -- Some executors only expose the RCDrive object through getgc().
    -- Reuse the same validated car physics discovered by the Speed page.
    local gcDrive=speedV6 and speedV6.drive
    if type(gcDrive)=='table' and gcDrive.car==WS:FindFirstChild('MyCar')
        and type(gcDrive.phys)=='table' then
        return gcDrive.phys
    end
    return nil
end
local function physicsSpeedLimit(p)
    local vmax=p and p.p and tonumber(p.p.vmax)
    -- During Boost, p.p.vmax is temporarily increased. The normal cruise
    -- target must remain the user's chosen 150/220/300 km/h, not Boost's cap.
    if speedV6 and speedV6.enabled and speedV6.drive
        and speedV6.drive.phys==p then
        vmax=speedV6.targetKmh/3.6
    end
    if vmax and vmax>=8 and vmax<=160 then return vmax end
    -- Native physics itself caps the car's actual vmax. This affects ONLY
    -- the AutoDrive speed target, not power or physics params.
    return 100
end

-- V6.7: The native AutoDrive calculates throttle from both maxSpeed and
-- heading-sensitive cap1/cap2/cap3. These MUST follow the user's live Speed
-- target; otherwise changing 150 -> 300 during a quest leaves old curve caps.
-- The severe-turn caps stay conservative to avoid trying to corner at 300 km/h.
local function tuneCurveCaps(C,vmax,stopNeeded)
    if type(C)~='table' or type(vmax)~='number' then return end
    if stopNeeded then
        C.cap1=math.clamp(vmax*0.55,24,44)
        C.cap2=math.clamp(vmax*0.28,12,25)
        C.cap3=math.clamp(vmax*0.18,8,14)
        C.lookAhead=27
    else
        C.cap1=math.clamp(vmax*0.85,30,85)
        C.cap2=math.clamp(vmax*0.43,17,35)
        C.cap3=math.clamp(vmax*0.22,9.5,19)
        C.lookAhead=math.clamp(vmax*0.55,27,46)
    end
end

local function restoreTuning()
    if original.auto and original.values then
        local a=original.auto
        if type(a.C)=='table' then
            for key,value in pairs(original.values) do a.C[key]=value end
        end
        if original.options then
            for key,value in pairs(original.options) do a.options[key]=value end
        end
    end
    original.auto,original.options,original.values=nil,nil,nil
end

local function tuneNative(a, objective)
    if original.auto~=a then
        restoreTuning()
        if type(a.C)~='table' or type(a.options)~='table' then return end
        original.auto=a
        original.options={endOnLane=a.options.endOnLane,escapeKey=a.options.escapeKey,
            arriveBrake=a.options.arriveBrake}
        original.values={}
        for _,key in ipairs(SPEED_KEYS) do original.values[key]=a.C[key] end
    end
    local C=a.C
    local p=livePhysics()
    local vmax=physicsSpeedLimit(p)
    bridge.maxKmh=p and math.floor(vmax*3.6+0.5) or 'CAR LIMIT'
    -- Tiny margin above physics vmax prevents AutoDrive from cycling gas OFF
    -- exactly at the speed cap (which cancels native Boost).
    C.maxSpeed=math.max(28,vmax*1.07)
    local nativeStop=objective and objective.dest and objective.dest.stop==true
    tuneCurveCaps(C,vmax,nativeStop)
    -- IMPORTANT: Roblox studs are divided by 2 inside native AutoDrive.
    -- Old V4.1 nearDestM=25..70 meant native cut gas 50..140 studs BEFORE
    -- the target, while arriveSlowM was only 1.5 m => permanent stop outside PASS.
    -- Here arrival and brake zones are both INSIDE the checkpoint corridor.
    local d=objective and objective.dest or nil
    local mustStop=d and d.stop==true
    local minPassKmh=d and tonumber(d.minSpeedKmh) or 0
    if mustStop then
        -- V6.2 bug: 75 m = 150 studs. The native driver cuts gas/brakes
        -- on entering that entire zone and stalls well outside NPC range.
        -- Leave a narrow native arrival zone; approach speed is shaped by
        -- updateCruiseSpeed(), with final brake inside the NPC talk radius.
        C.nearDestM=1.5         -- about 3 studs, not 150
        C.arriveSlowM=1.0       -- about 2 studs
        C.arriveSlowerM=0.5
        C.arriveKmh=6
    else
        -- Drive-through PASS zones must be crossed, not stopped at the edge.
        C.nearDestM=0.5          -- start coasting at the last 1 stud only
        C.arriveSlowM=0.35      -- <0.7 studs; server PASS owns completion
        C.arriveSlowerM=0.15
        C.arriveKmh=math.max(8,minPassKmh*0.8)
    end
    C.arriveNearM=28
    C.quickStopKmh=mustStop and 45 or 80
    C.timeoutFarMs=mustStop and 90000 or 45000
    C.timeoutMidMs=mustStop and 60000 or 20000
    C.timeoutNearMs=mustStop and 60000 or 12000
    C.stuckGraceMs=1000000000
    a.options.arriveBrake=mustStop
    a.options.endOnLane=not (objective and objective.roadInside==true)
    a.options.escapeKey=false
end

local function updateCruiseSpeed(root)
    if not bridge.owns or not AUTO or type(AUTO.C)~='table'
       or typeof(bridge.selectedGoal)~='Vector3' or not root then return end
    local vmax=physicsSpeedLimit(livePhysics())
    local studs=(xz(root.Position)-xz(bridge.selectedGoal)).Magnitude
    local metres=studs/2 -- confirmed inside native AutoDrive
    local dest=bridge.activeDest
    local stopNeeded=dest and dest.stop==true
    local minPassKmh=dest and tonumber(dest.minSpeedKmh) or 0
    -- Smooth distance-based speed envelope. Unlike V4.1 there is NO fixed
    -- wide brake zone (that was cutting gas ~130 studs before checkpoint).
    -- v=sqrt(2*a*d): high speed on long straights, progressive approach.
    -- Cruise target decreases progressively as the car approaches NPC.
    -- IMPORTANT: this only shapes speed; it must not engage a fixed brake
    -- from 150 studs away. Always retain a slow crawl until talk range.
    local stopRadius=stopNeeded and math.max(5,(cycle and cycle.npcRange or 10)-2) or 0
    local usable=math.max(0,metres-(stopNeeded and stopRadius/2 or 0.4))
    -- Drive-through PASS objectives do not require a full stop. V6.6 used
    -- the same conservative braking-distance envelope for PASS and NPC,
    -- often pulling the car well below the selected Speed before checkpoints.
    -- Keep the slow, proven NPC approach; allow higher cruising farther away
    -- from drive-through PASS while native corner caps still apply.
    local maxByDistance=math.sqrt(2*(stopNeeded and 5.0 or 18.0)*usable)
    local minCruise=stopNeeded and 4.0 or math.max(12.0,minPassKmh/3.6)
    local target=math.min(vmax*1.07,math.max(minCruise,maxByDistance))
    -- Retune these on EVERY speed update. Changing the TextBox mid-route
    -- previously kept cap1/cap2/cap3 from the old speed until next quest.
    tuneCurveCaps(AUTO.C,vmax,stopNeeded)
    if stopNeeded and npcParking.active then
        -- While in the talk corridor, never counteract our final brake by
        -- commanding cruising throttle. The native module may ignore this.
        target=0.5
    end
    -- Native cruise compares actual speed to maxSpeed to decide whether
    -- throttle is 1 or 0. While boosting on a clear road, a low target cuts
    -- throttle and cancels boost in RCDrive.Physics.step. Keep a margin above
    -- current speed without modifying the vehicle's real physics vmax.
    local phys=livePhysics()
    local runningSpeed=phys and phys.v and phys.v.Magnitude or 0
    local distToGoal=studs
    if not stopNeeded and phys and phys.boosting and distToGoal>110 then
        target=math.max(target,math.min(160,math.max(vmax*1.5,runningSpeed+8)))
    end
    AUTO.C.maxSpeed=target
    bridge.lastSpeedCap=target*3.6
    bridge.maxKmh=livePhysics() and math.floor(vmax*3.6+0.5) or 'CAR LIMIT'
end

-- EconomyRules is the same ModuleScript used by the original RCDriveClient
-- and its lastSPState points to that client's SP state when it is accessible.
local ECON=requireModule('RCDrive','EconomyRules')
local function spBudget(p)
    if not ECON then ECON=requireModule('RCDrive','EconomyRules') end
    local st=ECON and ECON.lastSPState
    local value=type(st)=='table' and tonumber(st.sp) or nil
    local max=type(st)=='table' and tonumber(st.maxSP) or nil
    local need,spent=nil,nil
    if ECON and type(ECON.boostCost)=='function' and p and p.p then
        local ok,a,b=pcall(ECON.boostCost, {
            BT_NeedSP=p.p.btNeedSP, BT_SpentSP=p.p.btSpentSP
        })
        if ok then need,spent=a,b end
    end
    bridge.spNow,bridge.spMax,bridge.boostNeed=value,max,need
    return value,need
end
local function nativeAction(car, action)
    if not car or car:GetAttribute('AutoCmd')~=nil then return false end
    local ok=pcall(car.SetAttribute,car,'AutoCmd',action)
    return ok
end
local function distanceToGoal(root)
    return typeof(bridge.selectedGoal)=='Vector3'
        and (xz(root.Position)-xz(bridge.selectedGoal)).Magnitude or math.huge
end

-- The ordinary double-tap on UP (two presses <200 ms apart) calls the
-- built-in quickStart(). AutoCmd='qstart' dispatches to that very function.
-- Native game code checks learned skill, SP, contact and quickstart timing.
local function autoQuickStartTick(car,root,status,p,now)
    if not bridge.autoQuickStart or not bridge.owns or not p or not status
       or status.active~=true or not car or not root then return false end
    if bridge.activeDest and bridge.activeDest.stop==true then
        bridge.quickNote='NPC STOP: NO QUICKSTART';return false
    end
    if now-bridge.lastQuickStartTry<4.0 then return false end
    local kmh=p.v and p.v.Magnitude*3.6 or 0
    if kmh>=50 or kmh<4 then bridge.quickNote='SPEED '..math.floor(kmh);return false end
    if distanceToGoal(root)<95 or p.qstart==true or (tonumber(p.qstartTimer) or 0)>0
       or p.anyContact~=true or tonumber(p.throttle)==nil or p.throttle<0.70
       or p.boosting==true then
       bridge.quickNote='WAIT DRIVE / PASS';return false
    end
    if bridge.hazardTtc and bridge.hazardTtc<2.0 then return false end
    bridge.lastQuickStartTry=now
    local ok=nativeAction(car,'qstart')
    bridge.quickNote=ok and 'QUICKSTART REQUEST' or 'CMD BUSY'
    if ok then bridge.quickStartCount+=1 end
    return ok
end

-- Re-fire the *normal* boost command after the previous boost ends, while
-- the actual SP value still covers the game-defined boost cost. No free SP.
local function autoBoostTick(car, root, status, now)
    local p=livePhysics()
    if not bridge.autoBoost or not bridge.owns or not car or not root
       or not status or status.active~=true or not p then return end
    local sp,need=spBudget(p)
    if bridge.activeDest and bridge.activeDest.stop==true then
        bridge.boostNote='NPC RETURN: BOOST DISABLED';return
    end
    if p.boosting then
        if not bridge.lastBoosting then bridge.boostCount+=1 end
        bridge.lastBoosting=true
        bridge.boostNote='ACTIVE'
        return
    end
    bridge.lastBoosting=false
    if sp~=nil and need~=nil and sp<need then
        bridge.boostNote='SP LOW '..math.floor(sp)..'/'..math.ceil(need)
        return
    end
    if now-bridge.lastBoostTry<0.85 then return end
    local dest=bridge.activeDest
    if dest and dest.stop==true and distanceToGoal(root)<120 then
        bridge.boostNote='STOP ZONE'; return
    end
    if bridge.hazardTtc and bridge.hazardTtc<2.5 then
        bridge.boostNote='TRAFFIC'; return
    end
    if p.p and tonumber(p.p.btPower) and p.p.btPower<=1 then
        bridge.boostNote='NO BOOST PART';return
    end
    local speed=typeof(p.v)=='Vector3' and p.v.Magnitude or 0
    local heading=tonumber(status.cosHeading)
    local straight=(heading==nil or heading>=0.960) and status.aiMode~=2
    if tonumber(p.throttle)==nil or p.throttle<=0.18 or not straight
       or speed<2.5 or status.noRoute==true or status.detour~=nil then
        bridge.boostNote='WAIT ROAD / GAS';return
    end
    if car:GetAttribute('AutoCmd')~=nil then return end
    bridge.lastBoostTry=now
    -- Prime the physics headroom for the native Boost request itself. Without
    -- this, a car sitting at the 150 km/h cap can have a Boost command yet
    -- never accelerate beyond the cap. Keep the pre-arm brief: real Boost
    -- continues only while the game's p.boosting flag is true.
    local canPrime=speedV6 and speedV6.enabled and speedV6.drive
        and speedV6.drive.phys==p and type(p.p)=='table'
    if canPrime then
        speedV6.boostPrimedUntil=now+0.18
        p.p.vmax=boostVmaxKmh()/3.6
    end
    local ok=nativeAction(car,'boost')
    if not ok and canPrime then speedV6.boostPrimedUntil=0 end
    bridge.boostNote=ok and 'REQUESTED' or 'CMD BUSY'
end


-- TRAFFIC RADAR V6 ---------------------------------------------------------
-- NPC cars are NOT player RemoteCar models. Game code constructs
-- Workspace.RBRCTrafficCars/AICar_* as anchored, CanCollide=false,
-- CanQuery=false visual objects. Blockcast alone cannot see them.
-- Official client traffic API shared.RCTraffic.cars() returns {id,aicar,
-- cframe,velocity,model}. Its velocity is already in studs/s.
local function vehicleModel(hit)
    local node=hit
    for _=1,9 do
        if not node or node==WS then break end
        if node:IsA('Model') then
            local n=node.Name:lower()
            if n:find('car',1,true) or n:find('vehicle',1,true)
                or n:find('traffic',1,true) or n:find('aicar',1,true) then return node end
            if node:FindFirstChild('Root') and node:FindFirstChild('Hull') then return node end
        end
        node=node.Parent
    end
    return nil
end
local function blockProbe(root,car,offset,direction,width)
    local p=RaycastParams.new()
    p.FilterType=Enum.RaycastFilterType.Exclude
    local ignored={car}
    if player.Character then table.insert(ignored,player.Character) end
    local fx=WS:FindFirstChild('RBRCQuestGuide')
    if fx then table.insert(ignored,fx) end
    p.FilterDescendantsInstances=ignored
    p.RespectCanCollide=true
    local at=root.Position+Vector3.new(0,2,0)+offset
    local dir=direction.Magnitude>0.01 and direction.Unit or root.CFrame.LookVector
    local cf=CFrame.lookAt(at,at+dir)
    local ok,res=pcall(WS.Blockcast,WS,cf,Vector3.new(width or 6,3,4),direction,p)
    return ok and res or nil
end
local function sameRoadCandidate(p)
    if not NAV then return false end
    if type(NAV.perceptionRoad)=='function' then
        local ok,r=pcall(NAV.perceptionRoad,p)
        if ok and r~=nil and r~=false then return true end
    end
    if type(NAV.snapToRoad)=='function' then
        local ok,r=pcall(NAV.snapToRoad,p,{level=65535})
        if ok and typeof(r)=='Vector3' then
            return (xz(r)-xz(p)).Magnitude<5 and math.abs(r.Y-p.Y)<11
        end
    end
    return false
end
-- V6.8: traffic collision is a custom CLIENT pair-hook, not only CanCollide.
-- Disabling ONLY 'traffic' preserves map, player and mission collision hooks.
-- We never change NPC geometry, global PhysicsService groups or RemoteEvents.
local npcNoClip={enabled=false,active=false,hookTable=nil,restoreHook=nil,
    lastPoll=-1e6,swaps=0,note='OFF'}
local function restoreNpcTrafficHook()
    local hooks=npcNoClip.hookTable
    local original=npcNoClip.restoreHook
    if type(hooks)=='table' and type(original)=='function' then
        -- Avoid overwriting a later replacement installed by another game module.
        if rawget(hooks,'traffic')==nil then
            pcall(function() hooks.traffic=original end)
        end
    end
    npcNoClip.hookTable=nil
    npcNoClip.restoreHook=nil
    npcNoClip.active=false
    npcNoClip.note=npcNoClip.enabled and 'WAITING FOR CLIENT HOOK' or 'OFF / RESTORED'
end
local function npcNoClipTick(now,force)
    if not npcNoClip.enabled then return end
    if not force and now-npcNoClip.lastPoll<0.35 then return end
    npcNoClip.lastPoll=now
    local hooks=nil
    -- Find the SAME pair-hook table referenced by RCDriveClient.
    for _,env in ipairs(sharedCandidate()) do
        local candidate=rawget(env,'RCDrivePairHooks')
        if type(candidate)=='table' then
            hooks=candidate
            if type(rawget(candidate,'traffic'))=='function'
               or candidate==npcNoClip.hookTable then break end
        end
    end
    if not hooks then
        if npcNoClip.hookTable then restoreNpcTrafficHook() end
        npcNoClip.note='NO CLIENT PAIR HOOK ACCESS'
        return
    end
    if npcNoClip.hookTable and npcNoClip.hookTable~=hooks then
        restoreNpcTrafficHook()
    end
    npcNoClip.hookTable=hooks
    local traffic=rawget(hooks,'traffic')
    if type(traffic)=='function' then
        -- Preserve newest genuine native function for lossless OFF restore.
        npcNoClip.restoreHook=traffic
        local ok=pcall(function() hooks.traffic=nil end)
        if ok then npcNoClip.swaps+=1 end
    end
    npcNoClip.active=type(npcNoClip.restoreHook)=='function'
        and rawget(hooks,'traffic')==nil
    npcNoClip.note=npcNoClip.active and 'CLIENT TRAFFIC HOOK DISABLED'
        or 'WAITING: GAME TRAFFIC HOOK NOT READY'
end
local function setNpcNoClip(on)
    if not on then
        npcNoClip.enabled=false
        restoreNpcTrafficHook()
    else
        npcNoClip.enabled=true
        npcNoClipTick(os.clock(),true)
    end
end
local function isNpcTrafficModel(model)
    if not model or not model:IsA('Model') then return false end
    local folder=WS:FindFirstChild('RBRCTrafficCars')
    return (folder and model:IsDescendantOf(folder)) or
        model.Name:lower():find('aicar_',1,true)~=nil
end
local trafficCache={at=-10,items={},history={}}
local function trafficModels(now,ourCar)
    if now-trafficCache.at<0.25 then return trafficCache.items end
    trafficCache.at=now
    local found,seen={},{ }
    local function include(key,model,pos,velocity,kind,width)
        if key==nil or seen[key] or model==ourCar or typeof(pos)~='Vector3' then return end
        if math.abs(pos.Y - (ourCar and ourCar:GetPivot().Position.Y or pos.Y))>90 then return end
        seen[key]=true
        found[#found+1]={model=model,position=pos,velocity=velocity,kind=kind,
            name=(model and model.Name) or tostring(key),width=tonumber(width) or 7}
    end
    -- Priority 1: genuine traffic state, not a physics raycast.
    local service=gameService('RCTraffic')
    if service and type(service.cars)=='function' then
        local ok,records=pcall(service.cars)
        if ok and type(records)=='table' then
            for _,rec in pairs(records) do
                if type(rec)=='table' and typeof(rec.cframe)=='CFrame' then
                    local key=rec.model or ('NPC:'..tostring(rec.id))
                    include(key,rec.model,rec.cframe.Position,rec.velocity,'NPC',8)
                end
            end
        end
    end
    -- Priority 2: model fallback for traffic API unavailable in Delta.
    local folders={
        {name='RBRCTrafficCars',kind='NPC'},
        {name='RaycityRemoteCars',kind='PLAYER'},
        {name='RBRCMissionCars',kind='MISSION'},
    }
    for _,entry in ipairs(folders) do
        local folder=WS:FindFirstChild(entry.name)
        if folder then
            for _,m in ipairs(folder:GetChildren()) do
                if m:IsA('Model') then
                    local r=m:FindFirstChild('Root') or m.PrimaryPart
                        or m:FindFirstChildWhichIsA('BasePart')
                    if r then include(m,m,r.Position,r.AssemblyLinearVelocity,entry.kind,r.Size.X) end
                end
            end
        end
    end
    -- Some RemoteCar models appear at workspace root.
    for _,m in ipairs(WS:GetChildren()) do
        if m:IsA('Model') and m~=ourCar then
            local n=m.Name:lower()
            if n:find('remotecar_',1,true) or n:find('aicar_',1,true) then
                local r=m:FindFirstChild('Root') or m.PrimaryPart
                if r then include(m,m,r.Position,r.AssemblyLinearVelocity,
                    n:find('aicar_',1,true) and 'NPC' or 'PLAYER',r.Size.X) end
            end
        end
    end
    -- Animated NPC visuals are anchored; use deltas only when no server motion data.
    local history={}
    for _,obj in ipairs(found) do
        local key=obj.model or obj.name
        local prev=trafficCache.history[key]
        if typeof(obj.velocity)~='Vector3' then obj.velocity=Vector3.zero end
        if prev and obj.velocity.Magnitude<0.2 then
            local elapsed=now-prev.time
            if elapsed>0.1 and elapsed<2.5 then
                obj.velocity=(obj.position-prev.pos)/elapsed
            end
        end
        history[key]={pos=obj.position,time=now}
    end
    trafficCache.history=history
    trafficCache.items=found
    return found
end
local function ourForwardStuds(root)
    local p=livePhysics()
    if p and typeof(p.v)=='Vector3' then
        -- RCDrive physics velocity in m/s; game uses ~2 studs/m.
        return math.max(0,p.v:Dot(root.CFrame.LookVector)*2)
    end
    return math.max(0,root.AssemblyLinearVelocity:Dot(root.CFrame.LookVector))
end
local function trafficAhead(root,ourCar,now)
    local look,right=root.CFrame.LookVector,root.CFrame.RightVector
    local speed=ourForwardStuds(root)
    local found=trafficModels(now,ourCar)
    bridge.radarModels=#found
    bridge.npcRadar=0;bridge.playerRadar=0
    local best=nil
    for _,other in ipairs(found) do
        if other.kind=='NPC' then bridge.npcRadar+=1
        elseif other.kind=='PLAYER' then bridge.playerRadar+=1 end
        local delta=other.position-root.Position
        local f=delta:Dot(look)
        local lat=delta:Dot(right)
        local width=math.clamp(other.width*0.5+4,6,12)
        if not (npcNoClip.active and other.kind=='NPC')
           and math.abs(delta.Y)<12 and f>4 and f<145 and math.abs(lat)<width then
            local forwardVel=other.velocity:Dot(look)
            local close=math.max(0,speed-forwardVel)
            local ttc=close>2 and math.max(0,(f-10)/close) or math.huge
            if not best or ttc<best.ttc or (ttc==best.ttc and f<best.distance) then
                best={vehicle=other.model,name=other.name,distance=f,ttc=ttc,
                    relativeLateral=lat,kind=other.kind,source=other.kind..'_STATE'}
            end
        end
    end
    return best,found
end
local function laneIsClear(root,items,side)
    -- A road nearby is not necessarily a same-direction lane. We reject the
    -- skill when we cannot verify a contiguous road corridor and native route.
    local look,right=root.CFrame.LookVector,root.CFrame.RightVector
    local lateralTarget=side*14
    for _,other in ipairs(items) do
        local off=other.position-root.Position
        local forward=off:Dot(look)
        local lateral=off:Dot(right)
        local margin=math.clamp(other.width*0.5+8,10,17)
        if math.abs(off.Y)<14 and forward>-40 and forward<90
            and math.abs(lateral-lateralTarget)<margin then
            return false,'SIDE '..other.kind..' '..other.name
        end
    end
    if not NAV or type(NAV.routeLanes)~='function' then
        return false,'NO VERIFIED LANE NAV'
    end
    -- Samples both along the lateral movement AND farther forward.
    -- Never send Z/X if any sample fails, especially near outer road edges.
    for _,forward in ipairs({14,26,42,65}) do
        for _,across in ipairs({7,14}) do
            local point=root.Position+look*forward+right*side*across
            if not sameRoadCandidate(point) then
                return false,'ROAD EDGE '..(side<0 and 'LEFT' or 'RIGHT')
            end
        end
    end
    local sideGoal=root.Position+look*75+right*side*14
    local ok,path=pcall(NAV.routeLanes,root.Position,sideGoal,{
        startFallback=true,forwardLanes=true,endOnLane=true})
    if not ok or type(path)~='table' or #path<2 or #path>120 then
        return false,'NO SIDE ROUTE'
    end
    local last=path[#path]
    if typeof(last)~='Vector3' or (xz(last)-xz(sideGoal)).Magnitude>9 then
        return false,'NAV RETURNS SAME LANE'
    end
    local length=0
    for i,p in ipairs(path) do
        if typeof(p)~='Vector3' then return false,'BAD ROAD POINT' end
        local d=p-root.Position
        local ahead=d:Dot(look)
        local sideways=d:Dot(right)
        if ahead<-8 or ahead>100 or sideways*side < -3 or sideways*side>23
            or math.abs(d.Y)>12 then
            return false,'SIDE ROUTE UNSAFE'
        end
        if i>1 then
            length+=(xz(p)-xz(path[i-1])).Magnitude
        end
    end
    if length>110 then return false,'SIDE DETOUR' end
    return true,'VERIFIED SIDE ROAD'
end
local function sideRisk(root,nearby,side)
    local look,right=root.CFrame.LookVector,root.CFrame.RightVector
    local minSpace=140
    for _,other in ipairs(nearby) do
        local d=other.position-root.Position
        if math.abs(d.Y)<12 and math.abs(d:Dot(right)-side*14)<17 then
            local a=d:Dot(look)
            if a>-45 and a<115 then
                minSpace=math.min(minSpace,math.abs(a))
            end
        end
    end
    return minSpace
end
local function evadeTick(car,root,p,now)
    if not bridge.owns or not car or not root then return end
    local look,right=root.CFrame.LookVector,root.CFrame.RightVector
    local speed=ourForwardStuds(root)
    local best,nearby=trafficAhead(root,car,now)
    local cast=blockProbe(root,car,look*5,look*math.clamp(speed*1.4,24,100),7)
    if cast then
        local target=vehicleModel(cast.Instance)
        if target and target~=car
           and not (npcNoClip.active and isNpcTrafficModel(target))
           and (not best or cast.Distance+5<best.distance) then
            local forwardV=cast.Instance.AssemblyLinearVelocity:Dot(look)
            local close=math.max(0,speed-forwardV)
            best={vehicle=target,name=target.Name,distance=cast.Distance+5,
                ttc=close>2 and math.max(0,cast.Distance-2)/close or math.huge,
                source='BLOCKCAST',kind='UNKNOWN'}
        end
    end
    bridge.hazard=nil;bridge.hazardDistance=nil;bridge.hazardTtc=nil
    if not best then
        bridge.evadeNote='CLEAR / NPC '..bridge.npcRadar..' / PLAYER '..bridge.playerRadar
        return
    end
    local ttc,d=best.ttc,best.distance
    bridge.hazard=best.name
    bridge.hazardSource=best.source
    bridge.hazardDistance=d;bridge.hazardTtc=ttc
    -- Never perform a side-jump or skill near a NPC, quest stop or lane detour.
    if lane.active or cycle.stage~='QUEST' or
        (bridge.activeDest and bridge.activeDest.stop==true) then
        bridge.evadeNote='OBSERVE ONLY: NPC / LANE / QUEST';return
    end
    if not bridge.autoEvade and not bridge.jumpFallback then
        bridge.evadeNote='RADAR ONLY / '..best.source;return
    end
    if ttc>2.3 and d>20 then
        bridge.evadeNote='TRACK '..best.source..' '..math.floor(d)..' st';return
    end
    if d>75 then bridge.evadeNote='TOO FAR';return end
    if distanceToGoal(root)<140 then
        bridge.evadeNote='NEAR CHECKPOINT: NO SIDE SKILL';return
    end
    if not p then bridge.evadeNote='PHYS NOT EXPOSED';return end
    if p.anyContact==false then bridge.evadeNote='AIRBORNE';return end
    if now-bridge.lastEvadeTry<5 then
        bridge.evadeNote='SKILL COOLDOWN';return
    end
    -- Collect BOTH directions before choosing; no more left-first bias.
    -- Fail closed if road bounds, traffic or side route cannot be verified.
    local options,reasons={},{}
    if bridge.autoEvade then
        for _,side in ipairs({-1,1}) do
            local clear,why=laneIsClear(root,nearby,side)
            if clear then
                local offset=right*side
                if blockProbe(root,car,look*3,offset*16,5) then
                    clear=false;why='SIDE WALL'
                elseif blockProbe(root,car,offset*14+look*5,look*40,6) then
                    clear=false;why='SIDE OBSTACLE'
                end
            end
            if clear then
                options[#options+1]={side=side,space=sideRisk(root,nearby,side),
                    cmd=side<0 and 'slideL' or 'slideR'}
            else
                reasons[#reasons+1]=(side<0 and 'L:' or 'R:')..why
            end
        end
        if #options>0 then
            table.sort(options,function(a,b)
                if a.space==b.space then
                    -- Alternate exact ties, rather than always favoring LEFT.
                    local preferred=bridge.slideSide==0 and 1 or -bridge.slideSide
                    return a.side==preferred
                end
                return a.space>b.space
            end)
            local pick=options[1]
            if nativeAction(car,pick.cmd) then
                bridge.slideSide=pick.side
                bridge.lastEvadeTry=now
                bridge.lastSlideRequest=pick.cmd
                bridge.lastSlideRequestAt=now
                bridge.evadeNote='VERIFIED '..(pick.side<0 and 'LEFT' or 'RIGHT')..
                    ' / '..pick.cmd..' / '..best.source
                return
            end
            reasons[#reasons+1]='AUTOCMD BUSY'
        end
    end
    bridge.evadeNote='NO VERIFIED SIDE: '..table.concat(reasons,' | ')
    -- The jump remains a separate manual toggle; it is not a side-lane change.
    if bridge.jumpFallback and d<30 and ttc<0.9 and now-bridge.lastJumpTry>6
       and p.anyContact~=false and nativeAction(car,'jump') then
        bridge.lastJumpTry=now
        bridge.evadeNote='JUMP REQUEST / '..best.source
    end
end
-- END TRAFFIC RADAR V6 -----------------------------------------------------

local function activeState()
    if not AUTO or type(AUTO.debugState)~='function' then return nil end
    local ok,s=pcall(AUTO.debugState)
    return ok and type(s)=='table' and s or nil
end

-- REVERSE RECOVERY (V6.3) ----------------------------------------------
-- Prefer executor keyboard simulation when present. A PC-only VIM fallback
-- is available, but some Roblox clients/executors deny synthetic keys.
-- Lack of key control is reported explicitly (never claim reverse succeeded).
escape.keysMap = {
    ARROWS={back={Enum.KeyCode.Down,0x28},left={Enum.KeyCode.Left,0x25},right={Enum.KeyCode.Right,0x27}},
    WASD={back={Enum.KeyCode.S,0x53},left={Enum.KeyCode.A,0x41},right={Enum.KeyCode.D,0x44}},
}
function escape.driver()
    if type(keypress)=='function' and type(keyrelease)=='function' then
        return 'EXECUTOR',nil
    end
    local ok,vim=pcall(game.GetService,game,'VirtualInputManager')
    if ok and vim then return 'VIM',vim end
    return nil,nil
end
function escape.send(action,down)
    local pair=escape.keysMap[escape.inputMode] and escape.keysMap[escape.inputMode][action]
    if not pair then return false end
    local ok=false
    if escape.inputDriver=='EXECUTOR' then
        ok=pcall(down and keypress or keyrelease,pair[2])
        -- A failed keypress can fall back to the built-in VirtualInputManager.
        if not ok and down and not next(escape.held) then
            local found,vim=pcall(game.GetService,game,'VirtualInputManager')
            if found and vim then
                local sent=pcall(vim.SendKeyEvent,vim,true,pair[1],false,game)
                if sent then
                    escape.inputDriver='VIM';escape.vim=vim;ok=true
                end
            end
        end
    elseif escape.inputDriver=='VIM' then
        local vim=escape.vim
        if vim then ok=pcall(vim.SendKeyEvent,vim,down,pair[1],false,game) end
    end
    if ok then escape.held[action]=down and true or nil end
    return ok
end
function escape.releaseKeys()
    for _,action in ipairs({'left','right','back'}) do
        if escape.held[action] then escape.send(action,false) end
    end
    escape.held={}
end
function escape.cancel(reason)
    escape.releaseKeys()
    escape.active=false
    escape.phase='IDLE'
    escape.note=tostring(reason or 'CANCELLED')
end

local function stopNative(reason)
    if escape.active and not escape.handoff then escape.cancel('CANCELLED: '..tostring(reason or 'STOP')) end
    -- A quest success, manual STOP, or external retarget cancels an active
    -- lane test; never restore the previous objective after it has changed.
    if lane.active and not lane.inTransition then
        lane.active=false
        lane.note='CANCELLED: '..tostring(reason or 'STOP')
    end
    bridge.owns=false
    bridge.armed=false
    local car=WS:FindFirstChild('MyCar')
    if car and car:GetAttribute('AutoCmd')=='boost' then
        car:SetAttribute('AutoCmd',nil)
    end
    if AUTO and type(AUTO.stop)=='function' then pcall(AUTO.stop,reason or 'bridge_stop') end
    restoreTuning()
    bridge.note=reason or 'STOPPED'
    bridge.stagnantSince=nil
    unstuck.lowSince=nil
    -- Reset recovery may be waiting for the game to place the car.
    -- Do not silently clear pending recovery here: a replan can follow.
    bridge.boostNote='-'
    bridge.quickNote='-'
    bridge.hazard=nil;bridge.hazardTtc=nil;bridge.hazardDistance=nil
end

local function startNative(target, source, objective)
    -- Release the local NPC hold before the native game driver takes over.
    if npcParking.active then releaseNpcParking() end
    -- Normal mission/QuestPush retargets take precedence over a lane waypoint.
    if lane.active and not lane.inTransition then
        lane.active=false
        lane.note='CANCELLED: NEW MISSION ROUTE'
    end
    refreshServices()
    local car,root=carRoot()
    if not car or not root then bridge.note='NO CAR'; return false end
    if typeof(target)~='Vector3' then bridge.note='NO TARGET'; return false end
    if not AUTO or type(AUTO.request)~='function' or type(AUTO.start)~='function'
       or type(AUTO.canCruise)~='function' then
        bridge.note='GAME AUTODRIVE MODULE UNAVAILABLE'; return false
    end
    local stage=player:GetAttribute('RaycityStage')
    if player:GetAttribute('RaycityInRace')==true or stage=='race'
       or stage=='raceLobby' or stage=='raceRoom' then
        bridge.note='RACE: NOT STARTING'; return false
    end
    local region=player:GetAttribute('RaycityRegion') or WS:GetAttribute('RaycityRegion')
    if region~=nil and region~='kr' then
        bridge.note='NATIVE CRUISE UNSUPPORTED IN '..tostring(region)
        return false
    end
    if bridge.owns then stopNative('retarget') end
    tuneNative(AUTO, objective)

    -- Temporary client-local mission exception only for the native request.
    -- Restore the original method in the same call, no persistent patch.
    local oldCan=AUTO.canCruise
    AUTO.canCruise=function() return true end
    local requested, accepted, reason=pcall(AUTO.request,target,{
        navStarted=true,snap=false,source='mission',stopNavOnCancel=false})
    local startedOK,started=false,false
    if requested and accepted==true then
        startedOK,started=pcall(AUTO.start)
    end
    AUTO.canCruise=oldCan
    if not requested or accepted~=true or not startedOK or started~=true then
        bridge.note='NATIVE REFUSED: '..tostring(reason or (requested and started or accepted))
        pcall(AUTO.cancel)
        restoreTuning()
        return false
    end
    bridge.owns=true
    bridge.armed=true
    bridge.lastRequestAt=os.clock()
    bridge.selectedGoal=target
    bridge.goalSource=source
    bridge.selectedIndex=objective and objective.idx or nil
    bridge.requestedPass=objective and objective.quest and (objective.quest.passCount or 0) or nil
    bridge.activeDest=objective and objective.dest or nil
    bridge.passInside=false
    bridge.lastQuestToken=objective and tostring(objective.quest.questId)..':'..tostring(objective.quest.step)..':'..tostring(objective.idx) or nil
    bridge.stagnantSince=nil
    bridge.lastPosition=root.Position
    bridge.activeObjective=objective
    unstuck.lowSince=nil
    unstuck.lastNativeWarps=0
    bridge.note='NATIVE DRIVE ACTIVE / MAX + BOOST'
    return true
end

-- V6.3: short, bounded reverse with steering instead of slideL/slideR.
-- Native input must be completely stopped before sending reverse keyboard keys.
function escape.rearClear(root,car,side)
    local back=-root.CFrame.LookVector
    local right=root.CFrame.RightVector
    -- Reject a reverse that is aimed into a solid obstacle, or a sidewalk/median.
    if blockProbe(root,car,Vector3.zero,back*18,6) then return false,'REAR BLOCKED' end
    if blockProbe(root,car,back*9,back*9+right*side*6,5) then
        return false,'REAR SIDE BLOCKED'
    end
    if not (sameRoadCandidate(root.Position+back*8)
        and sameRoadCandidate(root.Position+back*14+right*side*4)) then
        return false,'NOT VERIFIED ROAD'
    end
    -- NPC traffic is often CanCollide=false and invisible to a Blockcast.
    local others=trafficModels(os.clock(),car)
    for _,obj in ipairs(others) do
        local d=obj.position-root.Position
        local longitudinal=d:Dot(back)
        local lateral=d:Dot(right)
        if math.abs(d.Y)<12 and longitudinal>-5 and longitudinal<25
            and math.abs(lateral)<14 then
            return false,'REAR TRAFFIC '..obj.kind
        end
    end
    return true,'REAR CLEAR'
end
function escape.finish(reason,now)
    if not escape.active then return end
    escape.releaseKeys()
    local car,root=carRoot()
    local displacement=0
    local turn=0
    if root and escape.startPos then
        local d=root.Position-escape.startPos
        displacement=(xz(d)).Magnitude
        local f=escape.startForward
        if f then
            local dot=math.clamp(root.CFrame.LookVector:Dot(f),-1,1)
            turn=math.deg(math.acos(dot))
        end
    end
    escape.moved=displacement;escape.turned=turn
    local reallyMoved=displacement>=2.0 or turn>=10
    if reallyMoved then escape.successes+=1 end
    escape.active=false
    escape.phase='IDLE'
    unstuck.lowSince=nil
    unstuck.healthySince=nil
    unstuck.lastCheck=now
    local goal,source,obj=escape.savedGoal,escape.savedSource,escape.savedObjective
    local stage=cycle and cycle.stage or '-'
    if not bridge.alive or not cycle or not cycle.enabled
       or stage~=escape.savedStage then
        escape.note='CANCELLED: QUEST STATE CHANGED'
        return
    end
    if stage=='QUEST' then
        local t,src,o=chooseDestination()
        if typeof(t)=='Vector3' then goal,source,obj=t,src,o end
    elseif stage=='RETURN_NPC' and cycle.npcPos then
        goal=cycle.npcPos
        source='NPC AFTER REVERSE'
        obj={dest={stop=true},roadInside=true,kind='npc'}
    else
        escape.note='NO RESUME: '..tostring(stage)
        return
    end
    local result=false
    if root and typeof(goal)=='Vector3' then
        result=startNative(goal,source or 'AFTER REVERSE',obj)
    end
    escape.note=string.format('%s | SHIFT %.1f st TURN %.0f | DRIVE %s',
        tostring(reason),displacement,turn,result and 'OK' or 'FAIL')
end
function escape.begin(car,root,now,manual)
    if escape.active then return false end
    if not escape.enabled and not manual then return false end
    if not car or not root or not bridge.owns or lane.active then
        escape.note='NO ACTIVE NATIVE ROUTE';return false
    end
    local ph=livePhysics()
    local kmh=(ph and typeof(ph.v)=='Vector3') and ph.v.Magnitude*3.6 or root.AssemblyLinearVelocity.Magnitude*1.8
    if kmh>5 then escape.note='TOO FAST FOR REVERSE';return false end
    if cycle.stage~='QUEST' and cycle.stage~='RETURN_NPC' then
        escape.note='PAUSED: QUEST/NPC UI';return false
    end
    if now-escape.lastAttempt<5 then
        escape.note='ESCAPE REST '..math.ceil(5-(now-escape.lastAttempt))..'s'
        return false
    end
    if escape.perReset>=escape.maxPerReset then
        escape.note='MAX 2 REVERSE TRIES: WAIT FOR J';return false
    end
    -- Prefer the opposite side after each retry, but never use an unsafe side.
    local preferred=escape.lastSide==0 and 1 or -escape.lastSide
    local choices={preferred,-preferred}
    local pick=nil;local why='NO CLEAR REAR ROAD'
    for _,side in ipairs(choices) do
        local ok,msg=escape.rearClear(root,car,side)
        if ok then pick=side;break else why=(side<0 and 'LEFT ' or 'RIGHT ')..msg end
    end
    if not pick then escape.note=why;return false end
    local driver,vim=escape.driver()
    if not driver then escape.note='NO KEY INPUT API: REVERSE SKIPPED';return false end
    escape.inputDriver=driver;escape.vim=vim;escape.held={}
    escape.side=pick;escape.lastSide=pick
    escape.startPos=root.Position;escape.startForward=root.CFrame.LookVector
    escape.savedGoal=bridge.selectedGoal
    escape.savedSource=bridge.goalSource
    escape.savedObjective=bridge.activeObjective
    escape.savedStage=cycle.stage
    escape.attempts+=1;escape.perReset+=1;escape.lastAttempt=now
    escape.active=true;escape.phase='PREPARE';escape.phaseAt=now
    -- Pause native AutoDrive. Its gas/steer outputs otherwise fight keyboard input.
    escape.handoff=true
    stopNative('REVERSE RECOVERY PAUSE')
    escape.handoff=false
    escape.note='REVERSE PREP / '..(pick<0 and 'LEFT' or 'RIGHT')..' / '..driver
    return true
end
function escape.tick(now)
    if not escape.active then return end
    local car,root=carRoot()
    if not bridge.alive or not car or not root or not cycle or not cycle.enabled
        or cycle.stage~=escape.savedStage then
        escape.cancel('ABORT: QUEST/CAR CHANGED')
        return
    end
    local elapsed=now-escape.phaseAt
    if escape.phase=='PREPARE' and elapsed>=0.30 then
        if not escape.send('back',true) then
            escape.finish('INPUT REVERSE FAILED',now);return
        end
        escape.phase='BACK';escape.phaseAt=now
        escape.note='BACK STRAIGHT / '..escape.inputMode
    elseif escape.phase=='BACK' and elapsed>=0.70 then
        local key=escape.side<0 and 'left' or 'right'
        if not escape.send(key,true) then
            escape.finish('INPUT STEER FAILED',now);return
        end
        escape.phase='BACK_TURN';escape.phaseAt=now
        escape.note='BACK + '..string.upper(key)..' / '..escape.inputMode
    elseif escape.phase=='BACK_TURN' and elapsed>=0.85 then
        escape.releaseKeys()
        escape.phase='SETTLE';escape.phaseAt=now
        escape.note='RELEASING KEYS / CHECK MOTION'
    elseif escape.phase=='SETTLE' and elapsed>=0.40 then
        escape.finish('REVERSE COMPLETE',now)
    end
end
-- END REVERSE RECOVERY V6.3 ---------------------------------------------

local gui -- forward declaration: used by reward UI scanner below


-- SPEED V6: integrated from user's RayCity_Speed_Test_V2(2).lua ----------
-- Local, reversible physics parameters only. Does not guarantee server authority.
speedV6={enabled=false,targetKmh=220,assist=true,drive=nil,source='NONE',
    scanned=false,scanning=false,scanNote='READY',lastScan=0,lastTick=0,
    lastCar=nil,lastUI=0,boostPrimedUntil=0,boostOvercap=false,
    effectiveLimitKmh=nil, nativeLimitKmh=0, nativeLimitReason='WAIT',
    nativeTurnKmh=0, nativeHeading=nil, nativeThrottle=nil, nativeBrake=nil}
local speedOriginal=setmetatable({}, {__mode='k'})
local function physicsDriveValid(d)
    if type(d)~='table' then return false end
    local p=rawget(d,'phys')
    local params=type(p)=='table' and rawget(p,'p') or nil
    local car=WS:FindFirstChild('MyCar')
    return type(params)=='table' and type(rawget(params,'vmax'))=='number'
        and typeof(rawget(p,'v'))=='Vector3'
        and typeof(rawget(d,'car'))=='Instance' and rawget(d,'car')==car
end
local function physicsDriveFind()
    local d=gameService('RCDrive')
    if physicsDriveValid(d) then return d,'GAME SHARED' end
    if physicsDriveValid(speedV6.drive) then return speedV6.drive,speedV6.source end
    return nil,'NONE'
end
local function speedRestore()
    for p,snap in pairs(speedOriginal) do
        pcall(function()
            p.vmax=snap.vmax
            if type(p.torque)=='table' then
                for k,v in pairs(snap.torque) do p.torque[k]=v end
            end
        end)
    end
    speedOriginal=setmetatable({}, {__mode='k'})
end
local function speedSnapshot(p)
    if speedOriginal[p] then return speedOriginal[p] end
    local torque={}
    if type(p.torque)=='table' then
        for k,v in pairs(p.torque) do if type(v)=='number' then torque[k]=v end end
    end
    local s={vmax=p.vmax,torque=torque}
    speedOriginal[p]=s
    return s
end
local function speedScan()
    if speedV6.scanning then return end
    local d,source=physicsDriveFind()
    if d then speedV6.drive=d;speedV6.source=source;speedV6.scanNote='CONNECTED';return end
    speedV6.scanning=true;speedV6.scanNote='SCANNING'
    task.spawn(function()
        if type(getgc)~='function' then
            speedV6.scanNote='GETGC NOT AVAILABLE';speedV6.scanning=false;return
        end
        local ok,objects=pcall(function() return getgc(true) end)
        if not ok or type(objects)~='table' then
            speedV6.scanNote='GC BLOCKED';speedV6.scanning=false;return
        end
        local found=nil
        for i,v in pairs(objects) do
            if not bridge.alive then break end
            if type(v)=='table' then
                local checked,valid=pcall(physicsDriveValid,v)
                if checked and valid then found=v;break end
            end
            if type(i)=='number' and i%2000==0 then task.wait() end
        end
        if found and bridge.alive then
            speedV6.drive=found;speedV6.source='GC MATCH MYCAR'
            speedV6.scanNote='CONNECTED'
        else
            speedV6.scanNote='NO ACCESS'
        end
        speedV6.scanning=false
    end)
end
local function speedEnable(on)
    speedV6.enabled=on
    if on then
        local d,source=physicsDriveFind()
        if d then speedV6.drive=d;speedV6.source=source
        else speedScan() end
    else
        speedV6.boostPrimedUntil=0
        speedV6.boostOvercap=false
        speedV6.effectiveLimitKmh=nil
        speedRestore()
    end
end
local function speedTick(dt)
    if not speedV6.enabled then return end
    local d=speedV6.drive
    if not physicsDriveValid(d) then
        local found,source=physicsDriveFind()
        if found then d=found;speedV6.drive=d;speedV6.source=source
        elseif not speedV6.scanning and os.clock()-speedV6.lastScan>4 then
            speedV6.lastScan=os.clock();speedScan()
        end
    end
    if not physicsDriveValid(d) then return end
    local p=d.phys
    local original=speedSnapshot(p.p)
    -- The user's Speed value controls normal driving only. Native Boost may
    -- temporarily exceed it: 150 km/h normal -> up to 250 km/h with Boost.
    -- Manual Boost and Auto Boost use exactly the same p.boosting state.
    local stopping=bridge.activeDest and bridge.activeDest.stop==true
    local boosting=p.boosting==true
    local primed=os.clock()<speedV6.boostPrimedUntil
    local boostCap=boostVmaxKmh()
    speedV6.boostOvercap=(boosting or primed) and not stopping
    speedV6.effectiveLimitKmh=speedV6.boostOvercap and boostCap or speedV6.targetKmh
    p.p.vmax=speedV6.effectiveLimitKmh/3.6
    if type(p.p.torque)=='table' then
        for k,v in pairs(original.torque) do
            p.p.torque[k]=v*(stopping and 1 or 3)
        end
    end
    -- Let the game's own Boost physics handle acceleration. The optional
    -- extra speed assist must not inject additional velocity during Boost.
    if speedV6.boostOvercap then return end
    -- Optional modest forward assistance, only on open, nearly straight road.
    -- Never inject a velocity vector while braking, turning, airborne or near PASS.
    if stopping or not speedV6.assist or lane.active or not bridge.owns or p.inputLock or p.anyContact~=true
       or tonumber(p.throttle)==nil or p.throttle<0.8
       or tonumber(p.brake) and p.brake>0.1 then return end
    local native=activeState()
    if not native or native.active~=true or native.noRoute==true
       or (type(native.cosHeading)=='number' and native.cosHeading<0.985) then return end
    local car,root=carRoot()
    if not car or distanceToGoal(root)<150 or (bridge.hazardTtc and bridge.hazardTtc<3) then return end
    local flat=Vector3.new(root.CFrame.LookVector.X,0,root.CFrame.LookVector.Z)
    if flat.Magnitude<0.3 then return end
    flat=flat.Unit
    local forward=p.v:Dot(flat)
    if forward<4 or forward>=speedV6.targetKmh/3.6 then return end
    local delta=math.min(10*math.min(dt,0.05),speedV6.targetKmh/3.6-forward)
    p.v=p.v+flat*delta
end
-- END SPEED V6 ------------------------------------------------------------

-- QUEST CYCLE V4.4 ---------------------------------------------------------
-- The quest client itself listens for QuestPush.op='result' and validates
-- success on the server. Never infer victory simply from distance or GPS.
-- Reward dialog ("รับทั้งหมด(Enter)") is a *different* UI operation.
local QuestFolder=RS:FindFirstChild('RBRCQuest')
local QuestData=requireModule('RBRCQuest','QuestData')
local QuestRemotes=QuestFolder and QuestFolder:FindFirstChild('Remotes')
local QuestRequest=QuestRemotes and QuestRemotes:FindFirstChild('QuestRequest')
local QuestPush=QuestRemotes and QuestRemotes:FindFirstChild('QuestPush')
local RoadFightRequest=QuestRemotes and QuestRemotes:FindFirstChild('RoadFightRequest')
local RoadFightUI=requireModule('RBRCQuest','RoadFightUi')
local QuestUI=requireModule('RBRCQuest','QuestUI') -- game's native mission result display
local roundRandom=Random.new()
cycle={enabled=true,claim=true,returnNpc=true,accept=true,stage='IDLE',
    note='WAITING', questId=nil, npcId=nil, npcPos=nil, npcRange=10,
    lastResult=nil, resultAt=0, claimAt=0, claimed=false,
    targetNpc=nil, lastTalk=0, talkAttempts=0, lastAccept=0,
    acceptAttempts=0, justReturned=false, rewardAttempt=0, talkBusy=false,
    rewardMode='-', rewardWasShown=false, sentOffer=false,
    lastQuestStep=nil, lastQuestResult=nil, resultSignal=false,
    npcDriveAttempts=0,
    startedSignal=false,startedAt=0,replanAt=0,missionReady=false,
    waitQuestAt=0, acceptProtocol='-', roadFightOffer='-', rewardHandled=false,
    selectedRound=DEFAULT_ROUND, selectedQuestId=DERIX_ROUND_QUESTS[DEFAULT_ROUND],
    -- Toggle membership independently; only green rounds are allowed.
    roundEnabled={[1]=false,[2]=false,[3]=true,[4]=false},
    lastAcceptedRound=nil, randomCount=0,
    -- Diagnostics and bounded, delayed recovery for failed NPC accepts.
    lastAcceptError='-', lastAcceptErrorAt=0,
    retryCycles=0, retryWaitUntil=0, acceptConfirmed=false,
    -- V6.9: do not stay in FAILED after the server ended a quest.
    autoFailRetry=true,failCount=0,failStreak=0,failNextAt=0,
    failUiClosed=false,failRecoveryTrip=false,failNote='READY',
    failLastReason='-',failBlocked=false,
    autoDismissNpc=true, npcPopupsClosed=0, npcPopupNote='-', lastNpcPopupPoll=0}

local function enabledRounds()
    local rounds={}
    for i=1,4 do
        if cycle.roundEnabled[i]==true and DERIX_ROUND_QUESTS[i] then
            rounds[#rounds+1]=i
        end
    end
    return rounds
end

local function cycleStop(reason)
    if bridge.owns then stopNative(reason or 'CYCLE STOP') end
end

-- Preserve the real server response for diagnostics; never replace it with a
-- generic 'RETRIES EXHAUSTED' message before the user can see the reason.
local function serverReplyReason(response)
    if type(response)~='table' then return tostring(response) end
    local parts={}
    for _,key in ipairs({'reasonKey','reason','message','why','code','status'}) do
        local value=response[key]
        if value~=nil then parts[#parts+1]=key..'='..tostring(value) end
    end
    if #parts==0 then
        local keys={}
        for key in pairs(response) do keys[#keys+1]=tostring(key) end
        table.sort(keys)
        return 'no reason field (keys: '..table.concat(keys,',')..')'
    end
    return table.concat(parts,' / ')
end

local function rememberQuest(s)
    if type(s)~='table' then return end
    local questId=s.questId or (s.q and s.q.id)
    if questId then cycle.questId=questId end
    local giver=s.q and s.q.giverNpcId
    if giver then cycle.npcId=giver end
    if not QuestData then QuestData=requireModule('RBRCQuest','QuestData') end
    if QuestData and type(QuestData.get)=='function' and cycle.questId then
        local ok,q=pcall(QuestData.get,cycle.questId)
        if ok and type(q)=='table' then cycle.npcId=q.giverNpcId or cycle.npcId end
    end
    if type(cycle.npcId)=='number' then
        cycle.npcId='mission:'..tostring(math.floor(cycle.npcId))
    end
    if QuestData and type(QuestData.npc)=='function' and cycle.npcId then
        local ok,n=pcall(QuestData.npc,cycle.npcId)
        if ok and type(n)=='table' and typeof(n.position)=='Vector3' then
            cycle.npcPos=n.position
            cycle.npcRange=math.max(5,math.min(22,(tonumber(n.talkRangeM) or 5)*2))
        end
    end
    -- Derix and similar Road Fight quest-givers are not part of the normal
    -- QuestData NPC spatial index. RoadFightData.fights includes each NPC's
    -- server-authored world position (Derix: roadfight:1676).
    if not cycle.npcPos and type(cycle.npcId)=='string'
       and cycle.npcId:match('^roadfight:%d+$') then
        local rf=requireModule('RBRCQuest','RoadFightData')
        local rid=tonumber(cycle.npcId:match('(%d+)$'))
        if rf and type(rf.fights)=='table' then
            for _,entry in pairs(rf.fights) do
                if type(entry)=='table' and tonumber(entry.npcId)==rid then
                    local p=entry.pos
                    if type(p)=='table' and tonumber(p[1]) and tonumber(p[2]) and tonumber(p[3]) then
                        cycle.npcPos=Vector3.new(p[1],p[2],p[3]);cycle.npcRange=10
                        break
                    end
                end
            end
        end
    end
end

local function setDerixReturnNpc()
    -- Derix quest-giver is NOT in QuestData's normal NPC spatial index.
    -- Resolve only from the game's RoadFightData, never an invented position.
    cycle.npcId=START_NPC_ID
    local rf=requireModule('RBRCQuest','RoadFightData')
    local id=tonumber(START_NPC_ID:match('(%d+)$'))
    if rf and type(rf.fights)=='table' then
        for _,entry in pairs(rf.fights) do
            if type(entry)=='table' and tonumber(entry.npcId)==id then
                local p=entry.pos
                if type(p)=='table' and tonumber(p[1]) and tonumber(p[2])
                   and tonumber(p[3]) then
                    cycle.npcPos=Vector3.new(p[1],p[2],p[3])
                    cycle.npcRange=10
                    return true
                end
            end
        end
    end
    -- If data is not ready, approachNpc will perform its normal lookup.
    cycle.npcPos=nil
    return false
end
local function isDerixQuest(id)
    for _,qid in pairs(DERIX_ROUND_QUESTS) do
        if tostring(id or '')==tostring(qid) then return true end
    end
    return false
end

if QuestPush and QuestPush:IsA('RemoteEvent') then
    QuestPush.OnClientEvent:Connect(function(packet)
        if not bridge.alive or not cycle.enabled or type(packet)~='table' then return end
        local msg=packet.op=='mirror' and packet.msg or packet
        if type(msg)~='table' then return end
        if msg.op=='accepted' or msg.op=='started' then
            cycle.acceptConfirmed=true
            cycle.acceptAttempts=0
            cycle.retryCycles=0
            cycle.retryWaitUntil=0
            cycle.lastAcceptError='-'
            cycle.failNextAt=0
            cycle.failUiClosed=false
            cycle.failRecoveryTrip=false
            cycle.failBlocked=false
            cycle.failNote='SERVER '..msg.op
            if msg.mission then rememberQuest(msg.mission) end
            cycle.stage=(msg.op=='started' and bridge.owns) and 'QUEST' or 'WAIT_QUEST'
            cycle.note='QUEST '..msg.op..' BY SERVER'
            if msg.op=='started' then
                cycle.startedSignal=true;cycle.startedAt=os.clock();cycle.waitQuestAt=0
            else
                cycle.waitQuestAt=os.clock()
            end
            cycle.resultSignal=false;cycle.claimed=false
            cycle.lastResult=nil;cycle.rewardWasShown=false
        elseif msg.op=='objective' then
            if cycle.stage=='QUEST' then
                cycle.replanAt=os.clock()+1.0
                cycle.note='OBJECTIVE UPDATED: REPLAN IN 1s'
            end
        elseif msg.op=='result' then
            -- Server result is the only completion signal; failures do not loop.
            cycle.acceptConfirmed=false
            cycle.acceptAttempts=0
            cycle.resultSignal=true
            cycle.startedSignal=false
            cycle.replanAt=0
            cycle.lastResult=msg.success==true
            cycle.resultAt=os.clock()
            if msg.questId then cycle.questId=msg.questId end
            if msg.npcId then cycle.npcId=msg.npcId end
            rememberQuest({questId=cycle.questId})
            if cycle.lastResult then
                cycle.failStreak=0
                cycle.failRecoveryTrip=false
                cycle.failNote='LAST QUEST SUCCESS'
                cycle.stage='CLAIM';cycle.note='SERVER RESULT: SUCCESS' 
                task.defer(function()
                    if bridge.owns then cycleStop('QUEST SUCCESS - DO NOT CHASE OLD PASS') end
                end)
            else
                -- Only a real server result triggers recovery. Never mark an
                -- incomplete PASS as failed based on distance or GPS timeout.
                local why=tostring(msg.reasonKey or msg.reason or msg.message or
                    msg.why or 'SERVER RESULT: success=false')
                cycle.failLastReason=why
                cycle.failCount+=1
                cycle.failStreak+=1
                cycle.failUiClosed=false
                cycle.failRecoveryTrip=false
                cycle.failBlocked=false
                local lower=string.lower(why)
                if lower:find('anticheat',1,true) or lower:find('anti-cheat',1,true)
                   or lower:find('bot detected',1,true) or lower:find('suspicious',1,true)
                   or lower:find('banned',1,true) then
                    cycle.failBlocked=true
                end
                local delaySeconds=math.min(40,4+4*math.min(cycle.failStreak-1,8))
                cycle.failNextAt=os.clock()+delaySeconds
                cycle.stage='FAILED'
                cycle.failNote='SERVER FAILED / RETRY IN '..delaySeconds..'s'
                cycle.note='QUEST FAILED: '..why..' / '..cycle.failNote
                -- Stop tracking a stale checkpoint. Do not run J/reset or a
                -- lane return toward the completed quest after this packet.
                task.defer(function()
                    if not bridge.alive then return end
                    if bridge.owns then cycleStop('QUEST FAILED - CANCEL OLD PASS') end
                    unstuck.pending=false;unstuck.lowSince=nil
                    lane.manual=false
                    releaseNpcParking()
                end)
            end
        end
    end)
else
    cycle.note='QuestPush not accessible: auto loop needs server result'
end

local function visibleGui(g)
    if not g or not g.Parent or not g:IsA('GuiObject') then return false end
    if not g.Visible then return false end
    local node=g.Parent
    while node and node~=pg do
        if node:IsA('ScreenGui') and not node.Enabled then return false end
        if node:IsA('GuiObject') and not node.Visible then return false end
        node=node.Parent
    end
    return true
end

local function clickableParent(node)
    local p=node
    for i=1,5 do
        if not p or p==pg then return nil end
        if p:IsA('GuiButton') and visibleGui(p) then return p end
        p=p.Parent
    end
    return nil
end
local function rewardModalVisible()
    for _,node in ipairs(pg:GetDescendants()) do
        if (node:IsA('TextLabel') or node:IsA('TextButton'))
           and visibleGui(node) then
            local t=string.lower(node.Text or '')
            if t:find('รับไอเท็ม',1,true) or t:find('receive item',1,true) then
                return true
            end
        end
    end
    return false
end

local function collectButtons(mode)
    local found={}
    local seen={}
    for _,node in ipairs(pg:GetDescendants()) do
        if (node:IsA('TextLabel') or node:IsA('TextButton')) and visibleGui(node) then
            local label=string.lower(node.Text or '')
            local good=false
            if mode=='reward' then
                good=(label:find('รับทั้งหมด',1,true)~=nil
                   or label:find('รับไอเท็ม',1,true)~=nil
                   or label:find('take all',1,true)~=nil
                   or label:find('collect all',1,true)~=nil)
                and label:find('ยกเลิก',1,true)==nil
                and label:find('cancel',1,true)==nil
            elseif mode=='offer' then
                good=(label:find('ตกลง',1,true)~=nil
                   or label:find('รับเควส',1,true)~=nil
                   or label:find('เริ่ม',1,true)~=nil
                   or label:find('accept',1,true)~=nil
                   or label=='ok')
                   and label:find('ยกเลิก',1,true)==nil
                   and label:find('cancel',1,true)==nil
            end
            if good then
                local button=clickableParent(node)
                if button and not seen[button] then
                    -- Never click our own HUD or an ambiguous unrelated popup.
                    if not button:IsDescendantOf(gui) then
                        seen[button]=true;found[#found+1]={button=button,text=label}
                    end
                end
            end
        end
    end
    return found
end

-- The real reward UI shows "รับทั้งหมด(Enter)" in the user screenshot.
-- Attempt a native GUI activation, then an executor signal as an alternative.
local function activateButton(button)
    if not button or not visibleGui(button) then return false,'not-visible' end
    local ok,err=pcall(function() button:Activate() end)
    if ok then return true,'GuiButton.Activate' end
    if type(firesignal)=='function' then
        ok,err=pcall(firesignal,button.Activated)
        if ok then return true,'Activated signal' end
        ok,err=pcall(firesignal,button.MouseButton1Click)
        if ok then return true,'Click signal' end
    end
    return false,tostring(err)
end
local function nativeEnterForReward()
    -- Used ONLY while a recognized 'take all (Enter)' reward dialog is open.
    -- VirtualInputManager may be restricted on Android/Delta; the caller
    -- checks the dialog afterwards and will not claim success blindly.
    local ok,vim=pcall(game.GetService,game,'VirtualInputManager')
    if ok and vim then
        local pressed=pcall(vim.SendKeyEvent,vim,true,Enum.KeyCode.Return,false,game)
        if pressed then
            task.delay(0.10,function()
                pcall(vim.SendKeyEvent,vim,false,Enum.KeyCode.Return,false,game)
            end)
            return true,'VIM Return'
        end
    end
    if type(keypress)=='function' and type(keyrelease)=='function' then
        local pressed=pcall(keypress,0x0D)
        if pressed then
            task.delay(0.10,function() pcall(keyrelease,0x0D) end)
            return true,'Executor Return'
        end
    end
    return false,'no keyboard-injection API'
end

local function tryClaimReward(now)
    if not cycle.enabled or cycle.stage~='CLAIM' then return end
    local buttons=collectButtons('reward')
    if cycle.claimed then
        if #buttons==0 and now-cycle.claimAt>=0.65 then
            cycle.rewardMode='CLAIM UI CLOSED'
            cycle.stage=cycle.returnNpc and 'RETURN_NPC' or 'DONE'
            cycle.note='REWARD CONFIRMED; RETURN NPC'
            return
        elseif #buttons>0 and now-cycle.claimAt>1.3 then
            cycle.claimed=false
            local one=buttons[1]
            if #buttons==1 and one.text:find('enter',1,true) then
                local ok,how=nativeEnterForReward()
                if ok then
                    cycle.claimed=true;cycle.claimAt=now
                    cycle.rewardMode=how
                    cycle.note='CLAIM ENTER FALLBACK; CHECKING UI'
                    return
                end
            end
            cycle.note='CLAIM UI STILL OPEN; RETRYING'
        end
    end
    if not cycle.claim then
        cycle.note=#buttons>0 and 'CLAIM DISABLED: PLEASE TAKE REWARD' or 'CLAIM DISABLED'
        return
    end
    if now-cycle.rewardAttempt<1.5 then return end
    cycle.rewardAttempt=now
    if #buttons==1 then
        cycle.rewardWasShown=true
        local ok,how=activateButton(buttons[1].button)
        cycle.rewardMode=ok and how or ('UI failed: '..tostring(how))
        cycle.note=ok and 'REWARD: ACTIVATION SENT, CHECKING UI' or cycle.rewardMode
        if ok then cycle.claimed=true;cycle.claimAt=now end
    elseif #buttons>1 then
        cycle.note='REWARD: AMBIGUOUS BUTTONS '..#buttons
    elseif cycle.rewardWasShown then
        -- The button disappeared after a real activation or user input.
        cycle.rewardMode='BUTTON DISAPPEARED'
        cycle.stage=cycle.returnNpc and 'RETURN_NPC' or 'DONE'
        cycle.note='REWARD DISMISSED; RETURN NPC'
    elseif rewardModalVisible() then
        cycle.rewardMode='ITEM WINDOW DETECTED'
        cycle.note='BOX VISIBLE BUT TAKE-ALL BUTTON NOT FOUND'
    elseif now-cycle.resultAt>10 then
        -- Missions without an item-box UI have server-issued mission rewards.
        cycle.rewardMode='NO BOX FOR THIS QUEST'
        cycle.stage=cycle.returnNpc and 'RETURN_NPC' or 'DONE'
        cycle.note='QUEST SUCCESS: RETURN NPC'
    end
end

local function approachNpc(now)
    if cycle.stage~='RETURN_NPC' or not cycle.enabled then return end
    if not cycle.npcPos then
        rememberQuest({questId=cycle.questId})
        if not cycle.npcPos then
            cycle.note='NPC POSITION NOT IN QUESTDATA ('..tostring(cycle.npcId)..')'
            cycle.stage='NEED_NPC';return
        end
    end
    local car,root=carRoot()
    if not car or not root then cycle.note='WAITING FOR CAR';return end
    local dist=(xz(root.Position)-xz(cycle.npcPos)).Magnitude
    local active=activeState()
    if dist<=math.max(5,cycle.npcRange-2) then
        local p=livePhysics()
        local kmh=(p and typeof(p.v)=='Vector3') and p.v.Magnitude*3.6
            or root.AssemblyLinearVelocity.Magnitude*1.8
        -- Merely entering range at 50+ km/h is NOT being parked at the NPC.
        if kmh>5 then
            setNpcParking(car,now)
            cycle.note=string.format('NPC FINAL BRAKE: %.0f km/h / %.0f studs',kmh,dist)
            return
        end
        cycleStop('NPC STOPPED / TALK')
        setNpcParking(car,now)
        -- Allow every completed round to start with a fresh return-trip budget.
        cycle.npcDriveAttempts=0
        cycle.stage='TALK';cycle.justReturned=true
        cycle.note=string.format('NPC PARKED %.1f km/h / %.0f studs',kmh,dist)
        return
    end
    if bridge.owns and active and active.active then
        cycle.note='RETURN TO NPC '..math.floor(dist)..' studs / PROGRESSIVE APPROACH'
        return
    end
    if now-cycle.lastTalk<4 then return end
    cycle.lastTalk=now
    cycle.npcDriveAttempts+=1
    if cycle.npcDriveAttempts>6 then
        if cycle.failRecoveryTrip and cycle.autoFailRetry then
            cycle.retryCycles+=1
            local pause=math.min(180,20*2^(math.min(cycle.retryCycles-1,4)))
            cycle.retryWaitUntil=now+pause
            cycle.npcDriveAttempts=0
            cycle.stage='RETRY_WAIT'
            cycle.note='NPC ROUTE FAILED: RETRY IN '..pause..'s'
            cycle.failNote=cycle.note
        else
            cycle.stage='NEED_NPC'
            cycle.note='FAILED TO REACH NPC AFTER 6 ROAD ROUTES'
        end
        return
    end
    local target=cycle.npcPos
    -- NPC may stand on the sidewalk; drive to the nearest road accessible
    -- position ONLY when still inside the server's talk radius.
    if NAV and type(NAV.snapToRoad)=='function' then
        local ok,p=pcall(NAV.snapToRoad,target,{level=65535})
        if ok and typeof(p)=='Vector3' then
            if (xz(p)-xz(cycle.npcPos)).Magnitude<cycle.npcRange-1 then target=p end
        end
    end
    local objective={dest={stop=true},roadInside=true,kind='npc'}
    cycle.note='ROUTING NPC '..math.floor(dist)..' studs'
    startNative(target,'RETURN NPC '..tostring(cycle.npcId),objective)
end

-- Request the same Road Fight mission as the on-screen "ประลอง" button.
-- RoadFight is NOT QuestRequest: the game uses RBRCQuest.Remotes.RoadFightRequest.
local function roadFightTalkAccept(root,now)
    if not RoadFightRequest or not RoadFightRequest:IsA('RemoteFunction') then
        return false,'RoadFightRequest missing'
    end
    local npcId=tonumber(tostring(cycle.npcId or ''):match('^roadfight:(%d+)$'))
    if not npcId then return false,'invalid RoadFight NPC' end
    local ok,res=pcall(function()
        return RoadFightRequest:InvokeServer({op='talk',npcId=npcId,carPos=root.Position})
    end)
    if not ok or type(res)~='table' or res.ok~=true then
        return false,'RoadFight TALK denied: '..serverReplyReason(res)
    end
    -- Randomize only among green buttons AND server-playable NPC offers.
    -- Gray buttons never enter the pool; unavailable rounds are skipped.
    local offered={}
    for _,m in ipairs(type(res.missions)=='table' and res.missions or {}) do
        local obj=type(m)=='table' and (m.m or m) or nil
        if obj and obj.questId then offered[tostring(obj.questId)]=obj end
    end
    local candidates={}
    for _,round in ipairs(enabledRounds()) do
        local offer=offered[DERIX_ROUND_QUESTS[round]]
        if offer and offer.canAccept==true then
            candidates[#candidates+1]={round=round,offer=offer}
        end
    end
    if #candidates==0 then
        cycle.roadFightOffer='NO PLAYABLE GREEN ROUND'
        return false,'No enabled/available Derix round (check green buttons and unlocks)'
    end
    -- When possible, don't repeat the immediately previous successful round.
    local pool={}
    if #candidates>1 then
        for _,item in ipairs(candidates) do
            if item.round~=cycle.lastAcceptedRound then pool[#pool+1]=item end
        end
    end
    if #pool==0 then pool=candidates end
    local chosen=pool[roundRandom:NextInteger(1,#pool)]
    local match=chosen.offer
    local wanted=tostring(match.questId)
    cycle.roadFightOffer='R'..chosen.round..' '..wanted..' canAccept=true'
    local _,fresh=carRoot()
    if not fresh or not cycle.npcPos or
       (xz(fresh.Position)-xz(cycle.npcPos)).Magnitude>cycle.npcRange+2 then
        return false,'out of NPC talk range'
    end
    local ok2,accept=pcall(function()
        return RoadFightRequest:InvokeServer({op='accept',questId=match.questId,carPos=fresh.Position})
    end)
    if not ok2 or type(accept)~='table' or accept.ok~=true then
        return false,'RoadFight R'..chosen.round..' accept denied: '..serverReplyReason(accept)
    end
    cycle.selectedRound=chosen.round
    cycle.selectedQuestId=wanted
    cycle.questId=wanted
    cycle.lastAcceptedRound=chosen.round
    cycle.randomCount+=1
    if RoadFightUI and type(RoadFightUI.close)=='function' then
        pcall(RoadFightUI.close)
    end
    cycle.acceptProtocol='RoadFightRequest'
    return true,'RANDOM R'..chosen.round..' accepted ('..wanted..') # '..cycle.randomCount
end

local function normalQuestTalkAccept(root)
    if not QuestRequest or not QuestRequest:IsA('RemoteFunction') then
        return false,'QuestRequest unavailable'
    end
    local pos=root.Position
    local ok,res=pcall(function()
        return QuestRequest:InvokeServer({op='talk',npcId=cycle.npcId,carPos=pos})
    end)
    if not ok or type(res)~='table' or res.ok~=true then
        return false,'NPC TALK DENIED: '..serverReplyReason(res)
    end
    local choice=nil
    for _,offer in ipairs(type(res.offers)=='table' and res.offers or {}) do
        if type(offer)=='table' and tostring(offer.questId)==tostring(cycle.questId) then
            choice=offer;break
        end
    end
    if not choice then return false,'no same quest offered' end
    local _,fresh=carRoot()
    if not fresh or not cycle.npcPos or
       (xz(fresh.Position)-xz(cycle.npcPos)).Magnitude>cycle.npcRange+1 then
        return false,'moved out of talk range'
    end
    local ok2,result=pcall(function()
        return QuestRequest:InvokeServer({op='accept',questId=choice.questId,
            carPos=fresh.Position,carLook=fresh.CFrame.LookVector})
    end)
    if ok2 and type(result)=='table' and result.ok==true then
        cycle.acceptProtocol='QuestRequest'
        return true,'Quest ACCEPTED; awaiting server start'
    end
    return false,'NPC ACCEPT DENIED: '..serverReplyReason(result)
end

local function talkAndAccept(now)
    if cycle.stage~='TALK' or not cycle.enabled then return end
    local _,root=carRoot()
    if not root then return end
    if not cycle.npcPos or (xz(root.Position)-xz(cycle.npcPos)).Magnitude>cycle.npcRange+1 then
        cycle.stage='RETURN_NPC';return
    end
    if not cycle.accept then
        cycle.stage='DONE';cycle.note='AT NPC - AUTO ACCEPT DISABLED';return
    end
    local current=rawQuestState()
    if cycle.failRecoveryTrip and current and current.state=='running'
       and now-cycle.resultAt<15 then
        -- A local Quest mirror can lag behind the authoritative failed result.
        -- Give it time to clear, then let the server validate each new talk.
        cycle.note='WAIT CLIENT QUEST MIRROR TO CLEAR'
        return
    end
    if type(cycle.npcId)=='string' and cycle.npcId:match('^roadfight:%d+$')
       and #enabledRounds()==0 then
        cycle.note='NO GREEN ROUNDS: ENABLE R1-R4 TO CONTINUE'
        return
    end
    -- Once an accept is confirmed, wait for the server's started event. Do
    -- not send the same accept request again just because navigation is slow.
    if cycle.acceptConfirmed then
        cycle.stage='WAIT_QUEST'
        cycle.waitQuestAt=cycle.waitQuestAt>0 and cycle.waitQuestAt or now
        cycle.note='ALREADY ACCEPTED: WAIT SERVER START'
        return
    end
    if cycle.talkBusy or now-cycle.lastAccept<5 then return end
    cycle.lastAccept=now
    cycle.acceptAttempts+=1
    cycle.talkBusy=true
    cycle.note='CHALLENGE ATTEMPT '..cycle.acceptAttempts..'/4 / '..tostring(cycle.npcId)
    task.spawn(function()
        local ok,success,message=pcall(function()
            if type(cycle.npcId)=='string' and cycle.npcId:match('^roadfight:%d+$') then
                return roadFightTalkAccept(root,os.clock())
            end
            return normalQuestTalkAccept(root)
        end)
        cycle.talkBusy=false
        if not bridge.alive or not cycle.enabled or cycle.stage~='TALK' then return end
        if ok and success==true then
            cycle.stage='WAIT_QUEST'
            cycle.waitQuestAt=os.clock()
            cycle.acceptConfirmed=true
            cycle.note=tostring(message)..' / WAIT SERVER START'
            cycle.acceptAttempts=0
            cycle.retryCycles=0
            cycle.retryWaitUntil=0
            cycle.lastAcceptError='-'
        else
            local why=ok and tostring(message) or ('CHALLENGE ERROR '..tostring(success))
            cycle.lastAcceptError=why
            cycle.lastAcceptErrorAt=os.clock()
            cycle.note='ACCEPT FAIL '..cycle.acceptAttempts..'/4: '..why
            -- An explicit bot/security restriction is not a transient error.
            -- Leave it visible for manual review rather than repeatedly trying.
            local lower=string.lower(why)
            if lower:find('anticheat',1,true) or lower:find('anti-cheat',1,true)
               or lower:find('bot detected',1,true) or lower:find('suspicious',1,true)
               or lower:find('banned',1,true) then
                cycle.stage='NEED_NPC'
                cycle.note='SERVER RESTRICTION: '..why
                return
            end
            -- Four failures pause the accept process; do not permanently enter
            -- NEED_NPC, and do not spam the server every frame.
            if cycle.acceptAttempts>=4 then
                cycle.retryCycles+=1
                local delaySeconds=math.min(180, 20*2^(math.min(cycle.retryCycles-1,4)))
                cycle.retryWaitUntil=os.clock()+delaySeconds
                cycle.acceptAttempts=0
                cycle.stage='RETRY_WAIT'
                cycle.note='ACCEPT RETRY IN '..delaySeconds..'s | '..why
            end
        end
    end)
end

local function cycleTick(now)
    if not cycle.enabled or escape.active then return end
    local raw=rawQuestState()
    if raw and raw.state=='running' then
        rememberQuest(raw)
        -- Pending accepted state may need boarding; do not restart native
        -- while game controls boarding, only begin when running.
        if cycle.stage=='WAIT_QUEST' or cycle.stage=='RETRY_WAIT'
           or cycle.stage=='TALK' or cycle.stage=='NEED_NPC'
           or (cycle.stage=='IDLE' and bridge.armed) then
            cycle.stage='QUEST';cycle.note='QUEST RUNNING'
            if not bridge.owns and now-bridge.lastRequestAt>2 then
                local t,source,obj=chooseDestination()
                if t then startNative(t,source,obj) end
            end
        end
    end
    -- V6.9: the old code left FAILED forever. Resume only after the game
    -- has supplied a definitive result and the failed mission is no longer
    -- running. Do not click an unrelated 'Continue' reward popup.
    if cycle.stage=='FAILED' then
        if not cycle.failUiClosed and now-cycle.resultAt>=2.5 then
            if not QuestUI then QuestUI=requireModule('RBRCQuest','QuestUI') end
            if QuestUI and type(QuestUI.hideResult)=='function' then
                local ok=pcall(QuestUI.hideResult)
                cycle.failNote=ok and 'FAIL RESULT HIDDEN' or 'FAIL UI AUTOHIDE'
            end
            cycle.failUiClosed=true
        end
        if not cycle.autoFailRetry then
            cycle.failNote='AUTO FAIL RETRY OFF: MANUAL START'
        elseif cycle.failBlocked then
            cycle.failNote='SERVER RESTRICTION: MANUAL REVIEW'
        elseif #enabledRounds()==0 then
            cycle.failNote='NO GREEN ROUNDS: ENABLE R1-R4'
        elseif raw and raw.state=='running' and now-cycle.resultAt<10 then
            cycle.failNote='WAIT CLIENT QUEST MIRROR TO CLEAR'
        elseif now<cycle.failNextAt then
            cycle.failNote='RETURN NPC IN '..math.ceil(cycle.failNextAt-now)..'s'
        else
            -- Never reuse the old PASS goal. Restore the real quest NPC.
            local derix=isDerixQuest(cycle.questId)
                or cycle.npcId==START_NPC_ID
            if derix then setDerixReturnNpc() end
            cycle.startedSignal=false
            cycle.acceptConfirmed=false
            cycle.acceptAttempts=0
            cycle.npcDriveAttempts=0
            cycle.retryCycles=0
            cycle.retryWaitUntil=0
            cycle.waitQuestAt=0
            cycle.lastTalk=0
            cycle.lastAccept=0
            cycle.claimed=false
            cycle.replanAt=0
            cycle.failRecoveryTrip=true
            cycle.failNextAt=0
            cycle.stage='RETURN_NPC'
            cycle.failNote='RETURNING TO NPC FOR RANDOM QUEST'
            cycle.note='FAILED QUEST RECOVERY: RETURN NPC'
        end
        if cycle.stage=='FAILED' then
            cycle.note='FAILED #'..cycle.failCount..' | '..cycle.failNote
        end
    end
    if cycle.stage=='WAIT_QUEST' and not bridge.owns and cycle.waitQuestAt>0
       and now-cycle.waitQuestAt>10 and not cycle.startedSignal then
        if cycle.acceptConfirmed then
            -- A successful accept reply is not an assurance of a running quest.
            -- Wait for server 'started' or a genuine running quest state.
            -- Re-accepting at 10s caused duplicate requests and dead-end retries.
            cycle.note='ACCEPTED / WAIT SERVER START '..math.floor(now-cycle.waitQuestAt)..'s'
        else
            cycle.stage='TALK'
            cycle.note='NO ACCEPT CONFIRMATION: RETRY TALK'
            cycle.waitQuestAt=0
        end
    end
    if cycle.stage=='RETRY_WAIT' then
        if now>=cycle.retryWaitUntil then
            -- Revalidate distance to the NPC before trying a new challenge.
            -- This keeps retries bounded without resetting the whole script.
            cycle.acceptConfirmed=false
            cycle.stage='RETURN_NPC'
            cycle.note='RETRY COOLDOWN OVER: RECHECK NPC'
        else
            cycle.note='ACCEPT RETRY IN '..math.ceil(cycle.retryWaitUntil-now)..
                's | '..cycle.lastAcceptError
        end
    end
    -- Delta may not see the game's shared.RBRCQuest table. QuestPush
    -- events are the authoritative fallback for quest start / next PASS.
    if cycle.stage=='WAIT_QUEST' and cycle.startedSignal
       and now-cycle.startedAt>0.8 and not bridge.owns then
        local t,source,obj=chooseDestination()
        if t and startNative(t,source,obj) then
            cycle.stage='QUEST';cycle.note='STARTED FROM QUESTPUSH/GPS'
        else
            cycle.note='WAIT GPS AFTER START'
        end
    end
    if cycle.stage=='QUEST' and cycle.replanAt>0
       and now>=cycle.replanAt then
        cycle.replanAt=0
        local target,source,obj=chooseDestination()
        if target and (typeof(bridge.selectedGoal)~='Vector3'
            or (xz(target)-xz(bridge.selectedGoal)).Magnitude>12) then
            if startNative(target,source,obj) then
                cycle.note='NEXT PASS: NEW GAME GUIDE'
            end
        end
    end
    if cycle.stage=='CLAIM' then tryClaimReward(now)
    elseif cycle.stage=='RETURN_NPC' then approachNpc(now)
    elseif cycle.stage=='TALK' then talkAndAccept(now)
    end
end
-- A duplicate RoadFight prompt may appear when NPC proximity code opens UI
-- after RoadFightRequest.accept already succeeded. In the game's RoadFightUi,
-- the 'refuse' callback only calls closeWindow() -> RoadFightUi.close().
-- Therefore we close THIS dialog only; no rejection Remote is sent to server.
local function dismissDuplicateNpcDialog(now)
    if not cycle.enabled or not cycle.autoDismissNpc then return end
    if cycle.acceptProtocol ~= 'RoadFightRequest' then return end
    if cycle.stage ~= 'WAIT_QUEST' and cycle.stage ~= 'QUEST' then return end
    if now-cycle.lastNpcPopupPoll < 0.35 then return end
    cycle.lastNpcPopupPoll=now
    if not RoadFightUI then RoadFightUI=requireModule('RBRCQuest','RoadFightUi') end
    if not RoadFightUI then
        cycle.npcPopupNote='RoadFightUi unavailable'
        return
    end
    if type(RoadFightUI.isOpen)~='function' or type(RoadFightUI.close)~='function' then
        cycle.npcPopupNote='RoadFightUi no close API'
        return
    end
    local checked, opened=pcall(RoadFightUI.isOpen)
    if not checked then
        cycle.npcPopupNote='NPC popup check failed'
        return
    end
    if opened == true then
        local ok, closed=pcall(RoadFightUI.close)
        if ok and closed==true then
            cycle.npcPopupsClosed+=1
            cycle.npcPopupNote='CLOSED DUPLICATE #'..cycle.npcPopupsClosed
        else
            cycle.npcPopupNote='NPC popup close failed'
        end
    end
end
-- AUTO UNSTUCK ------------------------------------------------------------
-- Actual game RCDriveClient dispatch: AutoCmd='resetKey' -> resetKey() ->
-- resetAllowed() -> resetCar(false), same game action as pressing J.
-- 'reset' is intentionally NOT used: it bypasses the normal J cooldown gate.
local function nativeSpeedKmh(root)
    local p=livePhysics()
    if p and typeof(p.v)=='Vector3' then
        return p.v.Magnitude*3.6
    end
    -- Roblox positional velocities use studs/sec; this game uses 2 studs/m.
    return root.AssemblyLinearVelocity.Magnitude*1.8
end

local function safeToRecover(root, state)
    if not unstuck.enabled or not bridge.alive or not bridge.owns
       or not state or state.active~=true or not root then return false end
    if cycle.stage~='QUEST' and cycle.stage~='RETURN_NPC' then return false end
    if cycle.talkBusy or cycle.stage=='WAIT_QUEST' or lane.active then return false end
    if distanceToGoal(root)<20 then return false end
    if cycle.stage=='RETURN_NPC' and cycle.npcPos and
       (xz(root.Position)-xz(cycle.npcPos)).Magnitude <
           math.max(20,(cycle.npcRange or 10)+12)
    then return false end
    if bridge.activeDest and type(bridge.activeDest.poly)=='table' and
       pointInPolygon(root.Position,bridge.activeDest.poly) then return false end
    return true
end

local function unstuckTick(now)
    if escape.active then return end
    if now-unstuck.lastCheck<unstuck.checkPeriod then return end
    unstuck.lastCheck=now
    if unstuck.pending then
        unstuck.note='J SENT / WAIT RESET'
        -- Let the game's own reset routine place the car before replanning.
        if now-unstuck.pendingAt<1.8 then return end
        unstuck.pending=false
        unstuck.ignoreWarpUntil=now+4
        local goal,src,obj=unstuck.savedGoal,unstuck.savedSource,unstuck.savedObjective
        local car,root=carRoot()
        if cycle.stage=='QUEST' then
            local updated,why,objective=chooseDestination()
            if typeof(updated)=='Vector3' then
                goal,src,obj=updated,why,objective
            end
        elseif cycle.stage=='RETURN_NPC' and cycle.npcPos then
            -- Do not reroute towards a completed quest's old PASS area.
            goal=cycle.npcPos
            src='RETURN NPC AFTER J'
            obj={dest={stop=true},roadInside=true,kind='npc'}
        else
            unstuck.note='NO REPLAN: '..tostring(cycle.stage)
            return
        end
        if car and root and typeof(goal)=='Vector3' and bridge.alive then
            local ok=startNative(goal,src or 'AFTER J',obj)
            unstuck.note=ok and 'J DONE / ROAD REPLANNED' or 'J DONE / ROUTE FAILED'
            if ok then unstuck.successes+=1 end
        else
            unstuck.note='J DONE / CAR OR GOAL MISSING'
        end
        return
    end

    local car,root=carRoot()
    local state=activeState()
    if not safeToRecover(root,state) then
        unstuck.lowSince=nil
        unstuck.eta=0
        if not unstuck.enabled then unstuck.note='OFF'
        elseif cycle.stage=='TALK' or cycle.stage=='CLAIM' or cycle.stage=='WAIT_QUEST' then
            unstuck.note='PAUSED / QUEST UI'
        elseif root and distanceToGoal(root)<20 then
            unstuck.note='PAUSED / NEAR DEST'
        else
            unstuck.note='IDLE'
        end
        return
    end

    local speed=nativeSpeedKmh(root)
    unstuck.speed=speed
    if speed>=unstuck.thresholdKmh then
        unstuck.lowSince=nil
        unstuck.eta=0
        unstuck.note='MOVING '..math.floor(speed+0.5)..' km/h'
        unstuck.healthySince=unstuck.healthySince or now
        if now-unstuck.healthySince>=2.0 then
            unstuck.streak=0;escape.perReset=0
        end
        return
    end
    unstuck.healthySince=nil
    unstuck.lowSince=unstuck.lowSince or now
    local elapsed=now-unstuck.lowSince
    unstuck.eta=math.max(0,unstuck.triggerSeconds-elapsed)
    unstuck.note=string.format('LOW %.1f / %.1fs',speed,elapsed)
    if elapsed<unstuck.triggerSeconds then return end
    if now-unstuck.lastRequest<unstuck.cooldownSeconds then
        local remaining=unstuck.cooldownSeconds-(now-unstuck.lastRequest)
        unstuck.note='J COOLDOWN '..math.ceil(remaining)..'s'
        -- The game J key is still on cooldown; do not spam it.
        -- After the reset has settled, attempt a brief safe keyboard reverse.
        if escape.enabled and not unstuck.pending
            and now-unstuck.lastRequest>=3.5
            and escape.perReset<escape.maxPerReset then
            local attempted=escape.begin(car,root,now,false)
            if attempted then unstuck.note='REVERSE RECOVERY IN PROGRESS'
            elseif escape.note~='OFF: ENABLE TO TEST' then unstuck.note=escape.note end
        end
        return
    end
    if unstuck.streak>=3 then
        unstuck.note='J LIMIT 3: STOP FOR MANUAL CHECK'
        cycleStop('UNSTUCK LIMIT')
        return
    end
    -- Other actions (boost/jump/slide) share the single AutoCmd channel.
    if car:GetAttribute('AutoCmd')~=nil then
        unstuck.note='WAIT AUTO CMD FREE'
        return
    end
    local sent=nativeAction(car,'resetKey')
    if not sent then
        unstuck.note='J COMMAND REJECTED'
        return
    end
    unstuck.attempts+=1
    unstuck.streak+=1
    escape.perReset=0
    unstuck.lastRequest=now
    unstuck.pending=true
    unstuck.pendingAt=now
    unstuck.ignoreWarpUntil=now+6
    unstuck.savedGoal=bridge.selectedGoal
    unstuck.savedSource=bridge.goalSource
    unstuck.savedObjective=bridge.activeObjective
    unstuck.lowSince=nil
    bridge.stagnantSince=nil
    unstuck.note='J RESET REQUEST #'..unstuck.attempts
end
-- END AUTO UNSTUCK --------------------------------------------------------

-- LANE CHANGE TEST V6.3 ---------------------------------------------------
-- No direct car steering / velocity / PivotTo. Native driver can temporarily
-- request a *road-validated* side-lane waypoint, then resume the quest GPS.
-- NAV.routeLanes has no confirmed explicit lane selection, so the game may
-- reject, reroute to the same lane, or fail a conservative validation.
local laneRandom=Random.new()
local function laneFail(reason)
    lane.note=tostring(reason or 'NO SAFE LANE')
    lane.lastReason=lane.note
end
local function laneRouteCandidate(root,car,others,side)
    if not NAV or type(NAV.routeLanes)~='function' then
        return nil,'NAV ROUTELANES UNAVAILABLE'
    end
    local fwd=Vector3.new(root.CFrame.LookVector.X,0,root.CFrame.LookVector.Z)
    local right=Vector3.new(root.CFrame.RightVector.X,0,root.CFrame.RightVector.Z)
    if fwd.Magnitude<0.85 or right.Magnitude<0.85 then return nil,'BAD HEADING' end
    fwd=fwd.Unit;right=right.Unit
    -- Gradual lane offset (14 studs) over 145 studs of forward travel.
    -- This point is not a mission/PASS location and cannot finish a quest.
    local forwardDistance=145
    local lateralDistance=14
    local target=root.Position+fwd*forwardDistance+right*(side*lateralDistance)
    if not (sameRoadCandidate(root.Position+fwd*80+right*(side*lateralDistance))
        and sameRoadCandidate(target)
        and sameRoadCandidate(root.Position+fwd*forwardDistance)) then
        return nil,'NO ADJACENT ROAD'
    end
    -- Reject known traffic in the intended lane, including following cars.
    for _,other in ipairs(others) do
        local delta=other.position-root.Position
        local along=delta:Dot(fwd)
        local lateral=delta:Dot(right)
        if math.abs(delta.Y)<14 and along>-75 and along<forwardDistance+35
            and math.abs(lateral-side*lateralDistance)<math.max(10,other.width*0.5+5) then
            return nil,'TARGET LANE OCCUPIED: '..tostring(other.kind)
        end
    end
    local clear,why=laneIsClear(root,others,side)
    if not clear then return nil,why end
    -- Blockcast is only secondary: NPC visual cars cannot be found by raycasts.
    if blockProbe(root,car,fwd*10, fwd*28+right*(side*14),4) then
        return nil,'SIDE PHYSICAL OBSTACLE'
    end
    if blockProbe(root,car,fwd*30+right*(side*14),fwd*80,5) then
        return nil,'DESTINATION PHYSICAL OBSTACLE'
    end
    local ok,path=pcall(NAV.routeLanes,root.Position,target,{
        startFallback=true,forwardLanes=true,endOnLane=true
    })
    if not ok or type(path)~='table' or #path<2 or #path>220 then
        return nil,'NO VALID NATIVE SIDE ROUTE'
    end
    local first,last=path[1],path[#path]
    if typeof(first)~='Vector3' or typeof(last)~='Vector3' then
        return nil,'BAD ROUTE POINTS'
    end
    if (xz(first)-xz(root.Position)).Magnitude>42 or
        (xz(last)-xz(target)).Magnitude>12 then
        return nil,'ROUTE DOES NOT REACH SIDE LANE'
    end
    local pathLength=0
    for i,p in ipairs(path) do
        if typeof(p)~='Vector3' then return nil,'ROUTE FORMAT' end
        local delta=p-root.Position
        local f=delta:Dot(fwd)
        local l=delta:Dot(right)
        -- Avoid circling intersections, medians, U-turns and long detours.
        if math.abs(delta.Y)>20 or f< -15 or f>forwardDistance+42 or
            math.abs(l)>32 or (l*side)<-12 then
            return nil,'SIDE ROUTE LEAVES CORRIDOR'
        end
        if i>1 then
            local d=(xz(p)-xz(path[i-1])).Magnitude
            if d>90 then return nil,'SIDE ROUTE GAP' end
            pathLength+=d
            if pathLength>210 then return nil,'SIDE ROUTE DETOUR' end
        end
    end
    return target,nil
end
local function laneResume(reason,now)
    if not lane.active then return end
    -- If another handler retargeted while our timer was running, that new
    -- objective owns the car. Never restore a stale waypoint/quest over it.
    if typeof(bridge.selectedGoal)~='Vector3' or
        typeof(lane.waypoint)~='Vector3' or
        (bridge.selectedGoal-lane.waypoint).Magnitude>2 then
        lane.active=false
        laneFail('ABORT: ROUTE REPLACED')
        lane.lastFinish=now
        return
    end
    if cycle.stage~='QUEST' then
        lane.active=false
        stopNative('LANE CANCEL: QUEST NOT RUNNING')
        laneFail('ABORT: QUEST STATE CHANGED')
        lane.lastFinish=now
        return
    end
    local goal,source,obj=chooseDestination()
    if typeof(goal)=='Vector3' and (goal-lane.waypoint).Magnitude<25 then
        -- The native side request may temporarily expose its own waypoint
        -- as the GPS target. Never start another drive to that same point.
        goal=nil
    end
    if typeof(goal)~='Vector3' then
        -- Fallback is safe only while this exact quest cycle is still active.
        goal=lane.originalGoal
        source=lane.originalSource
        obj=lane.originalObjective
    end
    if typeof(goal)~='Vector3' then
        lane.active=false
        stopNative('LANE NO RETURN TARGET')
        laneFail('NO QUEST GOAL TO RESUME')
        lane.lastFinish=now
        return
    end
    lane.inTransition=true
    local started=startNative(goal,source or 'QUEST AFTER LANE',obj)
    lane.inTransition=false
    lane.active=false
    lane.lastFinish=now
    if started then
        -- Resuming the quest is NOT proof that a lane change occurred.
        -- We require a measurable lateral displacement in the requested direction.
        if (lane.maxShift or 0)>=7 then
            lane.successes+=1
            lane.note=string.format('SIDE SHIFT %.1f STUDS / RESUMED QUEST / #%d',lane.maxShift,lane.successes)
        else
            lane.note=string.format('NO SIDE SHIFT (%.1f STUDS) / QUEST RESTORED',lane.maxShift or 0)
        end
    else
        laneFail('RESUME FAILED: '..tostring(bridge.note))
    end
end
local function laneAttempt(now,manual)
    lane.lastAttempt=now
    lane.tries+=1
    if lane.active then return laneFail('LANE IN PROGRESS') end
    if not bridge.alive or not bridge.owns or cycle.stage~='QUEST' then
        return laneFail('NEED ACTIVE QUEST AUTODRIVE')
    end
    if not lane.enabled and not manual then return laneFail('OFF') end
    if unstuck.pending or cycle.talkBusy or (cycle.replanAt or 0)>0 then
        return laneFail('QUEST / RECOVERY BUSY')
    end
    local car,root=carRoot()
    local p=livePhysics()
    local status=activeState()
    if not car or not root or not status or status.active~=true or not p then
        return laneFail('NO ACTIVE CAR / NATIVE STATUS')
    end
    if p.boosting then return laneFail('BOOST ACTIVE: WAIT OR TURN AUTO BOOST OFF') end
    if p.qstart then return laneFail('QUICKSTART ACTIVE: WAIT') end
    if car:GetAttribute('AutoCmd')~=nil then return laneFail('AUTOCMD BUSY: WAIT') end
    if p.anyContact==false then return laneFail('CAR AIRBORNE') end
    if status.noRoute==true or (status.detour~=nil and status.detour~=false) or status.aiMode==2 then
        return laneFail('NATIVE TURNING / DETOUR')
    end
    if type(status.cosHeading)=='number' and status.cosHeading<0.99 then
        return laneFail('ROAD NOT STRAIGHT')
    end
    local kmh=nativeSpeedKmh(root)
    if kmh<35 or kmh>165 then return laneFail(string.format('SPEED %.0f KM/H: NEED 35-165',kmh)) end
    local goalDistance=distanceToGoal(root)
    if goalDistance<410 or (bridge.activeDest and bridge.activeDest.stop==true) then
        return laneFail(string.format('NEAR CHECKPOINT %.0f STUDS: NEED 410+',goalDistance))
    end
    if bridge.activeDest and type(bridge.activeDest.poly)=='table' and
        pointInPolygon(root.Position,bridge.activeDest.poly) then
        return laneFail('INSIDE PASS')
    end
    if bridge.hazardTtc and bridge.hazardTtc<5 then
        return laneFail('TRAFFIC HAZARD AHEAD')
    end
    local others=trafficModels(now,car)
    local side1=lane.lastSide~=0 and -lane.lastSide or (laneRandom:NextInteger(0,1)==0 and -1 or 1)
    local sides={side1,-side1}
    lane.failureLeft='-';lane.failureRight='-'
    local note='NO SIDE LANE'
    for _,side in ipairs(sides) do
        local target,why=laneRouteCandidate(root,car,others,side)
        if target then
            -- Preserve quest information while inserting a single temporary
            -- way-point; an objective update still supersedes this detour.
            lane.originalGoal=bridge.selectedGoal
            lane.originalSource=bridge.goalSource
            lane.originalObjective=bridge.activeObjective
            lane.originalToken=bridge.lastQuestToken
            lane.originalPass=bridge.requestedPass
            lane.originalIdx=bridge.selectedIndex
            local synthetic={
                idx=bridge.selectedIndex,
                quest=bridge.activeObjective and bridge.activeObjective.quest or nil,
                dest={target=target,stop=false},
                roadInside=true,kind='lane_test'
            }
            lane.inTransition=true
            local started=startNative(target,'LANE TEST '..(side<0 and 'LEFT' or 'RIGHT'),synthetic)
            lane.inTransition=false
            if started then
                -- Keep AutoNext tracking the original checkpoint, not the lane.
                bridge.lastQuestToken=lane.originalToken
                bridge.requestedPass=lane.originalPass
                bridge.selectedIndex=lane.originalIdx
                lane.active=true
                lane.waypoint=target
                lane.origin=root.Position
                lane.sideAxis=(root.CFrame.RightVector * side)
                lane.shiftNow=0;lane.maxShift=0
                lane.acceptedRoutes+=1
                lane.chosenSide=side
                lane.lastSide=side
                lane.startedAt=now
                lane.note='LANE '..(side<0 and 'LEFT' or 'RIGHT')..' / NATIVE WAYPOINT'
                return
            end
            -- Native rejected: the quest route is no longer running. Try to
            -- resume original target immediately; do not try the other side.
            lane.inTransition=true
            local restored=startNative(lane.originalGoal,lane.originalSource,lane.originalObjective)
            lane.inTransition=false
            lane.lastFinish=now
            laneFail(restored and 'LANE REFUSED / QUEST RESTORED' or 'LANE REFUSED / START QUEST MANUALLY')
            return
        end
        note=why or note
        if side<0 then lane.failureLeft=note else lane.failureRight=note end
    end
    laneFail('L: '..tostring(lane.failureLeft)..' | R: '..tostring(lane.failureRight))
end
local function laneTick(now)
    if escape.active then return end
    if now-(lane.lastPoll or -1e6)<0.20 then return end
    lane.lastPoll=now
    if lane.active and cycle.stage~='QUEST' then
        laneResume('QUEST STOPPED',now)
        return
    end
    if lane.active then
        local _,root=carRoot()
        local state=activeState()
        if root and lane.origin and lane.sideAxis then
            lane.shiftNow=(root.Position-lane.origin):Dot(lane.sideAxis)
            lane.maxShift=math.max(lane.maxShift or 0,lane.shiftNow)
            lane.note=string.format('NATIVE WAYPOINT %s: SHIFT %.1f / MAX %.1f ST',
                lane.chosenSide<0 and 'LEFT' or 'RIGHT',lane.shiftNow,lane.maxShift)
        end
        if not root then
            lane.active=false
            laneFail('NO CAR: LANE ABORT')
            return
        end
        if (lane.waypoint-root.Position).Magnitude<=19 then
            laneResume('WAYPOINT REACHED',now)
        elseif state and state.active~=true then
            laneResume('NATIVE ARRIVED',now)
        elseif now-lane.startedAt>lane.timeout then
            laneResume('12S TIMEOUT',now)
        end
        return
    end
    if lane.manual then
        lane.manual=false
        laneAttempt(now,true)
    elseif lane.enabled and now-lane.lastAttempt>=lane.period and
        now-lane.lastFinish>8 then
        laneAttempt(now,false)
    end
end
-- END LANE CHANGE TEST ----------------------------------------------------

-- END QUEST CYCLE ---------------------------------------------------------


-- RAYCITY X | V6.8 UI ----------------------------------------------------
-- One screen, five pages including SYSTEM; minimized floating R button.
local function rgb(r,g,b) return Color3.fromRGB(r,g,b) end
local COLORS={bg=rgb(14,15,20),card=rgb(24,25,31),panel=rgb(19,20,25),
    border=rgb(54,56,66),purple=rgb(116,79,157),green=rgb(42,143,94),
    red=rgb(145,56,68),blue=rgb(56,98,142),gray=rgb(52,54,65),
    text=rgb(240,242,246),muted=rgb(166,175,191)}
local function makeUI(class,parent,props)
    local o=Instance.new(class)
    for k,v in pairs(props or {}) do o[k]=v end
    o.Parent=parent
    return o
end
local function roundUI(o,r)
    makeUI('UICorner',o,{CornerRadius=UDim.new(0,r or 9)})
    return o
end
local function textUI(parent,str,pos,size,fontSize,col)
    return makeUI('TextLabel',parent,{Text=str or '',Position=pos,Size=size,
        TextColor3=col or COLORS.text,BackgroundTransparency=1,
        TextSize=fontSize or 12,Font=Enum.Font.Gotham,
        TextXAlignment=Enum.TextXAlignment.Left,TextYAlignment=Enum.TextYAlignment.Center,
        TextWrapped=true})
end
local function buttonUI(parent,str,x,y,w,h,bg)
    local b=makeUI('TextButton',parent,{Text=str,Position=UDim2.fromOffset(x,y),
        Size=UDim2.fromOffset(w,h),BackgroundColor3=bg or COLORS.gray,
        TextColor3=COLORS.text,Font=Enum.Font.GothamBold,TextSize=12,
        AutoButtonColor=true,BorderSizePixel=0})
    return roundUI(b,7)
end
local function cardUI(page,title,h)
    local c=roundUI(makeUI('Frame',page,{Size=UDim2.new(1,-10,0,h),
        BackgroundColor3=COLORS.card,BorderSizePixel=0}),9)
    makeUI('UIStroke',c,{Color=COLORS.border,Transparency=0.35,Thickness=1})
    textUI(c,title,UDim2.fromOffset(12,9),UDim2.new(1,-24,0,22),14,COLORS.text).Font=Enum.Font.GothamBold
    return c
end

gui=makeUI('ScreenGui',pg,{Name=NAME,ResetOnSpawn=false,
    IgnoreGuiInset=true,DisplayOrder=1000})
local frame=roundUI(makeUI('Frame',gui,{Size=UDim2.fromOffset(370,466),
    Position=UDim2.fromOffset(18,90),BackgroundColor3=COLORS.bg,
    BackgroundTransparency=0.04,BorderSizePixel=0}),12)
makeUI('UIStroke',frame,{Color=COLORS.border,Thickness=1})
local header=makeUI('Frame',frame,{Size=UDim2.new(1,0,0,45),
    BackgroundTransparency=1})
textUI(header,'RAYCITY X | V6.9',UDim2.fromOffset(13,0),UDim2.new(1,-100,1,0),
    17,COLORS.text).Font=Enum.Font.GothamBold
local miniButton=buttonUI(header,'−',301,9,29,28,COLORS.gray)
local quit=buttonUI(header,'X',337,9,27,28,COLORS.red)
makeUI('Frame',frame,{Position=UDim2.fromOffset(8,45),Size=UDim2.new(1,-16,0,1),
    BorderSizePixel=0,BackgroundColor3=COLORS.border})
local nav=makeUI('Frame',frame,{Position=UDim2.fromOffset(10,55),
    Size=UDim2.new(1,-20,0,34),BackgroundTransparency=1})
local tabs={}
for i,name in ipairs({'DRIVE','SP','QUEST','VISUAL','SYSTEM'}) do
    tabs[name]=buttonUI(nav,name,(i-1)*69,0,65,32,COLORS.gray)
    tabs[name].TextSize=11
end
local pages={}
for _,name in ipairs({'DRIVE','SP','QUEST','VISUAL','SYSTEM'}) do
    local p=makeUI('ScrollingFrame',frame,{Name='Page'..name,
        Position=UDim2.fromOffset(10,97),Size=UDim2.new(1,-20,1,-108),
        BackgroundTransparency=1,ScrollBarThickness=3,ScrollBarImageColor3=COLORS.purple,
        BorderSizePixel=0,CanvasSize=UDim2.fromOffset(0,0),
        AutomaticCanvasSize=Enum.AutomaticSize.Y,Visible=false})
    makeUI('UIListLayout',p,{Padding=UDim.new(0,9),SortOrder=Enum.SortOrder.LayoutOrder})
    pages[name]=p
end
local activeTab='DRIVE'
local function showPage(name)
    activeTab=name
    for n,p in pairs(pages) do
        p.Visible=(n==name)
        tabs[n].BackgroundColor3=(n==name) and COLORS.purple or COLORS.gray
    end
end
for name,b in pairs(tabs) do
    b.MouseButton1Click:Connect(function() showPage(name) end)
end
showPage('DRIVE')

-- DRIVE: speed from supplied Speed Test V2 + the proven native driver.
local driveCard=cardUI(pages.DRIVE,'VEHICLE SPEED',223)
textUI(driveCard,'Target speed (km/h)',UDim2.fromOffset(12,35),UDim2.fromOffset(195,20),12,COLORS.muted)
local speedInput=roundUI(makeUI('TextBox',driveCard,{
    Text='220',PlaceholderText='100 - 350',ClearTextOnFocus=false,
    Position=UDim2.fromOffset(12,61),Size=UDim2.fromOffset(194,35),
    BackgroundColor3=COLORS.gray,TextColor3=COLORS.text,Font=Enum.Font.GothamBold,
    TextSize=18,BorderSizePixel=0}),6)
local speedButton=buttonUI(driveCard,'SPEED OFF',215,61,120,35,COLORS.purple)
local presets={}
for i,value in ipairs({150,220,300}) do
    presets[i]=buttonUI(driveCard,tostring(value),12+(i-1)*109,107,103,32,
        value==220 and COLORS.purple or COLORS.gray)
end
local speedLive=textUI(driveCard,'PHYSICS: waiting / live: —',UDim2.fromOffset(12,143),
    UDim2.new(1,-22,0,22),11,COLORS.muted)
local speedDiag=textUI(driveCard,'NATIVE LIMIT: waiting for drive',
    UDim2.fromOffset(12,165),UDim2.new(1,-24,0,51),11,COLORS.muted)
speedDiag.TextYAlignment=Enum.TextYAlignment.Top
local nativeCard=cardUI(pages.DRIVE,'NATIVE AUTO DRIVE',116)
local go=buttonUI(nativeCard,'NATIVE GO',12,39,105,35,COLORS.green)
local stop=buttonUI(nativeCard,'STOP',126,39,96,35,COLORS.red)
local speedScanButton=buttonUI(nativeCard,'SCAN',231,39,104,35,COLORS.blue)
local nativeLine=textUI(nativeCard,'NATIVE: idle',UDim2.fromOffset(12,80),
    UDim2.new(1,-24,0,26),11,COLORS.muted)
local assistCard=cardUI(pages.DRIVE,'DRIVE OPTIONS',71)
local assistButton=buttonUI(assistCard,'ACCEL ASSIST: ON',12,36,182,30,COLORS.gray)
textUI(assistCard,'Straight roads only',UDim2.fromOffset(205,37),
    UDim2.fromOffset(126,27),11,COLORS.muted)
-- Experimental: defaults OFF; a failed lane candidate leaves the quest route unchanged.
local laneCard=cardUI(pages.DRIVE,'LANE TEST (NAV, NOT Z/X)',154)
local laneButton=buttonUI(laneCard,'AUTO LANE: OFF',12,40,156,31,COLORS.gray)
local laneTestButton=buttonUI(laneCard,'TRY LANE NOW',178,40,157,31,COLORS.blue)
local laneLine=textUI(laneCard,'OFF. Test only on open straight roads.',
    UDim2.fromOffset(12,79),UDim2.new(1,-24,0,70),11,COLORS.muted)
local npcCard=cardUI(pages.DRIVE,'NPC APPROACH / V6.9',78)
local npcStopLine=textUI(npcCard,'Waiting for return trip',
    UDim2.fromOffset(12,36),UDim2.new(1,-24,0,35),11,COLORS.muted)

-- SP: real boost & quickstart, auto unstuck.
local spCard=cardUI(pages.SP,'SP / BOOST',156)
local spStatus=textUI(spCard,'SP: waiting',UDim2.fromOffset(12,35),
    UDim2.new(1,-24,0,52),13,COLORS.muted)
local boostButton=buttonUI(spCard,'AUTO BOOST: ON',12,102,155,36,COLORS.purple)
local quickButton=buttonUI(spCard,'QUICKSTART: ON',178,102,157,36,COLORS.blue)
local unstuckCard=cardUI(pages.SP,'AUTO J / STUCK RECOVERY',106)
textUI(unstuckCard,'Below 5 km/h for 3s while driving',UDim2.fromOffset(12,36),
    UDim2.new(1,-22,0,25),12,COLORS.muted)
local unstuckButton=buttonUI(unstuckCard,'AUTO J: ON',12,70,155,29,COLORS.green)
local unstuckStatus=textUI(unstuckCard,'',UDim2.fromOffset(175,69),
    UDim2.fromOffset(163,30),11,COLORS.muted)
escape.ui.card=cardUI(pages.SP,'REVERSE RECOVERY / V6.9',153)
textUI(escape.ui.card,'Used only while J is cooling down and car is stuck',
    UDim2.fromOffset(12,33),UDim2.new(1,-20,0,23),11,COLORS.muted)
escape.ui.button=buttonUI(escape.ui.card,'AUTO REVERSE: OFF',12,63,155,30,COLORS.gray)
escape.ui.tryButton=buttonUI(escape.ui.card,'TRY REVERSE',178,63,157,30,COLORS.blue)
escape.ui.inputButton=buttonUI(escape.ui.card,'INPUT: ARROWS',12,100,155,30,COLORS.gray)
escape.ui.status=textUI(escape.ui.card,'OFF: safe trial mode',
    UDim2.fromOffset(178,96),UDim2.fromOffset(157,47),10,COLORS.muted)

-- QUEST: Derix rounds, auto loop, reward, original native quest logic.
local questCard=cardUI(pages.QUEST,'DERIX ROAD FIGHT',119)
local tierButtons={}
for i=1,4 do tierButtons[i]=buttonUI(questCard,'R'..i,12+(i-1)*82,37,75,33,COLORS.gray) end
local startDerix=buttonUI(questCard,'START DERIX RANDOM (1)',12,79,323,34,COLORS.green)
local questOptions=cardUI(pages.QUEST,'AUTO QUEST',145)
local loopButton=buttonUI(questOptions,'LOOP: ON',12,39,155,31,COLORS.green)
local claimButton=buttonUI(questOptions,'CLAIM: ON',178,39,157,31,COLORS.purple)
local nextButton=buttonUI(questOptions,'NEXT: ON',12,82,155,31,COLORS.blue)
local npcCloseButton=buttonUI(questOptions,'NPC CLOSE: ON',178,82,157,31,COLORS.gray)
local questLine=textUI(questOptions,'QUEST: waiting',UDim2.fromOffset(12,117),
    UDim2.new(1,-24,0,22),11,COLORS.muted)
local failCard=cardUI(pages.QUEST,'FAIL RECOVERY / V6.9',118)
local failButton=buttonUI(failCard,'AUTO FAIL RETRY: ON',12,37,323,32,COLORS.green)
local failStatus=textUI(failCard,'Waiting for server result',UDim2.fromOffset(12,75),
    UDim2.new(1,-24,0,37),11,COLORS.muted)
local debugCard=cardUI(pages.QUEST,'QUEST / ROUTE DEBUG',314)
local label=textUI(debugCard,'Loading native AutoDrive...',UDim2.fromOffset(10,34),
    UDim2.new(1,-18,0,270),11,COLORS.muted)
label.Font=Enum.Font.Code
label.TextXAlignment=Enum.TextXAlignment.Left
label.TextYAlignment=Enum.TextYAlignment.Top

-- VISUAL: actual toggles: NPC and vehicle Highlights and waypoint marker.
local visual={npc=false,traffic=false,pass=false}
local visCard=cardUI(pages.VISUAL,'ESP / MARKERS',161)
local npcESPButton=buttonUI(visCard,'NPC ESP: OFF',12,40,155,34,COLORS.gray)
local trafficESPButton=buttonUI(visCard,'CAR ESP: OFF',178,40,157,34,COLORS.gray)
local passESPButton=buttonUI(visCard,'PASS MARK: OFF',12,84,323,34,COLORS.gray)
local visualLine=textUI(visCard,'Car radar: waiting',UDim2.fromOffset(12,127),
    UDim2.new(1,-22,0,24),11,COLORS.muted)
local radarCard=cardUI(pages.VISUAL,'TRAFFIC RADAR',125)
local radarLine=textUI(radarCard,'NPC 0 | PLAYER 0',UDim2.fromOffset(12,38),
    UDim2.new(1,-22,0,75),12,COLORS.muted)
local noClipCard=cardUI(pages.VISUAL,'NPC TRAFFIC NOCLIP / V6.9',119)
local noClipButton=buttonUI(noClipCard,'NPC NOCLIP: OFF',12,40,323,32,COLORS.gray)
local noClipStatus=textUI(noClipCard,'OFF: NPC traffic only; client experiment',
    UDim2.fromOffset(12,80),UDim2.new(1,-24,0,32),11,COLORS.muted)

-- SYSTEM: channels use the game's channel.list -> channel.move protocol.
-- Auto join never changes channel during a quest/drive. Settings are local.
V66.channelCard=cardUI(pages.SYSTEM,'CHANNEL / V6.9',351)
V66.currentChannelLabel=textUI(V66.channelCard,'CURRENT CHANNEL: ...',
    UDim2.fromOffset(12,34),UDim2.new(1,-24,0,23),12,COLORS.text)
V66.currentChannelLabel.Font=Enum.Font.GothamBold
V66.lowPopInfo=textUI(V66.channelCard,'LOW POP: waiting for channel.list',
    UDim2.fromOffset(12,56),UDim2.new(1,-24,0,35),11,COLORS.muted)
textUI(V66.channelCard,'Channel number:',UDim2.fromOffset(12,90),
    UDim2.fromOffset(143,22),12,COLORS.muted)
V66.channelInput=roundUI(makeUI('TextBox',V66.channelCard,{
    Text='',PlaceholderText='e.g. 1',ClearTextOnFocus=false,
    Position=UDim2.fromOffset(172,90),Size=UDim2.fromOffset(163,32),
    BackgroundColor3=COLORS.gray,TextColor3=COLORS.text,
    Font=Enum.Font.GothamBold,TextSize=15,BorderSizePixel=0}),6)
V66.autoChannelButton=buttonUI(V66.channelCard,'AUTO CHANNEL: OFF',12,132,154,32,COLORS.gray)
V66.joinChannelButton=buttonUI(V66.channelCard,'JOIN NOW',178,132,157,32,COLORS.blue)
V66.lowPopButton=buttonUI(V66.channelCard,'RANDOM LOW POP: OFF',12,175,154,36,COLORS.gray)
V66.lowPopButton.TextSize=10
V66.lowPopNowButton=buttonUI(V66.channelCard,'PICK LOW POP NOW',178,175,157,36,COLORS.blue)
V66.checkChannelButton=buttonUI(V66.channelCard,'CHECK CHANNELS',12,220,323,31,COLORS.blue)
V66.channelStatus=textUI(V66.channelCard,
    'Low-pop random: ON selects once when idle; not during quest.',
    UDim2.fromOffset(12,262),UDim2.new(1,-24,0,79),11,COLORS.muted)
V66.settingsCard=cardUI(pages.SYSTEM,'SETTINGS / V6.9',195)
V66.autoSaveButton=buttonUI(V66.settingsCard,'AUTO SAVE: ON',12,40,155,31,COLORS.purple)
V66.saveNowButton=buttonUI(V66.settingsCard,'SAVE NOW',178,40,157,31,COLORS.blue)
V66.loadNowButton=buttonUI(V66.settingsCard,'LOAD SAVED SETTINGS',12,80,323,31,COLORS.gray)
V66.settingsStatus=textUI(V66.settingsCard,'Checking storage...',
    UDim2.fromOffset(12,118),UDim2.new(1,-24,0,68),11,COLORS.muted)

-- Small floating R launcher, supports mouse and touch dragging.
local miniLogo=roundUI(makeUI('TextButton',gui,{Name='RLogo',Visible=false,
    Size=UDim2.fromOffset(48,48),Position=UDim2.fromOffset(20,118),
    BackgroundColor3=COLORS.purple,BorderSizePixel=0,
    Font=Enum.Font.GothamBlack,Text='R',TextSize=28,TextColor3=COLORS.text}),24)
makeUI('UIStroke',miniLogo,{Color=rgb(162,122,207),Thickness=1.5})
local function startDrag(handle,movable,exclude)
    local dragging=false
    local dragInput,origin,beginPos
    local wasDragged=false
    handle.InputBegan:Connect(function(input)
        if input.UserInputType~=Enum.UserInputType.MouseButton1
           and input.UserInputType~=Enum.UserInputType.Touch then return end
        if exclude and exclude(input.Position) then return end
        dragging=true;wasDragged=false;dragInput=input
        origin=input.Position;beginPos=movable.Position
    end)
    UIS.InputChanged:Connect(function(input)
        if not dragging then return end
        if input~=dragInput and input.UserInputType~=Enum.UserInputType.MouseMovement then return end
        local dif=input.Position-origin
        if dif.Magnitude>5 then wasDragged=true end
        movable.Position=UDim2.new(beginPos.X.Scale,beginPos.X.Offset+dif.X,
            beginPos.Y.Scale,beginPos.Y.Offset+dif.Y)
    end)
    UIS.InputEnded:Connect(function(input)
        if input==dragInput or (dragInput and input.UserInputType==Enum.UserInputType.MouseButton1
            and dragInput.UserInputType==Enum.UserInputType.MouseButton1) then
            dragging=false;dragInput=nil
        end
    end)
    return function() return wasDragged end
end
startDrag(header,frame,function(pos) return pos.X>header.AbsolutePosition.X+285 end)
local miniDragged=startDrag(miniLogo,miniLogo)
miniButton.MouseButton1Click:Connect(function()
    frame.Visible=false;miniLogo.Visible=true
end)
miniLogo.MouseButton1Click:Connect(function()
    if miniDragged() then return end
    miniLogo.Visible=false;frame.Visible=true
end)

local highlights={}
local passMarker=nil
local function clearVisual()
    for obj,h in pairs(highlights) do pcall(function() h:Destroy() end) end
    highlights={}
    if passMarker then passMarker:Destroy();passMarker=nil end
end
local function highlightModel(model,kind)
    if not model or not model.Parent then return end
    if highlights[model] then return end
    local h=Instance.new('Highlight')
    h.Name='RayCityXHighlight';h.Adornee=model
    h.FillTransparency=0.82;h.OutlineTransparency=0
    h.OutlineColor=kind=='NPC' and rgb(255,190,76) or rgb(79,205,247)
    h.DepthMode=Enum.HighlightDepthMode.AlwaysOnTop
    h.Parent=WS;highlights[model]=h
end
local function refreshVisual(now)
    local desired={}
    local car,root=carRoot()
    if visual.traffic and car then
        local objects=trafficModels(now,car)
        local count=0
        for _,obj in ipairs(objects) do
            if obj.model and (not root or (obj.position-root.Position).Magnitude<180) then
                desired[obj.model]='CAR';count+=1
                if count>=30 then break end
            end
        end
    end
    if visual.npc then
        local count=0
        for _,obj in ipairs(WS:GetChildren()) do
            if obj:IsA('Model') then
                local lower=obj.Name:lower()
                if lower:find('npc_',1,true) or lower:find('derix',1,true) then
                    desired[obj]='NPC';count+=1
                    if count>=14 then break end
                end
            end
        end
    end
    for model,h in pairs(highlights) do
        if not desired[model] or not model.Parent then h:Destroy();highlights[model]=nil end
    end
    for model,kind in pairs(desired) do highlightModel(model,kind) end
    if visual.pass and typeof(bridge.selectedGoal)=='Vector3' then
        if not passMarker then
            passMarker=Instance.new('Part')
            passMarker.Name='RayCityXPassMarker'
            passMarker.Shape=Enum.PartType.Ball
            passMarker.Size=Vector3.new(3.5,3.5,3.5)
            passMarker.Anchored=true;passMarker.CanCollide=false
            passMarker.CanQuery=false;passMarker.CanTouch=false
            passMarker.Material=Enum.Material.Neon
            passMarker.Color=rgb(80,255,132);passMarker.Transparency=0.4
            passMarker.Parent=WS
        end
        passMarker.Position=bridge.selectedGoal+Vector3.new(0,2,0)
    elseif passMarker then passMarker:Destroy();passMarker=nil end
end
local function styleSwitch(b,enabled,text)
    b.Text=text..(enabled and ': ON' or ': OFF')
    b.BackgroundColor3=enabled and COLORS.purple or COLORS.gray
end
local function updateTier()
    local on=enabledRounds()
    for i,b in ipairs(tierButtons) do
        b.Text='R'..i
        b.BackgroundColor3=cycle.roundEnabled[i] and COLORS.green or COLORS.gray
    end
    startDerix.Text=#on>0 and ('START DERIX RANDOM ('..#on..')') or 'SELECT ROUNDS FIRST'
    startDerix.BackgroundColor3=#on>0 and COLORS.green or COLORS.gray
end
V66.markSettingsChanged=function() end -- assigned after controls are built
local function parseSpeed()
    local n=tonumber(speedInput.Text)
    if not n or n~=n or n<100 or n>350 then
        speedInput.Text=tostring(speedV6.targetKmh)
        speedV6.scanNote='SPEED RANGE: 100-350'
        return false
    end
    speedV6.targetKmh=math.floor(n+0.5)
    speedInput.Text=tostring(speedV6.targetKmh)
    for i,v in ipairs({150,220,300}) do
        presets[i].BackgroundColor3=v==speedV6.targetKmh and COLORS.purple or COLORS.gray
    end
    V66.markSettingsChanged()
    return true
end
for i,value in ipairs({150,220,300}) do
    presets[i].MouseButton1Click:Connect(function()
        speedInput.Text=tostring(value)
        parseSpeed()
    end)
end
speedInput.FocusLost:Connect(parseSpeed)
speedButton.MouseButton1Click:Connect(function()
    if not parseSpeed() then return end
    speedEnable(not speedV6.enabled)
    styleSwitch(speedButton,speedV6.enabled,'SPEED')
    V66.markSettingsChanged()
end)
assistButton.MouseButton1Click:Connect(function()
    speedV6.assist=not speedV6.assist
    styleSwitch(assistButton,speedV6.assist,'ACCEL ASSIST')
    V66.markSettingsChanged()
end)
laneButton.MouseButton1Click:Connect(function()
    lane.enabled=not lane.enabled
    lane.manual=false
    if not lane.enabled then
        lane.note=lane.active and 'OFF: RESUMING QUEST' or 'OFF'
        if lane.active then laneResume('SWITCH OFF',os.clock()) end
    else
        lane.note='ON: WAITING FOR SAFE ROAD'
        -- Don't retarget immediately after button press.
        lane.lastAttempt=os.clock()-lane.period+6
    end
    styleSwitch(laneButton,lane.enabled,'AUTO LANE')
    V66.markSettingsChanged()
end)
laneTestButton.MouseButton1Click:Connect(function()
    if lane.active then
        lane.note='ALREADY CHANGING: WAIT'
    else
        lane.manual=true
        lane.note='MANUAL LANE CHECK REQUESTED'
    end
end)
speedScanButton.MouseButton1Click:Connect(function() speedScan() end)
go.MouseButton1Click:Connect(function()
    local target,source,obj=chooseDestination()
    if not target then bridge.note=source;return end
    if cycle.enabled then cycle.stage='QUEST';cycle.note='MANUAL GO, CYCLE ARMED' end
    startNative(target,source,obj)
end)
stop.MouseButton1Click:Connect(function()
    cycle.enabled=false;cycle.stage='IDLE';cycle.note='STOPPED BY USER'
    stopNative('USER STOP')
    releaseNpcParking()
    unstuck.pending=false;unstuck.lowSince=nil;unstuck.note='STOPPED BY USER'
    styleSwitch(loopButton,false,'LOOP')
    V66.markSettingsChanged()
end)
boostButton.MouseButton1Click:Connect(function()
    bridge.autoBoost=not bridge.autoBoost
    styleSwitch(boostButton,bridge.autoBoost,'AUTO BOOST')
    V66.markSettingsChanged()
end)
quickButton.MouseButton1Click:Connect(function()
    bridge.autoQuickStart=not bridge.autoQuickStart
    styleSwitch(quickButton,bridge.autoQuickStart,'QUICKSTART')
    V66.markSettingsChanged()
end)
escape.ui.button.MouseButton1Click:Connect(function()
    escape.enabled=not escape.enabled
    if not escape.enabled and escape.active then escape.finish('AUTO REVERSE OFF',os.clock()) end
    escape.note=escape.enabled and 'ARMED: WAIT FOR J COOLDOWN' or 'OFF'
    styleSwitch(escape.ui.button,escape.enabled,'AUTO REVERSE')
    V66.markSettingsChanged()
end)
escape.ui.inputButton.MouseButton1Click:Connect(function()
    if escape.active then escape.note='WAIT: REVERSE IS ACTIVE';return end
    escape.inputMode=escape.inputMode=='ARROWS' and 'WASD' or 'ARROWS'
    escape.ui.inputButton.Text='INPUT: '..escape.inputMode
    V66.markSettingsChanged()
end)
escape.ui.tryButton.MouseButton1Click:Connect(function()
    local car,root=carRoot()
    local state=activeState()
    if not safeToRecover(root,state) then
        escape.note='TRY REFUSED: MUST BE STUCK ON ACTIVE ROUTE';return
    end
    escape.begin(car,root,os.clock(),true)
end)
unstuckButton.MouseButton1Click:Connect(function()
    unstuck.enabled=not unstuck.enabled
    if not unstuck.enabled then
        unstuck.lowSince=nil;unstuck.pending=false;unstuck.note='OFF'
        if escape.active then escape.finish('AUTO J OFF',os.clock()) end
    end
    styleSwitch(unstuckButton,unstuck.enabled,'AUTO J')
    V66.markSettingsChanged()
end)
loopButton.MouseButton1Click:Connect(function()
    cycle.enabled=not cycle.enabled
    if not cycle.enabled then cycle.stage='IDLE';cycle.note='AUTO LOOP OFF' end
    styleSwitch(loopButton,cycle.enabled,'LOOP')
    V66.markSettingsChanged()
end)
claimButton.MouseButton1Click:Connect(function()
    cycle.claim=not cycle.claim
    styleSwitch(claimButton,cycle.claim,'CLAIM')
    V66.markSettingsChanged()
end)
nextButton.MouseButton1Click:Connect(function()
    bridge.autoNext=not bridge.autoNext
    styleSwitch(nextButton,bridge.autoNext,'NEXT')
    V66.markSettingsChanged()
end)
npcCloseButton.MouseButton1Click:Connect(function()
    cycle.autoDismissNpc=not cycle.autoDismissNpc
    styleSwitch(npcCloseButton,cycle.autoDismissNpc,'NPC CLOSE')
    V66.markSettingsChanged()
end)
failButton.MouseButton1Click:Connect(function()
    cycle.autoFailRetry=not cycle.autoFailRetry
    failButton.BackgroundColor3=cycle.autoFailRetry and COLORS.green or COLORS.gray
    styleSwitch(failButton,cycle.autoFailRetry,'AUTO FAIL RETRY')
    failButton.BackgroundColor3=cycle.autoFailRetry and COLORS.green or COLORS.gray
    if cycle.stage=='FAILED' then
        cycle.failNote=cycle.autoFailRetry and 'AUTO RETRY ARMED' or 'AUTO RETRY DISABLED'
    end
    V66.markSettingsChanged()
end)
for i,b in ipairs(tierButtons) do
    b.MouseButton1Click:Connect(function()
        cycle.roundEnabled[i]=not cycle.roundEnabled[i]
        cycle.note='R'..i..(cycle.roundEnabled[i] and ' INCLUDED IN RANDOM' or ' EXCLUDED FROM RANDOM')
        -- A mission already accepted remains untouched; changes apply on next NPC talk.
        updateTier()
        V66.markSettingsChanged()
    end)
end
startDerix.MouseButton1Click:Connect(function()
    local on=enabledRounds()
    if #on==0 then
        cycle.note='TURN ON AT LEAST ONE ROUND (GREEN)'
        return
    end
    if bridge.owns or cycle.talkBusy or cycle.stage=='QUEST' or cycle.stage=='WAIT_QUEST' then
        cycle.note='QUEST ALREADY ACTIVE: CHANGES APPLY NEXT ROUND';return
    end
    cycle.enabled=true;styleSwitch(loopButton,true,'LOOP')
    V66.markSettingsChanged()
    -- Only needed to resolve the same Derix NPC location; actual mission is
    -- chosen randomly from playable green offers immediately before accepting.
    cycle.questId=DERIX_ROUND_QUESTS[on[1]];cycle.npcId=START_NPC_ID
    cycle.npcPos=nil;cycle.acceptProtocol='-';cycle.roadFightOffer='-'
    cycle.acceptAttempts=0;cycle.npcDriveAttempts=0
    cycle.retryCycles=0;cycle.retryWaitUntil=0;cycle.acceptConfirmed=false
    cycle.failRecoveryTrip=false;cycle.failNextAt=0;cycle.failUiClosed=false
    cycle.failBlocked=false;cycle.failNote='MANUAL START'
    cycle.lastAcceptError='-'
    cycle.lastTalk=0;cycle.lastAccept=0;cycle.startedSignal=false;cycle.waitQuestAt=0
    rememberQuest({questId=cycle.questId})
    cycle.npcId=START_NPC_ID;cycle.stage='RETURN_NPC'
    cycle.note='START DERIX RANDOM: '..#on..' GREEN ROUND(S)'
end)
local evadeButton=buttonUI(radarCard,'AUTO Z/X: OFF',12,80,154,31,COLORS.gray)
local jumpButton=buttonUI(radarCard,'AUTO JUMP: ON',178,80,157,31,COLORS.gray)
evadeButton.MouseButton1Click:Connect(function()
    bridge.autoEvade=not bridge.autoEvade
    styleSwitch(evadeButton,bridge.autoEvade,'AUTO Z/X')
    V66.markSettingsChanged()
end)
jumpButton.MouseButton1Click:Connect(function()
    bridge.jumpFallback=not bridge.jumpFallback
    styleSwitch(jumpButton,bridge.jumpFallback,'AUTO JUMP')
    V66.markSettingsChanged()
end)
local function visualToggle(b,key,title)
    visual[key]=not visual[key]
    styleSwitch(b,visual[key],title)
    V66.markSettingsChanged()
    if not visual[key] then refreshVisual(os.clock()) end
end
npcESPButton.MouseButton1Click:Connect(function() visualToggle(npcESPButton,'npc','NPC ESP') end)
trafficESPButton.MouseButton1Click:Connect(function() visualToggle(trafficESPButton,'traffic','CAR ESP') end)
passESPButton.MouseButton1Click:Connect(function() visualToggle(passESPButton,'pass','PASS MARK') end)
-- V6.6 SETTINGS (backward compatible V6.5 config) -------------------------
-- File persistence is executor-dependent. If readfile/writefile are missing,
-- values are retained for repeated injections only in the current session.
V66.HttpService=game:GetService('HttpService')
V66.CONFIG_FILE='RayCityX_Settings_'..tostring(player.UserId)..'.json'
V66.profile={autoSave=true,autoChannel=false,autoLowPop=false,channelNo=nil,
    saveNote='DEFAULTS',channelNote='OFF',queued=false,
    joinTried=false,joinBusy=false,nextJoinAt=0,lastAutoPoll=0,
    lowPopQueued=false,lowPopTried=false,lastLowPopMoveAt=0,
    currentNo=nil,currentName=nil,currentPlayers=nil,currentMax=nil,
    lowPopSummary='WAITING FOR CHANNEL LIST',lastChannelPoll=-1e6,pollBusy=false,
    serial=0,loadedSource='NONE'}
function V66.configSnapshot()
    return {schema=1,autoSave=V66.profile.autoSave,
        autoChannel=V66.profile.autoChannel,channelNo=V66.profile.channelNo,
        autoLowPop=V66.profile.autoLowPop,
        lastLowPopMoveAt=V66.profile.lastLowPopMoveAt,
        speedEnabled=speedV6.enabled,speedKmh=speedV6.targetKmh,
        assist=speedV6.assist,boost=bridge.autoBoost,quick=bridge.autoQuickStart,
        autoJ=unstuck.enabled,reverse=escape.enabled,reverseKeys=escape.inputMode,
        autoLane=lane.enabled,autoZX=bridge.autoEvade,autoJump=bridge.jumpFallback,
        loop=cycle.enabled,claim=cycle.claim,next=bridge.autoNext,
        npcClose=cycle.autoDismissNpc,failRetry=cycle.autoFailRetry,
        rounds={cycle.roundEnabled[1],cycle.roundEnabled[2],
            cycle.roundEnabled[3],cycle.roundEnabled[4]},
        npcESP=visual.npc,carESP=visual.traffic,passMark=visual.pass,
        npcNoClip=npcNoClip.enabled}
end
function V66.cacheConfig(encoded)
    pcall(function() shared.RayCityX_V65_Config=encoded end)
    if type(getgenv)=='function' then
        local ok,e=pcall(getgenv)
        if ok and type(e)=='table' then
            pcall(function() e.RayCityX_V65_Config=encoded end)
        end
    end
end
function V66.saveConfig(force)
    if not force and not V66.profile.autoSave then return false end
    local ok,encoded=pcall(V66.HttpService.JSONEncode,V66.HttpService,V66.configSnapshot())
    if not ok or type(encoded)~='string' then
        V66.profile.saveNote='ENCODE FAILED: '..tostring(encoded)
        return false
    end
    V66.cacheConfig(encoded)
    if type(writefile)=='function' then
        local written,err=pcall(writefile,V66.CONFIG_FILE,encoded)
        if written then
            V66.profile.saveNote='FILE SAVED: '..V66.CONFIG_FILE
            return true
        end
        V66.profile.saveNote='SESSION ONLY (writefile: '..tostring(err)..')'
    else
        V66.profile.saveNote='SESSION ONLY: writefile unavailable'
    end
    return false
end
function V66.readConfig()
    local raw,where=nil,'NONE'
    if type(readfile)=='function' then
        local ok,value=pcall(readfile,V66.CONFIG_FILE)
        if ok and type(value)=='string' then raw=value;where='FILE' end
    end
    if not raw and type(getgenv)=='function' then
        local ok,e=pcall(getgenv)
        if ok and type(e)=='table' and type(e.RayCityX_V65_Config)=='string' then
            raw=e.RayCityX_V65_Config;where='SESSION'
        end
    end
    if not raw and type(shared.RayCityX_V65_Config)=='string' then
        raw=shared.RayCityX_V65_Config;where='SESSION'
    end
    if not raw then return nil,'NO SAVED FILE' end
    local ok,value=pcall(V66.HttpService.JSONDecode,V66.HttpService,raw)
    if ok and type(value)=='table' and tonumber(value.schema)==1 then
        return value,where
    end
    return nil,'INVALID SETTINGS JSON'
end
function V66.bool(src,key,old)
    if type(src[key])=='boolean' then return src[key] end
    return old
end
function V66.styleAllSettings()
    speedInput.Text=tostring(speedV6.targetKmh)
    for i,v in ipairs({150,220,300}) do
        presets[i].BackgroundColor3=v==speedV6.targetKmh and COLORS.purple or COLORS.gray
    end
    styleSwitch(speedButton,speedV6.enabled,'SPEED')
    styleSwitch(assistButton,speedV6.assist,'ACCEL ASSIST')
    styleSwitch(laneButton,lane.enabled,'AUTO LANE')
    styleSwitch(boostButton,bridge.autoBoost,'AUTO BOOST')
    styleSwitch(quickButton,bridge.autoQuickStart,'QUICKSTART')
    styleSwitch(unstuckButton,unstuck.enabled,'AUTO J')
    styleSwitch(escape.ui.button,escape.enabled,'AUTO REVERSE')
    escape.ui.inputButton.Text='INPUT: '..escape.inputMode
    styleSwitch(loopButton,cycle.enabled,'LOOP')
    styleSwitch(claimButton,cycle.claim,'CLAIM')
    styleSwitch(nextButton,bridge.autoNext,'NEXT')
    styleSwitch(npcCloseButton,cycle.autoDismissNpc,'NPC CLOSE')
    styleSwitch(failButton,cycle.autoFailRetry,'AUTO FAIL RETRY')
    failButton.BackgroundColor3=cycle.autoFailRetry and COLORS.green or COLORS.gray
    styleSwitch(evadeButton,bridge.autoEvade,'AUTO Z/X')
    styleSwitch(jumpButton,bridge.jumpFallback,'AUTO JUMP')
    styleSwitch(npcESPButton,visual.npc,'NPC ESP')
    styleSwitch(trafficESPButton,visual.traffic,'CAR ESP')
    styleSwitch(passESPButton,visual.pass,'PASS MARK')
    styleSwitch(noClipButton,npcNoClip.enabled,'NPC NOCLIP')
    noClipButton.BackgroundColor3=npcNoClip.enabled and COLORS.green or COLORS.gray
    styleSwitch(V66.autoChannelButton,V66.profile.autoChannel,'AUTO CHANNEL')
    styleSwitch(V66.lowPopButton,V66.profile.autoLowPop,'RANDOM LOW POP')
    -- Green means randomized low-pop mode is enabled; gray means disabled.
    V66.lowPopButton.BackgroundColor3=V66.profile.autoLowPop and COLORS.green or COLORS.gray
    styleSwitch(V66.autoSaveButton,V66.profile.autoSave,'AUTO SAVE')
    V66.channelInput.Text=V66.profile.channelNo and tostring(V66.profile.channelNo) or ''
    updateTier()
end
function V66.applyConfig(cfg,source)
    if not cfg then
        V66.profile.saveNote='NOT LOADED: '..tostring(source)
        return false
    end
    V66.profile.autoSave=V66.bool(cfg,'autoSave',V66.profile.autoSave)
    V66.profile.autoChannel=V66.bool(cfg,'autoChannel',V66.profile.autoChannel)
    V66.profile.autoLowPop=V66.bool(cfg,'autoLowPop',V66.profile.autoLowPop)
    -- V6.5 configurations load normally; random mode wins if both were saved.
    if V66.profile.autoLowPop then V66.profile.autoChannel=false end
    V66.profile.lastLowPopMoveAt=math.max(0,tonumber(cfg.lastLowPopMoveAt) or 0)
    local chan=tonumber(cfg.channelNo)
    V66.profile.channelNo=(chan and chan>=1 and chan<=9999 and chan%1==0) and chan or nil
    local spd=tonumber(cfg.speedKmh)
    if spd and spd>=100 and spd<=350 then speedV6.targetKmh=math.floor(spd+0.5) end
    speedV6.assist=V66.bool(cfg,'assist',speedV6.assist)
    bridge.autoBoost=V66.bool(cfg,'boost',bridge.autoBoost)
    bridge.autoQuickStart=V66.bool(cfg,'quick',bridge.autoQuickStart)
    unstuck.enabled=V66.bool(cfg,'autoJ',unstuck.enabled)
    if escape.active then escape.finish('LOAD SETTINGS',os.clock()) end
    escape.enabled=V66.bool(cfg,'reverse',escape.enabled)
    if cfg.reverseKeys=='ARROWS' or cfg.reverseKeys=='WASD' then
        escape.inputMode=cfg.reverseKeys
    end
    if lane.active then laneResume('SETTINGS LOAD',os.clock()) end
    lane.enabled=V66.bool(cfg,'autoLane',lane.enabled)
    bridge.autoEvade=V66.bool(cfg,'autoZX',bridge.autoEvade)
    bridge.jumpFallback=V66.bool(cfg,'autoJump',bridge.jumpFallback)
    cycle.enabled=V66.bool(cfg,'loop',cycle.enabled)
    cycle.claim=V66.bool(cfg,'claim',cycle.claim)
    bridge.autoNext=V66.bool(cfg,'next',bridge.autoNext)
    cycle.autoDismissNpc=V66.bool(cfg,'npcClose',cycle.autoDismissNpc)
    cycle.autoFailRetry=V66.bool(cfg,'failRetry',cycle.autoFailRetry)
    if type(cfg.rounds)=='table' then
        for i=1,4 do
            if type(cfg.rounds[i])=='boolean' then cycle.roundEnabled[i]=cfg.rounds[i] end
        end
    end
    visual.npc=V66.bool(cfg,'npcESP',visual.npc)
    visual.traffic=V66.bool(cfg,'carESP',visual.traffic)
    visual.pass=V66.bool(cfg,'passMark',visual.pass)
    setNpcNoClip(V66.bool(cfg,'npcNoClip',npcNoClip.enabled))
    speedEnable(V66.bool(cfg,'speedEnabled',speedV6.enabled))
    V66.profile.loadedSource=source
    V66.profile.saveNote='LOADED FROM '..source..' (settings only)'
    V66.profile.joinTried=false
    V66.profile.queued=V66.profile.autoChannel and V66.profile.channelNo~=nil
    V66.profile.lowPopTried=false
    V66.profile.lowPopQueued=V66.profile.autoLowPop
    V66.profile.nextJoinAt=os.clock()+3
    V66.profile.channelNote=V66.profile.lowPopQueued and 'RANDOM LOW POP ARMED: WAIT IDLE'
        or (V66.profile.queued and 'FIXED CHANNEL ARMED: WAIT IDLE' or 'OFF / NO CHANNEL SET')
    V66.styleAllSettings()
    return true
end
V66.markSettingsChanged=function()
    if not V66.profile.autoSave then return end
    V66.profile.serial+=1
    local serial=V66.profile.serial
    task.delay(0.75,function()
        if bridge.alive and V66.profile.serial==serial then V66.saveConfig(false) end
    end)
end
function V66.parseChannelInput()
    local n=tonumber(V66.channelInput.Text)
    if not n or n%1~=0 or n<1 or n>9999 then
        V66.channelInput.Text=V66.profile.channelNo and tostring(V66.profile.channelNo) or ''
        V66.profile.channelNote='ENTER A VALID CHANNEL NUMBER (1-9999)'
        return false
    end
    local changed=V66.profile.channelNo~=n
    V66.profile.channelNo=n
    V66.channelInput.Text=tostring(n)
    if changed then
        V66.profile.joinTried=false
        V66.profile.queued=V66.profile.autoChannel
        V66.profile.nextJoinAt=os.clock()+3
    end
    V66.markSettingsChanged()
    return true
end
function V66.canSwitchChannel()
    if not bridge.alive then return false,'SCRIPT CLOSED' end
    if bridge.owns or lane.active or escape.active then
        return false,'DRIVING: STOP AUTODRIVE FIRST'
    end
    if cycle.stage=='FAILED' and cycle.autoFailRetry then
        return false,'AUTO FAIL RECOVERY PENDING: CHANNEL BLOCKED'
    end
    if cycle.stage~='IDLE' and cycle.stage~='DONE' and cycle.stage~='FAILED' then
        return false,'QUEST '..tostring(cycle.stage)..': SWITCH BLOCKED'
    end
    local q=rawQuestState()
    if q and (q.state=='running' or q.state=='accepted' or q.state=='pending') then
        return false,'SERVER QUEST ACTIVE: SWITCH BLOCKED'
    end
    local stage=player:GetAttribute('RaycityStage')
    if stage=='race' or stage=='raceRoom' or stage=='raceLobby' then
        return false,'RACE MODE: SWITCH BLOCKED'
    end
    if player:GetAttribute('RBRCMatchBusy')==true then
        return false,'MATCH BUSY: SWITCH BLOCKED'
    end
    return true
end
function V66.requestChannel(auto)
    if V66.profile.joinBusy then return end
    if not V66.profile.channelNo then
        V66.profile.channelNote='CHOOSE CHANNEL NUMBER FIRST'
        return
    end
    local safe,why=V66.canSwitchChannel()
    if not safe then
        V66.profile.channelNote=(auto and 'WAIT IDLE: ' or 'BLOCKED: ')..why
        return
    end
    V66.profile.queued=false
    V66.profile.joinTried=true
    V66.profile.joinBusy=true
    V66.profile.channelNote='CHECKING CHANNEL '..V66.profile.channelNo..'...'
    task.spawn(function()
        local sysFolder=RS:FindFirstChild('RaycitySystems')
        local mod=sysFolder and sysFolder:FindFirstChild('SysKit')
        if not mod or not mod:IsA('ModuleScript') then
            V66.profile.channelNote='GAME SysKit NOT FOUND'
            V66.profile.joinBusy=false
            return
        end
        local ok,kit=pcall(require,mod)
        if not ok or type(kit)~='table' or type(kit.request)~='function' then
            V66.profile.channelNote='GAME CHANNEL API NOT AVAILABLE'
            V66.profile.joinBusy=false
            return
        end
        local listed,data=pcall(kit.request,'channel.list',{})
        if not listed or type(data)~='table' or data.ok~=true then
            V66.profile.channelNote='CHANNEL LIST FAILED: '..tostring(
                type(data)=='table' and (data.err or data.code) or data)
            V66.profile.joinBusy=false
            return
        end
        local found=nil
        for _,entry in ipairs(type(data.channels)=='table' and data.channels or {}) do
            if type(entry)=='table' and tonumber(entry.no)==V66.profile.channelNo then
                found=entry
                break
            end
        end
        if not found then
            V66.profile.channelNote='CHANNEL '..V66.profile.channelNo..' NOT AVAILABLE'
        elseif found.current==true then
            V66.profile.channelNote='ALREADY IN CHANNEL '..V66.profile.channelNo
        elseif found.full==true or data.maint~=nil then
            V66.profile.channelNote='CHANNEL FULL / MAINTENANCE'
        elseif found.id==nil then
            V66.profile.channelNote='CHANNEL ID MISSING'
        else
            local allowed,reason=V66.canSwitchChannel()
            if not allowed then
                V66.profile.channelNote='SWITCH CANCELLED: '..reason
            else
                V66.profile.channelNote='REQUESTING CHANNEL '..V66.profile.channelNo
                V66.saveConfig(false)
                local moved,res=pcall(kit.request,'channel.move',{id=found.id})
                if moved and type(res)=='table' and res.ok==true then
                    V66.profile.channelNote=res.same and
                        ('ALREADY IN CHANNEL '..V66.profile.channelNo) or
                        ('CHANNEL MOVE ACCEPTED: '..V66.profile.channelNo..' / WAIT TELEPORT')
                else
                    V66.profile.channelNote='MOVE FAILED: '..tostring(
                        type(res)=='table' and (res.err or res.code) or res)
                end
            end
        end
        V66.profile.joinBusy=false
    end)
end
-- V6.6 CHANNEL INSPECTION AND RANDOM LOW-POP ---------------------------
function V66.channelApi()
    local folder=RS:FindFirstChild('RaycitySystems')
    local module=folder and folder:FindFirstChild('SysKit')
    if not module or not module:IsA('ModuleScript') then
        return nil,'SysKit MODULE MISSING'
    end
    local ok,kit=pcall(require,module)
    if not ok or type(kit)~='table' or type(kit.request)~='function' then
        return nil,'SysKit CHANNEL API UNAVAILABLE'
    end
    return kit,nil
end
function V66.channelList(kit)
    local success,data=pcall(kit.request,'channel.list',{})
    if not success or type(data)~='table' or data.ok~=true
       or type(data.channels)~='table' then
        return nil,'CHANNEL LIST FAILED: '..tostring(
            type(data)=='table' and (data.err or data.code) or data)
    end
    V66.profile.currentNo=nil
    V66.profile.currentName=nil
    V66.profile.currentPlayers=nil
    V66.profile.currentMax=nil
    local candidates={}
    local current=nil
    for _,ch in ipairs(data.channels) do
        if type(ch)=='table' then
            if ch.current==true then
                current=ch
                V66.profile.currentNo=ch.no
                V66.profile.currentName=ch.name
                V66.profile.currentPlayers=tonumber(ch.players)
                V66.profile.currentMax=tonumber(ch.max)
            end
            local count=tonumber(ch.players)
            local capacity=tonumber(ch.max)
            if ch.current~=true and ch.full~=true and ch.photo~=true
               and ch.id~=nil and ch.no~=nil
               and count and count>=0 and count<math.huge
               and capacity and capacity>0 and capacity<math.huge
               and count<capacity then
                candidates[#candidates+1]={
                    no=ch.no,id=ch.id,players=count,max=capacity,
                    name=ch.name}
            end
        end
    end
    table.sort(candidates,function(a,b)
        if a.players~=b.players then return a.players<b.players end
        return tostring(a.no)<tostring(b.no)
    end)
    if #candidates>0 then
        local top={}
        for i=1,math.min(3,#candidates) do
            local ch=candidates[i]
            top[#top+1]='Ch.'..tostring(ch.no)..' '..ch.players..'/'..ch.max
        end
        V66.profile.lowPopSummary=table.concat(top,' | ')
    else
        V66.profile.lowPopSummary='NO ELIGIBLE CHANNEL WITH PLAYER COUNT'
    end
    return {raw=data,candidates=candidates,current=current},nil
end
function V66.currentChannelText()
    local p=V66.profile
    if p.currentNo==nil then return 'CURRENT CHANNEL: UNKNOWN (refresh list)' end
    local s='CURRENT CHANNEL: Ch.'..tostring(p.currentNo)
    if p.currentName and tostring(p.currentName)~=''
       and tostring(p.currentName)~= ('Ch.'..tostring(p.currentNo)) then
        s=s..' ('..tostring(p.currentName)..')'
    end
    if p.currentPlayers~=nil then
        s=s..' | '..tostring(p.currentPlayers)..'/'..tostring(p.currentMax or '?')
    end
    return s
end
function V66.refreshChannels(manual)
    if V66.profile.joinBusy or V66.profile.pollBusy then return end
    V66.profile.pollBusy=true
    V66.profile.lastChannelPoll=os.clock()
    if manual then V66.profile.channelNote='REFRESHING CHANNEL DATA...' end
    task.spawn(function()
        local kit,err=V66.channelApi()
        if not kit then
            V66.profile.lowPopSummary=err
            if manual then V66.profile.channelNote=err end
        else
            local data,why=V66.channelList(kit)
            if not data then
                V66.profile.lowPopSummary=why
                if manual then V66.profile.channelNote=why end
            elseif manual then
                V66.profile.channelNote='CHANNEL DATA UPDATED / '..#data.candidates..' eligible'
            end
        end
        V66.profile.pollBusy=false
    end)
end
function V66.requestLowPop(auto)
    if V66.profile.joinBusy or V66.profile.pollBusy then
        V66.profile.channelNote='CHANNEL REQUEST BUSY / RETRY LATER'
        return
    end
    local safe,why=V66.canSwitchChannel()
    if not safe then
        V66.profile.channelNote=(auto and 'WAIT IDLE: ' or 'BLOCKED: ')..why
        return
    end
    -- Once per injection; after a successful move, do not hop repeatedly
    -- just because settings were loaded on a new server.
    if auto and os.time()-V66.profile.lastLowPopMoveAt<1800 then
        V66.profile.lowPopQueued=false
        V66.profile.lowPopTried=true
        V66.profile.channelNote='LOW POP COOLDOWN: NO RE-HOP FOR 30 MIN'
        return
    end
    V66.profile.lowPopQueued=false
    V66.profile.lowPopTried=true
    V66.profile.joinBusy=true
    V66.profile.channelNote='SCANNING LOW POP CHANNELS...'
    task.spawn(function()
        local kit,err=V66.channelApi()
        if not kit then
            V66.profile.channelNote=err
            V66.profile.joinBusy=false
            return
        end
        local data,why=V66.channelList(kit)
        if not data then
            V66.profile.channelNote=why
            V66.profile.joinBusy=false
            return
        end
        if type(data.raw.maint)=='string' and data.raw.maint~='' then
            V66.profile.channelNote='CHANNEL MAINTENANCE: NOT MOVING'
            V66.profile.joinBusy=false
            return
        end
        local list=data.candidates
        if #list==0 then
            V66.profile.channelNote='NO AVAILABLE NON-PHOTO CHANNEL WITH COUNT'
            V66.profile.joinBusy=false
            return
        end
        -- Pool: up to 3 lowest-populated channels within a small absolute
        -- or proportional margin of the minimum. Avoid busy channels.
        local minimum=list[1].players
        local tolerance=math.max(2,math.ceil(list[1].max*0.05))
        local pool={}
        for _,ch in ipairs(list) do
            if #pool>=3 or ch.players>minimum+tolerance then break end
            pool[#pool+1]=ch
        end
        if auto and data.current and tonumber(data.current.players)
           and tonumber(data.current.players)<=minimum+tolerance
           and data.current.photo~=true then
            V66.profile.channelNote='ALREADY LOW POP: '..V66.currentChannelText()
            V66.profile.joinBusy=false
            return
        end
        local choice=pool[math.random(1,#pool)]
        local allowed,blocked=V66.canSwitchChannel()
        if not allowed then
            V66.profile.channelNote='SWITCH CANCELLED: '..blocked
            V66.profile.joinBusy=false
            return
        end
        V66.profile.channelNote='LOW POP PICK: Ch.'..tostring(choice.no)..' ('..
            choice.players..'/'..choice.max..') / REQUESTING MOVE'
        -- Save current settings, including random-toggle state, before teleport.
        V66.saveConfig(false)
        local ok,res=pcall(kit.request,'channel.move',{id=choice.id})
        if ok and type(res)=='table' and res.ok==true then
            V66.profile.channelNote=res.same and 'ALREADY IN SELECTED CHANNEL'
                or ('MOVE ACCEPTED: Ch.'..tostring(choice.no)..' / TELEPORT PENDING')
            if not res.same then
                V66.profile.lastLowPopMoveAt=os.time()
                V66.saveConfig(false)
            end
        else
            V66.profile.channelNote='LOW POP MOVE FAILED: '..tostring(
                type(res)=='table' and (res.err or res.code) or res)
        end
        V66.profile.joinBusy=false
    end)
end
-- END V6.6 CHANNEL INSPECTION --------------------------------------------

local initialCfg,initialSource=V66.readConfig()
V66.applyConfig(initialCfg,initialSource)
if not initialCfg then V66.styleAllSettings() end
V66.channelInput.FocusLost:Connect(V66.parseChannelInput)
V66.autoChannelButton.MouseButton1Click:Connect(function()
    -- First validate input if enabling auto channel.
    if not V66.profile.autoChannel and not V66.parseChannelInput() then return end
    V66.profile.autoChannel=not V66.profile.autoChannel
    if V66.profile.autoChannel then
        V66.profile.autoLowPop=false
        V66.profile.lowPopQueued=false
        V66.profile.lowPopTried=false
        styleSwitch(V66.lowPopButton,false,'RANDOM LOW POP')
        V66.lowPopButton.BackgroundColor3=COLORS.gray
    end
    V66.profile.joinTried=false
    V66.profile.queued=V66.profile.autoChannel
    V66.profile.nextJoinAt=os.clock()+3
    V66.profile.channelNote=V66.profile.autoChannel and 'ARMED: WAIT UNTIL IDLE' or 'OFF'
    styleSwitch(V66.autoChannelButton,V66.profile.autoChannel,'AUTO CHANNEL')
    V66.markSettingsChanged()
end)
V66.lowPopButton.MouseButton1Click:Connect(function()
    V66.profile.autoLowPop=not V66.profile.autoLowPop
    if V66.profile.autoLowPop then
        V66.profile.autoChannel=false
        V66.profile.queued=false
        V66.profile.joinTried=false
        styleSwitch(V66.autoChannelButton,false,'AUTO CHANNEL')
        V66.profile.lowPopQueued=true
        V66.profile.lowPopTried=false
        V66.profile.nextJoinAt=os.clock()+3
        V66.profile.channelNote='RANDOM LOW POP ARMED: WILL TRY ONCE WHEN IDLE'
    else
        V66.profile.lowPopQueued=false
        V66.profile.lowPopTried=false
        V66.profile.channelNote='RANDOM LOW POP OFF'
    end
    styleSwitch(V66.lowPopButton,V66.profile.autoLowPop,'RANDOM LOW POP')
    V66.lowPopButton.BackgroundColor3=V66.profile.autoLowPop and COLORS.green or COLORS.gray
    V66.markSettingsChanged()
end)
V66.lowPopNowButton.MouseButton1Click:Connect(function()
    -- A manual random pick supersedes any queued fixed-channel one-shot.
    V66.profile.queued=false
    V66.profile.joinTried=true
    V66.requestLowPop(false)
end)
V66.joinChannelButton.MouseButton1Click:Connect(function()
    if V66.parseChannelInput() then V66.requestChannel(false) end
end)
V66.checkChannelButton.MouseButton1Click:Connect(function()
    V66.refreshChannels(true)
end)
noClipButton.MouseButton1Click:Connect(function()
    setNpcNoClip(not npcNoClip.enabled)
    styleSwitch(noClipButton,npcNoClip.enabled,'NPC NOCLIP')
    noClipButton.BackgroundColor3=npcNoClip.enabled and COLORS.green or COLORS.gray
    V66.markSettingsChanged()
end)
V66.autoSaveButton.MouseButton1Click:Connect(function()
    V66.profile.autoSave=not V66.profile.autoSave
    styleSwitch(V66.autoSaveButton,V66.profile.autoSave,'AUTO SAVE')
    -- Persist ON/OFF choice once, even when switching Auto Save OFF.
    V66.saveConfig(true)
end)
V66.saveNowButton.MouseButton1Click:Connect(function() V66.saveConfig(true) end)
V66.loadNowButton.MouseButton1Click:Connect(function()
    if bridge.owns or escape.active or lane.active or cycle.stage=='QUEST'
       or cycle.stage=='RETURN_NPC' or cycle.stage=='TALK' then
        V66.profile.saveNote='LOAD BLOCKED: STOP AUTODRIVE / QUEST FIRST'
        return
    end
    local cfg,source=V66.readConfig()
    V66.applyConfig(cfg,source)
end)
-- END V6.6 SETTINGS ------------------------------------------------------

updateTier()
styleSwitch(speedButton,speedV6.enabled,'SPEED')
styleSwitch(assistButton,speedV6.assist,'ACCEL ASSIST')
styleSwitch(laneButton,lane.enabled,'AUTO LANE')
styleSwitch(boostButton,bridge.autoBoost,'AUTO BOOST')
styleSwitch(quickButton,bridge.autoQuickStart,'QUICKSTART')
styleSwitch(unstuckButton,unstuck.enabled,'AUTO J')
styleSwitch(escape.ui.button,escape.enabled,'AUTO REVERSE')
styleSwitch(loopButton,cycle.enabled,'LOOP')
styleSwitch(claimButton,cycle.claim,'CLAIM')
styleSwitch(nextButton,bridge.autoNext,'NEXT')
styleSwitch(npcCloseButton,cycle.autoDismissNpc,'NPC CLOSE')
styleSwitch(failButton,cycle.autoFailRetry,'AUTO FAIL RETRY')
failButton.BackgroundColor3=cycle.autoFailRetry and COLORS.green or COLORS.gray
styleSwitch(evadeButton,bridge.autoEvade,'AUTO Z/X')
styleSwitch(jumpButton,bridge.jumpFallback,'AUTO JUMP')
styleSwitch(noClipButton,npcNoClip.enabled,'NPC NOCLIP')
noClipButton.BackgroundColor3=npcNoClip.enabled and COLORS.green or COLORS.gray
local visualTick=0
local function closeEverything()
    if not bridge.alive then return end
    V66.saveConfig(false)
    restoreNpcTrafficHook()
    bridge.alive=false
    cycle.enabled=false
    unstuck.pending=false
    stopNative('GUI CLOSED')
    releaseNpcParking()
    speedEnable(false)
    clearVisual()
    gui:Destroy()
end
quit.MouseButton1Click:Connect(closeEverything)
gui.Destroying:Connect(function()
    if bridge.alive then
        V66.saveConfig(false)
        restoreNpcTrafficHook()
        bridge.alive=false;cycle.enabled=false
        stopNative('GUI DESTROYED');releaseNpcParking();speedEnable(false);clearVisual()
    end
end)
-- END RAYCITY X UI --------------------------------------------------------

local lastWatch=0
local lastHud=0
local lastSpeedWatch=0
local lastRadarWatch=0
local lastAbilityWatch=0
local connection
connection=RunService.Heartbeat:Connect(function(dt)
    if not bridge.alive or not gui.Parent then
        restoreNpcTrafficHook()
        if connection then connection:Disconnect() end
        return
    end
    local now=os.clock()
    npcNoClipTick(now,false)
    -- One auto-channel attempt on load/enable; never during a live quest.
    if V66.profile.autoChannel and V66.profile.queued and not V66.profile.joinTried
       and not V66.profile.joinBusy and now>=V66.profile.nextJoinAt
       and now-V66.profile.lastAutoPoll>=2 then
        V66.profile.lastAutoPoll=now
        local safe=V66.canSwitchChannel()
        if safe then V66.requestChannel(true) end
    end
    -- Read-only current-channel refresh. No server move unless user opts in.
    if now-V66.profile.lastChannelPoll>=60 and not V66.profile.pollBusy
       and not V66.profile.joinBusy then
        V66.refreshChannels(false)
    end
    if V66.profile.autoLowPop and V66.profile.lowPopQueued
       and not V66.profile.lowPopTried and not V66.profile.joinBusy
       and not V66.profile.pollBusy and now>=V66.profile.nextJoinAt
       and now-V66.profile.lastAutoPoll>=2 then
        V66.profile.lastAutoPoll=now
        local safe=V66.canSwitchChannel()
        if safe then V66.requestLowPop(true) end
    end
    escape.tick(now)
    laneTick(now)
    unstuckTick(now)
    npcParkingTick(now)
    speedTick(math.min(0.05,dt or 0.016))
    -- Keep braking-distance speed envelope responsive even at high road speed.
    if bridge.owns and now-lastSpeedWatch>=0.20 then
        lastSpeedWatch=now
        local _,speedRoot=carRoot()
        if speedRoot then updateCruiseSpeed(speedRoot) end
    end
    -- Forward obstacle scan is independent of the slower quest UI check.
    if bridge.owns and now-lastRadarWatch>=0.18 then
        lastRadarWatch=now
        local car,root=carRoot()
        if car and root then evadeTick(car,root,livePhysics(),now) end
    end
    -- Skill actions at ~5 Hz, never two different AutoCmd values together.
    if bridge.owns and now-lastAbilityWatch>=0.20 then
        lastAbilityWatch=now
        local car,root=carRoot()
        local status=activeState()
        local p=livePhysics()
        if car and root and status and p then
            if not lane.active then
                autoQuickStartTick(car,root,status,p,now)
                autoBoostTick(car,root,status,now)
            end
        end
    end
    if now-lastWatch>=1.25 then
        lastWatch=now
        if bridge.owns then
            local car,root=carRoot()
            local status=activeState()
            if not car or not root or not status then
                stopNative('CAR / NATIVE STATE LOST')
            elseif status.active~=true then
                bridge.owns=false
                restoreTuning()
                bridge.note='NATIVE STOPPED: '..tostring(status.lastError and status.lastError.msg or 'arrived / blocked')
                -- No automatic retry at unchanged destination. Prevent loop.
            else
                local s=questState()
                local objs=liveDestinations(s)
                if cycle.stage=='QUEST' and bridge.autoNext and s and #objs>0 then
                    local still=false
                    for _,obj in ipairs(objs) do
                        if obj.id==bridge.selectedIndex then still=true;break end
                    end
                    local passChanged=bridge.requestedPass~=nil and
                        tonumber(s.passCount)~=nil and tonumber(s.passCount)>tonumber(bridge.requestedPass)
                    if (not still or passChanged) and now-bridge.lastRequestAt>4 then
                        local target,source,obj=chooseDestination()
                        if target and obj and obj.idx~=bridge.selectedIndex then
                            startNative(target,source,obj)
                        end
                    end
                end
                local dist=bridge.lastPosition and (root.Position-bridge.lastPosition).Magnitude or 100
                if dist<1.5 then
                    bridge.stagnantSince=bridge.stagnantSince or now
                    if now-bridge.stagnantSince>8 and not unstuck.enabled
                       and not unstuck.pending then
                        stopNative('STUCK: STOPPED, AUTO J OFF')
                    end
                else
                    bridge.stagnantSince=nil
                    bridge.lastPosition=root.Position
                end
                if tonumber(status.warps) and status.warps>unstuck.lastNativeWarps then
                    -- Own J reset is an intentional game reposition, not an
                    -- accidental AutoDrive warp; don't abort that recovery.
                    if now>unstuck.ignoreWarpUntil then
                        stopNative('NATIVE WARP DETECTED: STOP')
                    end
                end
                unstuck.lastNativeWarps=tonumber(status.warps) or 0
            end
        elseif cycle.stage=='QUEST' and bridge.armed and bridge.autoNext and now-bridge.lastRequestAt>5 then
            -- Native may have finished before QuestPush arrives. Restart only
            -- after an actual game objective/goal change; never retry the
            -- same unsuccessful checkpoint in a tight loop.
            local target,source,obj=chooseDestination()
            if target and obj and obj.quest then
                local newToken=tostring(obj.quest.questId)..':'..
                    tostring(obj.quest.step)..':'..tostring(obj.idx)
                local newPass=tonumber(obj.quest.passCount)
                local oldPass=tonumber(bridge.requestedPass)
                if newToken~=bridge.lastQuestToken
                   or (newPass and oldPass and newPass>oldPass) then
                    startNative(target,source,obj)
                end
            end
        end
    end
    if now-(cycle.lastCycleTick or 0)>=0.55 then
        cycle.lastCycleTick=now
        cycleTick(now)
        dismissDuplicateNpcDialog(now)
    end
    if now-visualTick>=0.65 then
        visualTick=now
        if visual.npc or visual.traffic or visual.pass then refreshVisual(now) end
    end
    if now-lastHud>=0.3 then
        lastHud=now
        local car,root=carRoot()
        local s=questState()
        local d=activeState()
        local dist=bridge.selectedGoal and root and
            (xz(root.Position)-xz(bridge.selectedGoal)).Magnitude or nil
        local centre=bridge.activeDest and bridge.activeDest.center
        local inside=(bridge.activeDest and root and type(bridge.activeDest.poly)=='table'
            and pointInPolygon(root.Position,bridge.activeDest.poly)
            and (typeof(centre)~='Vector3' or math.abs(root.Position.Y-centre.Y)<18)) or false
        bridge.passInside=inside
        local gas=car and car:GetAttribute('AutoThrottle')
        local brake=car and car:GetAttribute('AutoBrake')
        label.Text=table.concat({
            'LOOP '..cycle.stage..' | LAST R'..cycle.selectedRound..' ('..cycle.selectedQuestId..')'
                ..' | NPC CLOSE '..(cycle.autoDismissNpc and 'ON' or 'OFF'),
            'ACCEPT: '..cycle.acceptProtocol..' | '..cycle.roadFightOffer..' | '..cycle.npcPopupNote,
            'LAST ACCEPT ERROR: '..tostring(cycle.lastAcceptError),
            'FAIL RECOVERY: '..(cycle.autoFailRetry and 'ON' or 'OFF')
                ..' / FAILS '..cycle.failCount..' / '..cycle.failNote,
            'FAIL LAST: '..tostring(cycle.failLastReason),
            'CYCLE: '..cycle.note,
            'CAR: '..(root and root:GetFullName() or 'NOT FOUND'),
            'NATIVE: '..(d and (d.active and 'ACTIVE' or 'IDLE') or 'UNAVAILABLE')..' | OWN: '..tostring(bridge.owns),
            'QUEST: '..(s and (tostring(s.questId)..' STEP '..tostring(s.step)..' PASS '..tostring(s.passCount)) or 'state not exposed'),
            'TARGET: '..bridge.goalSource..(dist and (' | '..math.floor(dist)..' studs') or ''),
            'ROAD: '..(d and tostring(d.routeSrc) or '-')..' | WARP: '..(d and tostring(d.warps) or '-'),
            'PASS: '..bridge.passSource..' | depth '..string.format('%.1f',bridge.passDepth)..' studs',
            'INSIDE PASS: '..tostring(inside)..' | NATIVE NEAR: '..(d and tostring(d.near) or '-'),
            'GAS '..tostring(gas or '-')..' | BRAKE '..tostring(brake or '-')..
                ' | LIMIT '..math.floor(bridge.lastSpeedCap+0.5)..' km/h',
            'SP '..(bridge.spNow and math.floor(bridge.spNow)..'/'..tostring(bridge.spMax or '?') or '?')..
                ' | BOOST '..bridge.boostNote..' #'..bridge.boostCount,
            'QUICKSTART '..bridge.quickNote..' #'..bridge.quickStartCount,
            string.format('AUTO J %s | %.1f km/h | 3s < 5 | #%d | %s',
                unstuck.enabled and 'ON' or 'OFF',unstuck.speed,unstuck.attempts,unstuck.note),
            'NPC NOCLIP: '..tostring(npcNoClip.enabled)..' / '..npcNoClip.note,
            'RADAR '..tostring(bridge.radarModels)..' cars | OBSTACLE '..(bridge.hazard and (tostring(bridge.hazard)..' '..math.floor(bridge.hazardDistance or 0)..' st') or '-')..
                ' | '..bridge.evadeNote,
            'LANE: '..tostring(lane.note)..' | ACTIVE '..tostring(lane.active)..' | SHIFTED '..lane.successes,
            'NPC PARK: '..npcParking.note,
            'REVERSE: '..escape.note..' | #'..escape.attempts..' moved '..string.format('%.1f',escape.moved)..' st',
            'STATUS: '..bridge.note
        },'\n')
        local spText=bridge.spNow and (math.floor(bridge.spNow)..'/'..tostring(bridge.spMax or '?')) or '?'
        local phys=speedV6.drive and physicsDriveValid(speedV6.drive) and speedV6.drive.phys or livePhysics()
        local kmh=phys and typeof(phys.v)=='Vector3' and math.floor(phys.v.Magnitude*3.6+0.5) or 0
        local nativeC=AUTO and AUTO.C
        local heading=d and tonumber(d.cosHeading)
        local routeKmh=(nativeC and tonumber(nativeC.maxSpeed) or 0)*3.6
        local turnKmh=math.huge
        local limitReason='STRAIGHT'
        if nativeC and heading then
            if heading < (tonumber(nativeC.capCos3) or 0.5) then
                turnKmh=(tonumber(nativeC.cap3) or 0)*3.6
                limitReason='SHARP TURN'
            elseif heading < (tonumber(nativeC.capCos2) or 0.7) then
                turnKmh=(tonumber(nativeC.cap2) or 0)*3.6
                limitReason='TURN'
            elseif heading < (tonumber(nativeC.capCos1) or 0.866) then
                turnKmh=(tonumber(nativeC.cap1) or 0)*3.6
                limitReason='BEND'
            end
        end
        local nativeLimit=math.min(routeKmh,turnKmh)
        if bridge.owns and nativeC and heading then
            if routeKmh < turnKmh and routeKmh < speedV6.targetKmh-2 then
                limitReason=(bridge.activeDest and bridge.activeDest.stop==true)
                    and 'NPC APPROACH' or 'PASS APPROACH'
            elseif turnKmh<routeKmh then
                limitReason=limitReason..' LIMIT'
            elseif phys and phys.boosting then
                limitReason='BOOST OPEN ROAD'
            end
            speedV6.nativeLimitKmh=nativeLimit
            speedV6.nativeLimitReason=limitReason
            speedV6.nativeHeading=heading
            speedV6.nativeTurnKmh=turnKmh
        else
            speedV6.nativeLimitKmh=0
            speedV6.nativeLimitReason='NATIVE IDLE / NO ROUTE STATE'
        end
        local gas=car and tonumber(car:GetAttribute('AutoThrottle'))
        local brake=car and tonumber(car:GetAttribute('AutoBrake'))
        speedDiag.Text='NATIVE LIMIT '..(bridge.owns and tostring(math.floor(nativeLimit+0.5)) or '-')
            ..' km/h | '..speedV6.nativeLimitReason
            ..'\nGAS '..(gas and string.format('%.1f',gas) or '-')
            ..'  BRAKE '..(brake and string.format('%.1f',brake) or '-')
            ..'  HEADING '..(heading and string.format('%.2f',heading) or '-')
        laneLine.Text=(lane.active and 'ROUTING SIDE LANE' or (lane.enabled and 'AUTO ARMED' or 'AUTO OFF'))
            ..' | Attempts '..lane.tries..' / Side shifts '..lane.successes
            ..'\n'..tostring(lane.note)
            ..'\nNote: native GPS may still select the original lane.'
        speedLive.Text='SPEED '..tostring(speedV6.targetKmh)..' | REAL '..kmh
            ..' | PHYS CAP '..tostring(math.floor(speedV6.effectiveLimitKmh or speedV6.targetKmh))
            ..(speedV6.boostOvercap and ' BOOST' or '')
        nativeLine.Text=(bridge.owns and 'NATIVE: ACTIVE' or 'NATIVE: IDLE')
            ..' | '..bridge.note
        local nDist=(root and cycle.npcPos) and
            (xz(root.Position)-xz(cycle.npcPos)).Magnitude or nil
        npcStopLine.Text=string.format('MODE %s | NPC %s st | %d km/h | %s',
            cycle.stage, nDist and tostring(math.floor(nDist)) or '-',kmh,
            (cycle.stage=='RETURN_NPC' and not npcParking.active)
                and ('APPROACH CAP '..math.floor(bridge.lastSpeedCap+0.5)..' km/h')
                or npcParking.note)
        spStatus.Text='SP '..spText..' | BOOST '..bridge.boostNote
            ..'\nQuick Start: '..bridge.quickNote
            ..' | Boost count: '..bridge.boostCount
        unstuckStatus.Text=unstuck.note..' | #'..unstuck.attempts
        escape.ui.status.Text=tostring(escape.note)
            ..' | '..tostring(escape.attempts)..' tries / '..tostring(escape.successes)..' shifted'
        questLine.Text='LOOP: '..cycle.stage..' | '..cycle.note
        failStatus.Text='FAILS '..cycle.failCount..' | STREAK '..cycle.failStreak
            ..' | '..cycle.failNote..'\nLAST: '..cycle.failLastReason
        radarLine.Text='NPC: '..tostring(bridge.npcRadar or 0)
            ..'   PLAYERS: '..tostring(bridge.playerRadar or 0)
            ..'\nTARGET: '..tostring(bridge.hazard or '-')
            ..'\nDIST: '..tostring(bridge.hazardDistance and math.floor(bridge.hazardDistance) or '-')
            ..'   TTC: '..tostring(bridge.hazardTtc and bridge.hazardTtc<100 and string.format('%.1f',bridge.hazardTtc) or '-')
        noClipStatus.Text=npcNoClip.note..' | apply # '..tostring(npcNoClip.swaps)
            ..' | Client only; server may still validate collisions'
        visualLine.Text='Radar: '..(bridge.evadeNote or '-')
        V66.currentChannelLabel.Text=V66.currentChannelText()
        V66.lowPopInfo.Text='LOW POP: '..V66.profile.lowPopSummary
        V66.channelStatus.Text='FIXED AUTO '..(V66.profile.autoChannel and 'ON' or 'OFF')..
            ' | RANDOM LOW POP '..(V66.profile.autoLowPop and 'ON' or 'OFF')..
            '\nFIXED TARGET '..tostring(V66.profile.channelNo or '-')..
            '\nSTATUS: '..V66.profile.channelNote
        V66.settingsStatus.Text='AUTO SAVE '..(V66.profile.autoSave and 'ON' or 'OFF')..
            ' | SOURCE '..V66.profile.loadedSource..'\n'..V66.profile.saveNote..
            '\nFile: '..V66.CONFIG_FILE
    end
end)

if not AUTO then bridge.note='AUTO MODULE NOT FOUND' end
print('[RayCity X V6.9] Auto failed-quest return/retry; V6.8 NoClip, speed, random quest, channel and autosave retained')
