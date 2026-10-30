--[[ Who this computer is on the network, and who it believes.

Every computer has an Ed25519 identity key. Users' keys stay locked until they log in, but
networking runs even while nobody is logged in, so the identity belongs to the computer.

A root server is a computer whose key this computer has chosen to trust. It signs certificates,
each saying "this key belongs to this name on this computer". A peer that shows a current
certificate from a trusted root, for the computer id it claims, is verified. Any other peer is
pinned by computer id the first time it's seen, and is refused if its key ever changes. Computer
ids can be faked, so a certificate only counts for its own id: otherwise any certified computer
could claim another's id and replace its pinned key.

Keys in stored and transmitted tables are hex; the crypto functions take raw bytes. ]]

local crypto = require("crypto")
local keys = require("keys")
local util = require("util")

local trust = {}

trust.DIR = keys.NET_DIR
local IDENTITY = fs.combine(trust.DIR, "identity")
local ROOTS = fs.combine(trust.DIR, "roots")
local CERTS = fs.combine(trust.DIR, "certs")

local MAX_NAME = 24
local MAX_CERTS = 4 -- most certificates a peer can show, since each costs a signature check

trust.fingerprint = crypto.fingerprint

-- Names are shown on screens and signed into certificates.
function trust.validName(name)
    if type(name) ~= "string" or #name > MAX_NAME or not name:match("^[%w_%.%- ]+$")
            or name:match("^ ") or name:match(" $") then
        return false, "Names are 1-" .. MAX_NAME .. " letters, digits, spaces, ., - or _."
    end
    return true
end

function trust.defaultName()
    local label = os.getComputerLabel()
    if label and trust.validName(label) then return label end
    return "computer-" .. os.getComputerID()
end

------------------------------------------------------------------------------
-- This computer's identity
------------------------------------------------------------------------------

local seed, public

-- Returns the signing seed and public key, creating them the first time.
function trust.identity()
    if seed then return seed, public end
    local stored = util.readTable(IDENTITY)
    if type(stored) == "table" and crypto.isHex(stored.seed, 64) and crypto.isHex(stored.key, 64) then
        seed, public = crypto.fromHex(stored.seed), crypto.fromHex(stored.key)
    else
        seed, public = crypto.signingKeypair()
        util.writeTable(IDENTITY, { seed = crypto.toHex(seed), key = crypto.toHex(public) })
    end
    return seed, public
end

------------------------------------------------------------------------------
-- Trusted root servers
------------------------------------------------------------------------------

local function loadRoots()
    return util.readTable(ROOTS) or {}
end

-- Every trusted root as { key, name, host, fingerprint, ... }, sorted by name.
function trust.roots()
    local out = {}
    for key, root in pairs(loadRoots()) do
        root.key, root.fingerprint = key, crypto.fingerprint(crypto.fromHex(key))
        out[#out + 1] = root
    end
    table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
    return out
end

function trust.root(key)
    return loadRoots()[key]
end

function trust.addRoot(key, name, host)
    local roots = loadRoots()
    roots[key] = { name = name, host = host, added = os.epoch("utc") }
    util.writeTable(ROOTS, roots)
end

-- Removing a root also removes the certificates it issued to this computer.
function trust.removeRoot(key)
    local roots = loadRoots()
    roots[key] = nil
    util.writeTable(ROOTS, roots)
    trust.removeCert(key)
end

------------------------------------------------------------------------------
-- Certificates and adverts
------------------------------------------------------------------------------

-- os.epoch is too big for tostring, which would round it.
local function whole(n)
    return string.format("%.0f", n)
end

local function certBody(cert)
    return table.concat({ "zos-cert-1", cert.name, whole(cert.id), cert.key, cert.root, whole(cert.issued),
        whole(cert.expires) }, "\n")
end

local function advertBody(advert)
    return table.concat({ "zos-root-1", advert.name, advert.key, whole(advert.host) }, "\n")
end

local function wellFormed(cert)
    return type(cert) == "table" and trust.validName(cert.name) and type(cert.id) == "number"
        and crypto.isHex(cert.key, 64)
        and crypto.isHex(cert.root, 64) and crypto.isHex(cert.sig, 128)
        and type(cert.issued) == "number" and type(cert.expires) == "number"
end

-- Sign a certificate. Used by root servers.
function trust.issue(rootSeed, rootKey, name, id, key, lifetimeMs)
    local now = os.epoch("utc")
    local cert = { name = name, id = id, key = key, root = crypto.toHex(rootKey), issued = now,
        expires = now + lifetimeMs }
    cert.sig = crypto.toHex(crypto.sign(rootSeed, certBody(cert), rootKey))
    return cert
end

-- Signature checks take a moment, and a peer's certificate turns up at every handshake.
local checked, checkedCount = {}, 0

-- Is this certificate, for this key, signed by the root it names and still current?
-- Doesn't ask whether the root is trusted; see trust.verifiedBy.
function trust.checkCert(cert, key)
    if not wellFormed(cert) or cert.key ~= key or cert.expires <= os.epoch("utc") then return false end
    local body = certBody(cert) .. cert.sig
    if checked[body] == nil then
        if checkedCount >= 32 then checked, checkedCount = {}, 0 end
        checked[body] = crypto.verify(crypto.fromHex(cert.root), certBody(cert), crypto.fromHex(cert.sig))
        checkedCount = checkedCount + 1
    end
    return checked[body]
end

-- The first certificate from a trusted root that's valid for this computer and key, if any.
function trust.verifiedBy(id, key, certs)
    if type(certs) ~= "table" then return nil end
    for i = 1, math.min(#certs, MAX_CERTS) do
        local cert = certs[i]
        if type(cert) == "table" and cert.id == id and trust.root(cert.root) and trust.checkCert(cert, key) then
            return cert
        end
    end
end

-- What a root server announces: its name and key, signed with that key so that neither can be
-- changed on the way. It takes no work to send, so answering probes can't be used to tie it up.
function trust.signAdvert(rootSeed, rootKey, name)
    local advert = { name = name, key = crypto.toHex(rootKey), host = os.getComputerID() }
    advert.sig = crypto.toHex(crypto.sign(rootSeed, advertBody(advert), rootKey))
    return advert
end

function trust.checkAdvert(advert)
    if type(advert) ~= "table" or not trust.validName(advert.name) or not crypto.isHex(advert.key, 64)
            or not crypto.isHex(advert.sig, 128) or type(advert.host) ~= "number" then
        return false
    end
    return crypto.verify(crypto.fromHex(advert.key), advertBody(advert), crypto.fromHex(advert.sig))
end

------------------------------------------------------------------------------
-- This computer's certificates, one per root
------------------------------------------------------------------------------

local function loadCerts()
    return util.readTable(CERTS) or {}
end

-- Certificates to show peers, as a list.
function trust.certs()
    local out = {}
    for _, cert in pairs(loadCerts()) do out[#out + 1] = cert end
    table.sort(out, function(a, b) return a.expires > b.expires end)
    return out
end

function trust.cert(rootKey)
    return loadCerts()[rootKey]
end

function trust.installCert(cert)
    local certs = loadCerts()
    certs[cert.root] = cert
    util.writeTable(CERTS, certs)
end

function trust.removeCert(rootKey)
    local certs = loadCerts()
    certs[rootKey] = nil
    util.writeTable(CERTS, certs)
end

------------------------------------------------------------------------------
-- Deciding about a peer
------------------------------------------------------------------------------

-- What's believed about a peer right now. Roots can be removed and certificates can expire
-- during a session, so this is worked out again for each message. `key` is hex.
function trust.describe(id, key, certs)
    local cert = trust.verifiedBy(id, key, certs)
    return {
        id = id,
        key = key,
        fingerprint = crypto.fingerprint(crypto.fromHex(key)),
        verified = cert ~= nil,
        name = cert and cert.name or nil,
        root = cert and cert.root or nil,
    }
end

-- `key` is raw and already proven: the peer signed the handshake with it. Returns a description
-- of the peer, or nil and a reason if it must be refused.
function trust.evaluate(id, key, certs)
    local hex = crypto.toHex(key)
    local address = "net:" .. id
    local pinned = keys.known(address)
    local cert = trust.verifiedBy(id, hex, certs)

    if pinned and pinned ~= key and not cert then
        return nil, "computer " .. id .. " has a different key than before"
    end
    if pinned ~= key then keys.remember(address, key) end

    return trust.describe(id, hex, certs)
end

return trust
