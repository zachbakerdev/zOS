-- Announces this root server and answers computers asking for certificates. Probes get their own
-- loop because answering a certificate request waits for the other computer. Requests that come
-- in meanwhile wait in the port's inbox.

local db = require("rootdb")
local net = require("net")

net.listen(net.ROOT_PORT)

local function serving()
    return db.ready() and db.config().online
end

local function announcements()
    while true do
        local _, probe = os.pullEventRaw(net.PROBE_EVENT)
        if probe and probe.port == net.ROOT_PORT and serving() then
            net.answerProbe(probe, db.config().advert)
        end
    end
end

local function requests()
    while true do
        local msg = net.receive(net.ROOT_PORT)
        local payload = msg and msg.payload
        if msg and serving() and type(payload) == "table" and payload.op == "certificate" then
            net.reply(msg, db.handle(payload.name, msg.peer.key, msg.from))
        end
    end
end

parallel.waitForAll(announcements, requests)
