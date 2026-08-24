local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("bookends_i18n").gettext

local Updater = {}

-- Background check state (session-only, not persisted)
local _cached_version = nil   -- latest available version string, or nil
local _cached_zip_url = nil   -- download URL for the latest release ZIP
local _last_check_time = nil  -- os.time() of last successful or attempted check
local _check_in_flight = false
local CHECK_INTERVAL = 3600   -- 1 hour

function Updater.getInstalledVersion()
    local DataStorage = require("datastorage")
    local meta_path = DataStorage:getDataDir() .. "/plugins/bookends.koplugin/_meta.lua"
    local ok_meta, meta = pcall(dofile, meta_path)
    return (ok_meta and meta and meta.version) or "unknown"
end

local function parseVersion(v)
    local parts = {}
    for part in tostring(v):gsub("^v", ""):gmatch("([^.]+)") do
        table.insert(parts, tonumber(part) or 0)
    end
    return parts
end

local function isNewer(v1, v2)
    local a, b = parseVersion(v1), parseVersion(v2)
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x > y then return true end
        if x < y then return false end
    end
    return false
end

--- Compose the GitHub branch-archive URL for a given branch name.
-- Branch path is URL-encoded except for alnum, dash, underscore, dot, tilde
-- and forward slash (so feature/foo keeps its slash).
function Updater.composeBranchUrl(branch)
    local encoded = branch:gsub("[^%w%-_/.~]", function(c)
        return string.format("%%%02X", c:byte())
    end)
    return string.format(
        "https://github.com/AndyHazz/bookends.koplugin/archive/refs/heads/%s.zip",
        encoded)
end

--- Try LuaSocket first, fall back to curl for platforms where SSL crashes.
local function httpGetJSON(url, user_agent)
    local json = require("json")
    local ok_require, http, ltn12, socket, socketutil =
        pcall(function()
            return require("socket/http"),
                   require("ltn12"),
                   require("socket"),
                   require("socketutil")
        end)
    if ok_require then
        local body = {}
        local ok_req, code = pcall(function()
            socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
            local c = socket.skip(1, http.request({
                url = url,
                method = "GET",
                headers = {
                    ["User-Agent"] = user_agent,
                    ["Accept"] = "application/vnd.github.v3+json",
                },
                sink = ltn12.sink.table(body),
                redirect = true,
            }))
            socketutil:reset_timeout()
            return c
        end)
        if ok_req and code == 200 then
            local ok, data = pcall(json.decode, table.concat(body))
            if ok then return data end
        end
        pcall(function() socketutil:reset_timeout() end)
    end
    -- Fallback: curl (available on Android, desktop)
    local handle = io.popen(string.format(
        "curl -s -L -H 'User-Agent: KOReader-Bookends' -H 'Accept: application/vnd.github.v3+json' %q",
        url))
    if handle then
        local body = handle:read("*a")
        handle:close()
        if body and body ~= "" then
            local ok, data = pcall(json.decode, body)
            if ok then return data end
        end
    end
    return nil
end

function Updater.offerReleasesPage(message)
    local url = "https://github.com/AndyHazz/bookends.koplugin/releases"
    if Device:canOpenLink() then
        UIManager:show(ConfirmBox:new{
            text = message .. "\n\n" .. _("Open the releases page in a browser?"),
            ok_text = _("Open"),
            ok_callback = function()
                Device:openLink(url)
            end,
        })
    else
        UIManager:show(InfoMessage:new{
            text = message,
            timeout = 3,
        })
    end
end

-- Unpack a downloaded .zip into `dest`, stripping the archive's single
-- top-level directory (release and GitHub branch zips wrap everything in
-- bookends.koplugin/ or bookends.koplugin-<branch>/).
--
-- Extract via the core ffi/archiver (libarchive), the API KOReader itself uses
-- for its dictionary downloader and archive viewer. This used to call
-- Device:unpackArchive, which was only ever a thin wrapper around this same
-- Reader; KOReader dropped the wrapper mid-2026 and the call started failing
-- with "attempt to call method 'unpackArchive' (a nil value)", taking the whole
-- reader down mid-update. Confirmed gone in v2026.07.2. Calling ffi/archiver
-- directly works everywhere the wrapper did, since the wrapper depended on it,
-- and keeps working now it's gone.
--
-- libarchive's write-to-disk auto-creates parent directories, so extracting
-- each entry to its stripped path is sufficient. A missing extractor degrades
-- to a clean error string -- the caller then offers the releases page -- rather
-- than crashing, which is the failure mode that made this so unpleasant: the
-- update path is also the recovery path, so a crash here leaves users unable
-- to update to the fix.
--
-- Ported from bookshelf, which hit this first (its 78ec21c). The updater
-- originally went bookends -> bookshelf, so the fix had to come back the other
-- way.
local function unpackStripRoot(zip_path, dest)
    local ok_req, Archiver = pcall(require, "ffi/archiver")
    if not (ok_req and Archiver and Archiver.Reader) then
        return false, "archive extractor unavailable"
    end
    local arc = Archiver.Reader:new()
    if not arc:open(zip_path) then
        local e = arc.err
        arc:close()
        return false, e or "could not open archive"
    end
    local extract_err
    for entry in arc:iterate() do
        local rel = entry.path and entry.path:match("^[^/]+/(.+)$")
        if rel and rel ~= "" then
            if not arc:extractToPath(entry.path, dest .. "/" .. rel) then
                extract_err = arc.err or "extract failed"
                break
            end
        end
    end
    arc:close()
    if extract_err then return false, extract_err end
    return true
end

-- Test hook: the strip-root logic is pure once ffi/archiver is stubbed, and
-- install() is too entangled with the network to exercise it any other way
-- off-device.
Updater._unpackStripRoot = unpackStripRoot

--- Return the available update version and zip URL, or nil if none/not checked.
function Updater.getAvailableUpdate()
    return _cached_version, _cached_zip_url
end

--- Shared Wi-Fi gate for the user-initiated network paths (#77, #101).
--
-- Gate on isConnected, NOT isOnline. Despite the name, NetworkMgr:isOnline()
-- is canResolveHostnames() - a DNS lookup of Microsoft's dns.msftncsi.com
-- (manager.lua:348). Plenty of working connections fail it: a Pi-hole or
-- AdGuard blocking Microsoft telemetry domains, a captive portal, networks
-- where that host is unreachable, or simply a resolver that hasn't come back up
-- in the seconds after a wake. On any of those, gating on isOnline asks the
-- user to "turn on Wi-Fi" that is already on and connected (#101) - and
-- runWhenOnline then makes it worse, because in exactly that
-- connected-but-unresolvable case it shows the prompt and *forfeits* the
-- callback (manager.lua:698), so the action never runs even if they tap
-- "Turn on". runWhenConnected has no such branch: connected means run,
-- otherwise prompt per the user's prefs and run once the radio is up.
--
-- The re-entry is guarded by a second isConnected check rather than trusting
-- the callback: beforeWifiAction fires it once the connection attempt finishes,
-- which is not the same as having succeeded, and re-entering the gate while
-- still disconnected would prompt in a loop.
--
-- @param retry function: re-invokes the caller once a connection exists
-- @return boolean: true if the caller should return and wait, false to proceed
function Updater.gateOnConnection(retry)
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr:isConnected() then return false end
    NetworkMgr:runWhenConnected(function()
        if NetworkMgr:isConnected() then retry() end
    end)
    return true
end

--- Fire a silent background update check if the cache is stale (>1h or never checked).
-- Results available via getAvailableUpdate().
-- @param on_update_found function(version): optional callback when a new version is discovered
function Updater.checkBackground(on_update_found)
    if _check_in_flight then return end
    local now = os.time()
    if _last_check_time and (now - _last_check_time) < CHECK_INTERVAL then return end

    local NetworkMgr = require("ui/network/manager")
    if not NetworkMgr:isWifiOn() then return end

    _check_in_flight = true
    _last_check_time = now

    UIManager:scheduleIn(0.1, function()
        local installed_version = Updater.getInstalledVersion()
        local user_agent = "KOReader-Bookends/" .. installed_version

        -- Only fetch the latest release (lightweight)
        local release = httpGetJSON(
            "https://api.github.com/repos/AndyHazz/bookends.koplugin/releases/latest",
            user_agent)

        _check_in_flight = false

        if not release or not release.tag_name then return end
        if release.draft or release.prerelease then return end

        local ver = release.tag_name:gsub("^v", "")
        if isNewer(ver, installed_version) then
            _cached_version = ver
            _cached_zip_url = nil
            if release.assets then
                for _, asset in ipairs(release.assets) do
                    if asset.name:match("%.zip$") then
                        _cached_zip_url = asset.browser_download_url
                        break
                    end
                end
            end
            if on_update_found then
                on_update_found(ver)
            end
        else
            _cached_version = nil
            _cached_zip_url = nil
        end
    end)
end

function Updater.check(on_success)

    local installed_version = Updater.getInstalledVersion()

    -- Wi-Fi gate (parity with bookshelf #77): if Wi-Fi is off, bring it up
    -- (prompting per the user's KOReader prefs) and re-run once connected; if
    -- the user cancels, nothing happens. See Updater.gateOnConnection.
    if Updater.gateOnConnection(function() Updater.check(on_success) end) then
        return
    end

    UIManager:show(InfoMessage:new{
        text = _("Checking for updates..."),
        timeout = 1,
    })

    UIManager:scheduleIn(0.1, function()
        local user_agent = "KOReader-Bookends/" .. installed_version

        -- Fetch all releases to gather notes between installed and latest
        local releases = httpGetJSON(
            "https://api.github.com/repos/AndyHazz/bookends.koplugin/releases",
            user_agent)
        if not releases or #releases == 0 then
            Updater.offerReleasesPage(_("Could not check for updates."))
            return
        end

        -- Collect releases newer than installed version
        local new_releases = {}
        local latest_zip_url
        for _, rel in ipairs(releases) do
            if rel.draft or rel.prerelease then goto continue end
            local ver = rel.tag_name:gsub("^v", "")
            if isNewer(ver, installed_version) then
                table.insert(new_releases, rel)
                -- Find ZIP asset from the newest release
                if not latest_zip_url and rel.assets then
                    for _, asset in ipairs(rel.assets) do
                        if asset.name:match("%.zip$") then
                            latest_zip_url = asset.browser_download_url
                            break
                        end
                    end
                end
            end
            ::continue::
        end

        -- Update the background cache too
        _last_check_time = os.time()
        if #new_releases > 0 then
            _cached_version = new_releases[1].tag_name:gsub("^v", "")
            _cached_zip_url = latest_zip_url
        else
            _cached_version = nil
            _cached_zip_url = nil
        end

        if #new_releases == 0 then
            UIManager:show(InfoMessage:new{
                text = _("Bookends is up to date.") .. "\n\n" ..
                    _("Version: ") .. "v" .. installed_version,
                timeout = 3,
            })
            return
        end

        -- Build combined release notes (newest first)
        local latest_version = new_releases[1].tag_name:gsub("^v", "")
        local function stripMarkdown(text)
            text = text:gsub("#+%s*", "")        -- strip heading markers
            text = text:gsub("%*%*(.-)%*%*", "%1") -- strip bold
            text = text:gsub("%*(.-)%*", "%1")     -- strip italic
            text = text:gsub("`(.-)`", "%1")       -- strip inline code
            return text
        end
        local notes = {}
        for _, rel in ipairs(new_releases) do
            local header = "v" .. rel.tag_name:gsub("^v", "")
            local body = stripMarkdown(rel.body or "")
            table.insert(notes, header .. "\n" .. body)
        end
        local all_notes = table.concat(notes, "\n\n")

        local TextViewer = require("ui/widget/textviewer")
        local viewer
        local buttons = {
            {
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(viewer)
                    end,
                },
                {
                    text = _("Update and restart"),
                    callback = function()
                        UIManager:close(viewer)
                        if not latest_zip_url then
                            UIManager:show(InfoMessage:new{
                                text = _("No download available for this release."),
                                timeout = 3,
                            })
                            return
                        end
                        Updater.install(latest_zip_url, installed_version, latest_version, on_success)
                    end,
                },
            },
        }
        viewer = TextViewer:new{
            title = _("Update available!"),
            text = _("Installed: ") .. "v" .. installed_version .. "\n" ..
                _("Latest: ") .. "v" .. latest_version .. "\n\n" ..
                all_notes,
            buttons_table = buttons,
            add_default_buttons = false,
        }
        UIManager:show(viewer)
    end)
end

function Updater.install(zip_url, old_version, new_version, on_success, error_label)

    -- Single Wi-Fi gate for every install path (release, branch, latest-stable):
    -- bring Wi-Fi up if off and re-run once connected; cancel = no-op (#77).
    if Updater.gateOnConnection(function()
        Updater.install(zip_url, old_version, new_version, on_success, error_label)
    end) then
        return
    end

    local DataStorage = require("datastorage")
    local lfs = require("libs/libkoreader-lfs")

    UIManager:show(InfoMessage:new{
        text = _("Downloading update..."),
        timeout = 1,
    })

    UIManager:scheduleIn(0.1, function()
        -- Download ZIP to temp location
        local cache_dir = DataStorage:getSettingsDir() .. "/bookends_cache"
        if lfs.attributes(cache_dir, "mode") ~= "directory" then
            lfs.mkdir(cache_dir)
        end
        local zip_path = cache_dir .. "/bookends.koplugin.zip"

        -- Try LuaSocket first, fall back to curl
        local downloaded = false
        local ok_require, http, ltn12, socket, socketutil =
            pcall(function()
                return require("socket/http"),
                       require("ltn12"),
                       require("socket"),
                       require("socketutil")
            end)
        if ok_require then
            local file = io.open(zip_path, "wb")
            if file then
                local ok_dl, code = pcall(function()
                    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
                    local c = socket.skip(1, http.request({
                        url = zip_url,
                        method = "GET",
                        headers = {
                            ["User-Agent"] = "KOReader-Bookends/" .. old_version,
                        },
                        sink = ltn12.sink.file(file),
                        redirect = true,
                    }))
                    socketutil:reset_timeout()
                    return c
                end)
                if not ok_dl then
                    pcall(function() socketutil:reset_timeout() end)
                end
                downloaded = ok_dl and code == 200
            end
        end
        -- Fallback: curl (available on Android, desktop). The -f flag makes
        -- curl exit non-zero on HTTP errors (e.g. 404 for a missing branch);
        -- without it, curl would write the 404 HTML body to the zip file and
        -- the unpack step would surface a misleading "extracting failed".
        if not downloaded then
            pcall(os.remove, zip_path)
            local ret = os.execute(string.format(
                "curl -sfL -o %q %q", zip_path, zip_url))
            downloaded = ret == 0 or ret == true
        end
        if not downloaded then
            pcall(os.remove, zip_path)
            if error_label then
                UIManager:show(InfoMessage:new{
                    text = error_label,
                    timeout = 3,
                })
            else
                Updater.offerReleasesPage(_("Download failed."))
            end
            return
        end

        -- Extract to plugin directory (strip root folder from ZIP)
        local plugin_path = DataStorage:getDataDir() .. "/plugins/bookends.koplugin"
        local ok, err = unpackStripRoot(zip_path, plugin_path)
        pcall(os.remove, zip_path)

        if not ok then
            UIManager:show(InfoMessage:new{
                text = error_label or (_("Installation failed: ") .. tostring(err)),
                timeout = 5,
            })
            return
        end

        -- Stamp install context (e.g. last_install_source) before the restart
        -- prompt fires; runs only when unpack succeeded.
        if on_success then
            local ok_cb = pcall(on_success)
            if not ok_cb then
                -- Don't let a misbehaving callback abort the restart prompt.
            end
        end

        -- Restart KOReader to load the new version
        UIManager:show(ConfirmBox:new{
            text = _("Bookends updated to v") .. new_version .. ".\n\n" ..
                _("Restart KOReader now?"),
            ok_text = _("Restart"),
            ok_callback = function()
                UIManager:restartKOReader()
            end,
        })
    end)
end

--- Install from a GitHub branch's archive zip.
-- Same install pipeline as the release path; just composes a different URL.
-- @param branch string: branch name (e.g. "feature/v5.2-test")
-- @param on_success function or nil: fired after successful unpack
function Updater.installBranch(branch, on_success)
    -- Wi-Fi is handled by Updater.install's connection gate.
    local installed_version = Updater.getInstalledVersion()
    local zip_url = Updater.composeBranchUrl(branch)
    local error_label = _("Could not install branch:") .. " " .. branch
    Updater.install(zip_url, installed_version, "branch:" .. branch, on_success, error_label)
end

--- Install the latest stable (non-prerelease) release, regardless of installed version.
-- Used by the "Reset to latest stable release" entry: even when on a branch whose
-- _meta.lua reports a higher version than the current release, we still want to
-- pull the release zip and re-stamp last_install_source = "release".
-- @param on_success function or nil: fired after successful unpack
function Updater.installLatestStable(on_success)
    -- Wi-Fi gate (bookshelf #77); this path does its own release fetch before
    -- delegating to Updater.install.
    if Updater.gateOnConnection(function() Updater.installLatestStable(on_success) end) then
        return
    end

    UIManager:show(InfoMessage:new{
        text = _("Downloading latest release..."),
        timeout = 1,
    })

    UIManager:scheduleIn(0.1, function()
        local installed_version = Updater.getInstalledVersion()
        local user_agent = "KOReader-Bookends/" .. installed_version
        local release = httpGetJSON(
            "https://api.github.com/repos/AndyHazz/bookends.koplugin/releases/latest",
            user_agent)
        if not release or not release.tag_name or release.draft or release.prerelease then
            Updater.offerReleasesPage(_("Could not fetch latest release."))
            return
        end
        local zip_url
        if release.assets then
            for _, asset in ipairs(release.assets) do
                if asset.name:match("%.zip$") then
                    zip_url = asset.browser_download_url
                    break
                end
            end
        end
        if not zip_url then
            Updater.offerReleasesPage(_("Latest release has no downloadable zip."))
            return
        end
        local new_version = release.tag_name:gsub("^v", "")
        Updater.install(zip_url, installed_version, new_version, on_success)
    end)
end

return Updater
