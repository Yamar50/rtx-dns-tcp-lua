-- HTTPS downloads for the installer. Do not include response headers, URLs,
-- cookies, or native error strings in errors: redirects can contain signatures.
local M = {}
local ALLOWED = {
    ["github.com"] = true,
    ["raw.githubusercontent.com"] = true,
    ["release-assets.githubusercontent.com"] = true,
    ["objects.githubusercontent.com"] = true,
}
local REDIRECT = { [301] = true, [302] = true, [303] = true, [307] = true, [308] = true }

local function fail(message)
    error("Installer HTTP: " .. message, 0)
end

local function validate_url(url)
    if type(url) ~= "string" or #url == 0 then fail("missing URL") end
    if #url > 2048 then fail("URL exceeds the 2048-character firmware limit") end
    if url:find("[%z\1-\32\127]") or url:find("\\", 1, true) or url:find("#", 1, true) then
        fail("URL contains forbidden characters")
    end
    local host, path = url:match("^https://([^/]+)(/.*)$")
    if not host or not ALLOWED[host] then fail("URL must use HTTPS and an allowed GitHub host") end
    -- An exact authority match above also excludes ports and user information.
    local i = 1
    while true do
        local p = url:find("%", i, true)
        if not p then break end
        local hex = url:sub(p + 1, p + 2)
        if #hex ~= 2 or not hex:match("^%x%x$") then fail("URL contains an invalid percent escape") end
        local value = tonumber(hex, 16)
        if value < 32 or value == 127 then fail("URL contains an encoded control character") end
        i = p + 3
    end
    return host, path
end

local function request(rt, url)
    validate_url(url)
    if type(rt) ~= "table" or type(rt.httprequest) ~= "function" then
        fail("rt.httprequest is unavailable; HTTPS-capable firmware is required")
    end
    -- Yamaha may re-encode URL percent signs. Never try to compensate by
    -- decoding signed queries: spaces can also become '+', changing signatures.
    local ok, response = pcall(rt.httprequest, { url = url, method = "GET", timeout = 30 })
    if not ok or type(response) ~= "table" or response.rtn1 ~= true then
        if #url > 255 then
            fail("request failed; URLs above 255 characters require firmware with 2048-character URL support")
        end
        fail("request failed; check HTTPS support and connectivity")
    end
    local code = response.code
    if type(code) ~= "number" or code % 1 ~= 0 or code < 100 or code > 599 then
        fail("response has an invalid HTTP status")
    end
    return response
end

local function location(header)
    if type(header) ~= "string" then fail("redirect has no Location header") end
    local found, previous_location
    for line in (header .. "\n"):gmatch("([^\n]*)\n") do
        if line:sub(-1) == "\r" then line = line:sub(1, -2) end
        if line:find("\r", 1, true) then fail("redirect has malformed headers") end
        if line:match("^[ \t]") then
            if previous_location then fail("redirect has a folded Location header") end
        else
            local name, value = line:match("^([^:]+):(.*)$")
            previous_location = name and name:lower() == "location"
            if previous_location then
                if found then fail("redirect has duplicate Location headers") end
                found = value:match("^[ \t]*(.-)[ \t]*$")
            end
        end
    end
    if not found or found == "" then fail("redirect has no Location header") end
    validate_url(found)
    return found
end

function M.fetch(rt, url, maxbytes)
    if type(maxbytes) ~= "number" or maxbytes < 1 or maxbytes % 1 ~= 0 then
        fail("invalid download size limit")
    end
    local current, seen, redirects = url, {}, 0
    while true do
        validate_url(current)
        if seen[current] then fail("redirect loop") end
        seen[current] = true
        local response = request(rt, current)
        if REDIRECT[response.code] then
            if redirects >= 5 then fail("too many redirects (maximum 5)") end
            current = location(response.header)
            redirects = redirects + 1
        elseif response.code == 200 then
            if type(response.body) ~= "string" then fail("HTTP 200 response has no body") end
            if #response.body > maxbytes then fail("download exceeds its size limit") end
            return response.body, current
        else
            fail("download returned HTTP " .. response.code)
        end
    end
end

return M
