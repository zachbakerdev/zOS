-- Where this computer is, from GPS hosts that a trusted root server has vouched for.
-- See specs/libs/GPS.md.
--
-- Like CraftOS's gps, this asks every host in range and works out the position from how far away
-- each answer came from. Unlike it, an answer only counts if it carries a GPS certificate from a
-- root server this computer trusts, and a recent timestamp signed by the key on that certificate.
-- The position is then the one the most hosts agree on, so a host that has been moved, or an
-- answer passed on from somewhere else, is outvoted instead of believed.

local crypto = require("crypto")
local trust = require("trust")

local gps = {
    PORT = 4203,
    VERSION = 1,
    STAMP_LIFETIME = 600000, -- ms a host's signed timestamp is good for
    STAMP_EVERY = 300,       -- seconds between a host's timestamps
}

local DEFAULT_TIMEOUT = 2
local MAX_ANSWERS = 32  -- answers kept from one request
local MAX_CHECKS = 12   -- answers not seen before that one request checks, since each is slow
local MAX_HOSTS = 8     -- hosts used for one fix
local CLOCK_SKEW = 10000
local TOLERANCE = 0.05  -- blocks a distance may be out by and still agree
local SAME_PLACE = 0.5  -- candidates closer than this are the same answer
local MAX_REMEMBERED = 64

local myId = os.getComputerID()

local function homeChannel() return 30000 + myId % 30000 end

function gps.stampText(key, time)
    return "zos-gps-stamp-1|" .. key .. "|" .. time
end

-- Wireless modems only: a wired modem doesn't say how far away a message came from.
local function wirelessModems()
    local out = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" and peripheral.call(name, "isWireless") then
            out[#out + 1] = name
        end
    end
    return out
end
gps.wirelessModems = wirelessModems

-- Checking an answer ----------------------------------------------------------------------------

-- Signature checks are slow, and a host signs a new timestamp only every few minutes, so most
-- answers have been seen before. Each is remembered by everything its two signatures cover, and
-- the signatures themselves, so changing any part of an answer means checking it again.
local checked, checkedCount = {}, 0

local CERT_FIELDS = { "id", "key", "x", "y", "z", "root", "issued", "expires", "sig" }

-- What an answer is remembered by, or nil if it's the wrong shape to check at all.
local function answerId(answer)
    local cert, stamp = answer.cert, answer.stamp
    if type(cert) ~= "table" or type(stamp) ~= "table" then return nil end
    local parts = {}
    for i, field in ipairs(CERT_FIELDS) do
        local value = cert[field]
        if type(value) ~= "string" and type(value) ~= "number" then return nil end
        parts[i] = tostring(value)
    end
    if type(stamp.time) ~= "number" or type(stamp.sig) ~= "string" then return nil end
    parts[#parts + 1] = tostring(stamp.time)
    parts[#parts + 1] = stamp.sig
    return table.concat(parts, "|")
end

local function stampIntact(cert, stamp)
    return crypto.isHex(stamp.sig, 128)
        and crypto.verify(crypto.fromHex(cert.key), gps.stampText(cert.key, stamp.time), crypto.fromHex(stamp.sig))
end

local function trusted(answer, now)
    local id = answerId(answer)
    if not id then return false end
    local cert, stamp = answer.cert, answer.stamp
    if not trust.root(cert.root) then return false end
    -- The times are checked every time, since a remembered answer can go stale.
    if stamp.time > now + CLOCK_SKEW or stamp.time <= now - gps.STAMP_LIFETIME or cert.expires <= now then
        return false
    end
    if checked[id] == nil then
        if checkedCount >= MAX_REMEMBERED then checked, checkedCount = {}, 0 end
        checkedCount = checkedCount + 1
        checked[id] = trust.gpsCertIntact(cert) and stampIntact(cert, stamp) or false
    end
    return checked[id]
end

local function seenBefore(answer)
    local id = answerId(answer)
    return id ~= nil and checked[id] ~= nil
end

-- Geometry -------------------------------------------------------------------------------------

local function sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function add(a, b) return { a[1] + b[1], a[2] + b[2], a[3] + b[3] } end
local function mul(a, k) return { a[1] * k, a[2] * k, a[3] * k } end
local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
local function cross(a, b)
    return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] }
end
local function length(a) return math.sqrt(dot(a, a)) end

-- The one or two points at distance r1, r2 and r3 from p1, p2 and p3, or nothing if the three are
-- in a line or the spheres don't meet.
local function trilaterate(p1, r1, p2, r2, p3, r3)
    local d = length(sub(p2, p1))
    if d < 1e-6 then return end
    local ex = mul(sub(p2, p1), 1 / d)
    local i = dot(ex, sub(p3, p1))
    local ey = sub(sub(p3, p1), mul(ex, i))
    local j = length(ey)
    if j < 1e-6 then return end
    ey = mul(ey, 1 / j)
    local ez = cross(ex, ey)
    local x = (r1 * r1 - r2 * r2 + d * d) / (2 * d)
    local y = (r1 * r1 - r3 * r3 + i * i + j * j) / (2 * j) - i * x / j
    local zz = r1 * r1 - x * x - y * y
    if zz < -TOLERANCE then return end
    local base = add(p1, add(mul(ex, x), mul(ey, y)))
    if zz <= 0 then return { base } end
    local z = math.sqrt(zz)
    return { add(base, mul(ez, z)), add(base, mul(ez, -z)) }
end

local function support(point, hosts)
    local n = 0
    for _, host in ipairs(hosts) do
        if math.abs(length(sub(point, host.pos)) - host.distance) <= TOLERANCE then n = n + 1 end
    end
    return n
end

-- The point that the most hosts agree on, as long as it's more than half of them, at least three,
-- and no other point does as well.
function gps.solve(hosts)
    local best, bestCount, rivalCount = nil, 0, 0
    for a = 1, #hosts - 2 do
        for b = a + 1, #hosts - 1 do
            for c = b + 1, #hosts do
                local ha, hb, hc = hosts[a], hosts[b], hosts[c]
                for _, point in ipairs(trilaterate(ha.pos, ha.distance, hb.pos, hb.distance, hc.pos, hc.distance) or {}) do
                    local n = support(point, hosts)
                    if best and length(sub(point, best)) <= SAME_PLACE then
                        -- the same answer again
                    elseif n > bestCount then
                        if best then rivalCount = math.max(rivalCount, bestCount) end
                        best, bestCount = point, n
                    else
                        rivalCount = math.max(rivalCount, n)
                    end
                end
            end
        end
    end
    if not best or bestCount < 3 or bestCount * 2 <= #hosts or rivalCount >= bestCount then return nil end
    local function round(n) return math.floor(n * 100 + 0.5) / 100 end
    return round(best[1]), round(best[2]), round(best[3])
end

-- Asking ---------------------------------------------------------------------------------------

-- Where this computer is, as x, y, z, or nil if it can't tell. `timeout` is how many seconds to
-- listen for answers, 2 by default. Checking a host's signatures for the first time takes longer.
function gps.locate(timeout)
    local modems = wirelessModems()
    if #modems == 0 then return nil end
    local reply = homeChannel()
    local nonce = crypto.toHex(crypto.randomBytes(8))
    for _, name in ipairs(modems) do
        peripheral.call(name, "open", reply)
        peripheral.call(name, "transmit", gps.PORT, reply, { zg = gps.VERSION, t = "where", nonce = nonce })
    end

    local answers = {}
    local timer = os.startTimer(timeout or DEFAULT_TIMEOUT)
    while true do
        local event, side, channel, _, message, distance = os.pullEventRaw()
        if event == "timer" and side == timer then break end
        if event == "modem_message" and channel == reply and type(distance) == "number"
            and type(message) == "table" and message.zg == gps.VERSION and message.t == "here"
            and message.nonce == nonce and #answers < MAX_ANSWERS then
            answers[#answers + 1] = { cert = message.cert, stamp = message.stamp, distance = distance }
        end
    end

    -- Answers already checked cost nothing, so use those first.
    local ordered = {}
    for _, answer in ipairs(answers) do if seenBefore(answer) then ordered[#ordered + 1] = answer end end
    for _, answer in ipairs(answers) do if not seenBefore(answer) then ordered[#ordered + 1] = answer end end

    -- Anyone can pass a host's answer on from somewhere else. A host heard at two distances, or
    -- claiming two places, can't be placed, so it's left out rather than the first answer believed.
    local byKey, order, checks = {}, {}, 0
    local now = os.epoch("utc")
    for _, answer in ipairs(ordered) do
        -- Only an answer naming a trusted root costs a signature check, so only those are counted.
        local cert = answer.cert
        local costly = not seenBefore(answer) and type(cert) == "table" and type(cert.root) == "string"
            and trust.root(cert.root) ~= nil
        if costly then checks = checks + 1 end
        if (not costly or checks <= MAX_CHECKS) and trusted(answer, now) then
            local host = byKey[cert.key]
            if not host then
                host = { pos = { cert.x, cert.y, cert.z }, distance = answer.distance }
                byKey[cert.key] = host
                order[#order + 1] = host
            elseif math.abs(host.distance - answer.distance) > TOLERANCE or host.pos[1] ~= cert.x
                or host.pos[2] ~= cert.y or host.pos[3] ~= cert.z then
                host.conflict = true
            end
        end
    end

    local hosts, places = {}, {}
    for _, host in ipairs(order) do
        local place = table.concat(host.pos, ",")
        if not host.conflict and not places[place] and #hosts < MAX_HOSTS then -- one place adds nothing twice
            places[place] = true
            hosts[#hosts + 1] = host
        end
    end
    if #hosts < 3 then return nil end
    return gps.solve(hosts)
end

return gps
