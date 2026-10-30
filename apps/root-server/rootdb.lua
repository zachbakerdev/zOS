-- The root server's key, settings and certificate requests. Kept in files because the app and
-- its service each load their own copy of this module, and both change them. Nothing yields
-- between reading a file and writing it back, so they can't overwrite each other's changes.

local crypto = require("crypto")
local trust = require("trust")
local util = require("util")

local db = {}

local DIR = "/etc/zos/root-server"
local KEY = fs.combine(DIR, "key")
local CONFIG = fs.combine(DIR, "config")
local REQUESTS = fs.combine(DIR, "requests")

local DAY = 24 * 3600 * 1000
local MAX_PENDING = 32

db.DEFAULT_DAYS = 30

function db.ready()
    return fs.exists(KEY)
end

function db.config()
    local config = util.readTable(CONFIG) or {}
    if config.online == nil then config.online = true end
    config.days = config.days or db.DEFAULT_DAYS
    return config
end

function db.setConfig(changes)
    local config = db.config()
    for key, value in pairs(changes) do config[key] = value end
    util.writeTable(CONFIG, config)
end

function db.keypair()
    local stored = util.readTable(KEY)
    return crypto.fromHex(stored.seed), crypto.fromHex(stored.key)
end

-- Sign the name and key that go in announcements. Call again if the name changes.
local function refreshAdvert(name)
    local seed, public = db.keypair()
    db.setConfig({ name = name, advert = trust.signAdvert(seed, public, name) })
end

-- Make a new key. Everything signed with an old key stops being accepted.
function db.setup(name, tld)
    local seed, public = crypto.signingKeypair()
    util.writeTable(KEY, { seed = crypto.toHex(seed), key = crypto.toHex(public) })
    util.writeTable(REQUESTS, {})
    refreshAdvert(name)
    db.setConfig({ zone = trust.signZone(seed, public, tld or trust.tldFromName(name)) })
end

db.rename = refreshAdvert

function db.fingerprint()
    local _, public = db.keypair()
    return trust.fingerprint(public)
end

function db.requests()
    return util.readTable(REQUESTS) or {}
end

-- One computer's request or certificate, by its key. status is "pending", "issued", "denied"
-- or "revoked".
local function setRequest(key, entry)
    local requests = db.requests()
    requests[key] = entry
    util.writeTable(REQUESTS, requests)
end

-- Every request, pending ones first.
function db.list()
    local out = {}
    for key, entry in pairs(db.requests()) do
        entry.key = key
        out[#out + 1] = entry
    end
    table.sort(out, function(a, b)
        if (a.status == "pending") ~= (b.status == "pending") then return a.status == "pending" end
        return a.name:lower() < b.name:lower()
    end)
    return out
end

-- Plain certificate names have no dot, and hostnames always do.
local function isHostname(name)
    return name:find(".", 1, true) ~= nil
end

-- Set the top-level domain. A hostname can't move, so this only works while none are in use.
function db.setTld(tld)
    local ok, why = trust.validTld(tld)
    if not ok then return false, why end
    for _, entry in pairs(db.requests()) do
        if isHostname(entry.name) and (entry.status == "issued" or entry.status == "pending") then
            return false, "'" .. entry.name .. "' is using the current one. Revoke or refuse its hostname first."
        end
    end
    local seed, public = db.keypair()
    local zone = trust.signZone(seed, public, tld) -- yields, so check nothing has been asked for since
    for _, entry in pairs(db.requests()) do
        if isHostname(entry.name) and entry.status == "pending" then
            return false, "A new hostname was requested. Try again."
        end
    end
    db.setConfig({ zone = zone })
    return true
end

-- Roots set up before top-level domains existed get one from their name. Any dotted names they've
-- already signed keep working until they expire.
function db.ensureZone()
    if db.config().zone then return end
    local seed, public = db.keypair()
    db.setConfig({ zone = trust.signZone(seed, public, trust.tldFromName(db.config().name)) })
end

-- Hostnames have to be in this server's own top-level domain.
local function hostnameRefused(name)
    if not isHostname(name) then return nil end
    local label, tld = trust.parseHost(name)
    if not label then return tld end
    if tld ~= db.config().zone.tld then return "Hostnames on this server end in ." .. db.config().zone.tld .. "." end
end

-- Answer a computer looking up a hostname.
function db.resolve(name)
    for _, entry in pairs(db.requests()) do
        if entry.status == "issued" and entry.name == name and entry.cert.expires > os.epoch("utc") then
            return { cert = entry.cert }
        end
    end
    return {}
end

-- Why a certificate can't go to this key, if another one already holds the name or computer.
-- Computer ids are only claimed, so without this one key could take over another's id.
local function conflict(name, from, key)
    for otherKey, entry in pairs(db.requests()) do
        if otherKey ~= key and entry.status == "issued" then
            if entry.name:lower() == name:lower() then
                return "Another computer already has the name '" .. entry.name .. "'."
            elseif entry.from == from then
                return "Computer " .. tostring(from) .. " already has a certificate. Revoke it first."
            end
        end
    end
end

local function sign(entry, key)
    local seed, public = db.keypair()
    return trust.issue(seed, public, entry.name, entry.from, key, db.config().days * DAY)
end

-- Requesters can change a pending request at any time, including while it's on the admin's
-- screen, so only sign what the admin actually saw.
local function asReviewed(key, name, from)
    local entry = db.requests()[key]
    return entry and entry.status == "pending" and entry.name == name and entry.from == from
end

function db.approve(key, name, from)
    local changed = "The request has changed since you opened it. Review it again."
    if not asReviewed(key, name, from) then return false, changed end
    local why = conflict(name, from, key)
    if why then return false, why end
    local entry = db.requests()[key]
    local cert = sign(entry, key) -- yields, so check the request again before saving
    if not asReviewed(key, name, from) then return false, changed end
    entry.status, entry.cert = "issued", cert
    setRequest(key, entry)
    return true
end

function db.setStatus(key, status)
    local entry = db.requests()[key]
    entry.status, entry.cert = status, nil
    setRequest(key, entry)
end

function db.forget(key)
    setRequest(key, nil)
end

-- Answer a computer asking for a certificate. `key` is proven by its handshake.
function db.handle(name, key, from)
    local ok, why = trust.validName(name)
    if not ok then return { status = "error", message = why } end
    local taken = conflict(name, from, key)
    if taken then return { status = "error", message = taken } end

    local entry = db.requests()[key]
    -- A certificate from before this rule can still be renewed.
    if not (entry and entry.status == "issued" and entry.name == name) then
        local refused = hostnameRefused(name)
        if refused then return { status = "error", message = refused } end
    end
    if entry and (entry.status == "denied" or entry.status == "revoked") then
        return { status = "denied" }
    end
    if entry and entry.status == "issued" and (entry.name ~= name or entry.from ~= from) then
        return { status = "error", message = "This key is already certified as '" .. entry.name ..
            "' on computer " .. tostring(entry.from) .. ". Ask for it to be revoked first." }
    end
    if entry and entry.status == "issued" then
        -- Already approved, so this needs no one at the keyboard. Replace it once half used up.
        local left = entry.cert.expires - os.epoch("utc")
        if left < db.config().days * DAY / 2 then
            local cert = sign(entry, key)
            entry = db.requests()[key]
            if not entry or entry.status ~= "issued" then return { status = "denied" } end
            entry.cert = cert
            setRequest(key, entry)
        end
        return { status = "issued", cert = entry.cert }
    end
    if entry and entry.status == "pending" and entry.name == name and entry.from == from then
        return { status = "pending" }
    end

    local pending = 0
    for _, other in pairs(db.requests()) do
        if other.status == "pending" then pending = pending + 1 end
    end
    if pending >= MAX_PENDING then return { status = "error", message = "Too many requests are waiting." } end

    setRequest(key, { name = name, from = from, status = "pending", requested = os.epoch("utc") })
    return { status = "pending" }
end

return db
