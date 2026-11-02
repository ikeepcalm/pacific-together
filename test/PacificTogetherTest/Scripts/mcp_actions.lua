-- Game MCP "actions" (tools/gamemcp/ext_actions.py): make the local player do things in a running test game, one call each.
-- Runs through the live console, so everything is in scope as T.act_*. An action starts with T.act_begin(name, opts) and finishes
-- over the next frames (the console cannot block); T.act_poll(id) returns "pending" or "done\n<text>" / "err\n<text>".
-- Scenarios use the same pair: T.act_begin / T.act_done(id) (see promote in ext_actions.py). Test copies only, never shipped.
-- Every result starts with "path: ..." naming the game code path that did the work (the game's own input/interaction functions
-- where there is one, a clearly named fallback otherwise) and ends with state read back from the game.
local UEHelpers = require("UEHelpers")

return function(T)
    local GS = UEHelpers.GetGameplayStatics()
    T.act_loaded = os.date("%H:%M:%S")
    local ACT, jobs, nextId = {}, {}, 0

    -- ---------------------------------------------------------------- small helpers
    local function now()
        local s, p = {}, {}
        GS:GetAccurateRealTime(s, p)
        return s.Seconds + p.PartialSeconds
    end
    local function fmt(p) return p and string.format("(%.1f, %.1f, %.1f)", p.X, p.Y, p.Z) or "nil" end
    local function v3(x, y, z) return { X = x, Y = y, Z = z } end
    local function dist3(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2 + (a.Z - b.Z) ^ 2) end
    local function dist2(a, b) return math.sqrt((a.X - b.X) ^ 2 + (a.Y - b.Y) ^ 2) end
    local function alive(o) return o ~= nil and o:IsValid() end
    local function pc() local c = T.localPC(); assert(c, "no local PlayerController (not in a world yet?)"); return c end
    -- the character this side controls (not the car): the possessed pawn, or the character manager's one when driving
    local function char()
        local p = T.myPawn()
        if p and T.cls(p) == T.CHAR then return p end
        local m = T.first("BP_MainCharacterManager_C")
        local c = m and m.CharacterActor
        if alive(c) then return c end
        error("no character: the controlled pawn is " .. T.cls(p))
    end
    local function ground(a) return T.cls(a) end

    -- PlayerCarState of the car manager: 0 on foot, 2 entering / leaving (about 2.5 s), 1 in the car. In the real game the controller
    -- keeps the character as its pawn (attached to the car) and the view target is the car; only the fallback Possesses the car.
    local function carMode()
        local m = T.first("BP_CarManager_C")
        local st = {}
        m["Get PlayerCarState"](m, st)
        return tonumber(st.ReturnedState)
    end
    local function onFoot(what) assert(carMode() == 0, what .. ": the player is in or entering the car (state " .. tostring(carMode()) .. "): exit_car first") end

    -- ---------------------------------------------------------------- jobs
    local function newJob(name, opts)
        nextId = nextId + 1
        local j = { id = nextId, name = name, opts = opts or {}, t0 = now(), state = "pending" }
        function j.finish(text) if j.state == "pending" then j.state, j.text = "done", text end end
        function j.fail(text) if j.state == "pending" then j.state, j.text = "err", text end end
        jobs[j.id] = j
        for k in pairs(jobs) do if k < j.id - 40 then jobs[k] = nil end end
        return j
    end
    -- run fn(elapsedSeconds) every frame until it returns a string (the result) or timeoutS passes (onTimeout() gives the result)
    local function frames(job, fn, timeoutS, onTimeout)
        local t0, loop = now(), nil
        loop = LoopInGameThreadWithDelay(1, function()
            if job.state ~= "pending" then CancelDelayedAction(loop); return end
            local el = now() - t0
            local ok, r = pcall(fn, el)
            if not ok then CancelDelayedAction(loop); job.fail(tostring(r)); return end
            if type(r) == "string" then CancelDelayedAction(loop); job.finish(r); return end
            if el >= timeoutS then
                CancelDelayedAction(loop)
                local ok2, r2 = pcall(onTimeout or function() return "timeout after " .. timeoutS .. " s" end)
                if ok2 then job.finish(r2) else job.fail(tostring(r2)) end
            end
        end)
        job.loop = loop
    end
    -- wait n frames, then fn() -> result string
    local function afterFrames(job, n, fn)
        local k = 0
        frames(job, function() k = k + 1; if k >= n then return fn() end end, 30, fn)
    end

    function T.act_begin(name, opts)
        assert(ACT[name], "unknown action " .. tostring(name))
        local j = newJob(name, opts)
        local ok, r = pcall(ACT[name], j.opts, j)
        if not ok then j.fail(tostring(r):gsub("^[^:]*:%d+: ", ""))
        elseif type(r) == "string" then j.finish(r) end
        T.log("PT|act %s id=%d state=%s", name, j.id, j.state)
        return j.id
    end
    function T.act_done(id)
        local j = jobs[id]
        if not j then return true, "no such job " .. tostring(id), false end
        return j.state ~= "pending", j.text, j.state == "done"
    end
    function T.act_poll(id)
        local d, text, ok = T.act_done(id)
        if not d then return "pending" end
        return (ok and "done\n" or "err\n") .. text
    end
    function T.act_cancel(id)
        local j = jobs[id]
        if j and j.state == "pending" then j.fail("cancelled") end
        return "ok"
    end

    -- ---------------------------------------------------------------- targets
    -- opts.actor = object path / full name, or "nearest <Class>" (nearest to the player); opts.x/y/z = a point
    -- the garage streams sub-levels (Garage_Art, Garage_Mission) whose actors have their own World; dead copies have none
    local function liveWorld(a) local ok, w = pcall(function() return a:GetWorld() end); return ok and alive(w) end
    local function nearestOf(class)
        local me = pc().Pawn
        local from = me:K2_GetActorLocation()
        local best, bd, dbg
        local seen = {}
        local function try(a)
            if alive(a) and liveWorld(a) and not a:GetFullName():find("Default__", 1, true) and not seen[a:GetFullName()] then
                seen[a:GetFullName()] = true
                local ok, d = pcall(function() return dist3(a:K2_GetActorLocation(), from) end)
                if not ok then dbg = tostring(d) end
                if ok and (not bd or d < bd) then best, bd = a, d end
            end
        end
        for _, a in ipairs(FindAllOf(class) or {}) do try(a) end
        -- some interactables are missed by a class-name search; their highlight components still find them
        for _, h in ipairs(FindAllOf("HighlightComponent") or {}) do
            if alive(h) then local a = h:GetOwner(); if alive(a) and a:GetClass():GetFName():ToString() == class then try(a) end end
        end
        assert(best, "no live '" .. class .. "' in this world" .. (dbg and (" (" .. dbg .. ")") or ""))
        return best, bd
    end
    local function resolve(o)
        if o.actor and o.actor ~= "" then
            local cls = tostring(o.actor):match("^nearest%s+(%S+)$")
            local a
            if cls then a = nearestOf(cls) else a = T.mcp_obj(o.actor) end
            return a, a:K2_GetActorLocation(), "actor " .. T.cls(a) .. " " .. a:GetFName():ToString()
        end
        assert(o.x and o.y and o.z, "give a location (x, y, z) or an actor")
        return nil, v3(o.x, o.y, o.z), "point " .. fmt(v3(o.x, o.y, o.z))
    end
    -- the point to look at on an interactable: its highlight collision, else the actor
    local function highlightsOf(a)
        local r = {}
        for _, h in ipairs(FindAllOf("HighlightComponent") or {}) do
            if alive(h) and alive(h:GetOwner()) and h:GetOwner():GetFullName() == a:GetFullName() then r[#r + 1] = h end
        end
        return r
    end
    -- centre of the highlight's collision volume that is nearest to the player (a mesh pivot is often on the floor or a hinge)
    local KSL = UEHelpers.GetKismetSystemLibrary()
    -- bounds origin of a component; a collision far from the player can report exactly 0,0,0 (not updated yet): its location then
    -- (a highlight's collision array can hold null components, e.g. the car's door handles have 2 entries and one is null: nil then)
    local function boundsOrigin(c)
        local ok, res = pcall(function()
            local o, e, r = {}, {}, {}
            KSL:GetComponentBounds(c, o, e, r)
            if o.X == 0 and o.Y == 0 and o.Z == 0 then o = c:K2_GetComponentLocation() end
            if o.X and not (o.X == 0 and o.Y == 0 and o.Z == 0) then return v3(o.X, o.Y, o.Z) end
        end)
        return ok and res or nil
    end
    local function centerOf(a, comp)
        local best, bd
        pcall(function()
            local hc = (comp or a.Highlight).HighlightCollision
            local from = pc().Pawn:K2_GetActorLocation()
            for i = 1, hc:GetArrayNum() do
                local o = boundsOrigin(hc[i])
                if o then
                    local d = dist3(o, from)
                    if not bd or d < bd then best, bd = o, d end
                end
            end
        end)
        return best or a:K2_GetActorLocation()
    end
    local function aimAt(p)
        local c = pc()
        local cam = c.PlayerCameraManager:GetCameraLocation()
        local dx, dy, dz = p.X - cam.X, p.Y - cam.Y, p.Z - cam.Z
        local yaw, pitch = math.deg(math.atan(dy, dx)), math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy)))
        c:SetControlRotation({ Pitch = pitch, Yaw = yaw, Roll = 0 })
        return yaw, pitch
    end
    local function angErr(yaw, pitch)
        local r = pc():GetControlRotation()
        local dy = (r.Yaw - yaw + 180) % 360 - 180
        return math.sqrt(dy * dy + (r.Pitch - pitch) ^ 2)
    end
    -- a spot `off` uu from the actor's centre on the side the player is on, at the player's height
    local function standoff(p, from, off)
        local dx, dy = from.X - p.X, from.Y - p.Y
        local l = math.sqrt(dx * dx + dy * dy)
        if l < 1 then dx, dy, l = 1, 0, 1 end
        return v3(p.X + dx / l * off, p.Y + dy / l * off, from.Z)
    end

    -- ---------------------------------------------------------------- 1. player
    -- teleport: the game's own character-placement function (what BPI_TeleportPlayer calls), K2_SetActorLocation if it did not land
    local function place(c, dest)
        local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = dest, Scale3D = v3(1, 1, 1) }
        local ok, err = pcall(function() c:K2_HandleSetCharacterLocation(xf, false, false) end)
        return ok, err
    end
    function ACT.teleport(o, job)
        onFoot("teleport")
        local c = char()
        local from = c:K2_GetActorLocation()
        local a, loc, desc = resolve(o)
        local dest = loc
        if a and not o.exact then dest = standoff(loc, from, tonumber(o.offset) or 150) end
        local path = "BaseCharacter:K2_HandleSetCharacterLocation (the game's own player placement)"
        local ok, err = place(c, dest)
        if not ok then path = "K2_SetActorLocation (fallback: K2_HandleSetCharacterLocation failed: " .. tostring(err) .. ")"; c:K2_SetActorLocation(dest, false, {}, true) end
        afterFrames(job, 6, function()
            local to = c:K2_GetActorLocation()
            if dist3(to, dest) > 80 and ok then
                path = path .. "; did not land, K2_SetActorLocation fallback used"
                c:K2_SetActorLocation(dest, false, {}, true)
                to = c:K2_GetActorLocation()
            end
            return string.format("path: %s\ntarget: %s\nfrom %s to %s (wanted %s, off by %.1f uu)", path, desc, fmt(from), fmt(to), fmt(dest), dist3(to, dest))
        end)
    end

    -- look_at: the control rotation (where the mouse ends up), aimed from the camera
    function ACT.look_at(o, job)
        local a, loc, desc = resolve(o)
        local p = a and centerOf(a) or loc
        local yaw, pitch = aimAt(p)
        afterFrames(job, 2, function()
            local r = pc():GetControlRotation()
            return string.format("path: PlayerController:SetControlRotation (the end result of mouse look; Command Look* not used)\ntarget: %s at %s\ncontrol rotation now yaw %.1f pitch %.1f (wanted %.1f / %.1f, error %.2f deg)", desc, fmt(p), r.Yaw, r.Pitch, yaw, pitch, angErr(yaw, pitch))
        end)
    end

    -- move_to: the player's own input handler, "Command Move Forward/Backward", every frame, with the camera turned to the target.
    -- The handler stores an axis that real input rewrites every frame, so a single call moves ~nothing: it has to be per frame.
    function ACT.move_to(o, job)
        onFoot("move_to")
        local c = char()
        local a, loc, desc = resolve(o)
        local near, timeout = tonumber(o.radius) or 80, tonumber(o.timeout) or 15
        local start, last, lastAt, travelled = c:K2_GetActorLocation(), nil, 0, 0
        if o.sprint then c["Command Sprint"](c, true) end
        local function stop(why)
            pcall(function() c["Command Move Forward/Backward"](c, 0.0) end)
            if o.sprint then pcall(function() c["Command Sprint"](c, false) end) end
            local e = c:K2_GetActorLocation()
            return string.format("path: PDP_MainCharacter:\"Command Move Forward/Backward\"(1.0) every frame + control rotation towards the target%s\nresult: %s\ntarget: %s\nfrom %s to %s, %.0f uu left (horizontal), walked %.0f uu in %.1f s",
                o.sprint and " + \"Command Sprint\"" or "", why, desc, fmt(start), fmt(e), dist2(e, loc), travelled, now() - job.t0)
        end
        frames(job, function(el)
            local p = c:K2_GetActorLocation()
            if last then travelled = travelled + dist2(p, last) end
            last = p
            if dist2(p, loc) <= near then return stop("arrived (within " .. near .. " uu)") end
            if el - lastAt >= 1.5 then
                if travelled < (job.mark or -1000) + 20 and el > 1.5 then return stop("stuck: moved less than 20 uu in 1.5 s") end
                job.mark, lastAt = travelled, el
            end
            pc():SetControlRotation({ Pitch = 0, Yaw = math.deg(math.atan(loc.Y - p.Y, loc.X - p.X)), Roll = 0 })
            c["Command Move Forward/Backward"](c, 1.0)
        end, timeout, function() return stop("timeout after " .. timeout .. " s") end)
    end

    -- crouch: "Command Crouch Toggle" (the key), only when the state differs
    function ACT.crouch(o, job)
        local c = char()
        local want = o.on ~= false
        local was = c.bIsCrouched
        local sent = false
        if was ~= want then c["Command Crouch Toggle"](c); sent = true end
        local function report()
            return string.format("path: PDP_MainCharacter:\"Command Crouch Toggle\" (%s)\ncrouched %s -> %s (wanted %s), ALS_Stance=%s", sent and "sent" or "already in that state, not sent", tostring(was), tostring(c.bIsCrouched), tostring(want), tostring(c.ALS_Stance))
        end
        frames(job, function(el) if c.bIsCrouched == want then return report() end end, 1.5, report)
    end

    -- sprint: "Command Sprint"(on); the gait only counts while moving forward, the speed cap shows at once
    function ACT.sprint(o, job)
        local c = char()
        local want = o.on ~= false
        local was = c.ALS_Gait
        c["Command Sprint"](c, want)
        afterFrames(job, 8, function()
            return string.format("path: PDP_MainCharacter:\"Command Sprint\"(%s)\nALS_Gait %s -> %s (1 = run, 2 = sprint), MaxWalkSpeed %.0f", tostring(want), tostring(was), tostring(c.ALS_Gait), c.CharacterMovement.MaxWalkSpeed)
        end)
    end

    -- jump: "Command Jump" pressed (0) then released (1) after 8 frames, like a key tap; standing up first when crouched
    function ACT.jump(o, job)
        onFoot("jump")
        local c = char()
        local cm, prefix = c.CharacterMovement, ""
        if c.bIsCrouched then c["Command Crouch Toggle"](c); prefix = "stood up first (jump does nothing while crouched); " end
        local z0, peak, fell, k, pressed = nil, 0, false, 0, false
        frames(job, function(el)
            k = k + 1
            if not pressed and (not c.bIsCrouched or el > 1) and k >= (prefix ~= "" and 15 or 1) then
                pressed = true; z0 = c:K2_GetActorLocation().Z; k = 0
                c["Command Jump"](c, 0)
            end
            if not pressed then return end
            if k == 8 then c["Command Jump"](c, 1) end
            peak = math.max(peak, c:K2_GetActorLocation().Z - z0)
            if tostring(cm.MovementMode) == "3" then fell = true end
            if fell and tostring(cm.MovementMode) ~= "3" then
                return string.format("path: %sPDP_MainCharacter:\"Command Jump\"(Pressed) then (Released)\njumped: peak %.1f uu above take-off, airborne %.2f s, landed (MovementMode %s)", prefix, peak, el, tostring(cm.MovementMode))
            end
        end, 3, function() return string.format("path: %sPDP_MainCharacter:\"Command Jump\"\nno jump seen: peak %.1f uu, MovementMode %s (blocked by a menu, attached, or in the car?)", prefix, peak, tostring(cm.MovementMode)) end)
    end

    -- ---------------------------------------------------------------- 2. interaction
    -- what fired: the game's own HighlightComponent entry points, recorded once hooked
    local fired, hooked = {}, false
    local function hookFiring()
        if hooked then return end
        hooked = true
        for _, fn in ipairs({ "InteractPressed", "InteractReleased", "OnShortInteractTimeComplete", "OnInteractTimeComplete" }) do
            pcall(function()
                RegisterHook("/Script/PenDriverPro.HighlightComponent:" .. fn, function(self)
                    local ok, o = pcall(function() return self:get():GetOwner() end)
                    fired[#fired + 1] = fn .. "(" .. (ok and alive(o) and (T.cls(o) .. " " .. o:GetFName():ToString()) or "?") .. ")"
                end)
            end)
        end
    end
    local function menuOpen()
        local o = {}
        local ok = pcall(function() T.first("BP_InventoryManager_C"):IsPlayerMenuOpen(o, {}) end)
        return ok and o.IsOpen == true
    end
    local function invCount()
        local im = T.first("BP_InventoryManager_C")
        return im.Inventory_Player:GetNumItems() + im.Inventory_PlayerHand:GetNumItems()
    end
    local function highlighted() local h = T.first("BP_HighlightManager_C").CurrentHighlight; return alive(h) and h or nil end
    -- scalar properties of the target's own Blueprint classes, to show what the interaction changed (door open, lid, state enums)
    local function propSnap(a)
        local r = {}
        local c, depth = a:GetClass(), 0
        while c and c:IsValid() and depth < 6 do
            local cn = c:GetFName():ToString()
            if cn == "Actor" then break end
            c:ForEachProperty(function(p)
                local ty = p:GetClass():GetFName():ToString()
                if ty == "BoolProperty" or ty == "IntProperty" or ty == "FloatProperty" or ty == "ByteProperty" or ty == "EnumProperty" then
                    local n = p:GetFName():ToString()
                    local ok, v = pcall(function() return a[n] end)
                    if ok and not n:find("^UberGraph") and not n:find("Timeline") and not n:find("_Tick") then r[n] = tostring(v) end
                end
            end)
            c = c:GetSuperStruct(); depth = depth + 1
        end
        return r
    end
    local function propDiff(b, a2)
        local d = {}
        for k, v in pairs(a2) do if b[k] ~= nil and b[k] ~= v and not k:find("Alpha") and not k:find("Time") then d[#d + 1] = string.format("%s %s->%s", k, b[k], v) end end
        table.sort(d)
        if #d > 12 then local n = #d; d = { table.unpack(d, 1, 12) }; d[#d + 1] = "... (" .. n .. " changed)" end
        return #d > 0 and table.concat(d, ", ") or "no scalar property of the target changed"
    end
    local function sample(a)
        return string.format("backpack_items=%d menu_open=%s highlighted=%s", invCount(), tostring(menuOpen()),
            highlighted() and (T.cls(highlighted():GetOwner()) .. " " .. highlighted():GetOwner():GetFName():ToString()) or "none")
    end

    -- interact: aim the camera at the target's highlight, wait until the game's highlight manager has it, then press the interact
    -- handler ("Command Interact") like the key, hold for the interaction's duration, release. approach (default true) first
    -- teleports next to it when it is out of reach (reach is ~160 uu), and says so.
    -- Remote player (side=client): this runs the guest's OWN game, so effects are client-local; nothing reaches the host (X4).
    function ACT.interact(o, job)
        hookFiring()
        local c = char()
        local a = resolve(o)
        assert(a, "interact needs an actor (path or 'nearest <Class>')")
        local comps, comp = highlightsOf(a), nil
        assert(#comps > 0, T.cls(a) .. " has no HighlightComponent: it is not interactable through the game's interaction path")
        if o.component then for _, h in ipairs(comps) do if h:GetFName():ToString() == o.component then comp = h end end end
        comp = comp or comps[1]
        local p = centerOf(a, comp)
        local notes, me = {}, c:K2_GetActorLocation()
        -- the highlight trace starts at the camera (~75 uu above the pawn), reaches 160 uu and is blocked by walls in front of the
        -- target, so where we stand matters: stay if close enough, then try spots on a ring around it (teleport, aim, ~8 frames each)
        local camDist = dist3(v3(me.X, me.Y, me.Z + 75), p)
        local cands = {}
        if camDist <= (o.approach == false and 160 or 115) then cands[1] = false end
        if o.approach ~= false then
            local base = math.atan(me.Y - p.Y, me.X - p.X)
            for _, r in ipairs({ tonumber(o.offset) or 75, 105 }) do
                for _, da in ipairs({ 0, 45, -45, 90, -90, 135, -135, 180 }) do
                    local ang = base + math.rad(da)
                    cands[#cands + 1] = v3(p.X + math.cos(ang) * r, p.Y + math.sin(ang) * r, me.Z)
                end
            end
        end
        assert(#cands > 0, "target is " .. math.floor(camDist) .. " uu from the camera and approach=false")
        local before, props0 = sample(a), propSnap(a)
        fired = {}
        local state, tHold, holdFor, pressedAt = "aim", nil, nil, nil
        local ci, k, teleports, sawHighlight = 1, 0, 0, nil
        if cands[1] then place(c, cands[1]); teleports = 1 end
        frames(job, function(el)
            if state == "aim" then
                aimAt(centerOf(a, comp))
                local h = highlighted()
                if h and h:GetOwner():GetFullName() == a:GetFullName() then
                    sawHighlight = h:GetFName():ToString()
                    -- hold: a tap (0.3 s) for instant interactions (doors, containers, car door handles: a 0.9 s press on the car door
                    -- did NOT open it); the component's own short/long duration + 0.5 s when it has one (world items say 0.32 / 0.38 s,
                    -- game seconds; real-time holds of 0.3 and 0.5 s picked nothing up on a loaded machine and 0.8 s did); a duration
                    -- over 10 s means "disabled" (starter storage: 600 s)
                    local function num(fn) local ok, v = pcall(function() return h[fn](h) end); return ok and tonumber(v) or 0 end
                    local dur = math.max(num("GetShortDuration"), num("GetLongDuration"))
                    holdFor = tonumber(o.hold) or ((dur > 0 and dur <= 10) and dur + 0.5 or 0.3)
                    c["Command Interact"](c, true)
                    state, pressedAt, job.pressEl = "hold", GS:GetTimeSeconds(T.world()), el  -- the hold runs in GAME time: a loaded machine slows the game below real time
                    local at = c:K2_GetActorLocation()
                    if teleports > 0 then notes[#notes + 1] = string.format("approach: teleported (not walked) %d time(s), from %s (%.0f uu from the target) to %s", teleports, fmt(me), camDist, fmt(at)) end
                    job.notes = string.format("highlight component %s, hold %.2f s", sawHighlight, holdFor)
                    return
                end
                k = k + 1
                if k >= 8 then
                    ci, k = ci + 1, 0
                    local nxt = cands[ci]
                    if not nxt then
                        return string.format("path: HighlightManager trace + PDP_MainCharacter:\"Command Interact\" (not pressed)\nresult: NOT interactable here: the game never highlighted %s %s from %d standing spot(s) around %s (disabled for the player, wrong state, or no free spot)\nbefore: %s", T.cls(a), a:GetFName():ToString(), ci - 1, fmt(p), before)
                    end
                    if nxt then place(c, nxt); teleports = teleports + 1 end
                end
            elseif state == "hold" then
                if GS:GetTimeSeconds(T.world()) - pressedAt >= holdFor or el - job.pressEl > holdFor * 6 + 3 then
                    c["Command Interact"](c, false)
                    state, tHold = "after", el
                end
            else
                if el - tHold >= 1.0 then
                    local after = sample(a)
                    local changed = propDiff(props0, propSnap(a))
                    if o.close_menu ~= false and menuOpen() then
                        pcall(function() T.first("BP_InventoryManager_C"):RequestPlayerMenuClose() end)
                        after = after .. " (menu closed again by the tool: close_menu=false keeps it open)"
                    end
                    local remote = T.ROLE == "client" and "\nnote: remote player: ran in the guest's own game; the effect is client-local and does not reach the host (X4)." or ""
                    return string.format("path: HighlightManager aim (SetControlRotation) + PDP_MainCharacter:\"Command Interact\"(true/false), the interact key's handler\ntarget: %s %s\n%s\n%s\nfired: %s\nbefore: %s\nafter:  %s\ntarget changes: %s%s",
                        T.cls(a), a:GetFName():ToString(), job.notes or "", table.concat(notes, "\n"), #fired > 0 and table.concat(fired, ", ") or "nothing (no HighlightComponent entry point ran)", before, after, changed, remote)
                end
            end
        end, 12, function() return "timeout while interacting (state " .. state .. ")" end)
    end

    -- the engine delivers a bound action to its actor as a call of the InpActEvt_<Action> function with the key; this does the same
    -- (PlayerController:InputKey is native-only and cannot be called from Lua). press=true: Pressed event, false: Released event
    local function actionEvent(x, action, press, key)
        local cls, n = x:GetClass(), nil
        for _, i in ipairs(action == "ToolPrimaryUse" and { press and 2 or 3, press and 3 or 2 } or { press and 0 or 1 }) do
            local fn = "InpActEvt_" .. action .. "_K2Node_InputActionEvent_" .. i
            if x[fn] then n = fn; break end
        end
        assert(n, "no input event function for " .. action)
        x[n](x, { KeyName = FName(key) })
    end
    T.action_event = actionEvent

    -- use_tool: the tool in the hand, used like a player: aim at the target until the game's highlight manager has it, press the
    -- tool's own use input event (ToolPrimaryUse = left mouse button), hold, release. opts: actor, key, hold, tool (class: forces the target, headless).
    function ACT.use_tool(o, job)
        local c = char()
        local a = resolve(o)
        assert(a, "use_tool needs an actor")
        local comps = highlightsOf(a)
        local comp = comps[1]
        local key, holdS = o.key or "LeftMouseButton", tonumber(o.hold) or 3
        local state, k, pressedEl = "aim", 0, nil
        local before = sample(a)
        local seen
        frames(job, function(el)
            if o.tool and state ~= "aim" then
                -- headless aim: the car parts' highlight collisions are not reachable by a trace here (gas cap: null collision), so the
                -- tool's target is set by hand every frame while the key is down; everything after the press is the game's own
                for _, x in ipairs(FindAllOf(o.tool) or {}) do if alive(x) then pcall(function() x.TargetedActor = a; x.HighlightedActor = a end) end end
            end
            if state == "aim" then
                aimAt(comp and centerOf(a, comp) or a:K2_GetActorLocation())
                local h = highlighted()
                if o.tool or (h and h:GetOwner():GetFullName() == a:GetFullName()) then
                    seen = h and h:GetFName():ToString() or "forced"
                    state, pressedEl = "press", el
                    local tools = {}
                    for _, x in ipairs(FindAllOf(o.tool or "BP_BaseToolManifestation") or {}) do if alive(x) then tools[#tools + 1] = x end end
                    assert(#tools > 0, "no tool actor in the hand")
                    for _, x in ipairs(tools) do actionEvent(x, "ToolPrimaryUse", true, key) end
                    local t0 = GS:GetTimeSeconds(T.world())
                    job.rel = function()
                        if GS:GetTimeSeconds(T.world()) - t0 >= holdS then
                            for _, x in ipairs(tools) do pcall(actionEvent, x, "ToolPrimaryUse", false, key) end
                            job.rel = nil
                            state = "after"
                        end
                    end
                else
                    k = k + 1
                    if k > 90 then return "path: tool use key (" .. key .. ") not pressed\nresult: the game never highlighted " .. T.cls(a) .. " " .. a:GetFName():ToString() .. " from here (aim error, out of reach or not highlightable now)\nbefore: " .. before end
                end
            elseif state == "press" then
                aimAt(comp and centerOf(a, comp) or a:K2_GetActorLocation())
                if job.rel then job.rel() end
            elseif state == "after" then
                job.after = (job.after or 0) + 1
                if job.after > 30 then
                    return string.format("path: the tool's own ToolPrimaryUse input event (%s) pressed, held %.1f s, released (the call the engine makes for the bound key)\ntarget: %s %s highlighted via %s\nbefore: %s\nafter:  %s", key, holdS, T.cls(a), a:GetFName():ToString(), tostring(seen), before, sample(a))
                end
            end
        end, 40 + holdS, function() return "timeout in state " .. state end)
    end

    -- ---------------------------------------------------------------- 3. car
    local function car()
        for _, cc in ipairs(FindAllOf("BaseNewCar") or {}) do
            if alive(cc) and T.inWorld(cc) and (T.ROLE ~= "client" or cc.Role ~= 3) then
                local ok, p = pcall(function() return cc:K2_GetActorLocation() end)
                if ok and not (p.X == 0 and p.Y == 0 and p.Z == 0) and not cc:GetFullName():find("Default__", 1, true) then return cc end
            end
        end
        error("no car in this world")
    end
    local function driving(cc)
        local p = pc().Pawn
        return carMode() == 1 or (alive(p) and p:GetFullName() == cc:GetFullName())
    end
    local function carState(cc)
        local vc = cc.VehicleController
        local okg, gear = pcall(function() local m = T.first("BP_CarManager_C"); return m and T.str(m.MyCarGearBox) end)
        local oki, ign = pcall(function() local m = T.first("BP_CarManager_C"); return m and T.str(m.CarIgnitionState) end)
        local sp = 0
        pcall(function() sp = vc:GetSpeed() end)
        return string.format("pos %s speed %.0f uu/s (%.1f km/h) engineOn=%s ignition=%s gearbox=%s parkingBrake=%s playerCarState=%s (1 = in car) pawn=%s",
            fmt(cc:K2_GetActorLocation()), sp, sp * 0.036, tostring(cc.EngineOn), tostring(oki and ign), tostring(okg and gear),
            tostring(select(2, pcall(function() return vc:GetParkingBrakeActive() end))), tostring(carMode()), T.cls(pc().Pawn))
    end
    local function callBP(obj, fn, ...)
        local f = StaticFindObject(obj:GetClass():GetFullName():match("^%S+ (.+)$") .. ":" .. fn)
        assert(f and f:IsValid(), "no UFunction " .. fn)
        return f(obj, ...)
    end

    -- the actor a player presses to open and enter the driver's door: the allowed highlight (a door handle child actor, else the door
    -- part) whose collision is nearest to the car's enter-door highlight
    local function driverDoor(cc, mirror, ref)
        local hm = T.first("BP_HighlightManager_C")
        local o = assert(boundsOrigin(ref and ref.Highlight.HighlightCollision[1] or cc.Highlight_EnterDoor.HighlightCollision[1]), "the car's enter-door collision has no position yet")
        if mirror then -- the passenger door: the driver's mirrored across the car's centre line (car-local Y)
            local kml = StaticFindObject("/Script/Engine.Default__KismetMathLibrary")
            local l = kml:InverseTransformLocation(cc:GetTransform(), o)
            o = kml:TransformLocation(cc:GetTransform(), v3(l.X, -l.Y, l.Z))
        end
        local best, bd, seen = nil, nil, {}
        for _, h in ipairs(FindAllOf("HighlightComponent") or {}) do
            if alive(h) then
                local a = h:GetOwner()
                local cn = alive(a) and a:GetClass():GetFName():ToString()
                if (cn == "BP_CarPart_Interactive_C" or cn == "BP_CarPart_Door_Base_C") and liveWorld(a) then
                    local ok, d = pcall(function()
                        local hc = h.HighlightCollision
                        local m
                        for i = 1, hc:GetArrayNum() do
                            local p = boundsOrigin(hc[i])
                            local dd = p and dist3(p, o)
                            if dd and (not m or dd < m) then m = dd end
                        end
                        return m
                    end)
                    local o1 = {}
                    pcall(function() hm["Should Allow Highlight"](hm, h, o1, {}) end)
                    if ok and d and d < 150 then seen[#seen + 1] = string.format("%s d=%.0f allow=%s", a:GetFName():ToString():sub(-14), d, tostring(o1.Allow)) end
                    if ok and d and o1.Allow and d < 60 then
                        local score = d + (cn == "BP_CarPart_Interactive_C" and 0 or 25)
                        if not bd or score < bd then best, bd = a, score end
                    end
                end
            end
        end
        return best, table.concat(seen, "; ")
    end

    -- enter_car: 1) the game's own door interaction: press the driver's door handle like a player (the door opens, the character
    -- walks in and the game runs its enter sequence, ~3 s); 2) the door part's StartEntry (what the enter-door highlight calls);
    -- 3) PlayerController:Possess(car) as a named fallback (no animation, no attach by the game)
    function ACT.enter_car(o, job)
        local cc = car()
        if driving(cc) then return "path: none needed\nalready in the car\n" .. carState(cc) end
        local tried, sub, sub2 = {}, nil, nil
        local stage, t0 = "prep", 0
        -- the collision bounds of things far from the player are stale (all zeros): stand next to the car first, give it a few frames
        local c, me, cl = char(), nil, cc:K2_GetActorLocation()
        me = c:K2_GetActorLocation()
        if dist2(me, cl) > 450 and o.approach ~= false and carMode() == 0 then
            place(c, standoff(cl, me, 320))
            tried[#tried + 1] = string.format("teleported next to the car (was %.0f uu away)", dist2(me, cl))
        end
        local function startDoor()
            local door, cands = driverDoor(cc)
            tried[#tried + 1] = "door candidates within 150 uu of the enter-door collision: " .. cands
            if door then
                sub = newJob("interact", { actor = door:GetFullName(), approach = o.approach, hold = o.hold })
                local ok, err = pcall(ACT.interact, sub.opts, sub)
                if not ok then sub.fail(tostring(err)) end
                tried[#tried + 1] = "door handle interaction on " .. T.cls(door) .. " " .. door:GetFName():ToString()
                stage = "door"
            else
                tried[#tried + 1] = "no allowed driver-door interactable found"
                stage = "start"
            end
        end
        local function entered(path, extra)
            return "path: " .. path .. "\n" .. (extra or "") .. "tried: " .. table.concat(tried, " -> ") .. "\n" .. carState(cc)
        end
        local function startEntry()
            local okd = pcall(function() local item = cc.SLOT_FrontLeftDoor:GetItemActor({}); item:StartEntry(false) end)
            tried[#tried + 1] = "SLOT_FrontLeftDoor door part:StartEntry(false) ok=" .. tostring(okd)
        end
        frames(job, function(el)
            if stage == "prep" then
                if el > 0.4 then startDoor() end
            elseif stage == "door" then
                if driving(cc) or carMode() == 2 then stage, t0 = "wait", el end
                if sub.state ~= "pending" and stage == "door" then
                    if sub.state == "err" then tried[#tried + 1] = "interaction failed: " .. sub.text:gsub("\n.*", "") end
                    stage, t0 = "wait", el
                end
            elseif stage == "wait" then
                if carMode() == 1 then return entered("the game's own door interaction (driver door handle -> door opens, character enters)", sub and sub.state == "done" and (sub.text .. "\n") or nil) end
                -- a first press on a fresh car may only open the door: the enter-door highlight is then allowed, press that too
                if el - t0 > 4 and carMode() == 0 and not sub2 then
                    local o1 = {}
                    local hm = T.first("BP_HighlightManager_C")
                    pcall(function() hm["Should Allow Highlight"](hm, cc.Highlight_EnterDoor, o1, {}) end)
                    if o1.Allow then
                        sub2 = newJob("interact", { actor = cc:GetFullName(), component = "Highlight_EnterDoor", approach = o.approach })
                        local ok2, err2 = pcall(ACT.interact, sub2.opts, sub2)
                        if not ok2 then sub2.fail(tostring(err2)) end
                        tried[#tried + 1] = "door was open but nobody entered: pressed the car's Highlight_EnterDoor"
                        t0 = el - 3
                    end
                end
                if el - t0 > 9 then
                    tried[#tried + 1] = "not in the car 9 s after the interaction [" .. (sub and sub.text or "?"):gsub("\n", " | "):sub(1, 700) .. "]"
                    startEntry()
                    stage, t0 = "start", el
                end
            elseif stage == "start" then
                if t0 == 0 then t0 = el; startEntry() end
                if carMode() == 1 then return entered("BP_CarPart_Door_Base:StartEntry(false) (the call behind the enter-door highlight)") end
                if el - t0 > 9 then
                    tried[#tried + 1] = "Possess(car)"
                    pc():Possess(cc)
                    pcall(function() callBP(T.first("BP_CarManager_C"), "Register Car Possessed", true) end)
                    stage, t0 = "done", el
                end
            else
                if el - t0 > 1 then return entered("FALLBACK PlayerController:Possess(car) (the game's own enter did not take effect; no enter sequence, character not attached)") end
            end
        end, 40, function() return "enter_car timed out in stage " .. stage .. "; tried: " .. table.concat(tried, " -> ") .. "\n" .. carState(cc) end)
    end

    -- door_press: real input at a car door (the guest's way in): WALK to the handle (a guest's teleport is undone by the server),
    -- then press it like a player. passenger=true presses the mirrored (passenger) door; the game only enters through the driver's.
    function ACT.door_press(o, job)
        local cc = car()
        local door, cands = driverDoor(cc, o.passenger == true, o.ref and T.mcp_obj(o.ref))
        assert(door, "no allowed door interactable: " .. cands)
        local parent = pc().Pawn:GetAttachParentActor()
        if alive(parent) and parent:GetAddress() == cc:GetAddress() then
            return ACT.interact({actor=door:GetFullName(),hold=o.hold or 0.3},job)
        end
        -- the car is in the way from the other side: first a spot 170 uu outside the door (away from the car's centre), then the door
        local dp, cp = boundsOrigin(door.Highlight.HighlightCollision[1]) or door:K2_GetActorLocation(), cc:K2_GetActorLocation()
        local dx, dy = dp.X - cp.X, dp.Y - cp.Y
        local dl = math.sqrt(dx * dx + dy * dy)
        local stagePt = v3(dp.X + dx / dl * 120, dp.Y + dy / dl * 120, dp.Z)
        local sub, stage = newJob("move_to", { x = stagePt.X, y = stagePt.Y, z = stagePt.Z, radius = 40, timeout = 20 }), "walk"
        local ok, err = pcall(ACT.move_to, sub.opts, sub)
        if not ok then sub.fail(tostring(err)) end
        frames(job, function()
            if sub.state == "pending" then return end
            if stage == "walk" then
                stage = "walk2"
                sub = newJob("move_to", { actor = door:GetFullName(), radius = 55, timeout = 10 })
                local ok1, err1 = pcall(ACT.move_to, sub.opts, sub)
                if not ok1 then sub.fail(tostring(err1)) end
                return
            end
            if stage == "walk2" then
                stage = "press"
                sub = newJob("interact", { actor = door:GetFullName(), approach = o.approach == true, hold = o.hold or 0.3 })
                local ok2, err2 = pcall(ACT.interact, sub.opts, sub)
                if not ok2 then sub.fail(tostring(err2)) end
                return
            end
            return "door " .. door:GetFullName() .. "\ncandidates: " .. cands .. "\n" .. tostring(sub.text)
        end, 60)
    end

    -- exit_car: BP_PlayerCarNew:ManualActivate_ExitDoor (what the exit-door highlight calls; works when the game has the player in
    -- the car, state 1), Possess(character) fallback after a wait
    function ACT.exit_car(o, job)
        local cc = car()
        if not driving(cc) then return "path: none needed\nnot in the car; " .. carState(cc) end
        local c = char()
        local tried = { "BP_PlayerCarNew:ManualActivate_ExitDoor" }
        pcall(function() cc:ManualActivate_ExitDoor() end)
        frames(job, function(el)
            if carMode() == 0 and T.cls(pc().Pawn) == T.CHAR then return "path: " .. tried[#tried] .. "\n" .. carState(cc) .. "\ncharacter at " .. fmt(c:K2_GetActorLocation()) end
            if el > 8 and #tried == 1 then
                tried[2] = "FALLBACK Possess(character) + detach"
                pc():Possess(c)
                pcall(function() if c:GetAttachParentActor():IsValid() then c:K2_DetachFromActor(1, 1, 1) end end)
                pcall(function() c.CharacterMovement:SetMovementMode(1, 0) end)
                pcall(function() callBP(T.first("BP_CarManager_C"), "Register Car Possessed", false) end)
            end
        end, 25, function() return "exit_car timed out; tried " .. table.concat(tried, " -> ") .. "\n" .. carState(cc) end)
    end

    -- car_start: ignition, gearbox to drive, handbrake off (the car functions the ignition key, the shifter and the handbrake end in)
    function ACT.car_start(o, job)
        local cc = car()
        local before = carState(cc)
        local r = {}
        r[#r + 1] = "ignition=" .. tostring(pcall(function() cc:ManualSetIgnition_NoAnim(2) end))
        r[#r + 1] = "gearbox=" .. tostring(pcall(function() cc:ManualActivate_Gearbox(0, true) end))
        r[#r + 1] = "handbrake=" .. tostring(pcall(function() cc.VehicleController:SetParkingBrakeActive(false) end))
        afterFrames(job, 30, function()
            return "path: BP_PlayerCarNew:ManualSetIgnition_NoAnim(2) + ManualActivate_Gearbox(0 = drive) + VehicleController:SetParkingBrakeActive(false) (no key animations; the car's own manual entry points)\ncalls ok: " .. table.concat(r, " ") .. "\nbefore: " .. before .. "\nafter:  " .. carState(cc)
        end)
    end

    -- drive: throttle / steer / brake for `seconds`, through the car's own input handlers every frame (AccelerateBrake, SteerLeftRight)
    -- and the vehicle controller inputs (as the reference mod's driver did). Needs the car possessed (enter_car) and started (car_start).
    function ACT.drive(o, job)
        local cc = car()
        assert(driving(cc), "not driving: enter_car first (controlled pawn is " .. T.cls(pc().Pawn) .. ")")
        local th, st, br, secs = tonumber(o.throttle) or 1, tonumber(o.steer) or 0, tonumber(o.brake) or 0, tonumber(o.seconds) or 3
        local before, p0, maxSp = carState(cc), cc:K2_GetActorLocation(), 0
        pcall(function() cc.VehicleController:SetParkingBrakeActive(false) end)
        frames(job, function(el)
            local axis = br > 0 and -br or th
            pcall(function() cc:AccelerateBrake(axis) end)
            pcall(function() cc:SteerLeftRight(st) end)
            pcall(function() local vc = cc.VehicleController; vc.ThrottleInput = math.max(th, 0) * (br > 0 and 0 or 1); vc.BrakeInput = br; vc.SteerInput = st end)
            pcall(function() maxSp = math.max(maxSp, cc.VehicleController:GetSpeed()) end)
            if el >= secs then
                pcall(function() cc:AccelerateBrake(0) end); pcall(function() cc:SteerLeftRight(0) end)
                pcall(function() local vc = cc.VehicleController; vc.ThrottleInput = 0; vc.BrakeInput = 0; vc.SteerInput = 0 end)
                local p1 = cc:K2_GetActorLocation()
                local fw = cc:GetActorForwardVector()
                local along = (p1.X - p0.X) * fw.X + (p1.Y - p0.Y) * fw.Y
                return string.format("path: BP_PlayerCarNew:AccelerateBrake + SteerLeftRight + VehicleController inputs, every frame, host-authoritative\ninputs: throttle %.2f steer %.2f brake %.2f for %.1f s\nbefore: %s\nafter:  %s\nmoved %.0f uu (%.1f m) horizontally, %.0f uu along the car's forward axis, top speed %.0f uu/s (%.1f km/h)",
                    th, st, br, secs, before, carState(cc), dist2(p0, p1), dist2(p0, p1) / 100, along, maxSp, maxSp * 0.036)
            end
        end, secs + 5)
    end

    -- car_stop: inputs to zero, brake, then (park=true) the gearbox to park and the handbrake on
    function ACT.car_stop(o, job)
        local cc = car()
        local park = o.park ~= false
        local before = carState(cc)
        local t0 = now()
        frames(job, function(el)
            pcall(function() cc:AccelerateBrake(-1.0) end)
            pcall(function() local vc = cc.VehicleController; vc.ThrottleInput = 0; vc.BrakeInput = 1; vc.SteerInput = 0 end)
            local sp = 0
            pcall(function() sp = cc.VehicleController:GetSpeed() end)
            if sp < 5 or el > 8 then
                pcall(function() cc:AccelerateBrake(0) end)
                pcall(function() cc.VehicleController.BrakeInput = 0 end)
                if park then
                    pcall(function() cc:ManualActivate_Gearbox(1, true) end)
                    pcall(function() cc.VehicleController:SetParkingBrakeActive(true) end)
                end
                return string.format("path: BP_PlayerCarNew:AccelerateBrake(-1) until stopped%s\nbefore: %s\nafter:  %s", park and " + ManualActivate_Gearbox(1 = park) + parking brake" or "", before, carState(cc))
            end
        end, 12)
    end

    -- ---------------------------------------------------------------- 4. items
    local archCache
    local function archetypes()
        local r = {}
        for _, a in ipairs(FindAllOf("ItemArchetype") or {}) do
            if alive(a) and not a:GetFullName():find("Default__", 1, true) then r[#r + 1] = a end
        end
        return r
    end
    -- item id: a full asset path, "IA_Name", "Name", or a unique part of the name among the loaded archetypes
    local function findArchetype(id)
        id = tostring(id)
        if id:find("/", 1, true) then
            local a = StaticFindObject(id)
            if not alive(a) and LoadAsset then pcall(LoadAsset, id); a = StaticFindObject(id) end
            assert(alive(a), "no archetype at " .. id)
            return a
        end
        local exact, part = {}, {}
        local want = id:lower():gsub("^ia_", "")
        for _, a in ipairs(archetypes()) do
            local n = a:GetFName():ToString():lower():gsub("^ia_", "")
            -- the whole name, or its tail after a category prefix ("Raw_Scrap_Steel" = IA_Resource_Raw_Scrap_Steel, not ..._Evolved)
            if n == want or n:sub(-#want - 1) == "_" .. want then exact[#exact + 1] = a elseif n:find(want, 1, true) then part[#part + 1] = a end
        end
        table.sort(exact, function(x, y) return #x:GetFName():ToString() < #y:GetFName():ToString() end)
        local pick = #exact > 0 and exact or part
        if #pick == 1 or #exact >= 1 then return pick[1] end
        if #pick == 0 then error("no loaded item archetype matches '" .. id .. "' (give a full path /Game/.../IA_X.IA_X, or use item_search)") end
        local names = {}
        for i = 1, math.min(#pick, 12) do names[i] = pick[i]:GetFName():ToString() end
        error("'" .. id .. "' is ambiguous: " .. table.concat(names, ", "))
    end
    function T.act_item_search(q)
        local r, want = {}, tostring(q or ""):lower()
        for _, a in ipairs(archetypes()) do
            local n = a:GetFName():ToString()
            if n:lower():find(want, 1, true) then r[#r + 1] = n end
        end
        table.sort(r)
        local shown = {}
        for i = 1, math.min(#r, 80) do shown[i] = r[i] end
        return string.format("%d loaded item archetype(s) match '%s'%s\n%s", #r, want, #r > 80 and " (first 80)" or "", table.concat(shown, "\n"))
    end
    local function backpack()
        local im = T.first("BP_InventoryManager_C")
        local rows, total = {}, {}
        for _, spec in ipairs({ { "backpack", im.Inventory_Player }, { "hand", im.Inventory_PlayerHand } }) do
            local cont = spec[2]
            for i = 0, cont:GetNumSlots() - 1 do
                local s = cont:GetSlot(i)
                local n = s:GetNumItems()
                if n > 0 then
                    local nm = s:GetCurrentArchetype():GetFName():ToString():gsub("^IA_", "")
                    rows[#rows + 1] = string.format("%s slot %d: %s x%d", spec[1], i, nm, n)
                    total[nm] = (total[nm] or 0) + n
                end
            end
        end
        return rows, total
    end
    function T.act_inventory() local rows = backpack(); return #rows == 0 and "(backpack and hand empty)" or table.concat(rows, "\n") end

    function ACT.give_item(o, job)
        local arch = findArchetype(o.item)
        local n = math.max(1, math.floor(tonumber(o.count) or 1))
        local im = T.first("BP_InventoryManager_C")
        local _, before = backpack()
        local name = arch:GetFName():ToString():gsub("^IA_", "")
        local ok = 0
        for _ = 1, n do if pcall(function() im:GiveItemToPlayer(arch) end) then ok = ok + 1 end end
        afterFrames(job, 5, function()
            local rows, after = backpack()
            return string.format("path: BP_InventoryManager:GiveItemToPlayer(archetype) x%d (the game's own give, used by its debug events)\nitem: %s\ncalls ok: %d/%d, backpack count of %s: %d -> %d\nbackpack now:\n  %s", n, arch:GetFullName(), ok, n, name, before[name] or 0, after[name] or 0, table.concat(rows, "\n  "))
        end)
    end

    function ACT.spawn_item(o, job)
        local arch = findArchetype(o.item)
        local a, loc, desc = resolve(o)
        local at = a and v3(loc.X, loc.Y, loc.Z + 60) or loc
        local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = at, Scale3D = v3(1, 1, 1) }
        local actor = T.first("InventorySystem"):SpawnItemActor(T.world(), xf, arch, 0, 0)
        assert(alive(actor), "SpawnItemActor returned nothing")
        afterFrames(job, 3, function()
            return string.format("path: InventorySystem:SpawnItemActor(world, transform, archetype) (what the game uses to drop an item into the world)\nspawned: %s\nat %s (wanted %s)\nfull name (use it as target for pickup): %s", T.cls(actor), fmt(actor:K2_GetActorLocation()), fmt(at), actor:GetFullName())
        end)
    end

    local function findClass(s)
        s = tostring(s)
        local c
        if s:find("/", 1, true) then
            c = StaticFindObject(s)
            if not alive(c) and LoadAsset then pcall(LoadAsset, s); c = StaticFindObject(s) end
        else
            local inst = FindFirstOf(s)
            if alive(inst) then c = inst:GetClass() end
            if not alive(c) then c = FindObject("Class", s) end
            if not alive(c) then c = FindObject("BlueprintGeneratedClass", s) end
        end
        assert(alive(c), "no class '" .. s .. "' (give a path like /Game/X/BP_Y.BP_Y_C, or a class that has a live instance)")
        return c
    end
    function ACT.spawn_actor(o, job)
        local cls = findClass(o.class)
        local a, loc, desc = resolve(o)
        local at = a and v3(loc.X, loc.Y, loc.Z + 60) or loc
        local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = at, Scale3D = v3(1, 1, 1) }
        local actor = GS:FinishSpawningActor(GS:BeginDeferredActorSpawnFromClass(T.world(), cls, xf, 2, nil), xf)
        assert(alive(actor), "spawn failed (abstract class, or not an Actor)")
        afterFrames(job, 3, function()
            return string.format("path: GameplayStatics:BeginDeferredActorSpawnFromClass + FinishSpawningActor (engine spawn; the game has no own debug spawner for arbitrary classes)\nspawned: %s\nat %s (wanted %s)", actor:GetFullName(), fmt(actor:K2_GetActorLocation()), fmt(at))
        end)
    end

    -- pickup: the interact path on the item (aim + "Command Interact"); if the backpack did not grow, the character's own
    -- "Pickup Actor" function (what the interaction ends in) and the result says so
    function ACT.pickup(o, job)
        local a = resolve(o)
        assert(a, "pickup needs an actor (path or 'nearest <Class>', e.g. nearest BP_WorldItem_C)")
        local _, before = backpack()
        local c0 = invCount()
        local sub = newJob("interact", { actor = a:GetFullName(), approach = o.approach })
        local ok, err = pcall(ACT.interact, sub.opts, sub)
        if not ok then sub.fail(tostring(err)) end
        frames(job, function(el)
            if sub.state == "pending" then return end
            if invCount() > c0 then
                return "path: interact (highlight + \"Command Interact\")\n" .. sub.text .. "\nbackpack items " .. c0 .. " -> " .. invCount()
            end
            local why = sub.state == "done" and "interact ran but the backpack did not grow" or sub.text
            local c = char()
            local okp, e = pcall(function() c["Pickup Actor"](c, a, false) end)
            return string.format("path: FALLBACK PDP_MainCharacter:\"Pickup Actor\"(item, toHands=false) (%s)\nPickup Actor ok=%s%s\nbackpack items %d -> %d", why, tostring(okp), okp and "" or (" " .. tostring(e)), c0, invCount())
        end, 15)
    end

    -- drop: backpack slot -> hand -> the inventory manager's own PlayerDropHandItem (what dropping the held item does)
    function ACT.drop(o, job)
        local im = T.first("BP_InventoryManager_C")
        local slot = math.floor(tonumber(o.slot) or 0)
        local s = im.Inventory_Player:GetSlot(slot)
        assert(alive(s) and s:GetNumItems() > 0, "backpack slot " .. slot .. " is empty or does not exist (see inventory)")
        local name = s:GetCurrentArchetype():GetFName():ToString()
        local n0 = invCount()
        local okm, moved = pcall(function() return s:TransferSingleIntoContainer(im.Inventory_PlayerHand) end)
        afterFrames(job, 5, function()
            local out1, out2 = {}, {}
            local ok, e = pcall(function() im:PlayerDropHandItem(out1, out2) end)
            return string.format("path: ItemSlot:TransferSingleIntoContainer(hand) + BP_InventoryManager:PlayerDropHandItem (drops one item of the slot)\nmoved to hand: %s; PlayerDropHandItem ok=%s success=%s world actor=%s\nitem %s, backpack+hand items %d -> %d", tostring(okm and moved), tostring(ok), tostring(out1["Drop Success"]), T.str(out2["World Actor"]), name, n0, invCount())
        end)
    end

    -- ---------------------------------------------------------------- eval for scenarios (promoted journals)
    function T.mcp_run(code)
        local env = setmetatable({ T = T, show = T.show, out = function(...) T.log("PT|info mcp_run %s", table.concat({ ... }, " ")) end }, { __index = function(_, k) if T[k] ~= nil then return T[k] end return _G[k] end })
        local fn = assert(load(code, "=mcp_run", "t", env))
        return fn()
    end
end
