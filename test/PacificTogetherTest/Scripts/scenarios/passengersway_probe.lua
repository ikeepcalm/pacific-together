-- Live regression: seat the guest, cap its FPS at 12, start(), nudge the host's kinematic car by 1 uu and back, then check().
local M = {}
function M.start()
    local pc = require("UEHelpers").GetPlayerController()
    local pawn, cam = pc.Pawn
    assert(pawn:GetAttachParentActor():IsValid(), "guest must be seated")
    for _, c in ipairs(FindAllOf("CameraComponent") or {}) do
        if c:GetFName():ToString() == "FP_Camera" and c:GetOwner():GetAddress() == pawn:GetAddress() then cam = c end
    end
    assert(cam, "passenger camera missing")
    M.result = { start = os.clock(), max = 0, tail = 0, samples = 0, done = false }
    local id
    id = LoopInGameThreadWithDelay(1, function()
        local r, p = M.result, cam.RelativeLocation
        local age = os.clock() - r.start
        local d = math.sqrt(p.X * p.X + p.Y * p.Y + p.Z * p.Z)
        r.max = math.max(r.max, d)
        if age > 5 then r.tail = math.max(r.tail, d) end
        r.samples = r.samples + 1
        if age > 8 then r.done = true; CancelDelayedAction(id) end
    end)
end
function M.check()
    local r = assert(M.result, "start the probe first")
    assert(r.done and r.samples > 40, "probe needs eight seconds of camera samples")
    assert(r.tail < 0.2, string.format("stationary passenger sway did not settle: %.3f uu", r.tail))
    return r
end
return M
