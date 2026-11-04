--[[ Answers computers asking where they are, whether or not anyone is logged in, and keeps this
host's certificate from the root server current. See specs/libs/GPS.md for the protocol.

Answering never waits: an answer is the certificate and a timestamp signed ahead of time. Signing
a new timestamp and asking the root server are slow, so each gets its own loop and requests keep
being answered meanwhile. ]]

local crypto = require("crypto")
local db = require("gpsdb")
local gps = require("gps")
local util = require("util")

local MAX_ANSWERS_PER_TICK = 16
local ASK_PENDING = 10 -- seconds between asks while waiting for approval
local ASK_ISSUED = 3600
local RENEW_BEFORE = 7 * 24 * 3600 * 1000

local stamp -- { time, sig }, the latest signed timestamp

local function openAll()
    for _, name in ipairs(gps.wirelessModems()) do peripheral.call(name, "open", gps.PORT) end
end

local function answering()
    openAll()
    local tick, answered = nil, 0
    while true do
        local event, side, channel, replyChannel, message = os.pullEventRaw()
        if event == "peripheral" then
            openAll()
        elseif event == "modem_message" and channel == gps.PORT and type(message) == "table"
            and message.zg == gps.VERSION and message.t == "where"
            and type(message.nonce) == "string" and #message.nonce <= 64
            and type(replyChannel) == "number" and replyChannel >= 0 and replyChannel <= 65535 then
            local now = os.clock()
            if now ~= tick then tick, answered = now, 0 end
            local cert = stamp and db.config().online and db.usableCert()
            -- Only on the modem the request came in on, since its position is the one that's signed.
            if cert and answered < MAX_ANSWERS_PER_TICK and peripheral.getType(side) == "modem"
                and peripheral.call(side, "isWireless") then
                answered = answered + 1
                peripheral.call(side, "transmit", replyChannel, gps.PORT, {
                    zg = gps.VERSION, t = "here", nonce = message.nonce, cert = cert, stamp = stamp,
                })
            end
        end
    end
end

-- A new timestamp well before the last one runs out, so clients never see a stale one.
local function stamping()
    while true do
        local seed, public = db.keypair()
        local key, time = crypto.toHex(public), os.epoch("utc")
        stamp = { time = time, sig = crypto.toHex(crypto.sign(seed, gps.stampText(key, time), public)) }
        util.wait(gps.STAMP_EVERY)
    end
end

-- Wait this long, or until the app asks for something sooner.
local function nap(seconds)
    local timer = os.startTimer(seconds)
    repeat
        local event, id = os.pullEventRaw()
    until (event == "timer" and id == timer) or event == db.WAKE
end

local function asking()
    nap(5)
    while true do
        local config = db.config()
        local wait = ASK_PENDING
        if config.x and config.status == "pending" then
            db.ask()
        elseif config.x and config.status == "issued" then
            local cert = db.usableCert()
            if not cert or cert.expires - os.epoch("utc") < RENEW_BEFORE then db.ask() end
            if db.usableCert() then wait = ASK_ISSUED end
        end
        nap(wait)
    end
end

parallel.waitForAll(answering, stamping, asking)
