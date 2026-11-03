-- World-scoped replica ordering. Creation and destruction stay on the reliable object stream.
local M = {}
function M.new(epoch, limit)
    return { epoch = epoch, entries = {}, pending = 0, limit = limit or 256 }
end
function M.adopt(s, id)
    local e = s.entries[id]
    if e and e.dead then return false end
    if not e then e = { seq = -1 }; s.entries[id] = e end
    if not e.live and e.pose then s.pending = s.pending - 1 end
    e.live = true
    return true
end
function M.remove(s, id)
    local e = s.entries[id]
    if e and not e.live and e.pose then s.pending = s.pending - 1 end
    s.entries[id] = { dead = true }
end
function M.offer(s, epoch, id, seq, pose)
    if epoch ~= s.epoch or type(id) ~= "string" or not id:match("^W%d+$") or #id > 24
        or type(seq) ~= "number" or seq ~= seq or seq < 0 or seq % 1 ~= 0 or seq > 9007199254740991 then return false end
    local e = s.entries[id]
    if e and (e.dead or seq <= e.seq) and os.getenv("PT_MUTATE") ~= "oldreplica" then return false end
    if not e then
        if s.pending >= s.limit then return false end
        e = { seq = -1 }; s.entries[id] = e
    end
    if not e.live and not e.pose then s.pending = s.pending + 1 end
    e.seq, e.pose = seq, pose
    return true
end
function M.take(s, id)
    local e = s.entries[id]
    if e and e.live and not e.dead then local p = e.pose; e.pose = nil; return p end
end
return M
