--- Preset Gallery: fetch remote index + preset files over HTTPS.
-- Online-only by design: results live in the modal's in-memory state,
-- nothing is persisted to disk. Keeps the mental model simple — gallery
-- == current state of the upstream repo.

local Gallery = {}

local INDEX_URL = "https://raw.githubusercontent.com/AndyHazz/bookends-presets/main/index.json"
local BASE_URL  = "https://raw.githubusercontent.com/AndyHazz/bookends-presets/main/"
local SUBMIT_URL = "https://bookends-submit.andy-nmc.workers.dev/submit"
local INSTALL_URL = "https://bookends-submit.andy-nmc.workers.dev/install"
local COUNTS_URL  = "https://bookends-submit.andy-nmc.workers.dev/counts"

local function httpGet(url, user_agent)
    local ok_require, http, ltn12, socket, socketutil = pcall(function()
        return require("socket/http"), require("ltn12"), require("socket"), require("socketutil")
    end)
    if ok_require then
        local body = {}
        local ok_req, code = pcall(function()
            socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
            local c = socket.skip(1, http.request({
                url = url,
                method = "GET",
                headers = { ["User-Agent"] = user_agent },
                sink = ltn12.sink.table(body),
                redirect = true,
            }))
            socketutil:reset_timeout()
            return c
        end)
        if ok_req and code == 200 then return table.concat(body) end
        pcall(function() socketutil:reset_timeout() end)
    end
    -- curl fallback
    local handle = io.popen(string.format("curl -s -L -H 'User-Agent: %s' %q", user_agent, url))
    if handle then
        local body = handle:read("*a")
        handle:close()
        if body and body ~= "" then return body end
    end
    return nil
end

--- HTTP POST JSON body, return decoded JSON or nil+err. LuaSocket first, curl fallback.
local function httpPostJson(url, body_str, user_agent)
    local ok_require, http, ltn12, socket, socketutil = pcall(function()
        return require("socket/http"), require("ltn12"), require("socket"), require("socketutil")
    end)
    if ok_require then
        local resp = {}
        local ok_req, code = pcall(function()
            socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
            local c = socket.skip(1, http.request({
                url = url,
                method = "POST",
                headers = {
                    ["User-Agent"] = user_agent,
                    ["Content-Type"] = "application/json",
                    ["Content-Length"] = tostring(#body_str),
                },
                source = ltn12.source.string(body_str),
                sink = ltn12.sink.table(resp),
                redirect = true,
            }))
            socketutil:reset_timeout()
            return c
        end)
        if ok_req and code then
            local body = table.concat(resp)
            return body, code
        end
        pcall(function() socketutil:reset_timeout() end)
    end
    -- curl fallback (preserves status code via -w)
    local tmp = os.tmpname()
    local f = io.open(tmp, "w"); if not f then return nil end
    f:write(body_str); f:close()
    local cmd = string.format(
        "curl -s -w '\\n__STATUS__%%{http_code}' -L -X POST -H 'User-Agent: %s' -H 'Content-Type: application/json' --data-binary @%q %q",
        user_agent, tmp, url)
    local handle = io.popen(cmd)
    os.remove(tmp)
    if not handle then return nil end
    local raw = handle:read("*a"); handle:close()
    if not raw or raw == "" then return nil end
    local status = raw:match("__STATUS__(%d+)$") or "0"
    local body = raw:gsub("\n__STATUS__%d+$", "")
    return body, tonumber(status)
end

function Gallery.isOnline()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok or not NetworkMgr then return false end
    return NetworkMgr:isWifiOn() and NetworkMgr:isConnected()
end

--- Submit a preset to the community gallery (opens a PR via the Worker).
-- @param submission { slug, name, author, description, preset_lua }
-- @param user_agent string
-- @param callback function(result, err) — result = { pr_url = "...", pr_number = N }
function Gallery.submitPreset(submission, user_agent, callback)
    if not Gallery.isOnline() then
        callback(nil, "offline")
        return
    end
    local ok_json, json = pcall(require, "json")
    if not ok_json then callback(nil, "json module missing"); return end
    local body_str = json.encode(submission)
    local resp_body, code = httpPostJson(SUBMIT_URL, body_str, user_agent or "KOReader-Bookends")
    if not resp_body then callback(nil, "network error"); return end
    local ok_decode, decoded = pcall(json.decode, resp_body)
    if not ok_decode or type(decoded) ~= "table" then
        callback(nil, "invalid response from server")
        return
    end
    if code ~= 200 or not decoded.ok then
        callback(nil, decoded.error or ("server returned " .. tostring(code)))
        return
    end
    callback({ pr_url = decoded.pr_url, pr_number = decoded.pr_number }, nil)
end

function Gallery.fetchIndex(user_agent, callback)
    if not Gallery.isOnline() then
        callback(nil, "offline")
        return
    end
    -- No cache-buster: raw.githubusercontent.com sets Cache-Control: max-age=300,
    -- and we accept up-to-5-min staleness in exchange for ~100 ms edge-cached
    -- responses (vs ~1 s origin). The gallery changes a few times a week, so the
    -- staleness window is invisible. The original buster supported a Refresh
    -- button that's since been removed.
    local body = httpGet(INDEX_URL, user_agent or "KOReader-Bookends")
    if not body then
        callback(nil, "fetch failed")
        return
    end
    local ok_req, json = pcall(require, "json")
    if not ok_req then callback(nil, "json module missing"); return end
    local ok, data = pcall(json.decode, body)
    if not ok or type(data) ~= "table" or type(data.presets) ~= "table" then
        callback(nil, "invalid index")
        return
    end
    callback(data, nil)
end

--- Fire-and-forget install ping. Shells out to a detached background curl so
-- the UI never waits on the network (LuaSocket is synchronous on the main
-- thread; we don't want the modal close to stall for a few hundred ms).
-- All errors are silently swallowed — popularity tracking must NEVER block
-- or surface to the user.
function Gallery.recordInstall(slug, user_agent)
    -- Re-validate the slug locally: it ends up in a shell command string and
    -- the worker's regex is our backstop, not our front door. Belt-and-braces.
    if type(slug) ~= "string" or not slug:match("^[a-z0-9-]+$") or #slug > 64 then
        return
    end
    if not Gallery.isOnline() then return end
    local ua = (user_agent or "KOReader-Bookends"):gsub("'", "")
    -- Backgrounded via `&` inside a subshell, stdio redirected to /dev/null,
    -- so the io.popen handle unblocks as soon as the shell has forked curl.
    -- -m 10 caps the ping so runaway curls can't pile up.
    local cmd = string.format(
        "(curl -s -m 10 -X POST -H 'User-Agent: %s' -H 'Content-Type: application/json' --data '{\"slug\":\"%s\"}' %q) >/dev/null 2>&1 &",
        ua, slug, INSTALL_URL)
    local ok, handle = pcall(io.popen, cmd)
    if ok and handle then pcall(handle.close, handle) end
end

--- GET /counts → { slug = count, ... }. Edge-cached 60 s server-side; we
-- pass no cache-buster so chip-tap fetches actually hit that edge cache (a
-- per-tap unique ?ts= would defeat it). Called as a secondary fetch after
-- fetchIndex; failure is non-fatal, the UI just hides the Popular sort
-- until the next gallery refresh succeeds.
function Gallery.fetchCounts(user_agent, callback)
    if not Gallery.isOnline() then
        callback(nil, "offline")
        return
    end
    local body = httpGet(COUNTS_URL, user_agent or "KOReader-Bookends")
    if not body then
        callback(nil, "fetch failed")
        return
    end
    local ok_req, json = pcall(require, "json")
    if not ok_req then callback(nil, "json module missing"); return end
    local ok, data = pcall(json.decode, body)
    if not ok or type(data) ~= "table" or type(data.counts) ~= "table" then
        callback(nil, "invalid response")
        return
    end
    callback(data.counts, nil)
end

--- Repo-relative path to a preset file, from the index entry's own preset_url
--- when it has one, else derived from the slug.
---
--- The generator always writes `presets/<slug>.lua`, so the field is pure
--- redundancy — about 7 KB of the index at 170 presets. It can't simply be
--- dropped upstream, because released plugin versions read it straight out of
--- the index and would break. Deriving it here means a future index can omit it
--- safely once this has shipped and aged in; until then a present field still
--- wins, so a hand-edited index with a non-standard path keeps working.
---
--- Returns nil for a slug that couldn't form a safe path (it lands in a URL).
function Gallery.presetPath(slug, preset_url)
    if type(preset_url) == "string" and preset_url ~= "" then
        return preset_url
    end
    if type(slug) ~= "string" or not slug:match("^[a-z0-9-]+$") or #slug > 64 then
        return nil
    end
    return "presets/" .. slug .. ".lua"
end

function Gallery.downloadPreset(slug, preset_url, user_agent, callback)
    if not Gallery.isOnline() then
        callback(nil, "offline")
        return
    end
    local path = Gallery.presetPath(slug, preset_url)
    if not path then
        callback(nil, "bad preset reference")
        return
    end
    local body = httpGet(BASE_URL .. path, user_agent or "KOReader-Bookends")
    if not body then callback(nil, "fetch failed"); return end
    local fn, err = loadstring(body)
    if not fn then callback(nil, "parse error: " .. tostring(err)); return end
    setfenv(fn, {})
    local ok, preset = pcall(fn)
    if not ok or type(preset) ~= "table" then
        callback(nil, "runtime error")
        return
    end
    callback(preset, nil)
end

return Gallery
