package.path = "src/?.lua;" .. package.path
local http = require("installer_http")
local count = 0
local REPO = "https://github.com/Yamar50/rtx-dns-tcp-lua"
local RAW = "https://raw.githubusercontent.com/Yamar50/rtx-dns-tcp-lua/abcdef/rtx-dns.lua"
local function equal(actual, expected)
    count = count + 1
    assert(actual == expected, tostring(actual) .. " ~= " .. tostring(expected))
end
local function mock(responses)
    local calls = {}
    return { httprequest = function(options)
        calls[#calls + 1] = options.url
        equal(options.method, "GET")
        equal(options.timeout, 30)
        local response = responses[#calls]
        assert(response, "unexpected extra request")
        if type(response) == "function" then return response(options) end
        return response
    end }, calls
end
local function redirect(url, code)
    return { rtn1 = true, code = code or 302, header = "HTTP/1.1 302 Found\r\nLocation: " .. url .. "\r\n" }
end
local function rejects(fn, message)
    local ok, err = pcall(fn)
    equal(ok, false)
    assert(tostring(err):find(message, 1, true), tostring(err))
    count = count + 1
    return tostring(err)
end

do
    local rt, calls = mock({ { rtn1 = true, code = 200, body = "abcd" } })
    local body, final = http.fetch(rt, RAW, 4)
    equal(body, "abcd")
    equal(final, RAW)
    equal(#calls, 1)
end

-- Only the first latest redirect is requested; neither asset body nor cookies
-- are needed to choose the exact stable release.
do
    local target = REPO .. "/releases/download/v0.9.9/SHA256SUMS"
    local rt, calls = mock({ { rtn1 = true, code = 302, header =
        "HTTP/1.1 302 Found\nlocation:\t" .. target .. " \nSet-Cookie: private\n", body = "ignored" } })
    local version, base = http.latest(rt)
    equal(version, "v0.9.9")
    equal(base, REPO .. "/releases/download/v0.9.9/")
    equal(#calls, 1)
    equal(calls[1], REPO .. "/releases/latest/download/SHA256SUMS")
end
for _, suffix in ipairs({ "v0.9.9-beta/SHA256SUMS", "v0.9.90/SHA256SUMS.extra", "v0.9.9/SHA256SUMS?x=1", "v0.9.9/SHA256SUMS/SHA256SUMS" }) do
    local rt = mock({ redirect(REPO .. "/releases/download/" .. suffix) })
    rejects(function() http.latest(rt) end, "not an exact stable version")
end
do
    local rt = mock({ redirect("https://github.com/other/rtx-dns-tcp-lua/releases/download/v0.9.9/SHA256SUMS") })
    rejects(function() http.latest(rt) end, "expected repository")
    rt = mock({ { rtn1 = true, code = 200, body = "not a release redirect" } })
    rejects(function() http.latest(rt) end, "HTTP 302")
end

-- The allowlist matches authorities exactly, before any network request.
for _, url in ipairs({
    "http://github.com/file", "https://github.com.evil.example/file",
    "https://github.com@evil.example/file", "https://user@github.com/file",
    "https://github.com:443/file", "https://GITHUB.COM/file",
    "https://github.com/file#fragment", "https://github.com/a\\b",
    "https://github.com/white space", "https://github.com/line\nfeed",
    "https://github.com/file%0d%0aInjected", "https://github.com/%00",
    "https://github.com/%", "https://github.com/%GG",
}) do
    local rt, calls = mock({})
    rejects(function() http.fetch(rt, url, 10) end, "Installer HTTP:")
    equal(#calls, 0)
end
do
    local rt, calls = mock({ redirect("http://github.com/file") })
    rejects(function() http.fetch(rt, RAW, 10) end, "HTTPS")
    equal(#calls, 1)
    rt = mock({ redirect(RAW) })
    rejects(function() http.fetch(rt, RAW, 10) end, "redirect loop")
end

-- Five redirects are accepted; a sixth is rejected even without a loop.
do
    local responses = {}
    for i = 1, 5 do responses[i] = redirect(RAW .. "?hop=" .. i, ({301,302,303,307,308})[i]) end
    responses[6] = { rtn1 = true, code = 200, body = "done" }
    local rt, calls = mock(responses)
    equal(http.fetch(rt, RAW, 10), "done")
    equal(#calls, 6)
    responses[6] = redirect(RAW .. "?hop=6")
    rt, calls = mock(responses)
    rejects(function() http.fetch(rt, RAW, 10) end, "too many redirects")
    equal(#calls, 6)
end
for _, header in ipairs({
    "Location: " .. RAW .. "\r\nlocation: " .. RAW .. "\r\n",
    "Location: " .. RAW .. "\r\n continued\r\n",
    "Location: " .. RAW .. "\rInjected: text\n",
    "Location: \r\n", "X-Other: value\r\n",
}) do
    local rt, calls = mock({ { rtn1 = true, code = 302, header = header } })
    rejects(function() http.fetch(rt, RAW, 10) end, "redirect")
    equal(#calls, 1)
end

-- A signed asset URL is preserved and is never retried with altered escapes.
-- None of the native response, request, or headers can leak into an error.
do
    local signed = "https://release-assets.githubusercontent.com/path?sig=PRIVATE%2BA%3D&rscd=attachment%3B%20filename%3Dx"
    local rt, calls = mock({ { rtn1 = true, code = 403, err = signed, header = "Set-Cookie: PRIVATE", body = signed } })
    local err = rejects(function() http.fetch(rt, signed, 20) end, "HTTP 403")
    equal(#calls, 1)
    equal(calls[1], signed)
    equal(err:find("PRIVATE", 1, true), nil)
    rt = mock({ function() error(signed) end })
    err = rejects(function() http.fetch(rt, signed, 20) end, "request failed")
    equal(err:find("PRIVATE", 1, true), nil)
end
do
    local rt = mock({ { rtn1 = false, code = 200, body = "bad" } })
    rejects(function() http.fetch(rt, RAW, 10) end, "request failed")
    rt = mock({ { rtn1 = true, code = 200 } })
    rejects(function() http.fetch(rt, RAW, 10) end, "no body")
    rt = mock({ { rtn1 = true, code = 200, body = "12345" } })
    rejects(function() http.fetch(rt, RAW, 4) end, "size limit")
    rt = mock({ { rtn1 = true, code = "SECRET" } })
    rejects(function() http.fetch(rt, RAW, 10) end, "invalid HTTP status")
    rt = mock({ { rtn1 = false, err = "PRIVATE" } })
    rejects(function() http.fetch(rt, RAW .. "?pad=" .. string.rep("a", 256), 10) end, "2048-character URL support")
    local calls
    rt, calls = mock({})
    rejects(function() http.fetch(rt, RAW .. string.rep("a", 2048), 10) end, "2048-character firmware limit")
    equal(#calls, 0)
    rejects(function() http.fetch({}, RAW, 10) end, "unavailable")
    rejects(function() http.fetch(rt, RAW, 0) end, "size limit")
end
print("installer HTTP: " .. count .. " assertions passed")
