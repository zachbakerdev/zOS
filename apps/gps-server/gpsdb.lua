-- The GPS host's key, position and certificate. Kept in files because the app and its service each
-- load their own copy of this module. Nothing yields between reading a file and writing it back,
-- so they can't overwrite each other's changes.

local crypto = require("crypto")
local net = require("net")
local trust = require("trust")
local util = require("util")

local db = {}

local DIR = "/etc/gps-server"
local KEY = fs.combine(DIR, "key")
local CONFIG = fs.combine(DIR, "config")

db.WAKE = "gps_server_wake" -- queued by the app when the service should ask the root server now

-- The key GPS answers are signed with. It's this app's own, not the computer's identity, and the
-- root server ties it to this computer and position.
function db.keypair()
    local stored = util.readTable(KEY)
    if stored and crypto.isHex(stored.seed, 64) and crypto.isHex(stored.key, 64) then
        return crypto.fromHex(stored.seed), crypto.fromHex(stored.key)
    end
    local seed, public = crypto.signingKeypair()
    util.writeTable(KEY, { seed = crypto.toHex(seed), key = crypto.toHex(public) })
    return seed, public
end

function db.publicKey()
    return crypto.toHex(select(2, db.keypair()))
end

--[[ config fields:
  x, y, z   where the wireless modem is, or nil before it's set
  root      the key of the root server asked to vouch for it
  status    "pending", "issued", "denied" or "error", once asked
  message   why, for "error"
  cert      the GPS certificate, once issued
  online    whether to answer, true unless turned off ]]
function db.config()
    local config = util.readTable(CONFIG) or {}
    if config.online == nil then config.online = true end
    return config
end

function db.setConfig(changes)
    local config = db.config()
    for key, value in pairs(changes) do config[key] = value end
    util.writeTable(CONFIG, config)
end

-- A new position or root drops the certificate, since it says where this host was.
function db.setPosition(x, y, z, rootKey)
    local config = db.config()
    config.x, config.y, config.z, config.root = x, y, z, rootKey
    config.status, config.message, config.cert = "pending", nil, nil
    util.writeTable(CONFIG, config)
    os.queueEvent(db.WAKE)
end

-- Send the same request again, after a refusal or an error.
function db.retry()
    db.setConfig({ status = "pending", message = nil })
    os.queueEvent(db.WAKE)
end

-- The certificate to send, if it's current and still for this key and position.
function db.usableCert()
    local config = db.config()
    local cert = config.cert
    if type(cert) ~= "table" or cert.expires <= os.epoch("utc") then return nil end
    if cert.x ~= config.x or cert.y ~= config.y or cert.z ~= config.z or cert.root ~= config.root then return nil end
    return cert
end

-- Ask the root server for a certificate, or for a new one. Returns the status it ends up with.
-- Safe to repeat.
function db.ask()
    local config = db.config()
    local root = config.root and trust.root(config.root)
    if not root then
        db.setConfig({ status = "error", message = "This computer doesn't trust that root server any more." })
        return "error"
    end
    local x, y, z, key = config.x, config.y, config.z, db.publicKey()
    local reply, err = net.request(root.host, net.ROOT_PORT, { op = "gps", key = key, x = x, y = y, z = z },
        { timeout = 15 })

    -- Work out the answer first, because checking a certificate yields.
    local payload = reply and reply.payload
    local changes
    if not reply then
        -- A root server that can't be reached doesn't change anything, so a certificate stays.
        changes = { message = tostring(err) }
    elseif type(payload) ~= "table" then
        changes = { status = "error", message = "The root server sent a bad answer." }
    elseif payload.status == "issued" then
        local cert = payload.cert
        if trust.gpsCertIntact(cert) and cert.root == config.root and cert.key == key
            and cert.id == os.getComputerID() and cert.x == x and cert.y == y and cert.z == z then
            changes = { status = "issued", cert = cert, message = false }
        else
            changes = { status = "error", message = "The root server sent a bad certificate." }
        end
    elseif payload.status == "pending" then
        changes = { status = "pending", message = false }
    elseif payload.status == "denied" then
        changes = { status = "denied", cert = false, message = false }
    else
        changes = { status = "error",
            message = type(payload.message) == "string" and payload.message or "The root server refused." }
    end

    -- The position may have changed while waiting. That answer is for the old one.
    local now = db.config()
    if now.x ~= x or now.y ~= y or now.z ~= z or now.root ~= config.root then return now.status end
    if not reply and now.status == "issued" then return now.status end
    for field, value in pairs(changes) do
        if value == false then now[field] = nil else now[field] = value end -- false clears a field
    end
    util.writeTable(CONFIG, now)
    return now.status
end

return db
