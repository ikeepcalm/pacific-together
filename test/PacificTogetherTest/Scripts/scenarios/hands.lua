-- P1 hands: each player sees what the other holds and does with it, both directions (host sees guest, then guest sees host).
--   Fixture `garage`. Per direction the acting side (A) does one thing, the observing side (B) checks its view of A's character:
--   1 item     A holds a flashlight: B has a mesh actor attached to A's character with the same mesh as A's hand, within 2 s
--   2 light    A presses the flashlight's use input (the game's own toggle): B has a light at A's head, and the use swing ran
--   3 off      A presses again: the light is gone
--   4 switch   A holds a patch kit instead: the mesh follows (a different one), no light
--   5 use      A presses the patch kit's use input: B sees the use swing (the mannequin has no tool montage, the mirror swings)
--   6 empty    A puts the stack back in the pack: the mirror is gone
--   7 carry    A holds a two-handed item (a car door): the mirror sits in front of the chest, not on the hand
--   8 hammer   A holds the Impact Hammer: B's mirror is the tool's world mesh (one piece, "_World"), no part over 100 uu
--              (first-person parts showed as a jumble of textures, 2026-10-30; mutation noworldmesh fails it)
-- Run: tools/run-test.ps1 -Scenario hands -Fixture garage -Headless      Mutation nohands: hands.lua inert, B's checks FAIL.
return function(T)
    local L = require("scenarios.sessionlib")(T)
    local log, ROLE = T.log, T.ROLE
    local TOOLS = "/Game/Gameplay/Inventory/Items/Tools/"
    local bio = os.getenv("PT_VARIANT") == "bio"
    local FLASH = bio and (TOOLS .. "BioLantern/IA_Tool_Toggle_Flashlight_Bio.IA_Tool_Toggle_Flashlight_Bio") or (TOOLS .. "Flashlight/Potato/IA_Tool_Toggle_Flashlight.IA_Tool_Toggle_Flashlight")
    local PATCH = TOOLS .. "PatchKit/IA_Tool_Target_Consumable_PatchKit.IA_Tool_Target_Consumable_PatchKit"
    -- a car part is the two-handed kind (Archetype.Size 1; the fuel can is a one-hand tool)
    local BREAKER = TOOLS .. "Breaker/IA_Tool_Target_Breaker.IA_Tool_Target_Breaker" -- the Impact Hammer: carries an engine Cylinder (VFX volume)
    local DOOR = "/Game/Gameplay/Inventory/Items/Car/Doors/Door_Titanium_Basic_01/IA_Attach_Body_Door_Titanium_Basic.IA_Attach_Body_Door_Titanium_Basic"
    local slow = (T.MUTATE == "nohands") and 0.15 or 1
    local function to(s) return math.max(6, math.floor(s * slow)) end
    local function alive(o) return type(o) == "userdata" and o:IsValid() and not o:HasAnyInternalFlags(EInternalObjectFlags.PendingKill) end

    local got = {}
    local function has(kind)
        while true do
            local k, d = PTNative_MsgPoll("t.")
            if not k then break end
            got[k] = d
        end
        return got[kind]
    end
    local function say(kind, data)
        if ROLE == "host" then PTNative_MsgToGuest(L.remotePCs()[1]:GetAddress(), kind, data or "")
        else PTNative_MsgToHost(T.localPC():GetAddress(), kind, data or "") end
    end

    -- A's side -----------------------------------------------------------------------------------------------------------
    local function arch(path)
        local a = StaticFindObject(path)
        if not (a and a:IsValid()) then pcall(LoadAsset, path); a = StaticFindObject(path) end
        return a
    end
    local function im() return T.first("BP_InventoryManager_C") end
    local function hold(path)
        local m = im()
        m.Inventory_PlayerHand:GetSlot(0):RemoveAllItems({})
        if not path then return end
        m:GiveItemToPlayer(arch(path))
        if m.Inventory_PlayerHand:GetNumItems() > 0 then return end -- a car part goes straight into the hands
        local want = path:match("([^/%.]+)$")
        for i = 0, m.Inventory_Player:GetNumSlots() - 1 do
            local s = m.Inventory_Player:GetSlot(i)
            if s:GetNumItems() > 0 and s:GetCurrentArchetype():GetFName():ToString() == want then s:TransferStackIntoContainer(m.Inventory_PlayerHand, {}); return end
        end
        error("not in the backpack: " .. want)
    end
    local function me() return L.own() end
    local function handItem()
        local c = me()
        if not c then return end
        local o = {}
        c:GetActiveHandItem(false, o)
        local h = o["Hand Item"]
        return alive(h) and h or nil
    end
    local SMC = StaticFindObject("/Script/Engine.StaticMeshComponent")
    -- the main mesh of our own hand item, found the way the mod does (the biggest visible static mesh, not the VFX bbox tube)
    local function ownMesh()
        local h = handItem()
        if not h then return "none" end
        local best, size = nil, -1
        for _, c in ipairs(h:K2_GetComponentsByClass(SMC)) do
            c = c:get()
            local sm = alive(c) and c:IsVisible() and c.StaticMesh
            if alive(sm) and not sm:GetFullName():find("bboxTube", 1, true) and sm:GetBounds().SphereRadius > size then best, size = sm, sm:GetBounds().SphereRadius end
        end
        return best and best:GetFullName() or "none"
    end
    -- the game's own input event of the use button: press (sets the desire flag the hand item acts on) and release
    local function press()
        local h = handItem()
        h:InpActEvt_ToolPrimaryUse_K2Node_InputActionEvent_2({})
        h:InpActEvt_ToolPrimaryUse_K2Node_InputActionEvent_3({})
        log("PT|info press on %s desire=%s", T.name(h), tostring(h["Desire Tool Primary Use"]))
    end

    -- B's side -----------------------------------------------------------------------------------------------------------
    local swing = { last = nil, max = 0 }
    local sampling = false
    local function otherC() return T.otherChar() end
    local function mirror()
        local o = otherC()
        if not o then return end
        for _, a in ipairs(FindAllOf("StaticMeshActor") or {}) do
            if alive(a) and a:GetAttachParentActor():IsValid() and a:GetAttachParentActor():GetFullName() == o:GetFullName() then return a end
        end
    end
    -- the mirror shows a tool's world mesh when it has one ("X" -> "X_World")
    local function sameTool(m, hand) return m == hand or m == hand:gsub("([^/%.]+)%.([^/%.]+)$", "%1_World.%2_World") end
    local function mirrorMesh()
        local a = mirror()
        local m = a and a.StaticMeshComponent.StaticMesh
        return (m and m:IsValid()) and m:GetFullName() or "none"
    end
    -- hand_r for one-hand items; "None" with the item 45 uu in front of the character for the two-handed carry
    local function mirrorSocket()
        local a = mirror()
        if not a then return "none" end
        local s = a.RootComponent:GetAttachSocketName():ToString()
        return s == "None" and string.format("chest(x=%.0f)", a.RootComponent.RelativeLocation.X) or s
    end
    local function lightAtHead()
        local o = otherC()
        if not o then return false end
        local head = o.Mesh:GetSocketLocation(FName("head"))
        for _, cls in ipairs({ "SpotLight", "PointLight" }) do
            for _, a in ipairs(FindAllOf(cls) or {}) do
                if alive(a) and a.LightComponent:IsVisible() then
                    local l = a:K2_GetActorLocation()
                    if math.sqrt((l.X - head.X) ^ 2 + (l.Y - head.Y) ^ 2 + (l.Z - head.Z) ^ 2) < 120 then
                        local c = a.LightComponent.LightColor
                        if not bio or (c.R > 240 and c.G > 90 and c.G < 140 and c.B > 220 and not a.LightComponent.bUseInverseSquaredFalloff and math.abs(a.LightComponent.Intensity - 100) < 1) then return true end
                    end
                end
            end
        end
        return false
    end
    -- the mirror's use swing is a rotation of the mirror for 0.45 s: sample it every 30 ms
    local function startSampler()
        if sampling then return end
        sampling = true
        local cache, at = nil, -1
        LoopInGameThreadWithDelay(30, function()
            pcall(function()
                -- FindAllOf is slow: look for the mirror twice a second, read its rotation every tick
                if not alive(cache) or os.clock() - at > 0.15 then cache, at = mirror(), os.clock() end
                -- the mirror rests in its grip pose: a swing is a turn away from that pose
                if alive(cache) then
                    local r = cache.RootComponent.RelativeRotation
                    if swing.of ~= cache:GetFullName() then swing.of, swing.rest = cache:GetFullName(), { r.Pitch, r.Yaw, r.Roll } end
                    local d = math.max(math.abs(r.Pitch - swing.rest[1]), math.abs((r.Yaw - swing.rest[2] + 180) % 360 - 180), math.abs((r.Roll - swing.rest[3] + 180) % 360 - 180))
                    if d > 5 then swing.last = os.clock() end
                end
            end)
        end)
    end

    -- every mirror part of the other's character: engine basic shapes (the hammer's VFX cylinder) and anything over 100 uu are wrong
    local function mirrorsBad()
        local o = otherC()
        local bad = {}
        for _, a in ipairs(o and FindAllOf("StaticMeshActor") or {}) do
            local pa = alive(a) and a:GetAttachParentActor()
            if pa and pa:IsValid() and pa:GetFullName() ~= o:GetFullName() then pa = pa:GetAttachParentActor() end -- extra parts hang on the first
            if pa and pa:IsValid() and pa:GetFullName() == o:GetFullName() then
                local c = a.StaticMeshComponent
                local sm = c.StaticMesh
                local r = (alive(sm) and sm:GetBounds().SphereRadius or 0) * c:K2_GetComponentScale().Z
                local n = alive(sm) and sm:GetFullName() or "none"
                log("PT|info mirror part %s r=%.0f", n, r)
                if n:find("/Engine/", 1, true) or r > 100 then bad[#bad + 1] = n end
            end
        end
        return #bad > 0
    end

    local steps = {}
    local function add(s) steps[#steps + 1] = s end
    local function hostSetup()
        for _, s in ipairs(T.loadFixture("garage")) do add(s) end
        add({ check = "host_listen_garage", timeout = 30, cond = function() return T.netMode() == "listen" and T.listening() end })
        add({ check = "host_guest_in_garage", timeout = 240, cond = function() return L.guestChar() ~= nil end })
        add({ wait = 8 })
        add({ run = function() startSampler() end })
    end
    local function guestSetup()
        steps[1] = T.onMap("RB_MainMenu", 90)
        add({ check = "client_in_garage", timeout = 400, cond = function() return T.netMode() == "client" and T.map() == "RB_Garage" and T.cls(T.myPawn()) == T.CHAR end })
        add({ check = "guest_sees_host", timeout = 60, cond = function() return otherC() ~= nil end })
        add({ wait = 8 })
        add({ run = function() startSampler() end })
    end
    if ROLE == "host" then hostSetup() else guestSetup() end

    local dirs = { { a = "host", b = "guest", tag = "1" }, { a = "guest", b = "host", tag = "2" } }
    for _, d in ipairs(dirs) do
        local I, tag = (ROLE == "host" and "host" or "guest") == d.a, d.tag -- ROLE is host or client
        local pre = (I and d.a or d.b) .. "_"
        local function msg(n) return "t.h" .. tag .. "_" .. n end
        -- A: act, announce; B: wait for the announcement, check, acknowledge. A waits for the ack before the next step.
        local function phase(n, name, act, observe)
            if I then
                add({ run = function() act() end })
                add({ wait = 1.5 }) -- the hand item actor appears a frame or two after the inventory move
                add({ run = function() say(msg(n), ownMesh()) end })
                add({ check = d.a .. "_phase_" .. name .. "_acked", timeout = to(30), cond = function() return has(msg(n) .. "k") ~= nil end })
            else
                add({ check = d.b .. "_told_" .. name, timeout = to(60), cond = function() return has(msg(n)) ~= nil end })
                add({ check = d.b .. "_sees_" .. name, timeout = to(4), cond = function() return observe(has(msg(n))) end })
                -- A acts only after our ack, so a swing seen later belongs to A's next action
                add({ run = function() swing.last = nil; say(msg(n) .. "k", "") end })
            end
        end
        phase(1, "item", function() hold(FLASH) end, function(mesh)
            local m = mirrorMesh()
            log("PT|info %s item mirror=%s hand=%s", d.b, m, mesh)
            return m ~= "none" and mesh ~= "none" and sameTool(m, mesh)
        end)
        phase(2, "light", function() press() end, function()
            log("PT|info %s light=%s swing=%s", d.b, tostring(lightAtHead()), tostring(swing.last))
            return lightAtHead() and swing.last ~= nil
        end)
        phase(3, "lightoff", function() press() end, function() return not lightAtHead() end)
        phase(4, "switch", function() hold(PATCH) end, function(mesh)
            local m = mirrorMesh()
            log("PT|info %s switch mirror=%s hand=%s", d.b, m, mesh)
            return m ~= "none" and sameTool(m, mesh) and not m:find("lashlight", 1, true) and not lightAtHead()
        end)
        phase(5, "use", function() press() end, function()
            log("PT|info %s swing=%s", d.b, tostring(swing.last))
            return swing.last ~= nil
        end)
        -- nothing in hand: the equipped tool leaves its pack slot (the game then has no hand item; a tool put back is the same state)
        phase(6, "empty", function()
            local h = handItem()
            h.Instance:GetOuterSlot():RemoveAllItems({})
        end, function() return mirror() == nil end)
        phase(8, "hammer", function() hold(BREAKER) end, function()
            local m = mirrorMesh()
            log("PT|info %s hammer mirror=%s", d.b, m)
            return mirror() ~= nil and not mirrorsBad() and m:find("_World", 1, true) ~= nil
        end)
        phase(7, "carry", function() hold(DOOR) end, function(mesh)
            local s, m = mirrorSocket(), mirrorMesh()
            log("PT|info %s carry socket=%s mirror=%s hand=%s", d.b, s, m, mesh)
            return s == "chest(x=45)" and sameTool(m, mesh)
        end)
    end
    add({ wait = 3 })
    return steps
end
