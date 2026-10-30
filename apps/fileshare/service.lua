-- Answers other computers, whether or not anyone is logged in. Probes get their own loop because
-- answering a request waits for the other computer. Requests that come in meanwhile wait in the
-- port's inbox.

local net = require("net")
local share = require("share")
local system = require("system")
local trust = require("trust")

local SWEEP = 60 -- seconds

net.listen(share.PORT)

local function announcements()
    while true do
        local _, probe = os.pullEventRaw(net.PROBE_EVENT)
        if probe and probe.port == share.PORT then
            net.answerProbe(probe, { name = trust.defaultName() })
        end
    end
end

local function requests()
    while true do
        local msg = net.receive(share.PORT, SWEEP)
        if msg then
            local ok, err = pcall(share.serve, msg)
            if not ok then system.log("fileshare: " .. tostring(err)) end
        end
        share.sweep()
    end
end

parallel.waitForAll(announcements, requests)
