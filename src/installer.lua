-- Stable-release installer. Separate from the DNS relay runtime.
local sha = require("installer_sha256")
local http = require("installer_http")
local M = {}
local target = "/lua/rtx-dns.lua"
local self = "/lua/rtx-dns-install.lua"
local stage = "/lua/rtx-dns.install-new"
local backup = "/lua/rtx-dns.install-old"
local marker = "/lua/rtx-dns.install-state"
local distribution = "https://raw.githubusercontent.com/Yamar50/rtx-dns-tcp-lua/main/installer/stable/"

function M.checksum(text)
    local result
    assert(type(text) == "string" and #text <= 16384, "invalid SHA256SUMS")
    for line in (text .. "\n"):gmatch("([^\r\n]+)") do
        local digest, name = line:match("^(%x+)%s+%*?([^%s]+)%s*$")
        assert(digest and #digest == 64, "malformed SHA256SUMS")
        if name == "rtx-dns.lua" then
            assert(not result, "duplicate rtx-dns.lua checksum")
            result = digest:lower()
        end
    end
    return assert(result, "rtx-dns.lua checksum missing")
end

function M.schedule(config)
    local used, existing = {}, nil
    for line in config:gmatch("[^\r\n]+") do
        local id = line:match("^schedule at (%d+) ")
        if id then
            used[tonumber(id)] = true
            if line:find("rtx-dns.lua", 1, true) or line:find("nvr-dns.lua", 1, true) then
                assert(line == "schedule at " .. id .. " startup * lua " .. target,
                    "custom DNS startup schedule: update it manually before installing")
                assert(not existing, "multiple DNS startup schedules")
                existing = tonumber(id)
            end
        end
    end
    if existing then return existing, true end
    for id = 1, 999 do if not used[id] then return id, false end end
    error("no free schedule number in installer search range 1..999")
end

function M.count(status, path)
    local paths, commands = 0, 0
    for line in status:gmatch("[^\r\n]+") do
        if line:match(":%s*(/%S+)%s*$") == path then paths = paths + 1 end
        if line:match("%f[%a]lua%s+(/%S+)%s*$") == path then commands = commands + 1 end
    end
    return math.max(paths, commands)
end

function M.installers(status)
    local count = M.count(status, self)
    for line in status:gmatch("[^\r\n]+") do
        if line:find("lua %-e ") and line:find("local DNSINSTALL_BOOT=", 1, true) then count = count + 1 end
    end
    return count
end

local function config_text(raw)
    local lines = {}
    for line in raw:gmatch("[^\r\n]+") do
        if not line:match("^%s*#") and line:match("%S") then lines[#lines + 1] = line end
    end
    return table.concat(lines, "\n")
end

function M.run(rt, mode, env)
    env = env or {}
    local fs, system = env.io or io, env.os or os
    local compile, say = env.compile or loadstring or load, env.print or print
    local function log(s) say("DNSINSTALL " .. s) end
    local function command(cmd)
        local ok, output = rt.command(cmd, "off")
        assert(ok and (output == nil or type(output) == "string"), "router command failed: " .. cmd)
        if cmd:match("^show ") then assert(type(output) == "string", "missing router output: " .. cmd) end
        return output or ""
    end
    local function read(path)
        local f = fs.open(path, "rb")
        if not f then return nil end
        local data = f:read("*a"); local ok = f:close()
        assert(type(data) == "string" and ok, "file read failed: " .. path)
        return data
    end
    local function write(path, data)
        local f = assert(fs.open(path, "wb"), "cannot write: " .. path)
        local ok = f:write(data); local closed = f:close()
        assert(ok and closed and read(path) == data, "file write/read-back failed: " .. path)
    end
    local function remove(path)
        if read(path) ~= nil then assert(system.remove(path), "cannot remove: " .. path) end
    end
    local function status() return command("show status lua running") end
    local function wait_stopped()
        for _ = 1, 10 do
            if M.count(status(), target) == 0 then return end
            rt.sleep(1)
        end
        error("DNS task did not stop")
    end
    local function stop()
        if M.count(status(), target) > 0 then command("terminate lua file " .. target) end
        wait_stopped()
    end
    local function running()
        -- Do not mistake successful submission of an asynchronous lua command
        -- for a running relay. Check its exact path repeatedly after startup.
        rt.sleep(5)
        for _ = 1, 3 do
            assert(M.count(status(), target) == 1, "DNS task failed to stay running; inspect DNSRELAY log")
            rt.sleep(1)
        end
    end
    local old, was_running, changed, added_schedule
    local complete, save_attempted, prepared = false, false, false
    local ok, err = pcall(function()
        assert(mode == "yes" or mode == "no", "usage: lua " .. self .. " yes|no")
        assert(type(rt.sleep) == "function", "rt.sleep is required by the installer")
        assert(not read(marker) and not read(stage) and not read(backup),
            "previous installer files remain; see installer recovery instructions before retrying")
        local tasks = status()
        assert(M.installers(tasks) <= 1, "another installer is running")
        assert(not tasks:find("nvr-dns.lua", 1, true), "stop the NVR trial before installing")
        assert(M.count(tasks, target) <= 1, "multiple DNS tasks are running")
        local config = config_text(command("show config"))
        local schedule_id, existing = M.schedule(config)
        local version = http.latest(rt)
        log("latest stable release: " .. version .. " (Pre-release excluded)")
        -- Version and digest are one HTTP representation. Separate metadata
        -- URLs could be cached from different publications.
        local manifest = http.fetch(rt, distribution .. "manifest.txt", 16384)
        local published, sums = manifest:match("^(v%d+%.%d+%.%d+)\n(.*)$")
        assert(published == version, "stable installer distribution is not ready for " .. version .. "; use Release downloads")
        local expected = M.checksum(sums)
        local body = http.fetch(rt, distribution .. "rtx-dns.lua", 524288)
        assert(#body >= 1024 and body:byte(1) ~= 27, "invalid Lua source download")
        log("checking SHA256 (please wait)")
        local hash_ticks = 0
        assert(sha.hex(body, function()
            hash_ticks = hash_ticks + 1
            if hash_ticks % 8 == 0 then rt.sleep(1) end
            if hash_ticks % 32 == 0 then log("SHA256 progress: " .. math.min(hash_ticks * 2048, #body) .. "/" .. #body .. " bytes") end
        end) == expected, "SHA256 mismatch; current DNS unchanged")
        assert(compile(body), "downloaded Lua syntax is invalid")
        log("SHA256 OK: " .. expected)
        assert(config_text(command("show config")) == config, "router config changed during download; retry")
        tasks = status()
        assert(M.installers(tasks) <= 1 and M.count(tasks, target) <= 1, "another installer or DNS task appeared")
        assert(not tasks:find("nvr-dns.lua", 1, true), "NVR trial task appeared during download")
        old = read(target)
        was_running = M.count(tasks, target) == 1
        assert(not was_running or old, "running DNS file is missing")
        prepared = true
        if old ~= body then write(stage, body) end
        if old then write(backup, old) end
        write(marker, "version=" .. version .. "\nsha256=" .. expected .. "\nold=" .. (old and "yes" or "no")
            .. "\nrunning=" .. (was_running and "yes" or "no") .. "\n")
        assert(read(target) == old, "installed file changed during preparation")
        assert(config_text(command("show config")) == config, "router config changed during preparation; retry")
        tasks = status()
        assert(M.installers(tasks) <= 1 and M.count(tasks, target) == (was_running and 1 or 0)
            and not tasks:find("nvr-dns.lua", 1, true), "Lua tasks changed during preparation; retry")
        changed = true
        stop()
        if old ~= body then
            remove(target)
            assert(system.rename(stage, target), "cannot activate staged Lua file")
        else
            log("installed file matches latest stable; restarting to load verified code and current config")
        end
        assert(read(target) == body, "activated file differs from verified download")
        command("lua " .. target)
        running()
        log("DNS task is running: " .. target)
        assert(config_text(command("show config")) == config, "router config changed during startup")
        if mode == "yes" then
            if not existing then
                local line = "schedule at " .. schedule_id .. " startup * lua " .. target
                added_schedule = schedule_id
                command(line)
                local after = command("show config")
                local id, found = M.schedule(after)
                assert(found and id == schedule_id, "startup schedule verification failed")
                local without = {}
                for l in config_text(after):gmatch("[^\n]+") do if l ~= line then without[#without + 1] = l end end
                assert(table.concat(without, "\n") == config, "router config changed while adding startup schedule")
            end
            -- save may affect the boot-selected config rather than CONFIG0.
            -- If its response is lost, keep the verified running file; never
            -- roll it back while a new startup entry may already be durable.
            save_attempted = true
            command("save")
            log("autostart schedule " .. schedule_id .. " configured; current router configuration saved")
        else
            log("autostart configuration unchanged; config not saved")
        end
        complete = true
        remove(backup); remove(marker); remove(stage)
        remove(self)
        log("complete: " .. version .. "; installer removed")
    end)
    if not ok then
        log("failed: " .. tostring(err))
        if (changed or added_schedule) and not complete and not save_attempted then
            local restored, restore_error = pcall(function()
                if added_schedule then
                    local owned = "schedule at " .. added_schedule .. " startup * lua " .. target
                    for line in command("show config"):gmatch("[^\r\n]+") do
                        if line == owned then command("no schedule at " .. added_schedule) end
                    end
                end
                if changed then
                    stop()
                    if old then
                        if read(target) ~= old then write(target, old) end
                    else remove(target) end
                    if was_running then command("lua " .. target); running() end
                end
                if prepared then remove(stage); remove(backup); remove(marker) end
            end)
            if restored then log("previous file and running state restored")
            else log("automatic rollback failed: " .. tostring(restore_error) .. "; keep " .. backup) end
        elseif prepared and not changed then
            local cleaned = pcall(function() remove(stage); remove(backup); remove(marker) end)
            log(cleaned and "current DNS unchanged; staging cleaned" or "current DNS unchanged; staging cleanup failed")
        elseif save_attempted then
            log("verified DNS retained; check whether save succeeded and inspect remaining installer files")
        end
        return nil, tostring(err)
    end
    return true
end
return M
