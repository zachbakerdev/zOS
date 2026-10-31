-- The computer's identity, trusted root servers, certificates and names.
-- See specs/libs/TRUST.md.

local crypto = require("crypto")
local system = require("system")
local util = require("util")

local trust = {}

local DIR = system.DATA .. "/net"
local IDENTITY = DIR .. "/identity"
local ROOTS = DIR .. "/roots"
local CERTS = DIR .. "/certs"

local MAX_HOST = 24
local MAX_TLD = 16
local MAX_NAME = 32

-- Limits on what a peer can make this computer do. Signatures are the slow part, so only
-- certificates that could count use one up.
local MAX_PEER_CERTS, MAX_CERT_CHECKS = 32, 4
local MAX_REMEMBERED = 64

-- Identity ------------------------------------------------------------------------------------

local seed, public

-- The computer's secret seed and public key. Apps MUST NOT use this.
function trust.identity()
    if seed then return seed, public end
    local stored = util.readTable(IDENTITY)
    if stored and crypto.isHex(stored.seed, 64) and crypto.isHex(stored.key, 64) then
        seed, public = crypto.fromHex(stored.seed), crypto.fromHex(stored.key)
    else
        seed, public = crypto.signingKeypair()
        util.writeTable(IDENTITY, { seed = crypto.toHex(seed), key = crypto.toHex(public) })
    end
    return seed, public
end

-- Names ---------------------------------------------------------------------------------------

function trust.defaultName()
    local label = os.getComputerLabel()
    if label and label:match("^%w[%w%-_ ]*$") and #label <= MAX_HOST then return label end
    return "computer-" .. os.getComputerID()
end

-- The label and top-level domain of a hostname, or nil and a reason.
function trust.parseHost(host)
    local bad = "Hostnames look like label.tld, in lowercase letters, digits and -."
    if type(host) ~= "string" then return nil, bad end
    if #host > MAX_HOST then return nil, "Hostnames can be at most " .. MAX_HOST .. " characters." end
    local label, tld = host:match("^([a-z0-9][a-z0-9%-]*)%.([a-z0-9][a-z0-9%-]*)$")
    if not label then return nil, bad end
    return label, tld
end

function trust.validTld(tld)
    if type(tld) ~= "string" or #tld < 1 or #tld > MAX_TLD or not tld:match("^[a-z0-9][a-z0-9%-]*$") then
        return false, "A top-level domain is 1-" .. MAX_TLD .. " lowercase letters, digits or -."
    end
    return true
end

function trust.tldFromName(name)
    local tld = name:lower():gsub("[^a-z0-9]+", "-"):gsub("^%-+", ""):sub(1, MAX_TLD):gsub("%-+$", "")
    return tld ~= "" and tld or "root"
end

-- Certificate and server names: a hostname if it has a dot, otherwise plain text.
function trust.validName(name)
    if type(name) ~= "string" or #name < 1 or #name > MAX_NAME or not name:match("^[%w%-_ %.]+$") then
        return false, "Names are 1-" .. MAX_NAME .. " letters, digits, spaces, - or _."
    end
    if name:find(".", 1, true) then
        local label, why = trust.parseHost(name)
        if not label then return false, why end
    end
    return true
end

-- Signatures -----------------------------------------------------------------------------------

local function certText(c)
    return table.concat({ "zos-cert-1", c.name, c.id, c.key, c.root, c.issued, c.expires }, "|")
end

local function advertText(a)
    return "zos-advert-1|" .. a.name .. "|" .. a.key
end

local function zoneText(z)
    return "zos-zone-1|" .. z.tld .. "|" .. z.root
end

-- Ed25519 is slow and certificates are checked on every message, so remember the good ones.
local verified, rememberedCount = {}, 0

local function checkSignature(key, text, sig)
    if not crypto.isHex(key, 64) or not crypto.isHex(sig, 128) then return false end
    local id = key .. "|" .. text .. "|" .. sig
    if verified[id] == nil then
        if rememberedCount >= MAX_REMEMBERED then verified, rememberedCount = {}, 0 end
        rememberedCount = rememberedCount + 1
        verified[id] = crypto.verify(crypto.fromHex(key), text, crypto.fromHex(sig))
    end
    return verified[id]
end

function trust.signAdvert(rootSeed, rootPublic, name)
    local advert = { name = name, key = crypto.toHex(rootPublic) }
    advert.sig = crypto.toHex(crypto.sign(rootSeed, advertText(advert), rootPublic))
    return advert
end

function trust.verifyAdvert(advert)
    return type(advert) == "table" and type(advert.name) == "string" and type(advert.key) == "string"
        and checkSignature(advert.key, advertText(advert), advert.sig)
end

function trust.signZone(rootSeed, rootPublic, tld)
    local zone = { tld = tld, root = crypto.toHex(rootPublic) }
    zone.sig = crypto.toHex(crypto.sign(rootSeed, zoneText(zone), rootPublic))
    return zone
end

function trust.verifyZone(zone, rootKey)
    return type(zone) == "table" and type(zone.tld) == "string" and zone.root == rootKey
        and checkSignature(rootKey, zoneText(zone), zone.sig)
end

-- Sign a certificate saying that `key` (hex) belongs to `name` on computer `id`.
function trust.issue(rootSeed, rootPublic, name, id, key, lifetime)
    local now = os.epoch("utc")
    local cert = {
        name = name, id = id, key = key, root = crypto.toHex(rootPublic),
        issued = now, expires = now + lifetime,
    }
    cert.sig = crypto.toHex(crypto.sign(rootSeed, certText(cert), rootPublic))
    return cert
end

-- Whether a certificate is well formed, current and signed by its root. Doesn't check trust.
function trust.certIntact(cert)
    return type(cert) == "table" and type(cert.name) == "string" and type(cert.id) == "number"
        and type(cert.key) == "string" and type(cert.root) == "string"
        and type(cert.issued) == "number" and type(cert.expires) == "number"
        and cert.expires > os.epoch("utc") and checkSignature(cert.root, certText(cert), cert.sig)
end

-- Roots ---------------------------------------------------------------------------------------

local function allRoots()
    return util.readTable(ROOTS) or {}
end

local function allCerts()
    return util.readTable(CERTS) or {}
end

function trust.roots()
    local out = {}
    for _, root in pairs(allRoots()) do out[#out + 1] = root end
    table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
    return out
end

function trust.root(key)
    return allRoots()[key]
end

function trust.addRoot(key, name, host)
    local all = allRoots()
    all[key] = { key = key, name = name, host = host, tld = all[key] and all[key].tld }
    util.writeTable(ROOTS, all)
end

function trust.removeRoot(key)
    local all = allRoots()
    all[key] = nil
    util.writeTable(ROOTS, all)
    local certs = allCerts()
    certs[key] = nil
    util.writeTable(CERTS, certs)
end

-- Remember a root's top-level domain, from a zone record already checked with verifyZone.
function trust.setRootTld(key, tld)
    local all = allRoots()
    if all[key] then
        all[key].tld = tld
        util.writeTable(ROOTS, all)
    end
end

-- This computer's certificates -----------------------------------------------------------------

function trust.certs()
    local out = {}
    for _, cert in pairs(allCerts()) do out[#out + 1] = cert end
    table.sort(out, function(a, b) return a.root < b.root end)
    return out
end

function trust.cert(rootKey)
    return allCerts()[rootKey]
end

-- A computer holds one certificate per root.
function trust.installCert(cert)
    local certs = allCerts()
    certs[cert.root] = cert
    util.writeTable(CERTS, certs)
end

-- What a peer's certificates prove: each valid name by root key. A certificate only counts for
-- its own computer id and key, and only if a root this computer trusts signed it.
function trust.namesFor(certs, id, keyHex)
    local names, first, checks = {}, nil, 0
    local trusted = allRoots()
    local now = os.epoch("utc")
    for i = 1, math.min(type(certs) == "table" and #certs or 0, MAX_PEER_CERTS) do
        local cert = certs[i]
        if type(cert) == "table" and cert.id == id and cert.key == keyHex and trusted[cert.root]
            and type(cert.expires) == "number" and cert.expires > now then
            checks = checks + 1
            if trust.certIntact(cert) then
                names[cert.root] = cert.name
                first = first or cert
            end
            if checks == MAX_CERT_CHECKS then break end
        end
    end
    return names, first
end

return trust
