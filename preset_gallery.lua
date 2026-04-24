--- Preset Gallery: fetch remote index + preset files over HTTPS.
-- Online-only by design: Refresh always hits the network, results live in
-- the modal's in-memory state, nothing is persisted to disk. Keeps the
-- mental model simple — gallery == current state of the upstream repo.

local Gallery = {}

local INDEX_URL = "https://raw.githubusercontent.com/AndyHazz/bookends-presets/main/index.json"
local BASE_URL  = "https://raw.githubusercontent.com/AndyHazz/bookends-presets/main/"
local SUBMIT_URL = "https://bookends-submit.andy-nmc.workers.dev/submit"
local INSTALL_URL = "https://bookends-submit.andy-nmc.workers.dev/install"
local COUNTS_URL  = "https://bookends-submit.andy-nmc.workers.dev/counts"
-- GitHub Pulls API — returns open PRs on the presets repo. 100/page is the
-- max without pagination; the gallery's approval queue is never close to
-- that in practice so we trust the first page as the total.
local PRS_URL = "https://api.github.com/repos/AndyHazz/bookends-presets/pulls?state=open&per_page=100"

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
    -- Cache-bust GitHub's CDN (Cache-Control: max-age=300 on raw.githubusercontent.com)
    -- so each Refresh consults origin and sees repo edits immediately.
    local url = INDEX_URL .. "?ts=" .. tostring(os.time())
    local body = httpGet(url, user_agent or "KOReader-Bookends")
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

--- Count open PRs (preset submissions awaiting review) on the presets repo.
-- Only called as a secondary fetch after a user-initiated Refresh — never
-- on its own. Unauthenticated GitHub API is rate-limited to 60/hr per IP,
-- plenty for a refresh-gated call.
function Gallery.fetchApprovalQueueCount(user_agent, callback)
    if not Gallery.isOnline() then
        callback(nil, "offline")
        return
    end
    local url = PRS_URL .. "&ts=" .. tostring(os.time())
    local body = httpGet(url, user_agent or "KOReader-Bookends")
    if not body then
        callback(nil, "fetch failed")
        return
    end
    local ok_req, json = pcall(require, "json")
    if not ok_req then callback(nil, "json module missing"); return end
    local ok, data = pcall(json.decode, body)
    if not ok or type(data) ~= "table" then
        callback(nil, "invalid response")
        return
    end
    callback(#data, nil)
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

--- GET /counts → { slug = count, ... }. Edge-cached 60s server-side so
-- tapping Refresh repeatedly within a minute is cheap. Called as a secondary
-- fetch alongside the approval-queue count; failure is non-fatal, the UI
-- just hides the Popular sort until a refresh succeeds.
function Gallery.fetchCounts(user_agent, callback)
    if not Gallery.isOnline() then
        callback(nil, "offline")
        return
    end
    local body = httpGet(COUNTS_URL .. "?ts=" .. tostring(os.time()),
                         user_agent or "KOReader-Bookends")
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

function Gallery.downloadPreset(slug, preset_url, user_agent, callback)
    if not Gallery.isOnline() then
        callback(nil, "offline")
        return
    end
    local body = httpGet(BASE_URL .. preset_url, user_agent or "KOReader-Bookends")
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
