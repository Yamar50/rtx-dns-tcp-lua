package.path = "src/?.lua;" .. package.path
local target = "/lua/rtx-dns.lua"
local installer_path = "/lua/rtx-dns-install.lua"
local stage = "/lua/rtx-dns.install-new"
local backup = "/lua/rtx-dns.install-old"
local marker = "/lua/rtx-dns.install-state"
local digest = string.rep("a", 64)
local new_body = "-- mock verified release\n" .. string.rep("-- source\n", 120)
local preview_digest = string.rep("c", 64)
local preview_body = new_body:gsub("mock", "v099", 1)
local raw_root = "https://raw.githubusercontent.com/Yamar50/rtx-dns-tcp-lua/"
local immutable_ref = string.rep("1", 40)
local function release(version, overrides)
    version = version or "v0.1.4"
    local metadata = {
        version = version,
        sha256 = version == "v0.9.9" and preview_digest or digest,
        bytes = #new_body,
        url = raw_root .. immutable_ref .. "/installer/versions/" .. version .. "/rtx-dns.lua",
    }
    for key, value in pairs(overrides or {}) do metadata[key] = value end
    return metadata
end
local old_body = "-- previous working release"
local count = 0
local function check(value, message)
    count = count + 1
    assert(value, message or ("assertion " .. count .. " failed"))
    return value
end
local function equal(actual, expected, message)
    check(actual == expected, (message or "values differ") .. ": " .. tostring(actual) .. " ~= " .. tostring(expected))
end

-- Replace external downloads and hashing, not filesystem or transaction logic.
local saved_sha, saved_http = package.loaded.installer_sha256, package.loaded.installer_http
local host_floor = math.floor
local active
package.loaded.installer_sha256 = { hex = function(data, yield_fn)
    -- Match the real SHA module's callback cadence, including its padding.
    -- Progress output must not count a padding-only 64 KiB boundary.
    local padded_bytes = #data + 9 + (119 - #data % 64) % 64
    for _ = 1, host_floor(padded_bytes / 2048) do yield_fn() end
    if active.options.bad_sha then return string.rep("b", 64) end
    if active.options.verified_body and data == active.options.verified_body then return digest end
    if data == new_body then return digest end
    if data == preview_body then return preview_digest end
    error("unexpected body passed to SHA256")
end }
package.loaded.installer_http = {
    latest = function(rt)
        rt.case.latest_calls = rt.case.latest_calls + 1
        error("version-specific installer must never look up latest")
    end,
    fetch = function(rt, url)
        local state = rt.case
        state.downloads = state.downloads + 1
        state.download_urls[#state.download_urls + 1] = url
        if state.options.download_error then error("download unavailable") end
        if url:match("/rtx%-dns%.lua$") then return state.body end
        error("unexpected URL")
    end,
}
package.loaded.installer = nil
local installer = require("installer")
package.loaded.installer_sha256, package.loaded.installer_http = saved_sha, saved_http

local function check_output(state, success)
    local seen, total, failed = 0, nil, false
    local enter = "DNSINSTALL Press ENTER to display the router command prompt."
    for _, line in ipairs(state.logs) do
        local current, denominator = line:match("^DNSINSTALL %((%d+)/(%d+)%) ")
        if current then
            check(not failed, "failure/rollback advanced the success counter")
            seen = seen + 1
            equal(tonumber(current), seen, "progress must increase once per displayed message")
            total = total or tonumber(denominator)
            equal(tonumber(denominator), total, "progress denominator changed")
            check(seen <= total, "progress exceeded its total")
        elseif line:match("^DNSINSTALL failed at stage %d+: ") then
            check(not success, "success emitted a failure notice")
            failed = true
        elseif success then
            check(line == "" or line == enter, "unexpected unnumbered success message: " .. line)
        end
        if not success then
            check(not line:find("Installation complete:", 1, true), "failure claimed completion")
            check(not line:find("Press ENTER", 1, true), "failure emitted the success Enter prompt")
        end
    end
    if success then
        local expected = 14 + math.floor(state.release.bytes / 65536)
        equal(total, expected, "progress total must match payload-sized SHA checkpoints")
        equal(seen, expected, "successful output did not finish at its total")
        check(state.logs[#state.logs - 1]:find("Installation complete:", 1, true),
            "completion must be the final numbered line")
        equal(state.logs[#state.logs], enter, "Enter prompt must have no counter")
    else
        check(failed, "failure must have an unnumbered stage notice")
        check(not total or seen < total, "failure falsely reached 100 percent")
    end
end

local function scenario(options)
    options = options or {}
    local state = {
        options = options, files = { [installer_path] = "-- installer" },
        release = options.release or release(options.version),
        body = options.body or (options.version == "v0.9.9" and preview_body or new_body),
        commands = {}, logs = {}, sleeps = {}, schedules = {},
        running = options.running == true, starts = 0, stops = 0, saves = 0, downloads = 0,
        directory_exists = not options.missing_directory, directory_calls = 0,
        latest_calls = 0, download_urls = {},
        writes = 0, writes_by_path = {}, removes_by_path = {}, renames = 0, status_calls = 0, config_reads = 0,
        loaded_body = options.running and old_body or nil,
    }
    if options.old then state.files[target] = options.same_version and state.body or old_body end
    if options.memory_bootstrap and not options.keep_installer then state.files[installer_path] = nil end
    if options.leftover then state.files[options.leftover] = "previous interrupted install" end
    for id, suffix in pairs(options.schedules or {}) do state.schedules[id] = suffix end
    local function config()
        local lines, ids = { "dns service recursive", "dns host lan1" }, {}
        for id in pairs(state.schedules) do ids[#ids + 1] = id end
        table.sort(ids)
        for _, id in ipairs(ids) do lines[#lines + 1] = "schedule at " .. id .. " " .. state.schedules[id] end
        return table.concat(lines, "\r\n") .. "\r\n"
    end
    state.config = config
    local rt = { case = state }
    function rt.sleep(seconds) state.sleeps[#state.sleeps + 1] = seconds end
    function rt.command(command)
        state.commands[#state.commands + 1] = command
        if command == "show status lua running" then
            state.status_calls = state.status_calls + 1
            local boot = "Command line: lua -e 'local DNSINSTALL_BOOT=\"yes\";local f=1'"
            local lines = { options.bootstrap and boot or ("Lua script file: " .. installer_path) }
            if state.running then lines[#lines + 1] = "Lua script file: " .. target end
            if options.extra_task then lines[#lines + 1] = "Lua script file: " .. options.extra_task end
            for _ = 1, options.extra_boots or 0 do lines[#lines + 1] = boot end
            if options.late_extra_boot == state.status_calls then lines[#lines + 1] = boot end
            if options.late_extra_dns == state.status_calls then lines[#lines + 1] = "Lua script file: " .. target end
            return true, table.concat(lines, "\r\n")
        elseif command == "show config" then
            state.config_reads = state.config_reads + 1
            local output = config()
            if options.config_header then output = "# TIME: " .. state.config_reads .. "\r\n" .. output end
            if options.config_change_at == state.config_reads then output = output .. "dns server 192.0.2.1\r\n" end
            return true, output
        elseif command == "show config 0" then return true, state.saved_config or config()
        elseif command == "make directory /lua" then
            state.directory_calls = state.directory_calls + 1
            if state.directory_exists then return false, "already exists" end
            if options.mkdir_failure then return false, "storage unavailable" end
            state.directory_exists = true
        elseif command == "terminate lua file " .. target then
            state.stops = state.stops + 1
            state.running = false
            state.loaded_body = nil
        elseif command == "lua " .. target then
            state.starts = state.starts + 1
            state.running = not (options.new_start_failure and state.files[target] == state.body)
            state.loaded_body = state.running and state.files[target] or nil
        elseif command == "save" then
            if options.save_failure then return false, "save failed" end
            state.saves = state.saves + 1
            state.saved_config = config()
        else
            local id, suffix = command:match("^schedule at (%d+) (.+)$")
            local deleted = command:match("^no schedule at (%d+)$")
            if id then
                state.schedules[tonumber(id)] = suffix
                if options.schedule_false_replace then
                    state.schedules[tonumber(id)] = "daily * echo concurrent-user-change"
                    return false, "concurrent schedule change"
                end
                if options.schedule_false then return false, "response lost after schedule was applied" end
            elseif deleted then state.schedules[tonumber(deleted)] = nil
            else error("unexpected router command: " .. command) end
        end
        -- Yamaha documents successful commands with no output as true, nil.
        return true, nil
    end
    local fs = {}
    function fs.open(path, mode)
        if mode == "rb" then
            if state.files[path] == nil then return nil, "not found" end
            return { read = function() return state.files[path] end, close = function() return true end }
        end
        equal(mode, "wb")
        if not state.directory_exists then return nil, "directory unavailable" end
        state.writes = state.writes + 1
        state.writes_by_path[path] = (state.writes_by_path[path] or 0) + 1
        if options.write_failure == path then return nil, "storage full" end
        state.files[path] = ""
        local file = {}
        function file:write(data) state.files[path] = state.files[path] .. data; return self end
        function file:close() return true end
        return file
    end
    local system = {}
    function system.remove(path)
        if options.remove_failure == path then return nil, "remove failed" end
        state.removes_by_path[path] = (state.removes_by_path[path] or 0) + 1
        state.files[path] = nil
        return true
    end
    function system.rename(from, to)
        if options.rename_failure then return nil, "rename failed" end
        state.renames = state.renames + 1
        check(state.files[from] ~= nil, "renamed a missing file")
        state.files[to], state.files[from] = state.files[from], nil
        return true
    end
    state.env = {
        io = fs, os = system,
        memory_bootstrap = options.memory_bootstrap,
        compile = function(body)
            equal(body, state.body)
            if options.syntax_failure then return nil, "bad syntax" end
            return function() end
        end,
        print = function(message) state.logs[#state.logs + 1] = message end,
    }
    function state.run(mode)
        active = state
        local metadata = state.release
        if options.missing_release then metadata = nil end
        -- Yamaha's integer Lua does not provide math.floor. Keep the host-only
        -- helper out of the runtime even when exercising failure/rollback paths.
        local saved_floor = math.floor
        math.floor = nil
        local returned, ok, err = pcall(installer.run, rt, mode or "yes", state.env, metadata)
        math.floor = saved_floor
        if not returned then error(ok, 0) end
        equal(state.latest_calls, 0, "installer queried latest")
        check_output(state, ok)
        return ok, err
    end
    return state
end

-- One command-line bootstrap is this installer; a second bootstrap or direct
-- installer must be counted separately even though it has no script-file path.
local boot_status = "Command line: lua -e 'local DNSINSTALL_BOOT=\"yes\"; local f=1'"
equal(installer.installers(boot_status), 1)
equal(installer.installers(boot_status .. "\n" .. boot_status), 2)
equal(installer.installers(boot_status .. "\nLua script file: " .. installer_path), 2)
equal(installer.installers("Command line: lua -e 'print(1)'"), 0)

-- Fresh installation selects the first unused ID and preserves other jobs.
local s = scenario({ schedules = { [1] = "daily * reboot", [3] = "startup * echo unrelated" } })
check(s.run("yes"))
equal(s.files[target], new_body)
check(s.running)
equal(s.schedules[2], "startup * lua " .. target)
equal(s.schedules[1], "daily * reboot")
equal(s.schedules[3], "startup * echo unrelated")
equal(s.saves, 1)
equal(s.files[installer_path], nil)
equal(s.files[backup], nil)
equal(s.files[marker], nil)
equal(s.files[stage], nil)
equal(s.downloads, 1)
equal(s.download_urls[1], s.release.url)

-- The memory entry writes no installer file and creates /lua when needed.
-- It must not remove a pre-existing file owned by a manual installation.
for _, keep_installer in ipairs({false, true}) do
    s = scenario({bootstrap = true, memory_bootstrap = true, keep_installer = keep_installer,
        missing_directory = not keep_installer})
    check(s.run("no"))
    check(s.directory_exists)
    equal(s.directory_calls, 1)
    equal(s.files[installer_path], keep_installer and "-- installer" or nil)
    equal(s.writes_by_path[installer_path], nil)
    equal(s.removes_by_path[installer_path], nil)
    equal(s.files[target], new_body)
    check(s.running)
    equal(s.saves, 0)
end

-- An unusable /lua fails at preparation, before the existing task is stopped.
s = scenario({bootstrap = true, memory_bootstrap = true, old = true, running = true,
    missing_directory = true, mkdir_failure = true})
check(not s.run("no"))
equal(s.directory_calls, 1)
equal(s.files[target], old_body)
check(s.running)
equal(s.stops, 0)
equal(s.starts, 0)

-- A version-specific installer accepts the explicitly selected v0.9.9 body
-- without looking up stable/latest or fetching a separate manifest.
s = scenario({ version = "v0.9.9", old = true, running = true })
check(s.run("no"))
equal(s.files[target], preview_body)
equal(s.loaded_body, preview_body)
equal(s.downloads, 1)
equal(s.download_urls[1], release("v0.9.9").url)
check(table.concat(s.logs, "\n"):find("v0.9.9", 1, true))

-- Embedded metadata is mandatory and must pin both the path's version and a
-- complete commit ID. No network access or filesystem mutation precedes this
-- validation; a mutable branch or a URL for another version is never used.
for _, options in ipairs({
    { missing_release = true },
    { release = {} },
    { release = release(nil, { version = "latest" }) },
    { release = release(nil, { version = "v0.1.4-rc.1" }) },
    { release = release(nil, { sha256 = "short" }) },
    { release = release(nil, { sha256 = string.rep("g", 64) }) },
    { release = release(nil, { bytes = 0 }) },
    { release = release(nil, { bytes = 1024.5 }) },
    { release = release(nil, { bytes = "1224" }) },
    { release = release(nil, { url = release("v0.9.9").url }) },
    { release = release(nil, { url = raw_root .. "main/installer/versions/v0.1.4/rtx-dns.lua" }) },
    { release = release(nil, { url = raw_root .. "latest/installer/versions/v0.1.4/rtx-dns.lua" }) },
    { release = release(nil, { url = raw_root .. string.rep("1", 39) .. "/installer/versions/v0.1.4/rtx-dns.lua" }) },
    { release = release(nil, { url = raw_root .. string.rep("g", 40) .. "/installer/versions/v0.1.4/rtx-dns.lua" }) },
    { release = release(nil, { url = release().url .. "?ref=main" }) },
    { release = release(nil, { url = release().url:gsub("https:", "http:") }) },
    { release = release(nil, { url = release().url:gsub("Yamar50", "another-owner") }) },
}) do
    options.old, options.running = true, true
    s = scenario(options)
    local ok, err = s.run("no")
    check(not ok and type(err) == "string", "invalid embedded release was accepted")
    equal(s.downloads, 0)
    equal(s.directory_calls, 0)
    equal(s.writes, 0)
    equal(s.stops, 0)
    equal(s.starts, 0)
    equal(s.saves, 0)
    equal(s.files[target], old_body)
    check(s.running)
end

-- Swapped or truncated bytes cannot replace a running relay, even when the
-- other payload is an otherwise valid published version of the same size.
for _, options in ipairs({
    { body = new_body .. "\n" },
    { body = new_body:sub(1, -2) },
    { bad_sha = true },
    { body = preview_body },
    { version = "v0.9.9", body = new_body },
    { version = "v0.9.9", release = release("v0.9.9", { sha256 = digest }) },
}) do
    options.old, options.running = true, true
    s = scenario(options)
    local ok, err = s.run("no")
    check(not ok and type(err) == "string", "unverified payload was accepted")
    equal(s.downloads, 1)
    equal(s.directory_calls, 0)
    equal(s.writes, 0)
    equal(s.stops, 0)
    equal(s.starts, 0)
    equal(s.saves, 0)
    equal(s.files[target], old_body)
    check(s.running)
end

-- Upgrade reuses an exact existing startup schedule; no duplicate is added.
s = scenario({ old = true, running = true, schedules = { [100] = "startup * lua " .. target } })
check(s.run("yes"))
equal(s.stops, 1)
equal(s.starts, 1)
equal(s.schedules[1], nil)
equal(s.schedules[100], "startup * lua " .. target)
equal(s.saves, 1)

-- 'no' controls autostart only: existing startup settings remain untouched.
s = scenario({ old = true, running = true, schedules = { [100] = "startup * lua " .. target } })
local before = s.config()
check(s.run("no"))
equal(s.config(), before)
equal(s.saves, 0)
equal(s.files[target], new_body)
check(s.running)
s = scenario({ config_header = true })
check(s.run("no"))
equal(next(s.schedules), nil)
equal(s.saves, 0)

-- The file can contain new bytes while the task still runs older loaded code.
-- Even with identical files, restart once to load verified code/current config;
-- skip rewriting or renaming the active file, but keep transaction recovery data.
for _, mode in ipairs({"yes", "no"}) do
    s = scenario({ old = true, running = true, same_version = true,
        schedules = { [100] = "startup * lua " .. target }, bootstrap = true })
    equal(s.loaded_body, old_body)
    check(s.run(mode))
    equal(s.writes, 2)
    equal(s.writes_by_path[target], nil)
    equal(s.writes_by_path[stage], nil)
    equal(s.writes_by_path[backup], 1)
    equal(s.writes_by_path[marker], 1)
    equal(s.removes_by_path[target], nil)
    equal(s.renames, 0)
    equal(s.stops, 1)
    equal(s.starts, 1)
    equal(s.loaded_body, new_body)
    equal(s.files[target], new_body)
    equal(s.files[installer_path], nil)
    equal(s.schedules[100], "startup * lua " .. target)
    equal(s.saves, mode == "yes" and 1 or 0)
    equal(s.downloads, 1)
end

-- Both invocation modes and all three file states have the same number of
-- progress messages. The SHA checkpoint count follows downloaded bytes only,
-- even when hash padding crosses the next callback boundary.
for _, mode in ipairs({"yes", "no"}) do
    for _, file_state in ipairs({"fresh", "update", "same"}) do
        s = scenario({ old = file_state ~= "fresh", running = file_state ~= "fresh",
            same_version = file_state == "same", bootstrap = true, memory_bootstrap = true })
        check(s.run(mode))
        equal(s.files[target], new_body)
        check(s.running)
    end
end
for index, item in ipairs({
    {65463, 0}, {65464, 0}, {65527, 0}, {65528, 0}, {65535, 0}, {65536, 1},
    {131071, 1}, {131072, 2}, {143094, 2}, {151437, 2}, {524288, 8},
}) do
    local bytes, checkpoints = item[1], item[2]
    local body = "--" .. string.rep("x", bytes - 2)
    s = scenario({ body = body, verified_body = body, release = release(nil, {bytes = bytes}),
        old = index % 3 ~= 1, running = index % 3 ~= 1, same_version = index % 3 == 0,
        bootstrap = true, memory_bootstrap = true })
    check(s.run(index % 2 == 0 and "yes" or "no"))
    local actual_checkpoints = 0
    for _, line in ipairs(s.logs) do
        local processed, size = line:match("SHA256 progress: (%d+)/(%d+) bytes")
        if processed then
            actual_checkpoints = actual_checkpoints + 1
            equal(tonumber(processed), actual_checkpoints * 65536)
            equal(tonumber(size), bytes)
            check(tonumber(processed) <= bytes, "hash padding leaked into payload progress")
        end
    end
    equal(actual_checkpoints, checkpoints, "wrong number of SHA progress checkpoints for " .. bytes)
end

-- Errors before activation must never stop or replace a working DNS task.
for _, options in ipairs({
    { bad_sha = true }, { download_error = true }, { syntax_failure = true },
    { leftover = stage }, { leftover = backup }, { leftover = marker },
    { write_failure = stage }, { write_failure = backup }, { write_failure = marker },
    { schedules = { [10] = "daily * lua " .. target } },
    { extra_task = "/lua/nvr-dns.lua" },
    { bootstrap = true, extra_boots = 1 }, { extra_boots = 1 },
    { bootstrap = true, late_extra_boot = 2 }, { late_extra_boot = 3 }, { late_extra_dns = 3 },
    { config_change_at = 2 }, { config_change_at = 3 },
}) do
    options.old, options.running = true, true
    s = scenario(options)
    local ok, err = s.run("yes")
    check(not ok and type(err) == "string", "pre-activation failure was accepted")
    equal(s.files[target], old_body)
    check(s.running)
    equal(s.stops, 0)
    equal(s.starts, 0)
    equal(s.saves, 0)
    check(s.files[installer_path] ~= nil)
end

-- If someone replaces the newly selected schedule before a failed command's
-- rollback, the installer must not remove that now-unrelated user setting.
s = scenario({ old = true, running = true, schedule_false_replace = true })
check(not s.run("yes"))
equal(s.files[target], old_body)
check(s.running)
equal(s.schedules[1], "daily * echo concurrent-user-change")
equal(s.saves, 0)

-- A false command result after schedule mutation must remove only the new
-- startup line. Existing unrelated jobs and previous DNS operation survive.
for _, same_version in ipairs({false, true}) do
    s = scenario({ old = true, running = true, same_version = same_version,
        schedule_false = true, schedules = { [1] = "daily * echo unrelated" } })
    local ok, err = s.run("yes")
    check(not ok and type(err) == "string")
    equal(s.files[target], same_version and new_body or old_body)
    check(s.running)
    equal(s.schedules[1], "daily * echo unrelated")
    equal(s.schedules[2], nil)
    equal(s.saves, 0)
    if same_version then
        equal(s.starts, 2)
        equal(s.stops, 2)
        equal(s.writes_by_path[target], nil)
        equal(s.removes_by_path[target], nil)
        equal(s.loaded_body, new_body)
    end
end

-- Failure to activate/start the verified update restores both previous file
-- and previous running state, rather than accidentally starting a stopped task.
for _, options in ipairs({
    { new_start_failure = true, old = true, running = true },
    { new_start_failure = true, old = true, running = false },
    { new_start_failure = true, old = false, running = false },
    { rename_failure = true, old = true, running = true },
}) do
    s = scenario(options)
    local ok, err = s.run("yes")
    check(not ok and type(err) == "string")
    equal(s.files[target], options.old and old_body or nil)
    equal(s.running, options.running)
    equal(s.files[backup], nil)
    equal(s.files[marker], nil)
    equal(s.files[stage], nil)
    equal(s.schedules[1], nil)
    equal(s.saves, 0)
    check(s.files[installer_path] ~= nil)
end

-- A failed save response may follow a durable save. Keep the new working file
-- until an operator can confirm persistence instead of leaving a boot entry
-- pointing at a rolled-back or removed file.
s = scenario({ old = true, running = true, save_failure = true })
local saved_ok, saved_err = s.run("yes")
check(not saved_ok and type(saved_err) == "string")
equal(s.files[target], new_body)
check(s.running)
equal(s.schedules[1], "startup * lua " .. target)
equal(s.files[backup], old_body)
check(s.files[marker] ~= nil)
check(s.files[installer_path] ~= nil)

-- Once save has succeeded, a cleanup failure must retain the verified version
-- and persisted startup schedule rather than rolling back only the file.
s = scenario({ old = true, running = true, remove_failure = backup })
local ok, err = s.run("yes")
check(not ok and type(err) == "string")
equal(s.files[target], new_body)
check(s.running)
equal(s.saves, 1)
equal(s.schedules[1], "startup * lua " .. target)
equal(s.files[backup], old_body)
check(s.files[installer_path] ~= nil)

-- No mode default: invalid invocation must have no network or task effects.
s = scenario({ old = true, running = true })
check(not s.run("maybe"))
equal(s.downloads, 0)
equal(s.stops, 0)
equal(s.files[target], old_body)
print("installer transaction: " .. count .. " assertions passed")
