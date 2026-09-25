package.path = "src/?.lua;" .. package.path
local uninstaller = require("uninstaller")
local target = "/lua/rtx-dns.lua"
local standard = "startup * lua " .. target
local total = 0
local function check(value, message)
    total = total + 1
    assert(value, message or ("assertion " .. total .. " failed"))
end
local function equal(a, b, message)
    check(a == b, (message or "values differ") .. ": " .. tostring(a) .. " ~= " .. tostring(b))
end
local function scenario(options)
    local o = options or {}
    local s = { options = o, files = {}, schedules = {}, commands = {}, logs = {}, syslogs = {},
        status_reads = 0, config_reads = 0, stops = 0, saves = 0, deletes = 0, sleeps = 0,
        running = o.running == nil and 1 or o.running }
    if not o.absent then s.files[target] = "-- installed relay" end
    s.files["/lua/other.lua"] = "-- unrelated script"
    s.files["/lua/rtx-dns-old.lua"] = "-- retained historical file"
    s.files["/other/rtx-dns.lua"] = "-- different path"
    if o.leftover then s.files["/lua/rtx-dns.install-" .. o.leftover] = "recovery data" end
    for id, body in pairs(o.schedules or { [100] = standard, [200] = "startup * lua /lua/other.lua" }) do
        s.schedules[id] = body
    end
    local function config()
        local lines, ids = { "dns service recursive", "dns host lan1", "dns server 192.0.2.53" }, {}
        for id in pairs(s.schedules) do ids[#ids + 1] = id end
        table.sort(ids)
        for _, id in ipairs(ids) do lines[#lines + 1] = "schedule at " .. id .. " " .. s.schedules[id] end
        if s.extra_config then lines[#lines + 1] = s.extra_config end
        return table.concat(lines, "\r\n") .. "\r\n"
    end
    s.config = config
    s.saved = config()
    local rt = {}
    function rt.sleep(seconds) equal(seconds, 1, "bounded one-second wait"); s.sleeps = s.sleeps + 1 end
    function rt.syslog(level, line)
        equal(level, "info")
        check(#line <= 231, "YAMAHA SYSLOG size limit")
        if o.syslog_error then error("log unavailable") end
        s.syslogs[#s.syslogs + 1] = line
    end
    function rt.command(cmd, logging)
        equal(logging, "off")
        s.commands[#s.commands + 1] = cmd
        if o.command_false == cmd then return false, "injected command failure" end
        if cmd == "show status lua running" then
            s.status_reads = s.status_reads + 1
            if o.missing_status then return true, nil end
            local label = o.cp932 and string.char(131, 88, 131, 78, 131, 138) or "Script file"
            local boot = "Command line: lua -e 'local DNSINSTALL_BOOT=\"uninstall\";run()'"
            local lines = { boot, label .. ": /lua/other.lua" }
            for _ = 1, s.running do
                lines[#lines + 1] = label .. ": " .. target
                lines[#lines + 1] = "Command line: lua " .. target
            end
            if o.other_installer then lines[#lines + 1] = label .. ": /lua/rtx-dns-install.lua" end
            if o.other_uninstaller then lines[#lines + 1] = boot end
            if o.late_installer == s.status_reads then lines[#lines + 1] = boot end
            if o.nvr then lines[#lines + 1] = label .. ": /lua/nvr-dns.lua" end
            return true, table.concat(lines, "\r\n")
        elseif cmd == "show config" then
            s.config_reads = s.config_reads + 1
            if o.change_config == s.config_reads then s.extra_config = "dns cache use off" end
            return true, "# TIME: " .. s.config_reads .. "\r\n" .. config()
        elseif cmd == "terminate lua file " .. target then
            s.stops = s.stops + 1
            if o.stop_false then return false, "stop failed" end
            if not o.stop_stuck then s.running = 0 end
        elseif cmd == "save" then
            s.saves = s.saves + 1
            if o.save_false then
                if o.save_applied then s.saved = config() end
                return false, "save result unavailable"
            end
            if o.save_error then error("save interrupted") end
            s.saved = config()
            if o.change_at_save then s.extra_config = "dns cache use off" end
            if o.restart_at_save then s.running = 1 end
        else
            local id = tonumber(cmd:match("^no schedule at (%d+)$"))
            check(id ~= nil, "unexpected command: " .. cmd)
            if o.schedule_false == id then
                if o.schedule_applied then s.schedules[id] = nil end
                return false, "remove failed"
            end
            if not o.schedule_noop then s.schedules[id] = nil end
            if o.change_at_schedule then s.extra_config = "dns cache use off" end
        end
        return true, nil
    end
    local fs = {}
    function fs.open(path, mode)
        equal(mode, "rb", "uninstaller must not write files")
        if s.files[path] == nil then return nil, "not found" end
        return { close = function() return not o.close_failure end }
    end
    local os_mock = {}
    function os_mock.remove(path)
        equal(path, target, "only the exact relay file may be removed")
        check(s.saves > 0, "body removed before saving configuration")
        equal(s.running, 0, "body removed while task running")
        s.deletes = s.deletes + 1
        if o.delete_false then
            if o.delete_applied then s.files[path] = nil end
            return nil, "delete failed"
        end
        if not o.delete_noop then s.files[path] = nil end
        return true
    end
    s.rt = rt
    s.env = { io = fs, os = os_mock, print = function(line) s.logs[#s.logs + 1] = line end }
    function s.run()
        local saved_floor = math.floor
        math.floor = nil -- YAMAHA integer-only Lua does not provide math.floor.
        local ok, err = uninstaller.run(rt, s.env)
        math.floor = saved_floor
        equal(s.files["/lua/other.lua"], "-- unrelated script")
        equal(s.files["/lua/rtx-dns-old.lua"], "-- retained historical file")
        equal(s.files["/other/rtx-dns.lua"], "-- different path")
        return ok, err
    end
    return s
end
local function success(s)
    local ok, err = s.run()
    check(ok, err)
    equal(s.files[target], nil)
    equal(s.running, 0)
    equal(s.saved, s.config())
    local n = 0
    for _, line in ipairs(s.logs) do
        local number = line:match("^DNSUNINSTALL %((%d+)/7%)")
        if number then n = n + 1; equal(tonumber(number), n) end
    end
    equal(n, 7, "seven increasing progress messages")
    check(s.syslogs[#s.syslogs]:match("^DNSUNINSTALL complete:"), "GUI-visible completion")
end
local function failure(s, expected, unchanged)
    local body = s.files[target]
    local ok, err = s.run()
    check(not ok and type(err) == "string", "failure was reported as success")
    check(err:find(expected, 1, true), err)
    equal(s.files[target], body, "body must be retained on pre-delete failure")
    check(s.syslogs[#s.syslogs]:match("^DNSUNINSTALL failed:"), "GUI-visible error")
    for _, line in ipairs(s.logs) do check(not line:find("Uninstallation complete", 1, true), "false completion") end
    if unchanged then equal(s.stops + s.saves + s.deletes, 0, "preflight failure mutated router") end
end

local s = scenario()
success(s)
equal(s.schedules[100], nil)
equal(s.schedules[200], "startup * lua /lua/other.lua")
equal(s.stops, 1)
s.logs = {}; success(s) -- Second run must succeed without terminating/deleting again.
equal(s.stops, 1); equal(s.deletes, 1)

success(scenario({ running = 0 }))
success(scenario({ absent = true, running = 0, schedules = {} }))
success(scenario({ absent = true })) -- Orphaned running task is still stopped.
success(scenario({ running = 3, cp932 = true, schedules = {
    [1] = standard, [999] = standard, [3000] = "startup * lua /lua/other.lua",
} }))

for _, schedule in ipairs({
    "startup * lua /other/rtx-dns.lua", "startup * lua /lua/rtx-dns.lua extra",
    "12:00 * lua /lua/rtx-dns.lua", "startup * lua /lua/nvr-dns.lua",
    "startup * echo rtx-dns.lua", "startup * lua /lua/rtx-dns.lua.old",
}) do failure(scenario({ schedules = { [100] = standard, [101] = schedule } }), "custom DNS schedule", true) end
for _, suffix in ipairs({ "new", "old", "state" }) do failure(scenario({ leftover = suffix }), "recovery files", true) end
failure(scenario({ other_installer = true }), "another installer", true)
failure(scenario({ other_uninstaller = true }), "another installer", true)
failure(scenario({ late_installer = 2 }), "another installer", true)
failure(scenario({ nvr = true }), "NVR trial", true)
failure(scenario({ missing_status = true }), "missing router output", true)
failure(scenario({ command_false = "show status lua running" }), "router command failed", true)
failure(scenario({ command_false = "show config" }), "router command failed", true)
failure(scenario({ change_config = 2 }), "configuration changed", true)
failure(scenario({ close_failure = true, leftover = "old" }), "cannot close", true)

s = scenario({ stop_false = true }); failure(s, "router command failed")
equal(s.saves, 0); equal(s.schedules[100], standard)
s.options.stop_false = false; s.logs = {}; success(s)
s = scenario({ stop_stuck = true }); failure(s, "DNS task did not stop")
equal(s.sleeps, 11); equal(s.schedules[100], standard)
failure(scenario({ late_installer = 3 }), "another installer")
failure(scenario({ change_config = 3 }), "configuration changed")
failure(scenario({ schedule_noop = true }), "schedule removal verification failed")
failure(scenario({ change_at_schedule = true }), "schedule removal verification failed")
for _, applied in ipairs({ false, true }) do
    s = scenario({ schedules = { [100] = standard, [101] = standard }, schedule_false = 101, schedule_applied = applied })
    failure(s, "router command failed")
    equal(s.schedules[100], nil); equal(s.saves, 0)
    s.options.schedule_false = nil; s.logs = {}; success(s)
end
for _, applied in ipairs({ false, true }) do
    s = scenario({ save_false = true, save_applied = applied })
    failure(s, "router command failed")
    equal(s.deletes, 0); equal(s.schedules[100], nil)
    s.options.save_false = false; s.logs = {}; success(s)
end
failure(scenario({ save_error = true }), "save interrupted")
failure(scenario({ change_at_save = true }), "configuration changed during save")
failure(scenario({ restart_at_save = true }), "DNS task restarted during save")
s = scenario({ delete_false = true }); failure(s, "cannot remove DNS script")
s.options.delete_false = false; s.logs = {}; success(s)
s = scenario({ delete_false = true, delete_applied = true })
local ok, err = s.run(); check(not ok and err:find("cannot remove", 1, true))
equal(s.files[target], nil)
s.options.delete_false = false; s.logs = {}; success(s)
failure(scenario({ delete_noop = true }), "DNS script still exists")

s = scenario({ syslog_error = true }); check(s.run(), "logging failure should not undo successful removal")
s = scenario(); s.rt.syslog = nil; check(s.run(), "syslog is optional")
s = scenario(); s.rt.sleep = nil
failure(s, "rt.sleep is required", true)

print("uninstaller: " .. total .. " assertions passed")
