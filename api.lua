-- Minetest Chat Anti-VPN
-- license: Apache 2.0
--
-- Our namespace.
anti_vpn = {}

-- By default, talk to local testing stub.  For production, you should
-- configure the settings in `minetest.conf`.  See the `README.md` file.
local DEFAULT_URL = 'http://localhost:48888'

-- User agent to transmit with HTTP requests.
local USER_AGENT = 'https://github.com/EdenLostMinetest/anti_vpn'

-- Timeout (seconds) when sending HTTP requests.
local DEFAULT_TIMEOUT = 10

-- How often (seconds) to run the async background tasks.
local ASYNC_WORKER_DELAY = 5

-- Seconds to allow an outstanding request for an external lookup before
-- allowing a repeat of the same.
local GATING_THRESHOLD = 30

-- For testing.  Normally this table should be empty.
-- Map a player name (string) to an IPV4 address (string).
local testdata_player_ip = {}

-- Passed from `init.lua`.  It can only be obtained from there.
local http_api = nil

-- Cache of vpnapi.io lookups, in mod_storage().
-- Key = IP address.
-- Value = table:
--   'vpn' (boolean).
--   'created' (seconds since unix epoch).
local cache = {}

-- List of outstanding IP lookups.  Used to prevent duplicate in-flight lookups.
-- https://github.com/EdenLostMinetest/anti_vpn/issues/1
local inflight_lookups = {}

-- Allow list of players who can bypass anti_vpn checks, in mod_storage().
-- Key = player name, Value = true.
local player_allow_list = {}

-- Storage backing the cache.
local mod_storage = minetest.get_mod_storage()

-- Never expose the APIKEY outside this mod.
local apikey = nil

local vpnapi_url = DEFAULT_URL

local function count_keys(tbl)
    local count = 0
    for k in pairs(tbl) do count = count + 1 end
    return count
end

-- https://www.rfc-editor.org/rfc/rfc1918
local function is_private_ip(ip)
    local PATTERN = '(%d+)%.(%d+)%.(%d+)%.(%d+)'
    local a, b, c, d = string.match(ip, PATTERN)
    if a and b and c and d then
        a, b = tonumber(a), tonumber(b)
        return (a == 10) -- 10.0.0.0/8
        or ((a == 172) and (b >= 16) and (b <= 31)) -- 172.16.0.0/12
        or ((a == 192) and (b == 168)) -- 192.168.0.0/16
        or (a == 127) -- loopback
    end
    return false
end

local function kick_player(pname, ip)
    minetest.kick_player(pname,
                         'Logins from VPNs are not allowed.  Your IP address: ' ..
                             ip)
    minetest.log('warning',
                 '[anti_vpn] kicking player ' .. pname .. ' from ' .. ip)
end

anti_vpn.get_player_ip = function(pname)
    return testdata_player_ip[pname] or minetest.get_player_ip(pname)
end

-- Returns table:
--   [1] (bool) "found" - Was the IP found in the cache?
--   [2] (bool) "blocked" - Should we reject the user from this IP address?
anti_vpn.lookup = function(pname, ip)
    assert(type(pname) == 'string')
    assert(type(ip) == 'string')

    if player_allow_list[pname] then return true, false end

    if is_private_ip(ip) then return true, false end

    if cache[ip] == nil then return false, false end

    return true, cache[ip]['vpn']
end

-- If IP is in cache, do nothing.  If not, queue up a remote lookup.
-- Returns nothing.
local function enqueue_lookup(ip)
    -- Don't bother looking up private/LAN IPs.
    if is_private_ip(ip) then return end

    -- If IP is already cached, then do nothing.
    if cache[ip] ~= nil then return end

    -- If lookup already inflight, then do nothing.
    -- Note that if our lookup fails, we won't know which IP failed, so
    -- we cannot remove IPs for failed entries.  So we capture the time of the
    -- request as well.
    --    if (inflight_lookups[ip] ~= nil) and
    --        ((inflight_lookups[ip] or 0) + GATING_THRESHOLD < os.time()) then
    if (inflight_lookups[ip] ~= nil) then
        minetest.log('warning', '[anti_vpn] gating request for ' .. ip)
        return
    end

    if http_api == nil then
        minetest.log('error', '[anti_vpn] http_api failed to allocate.  Add ' ..
                         minetest.get_current_modname() ..
                         ' to secure.http_mods.')
        return
    end

    inflight_lookups[ip] = os.time()

    -- Queue up an external lookup.  This is async and can take several
    -- seconds, so we don't want to block the server during this time.
    -- We'll allow the login for now, and kick the player later if needed.
    local url = vpnapi_url .. '/api/' .. ip
    minetest.log('action', '[anti_vpn] fetching ' .. url)
    http_api.fetch({
        url = url .. '?key=' .. apikey,
        method = 'GET',
        user_agent = USER_AGENT,
        timeout = DEFAULT_TIMEOUT
    }, function(result)
        if result.succeeded then
            local tbl = minetest.parse_json(result.data)
            if type(tbl) ~= 'table' then
                minetest.log('error', '[anti_vpn] HTTP response is not JSON?')
                minetest.log('error', dump(result))
                return
            end

            if tbl['ip'] == nil then
                minetest.log('error',
                             '[anti_vpn] HTTP response is missing the original IP address.')
                minetest.log('error', dump(result))
                return
            end

            local ip = tbl.ip
            local vpn = false

            -- Expected keys are 'vpn', 'proxy', 'tor', 'relay'.
            -- We'll reject the IP if any are true.
            for k, v in pairs(tbl.security) do vpn = vpn or v end

            cache[ip] = cache[ip] or {}
            cache[ip]['vpn'] = vpn
            cache[ip]['created'] = os.time()

            anti_vpn.flush_mod_storage()
            inflight_lookups[ip] = nil

            minetest.log('action', '[anti_vpn] HTTP response: ' .. ip .. ': ' ..
                             tostring(vpn))
        else
            minetest.log('error', '[anti_vpn] HTTP request failed')
            minetest.log('error', dump(result))
        end

    end)
end

-- prejoin must return either 'nil' (allow the login) or a string (reject login
-- with the string as the error message).
anti_vpn.on_prejoinplayer = function(pname, ip)
    ip = testdata_player_ip[pname] or ip -- Hack for testing.
    local found, blocked = anti_vpn.lookup(pname, ip)
    if found and blocked then
        return 'Logins from VPNs are not allowed.  Your IP address: ' .. ip
    end

    if not found then enqueue_lookup(ip) end

    return nil
end

anti_vpn.on_joinplayer = function(player, last_login)
    local pname = player:get_player_name()
    local ip = anti_vpn.get_player_ip(pname) or ''
    local found, blocked = anti_vpn.lookup(pname, ip)
    if found and blocked then kick_player(pname, ip) end
    if not found then enqueue_lookup(ip) end
end

anti_vpn.flush_mod_storage = function()
    mod_storage:set_string('cache', minetest.write_json(cache))
    mod_storage:set_string('player_allow_list',
                           minetest.write_json(player_allow_list))
end

anti_vpn.init = function(http_api_provider)
    http_api = http_api_provider

    local json = mod_storage:get('cache')
    cache = json and minetest.parse_json(json) or {}
    minetest.log('action', '[anti_vpn] Loaded ' .. count_keys(cache) ..
                     ' cached IP lookups.')

    json = mod_storage:get('player_allow_list')
    player_allow_list = json and minetest.parse_json(json) or {}
    minetest.log('action',
                 '[anti_vpn] Loaded ' .. count_keys(player_allow_list) ..
                     ' immune players.')

    apikey = minetest.settings:get('anti_vpn.provider.vpnapi.apikey')
    if apikey == nil then
        -- TODO: try a text file, so that we don't need to store it in the main
        -- config file, which might end up in a source code repo.
        minetest.log('error', '[anti_vpn] Failed to lookup vpnapi.io api key.')
    end

    vpnapi_url = minetest.settings:get('anti_vpn.provider.vpnapi.url') or
                     DEFAULT_URL
end

local function async_player_kick()
    local count = 0
    for _, player in ipairs(minetest.get_connected_players()) do
        local pname = player:get_player_name()
        local ip = anti_vpn.get_player_ip(pname)
        local found, blocked = anti_vpn.lookup(pname, ip)

        if found and blocked then
            kick_player(pname, ip)
            count = count + 1
        end
    end

    if count > 0 then
        minetest.log('action', '[anti_vpn] kicked ' .. count .. ' VPN users.')
    end
end

local function async_inflight_lookup_prune()
    local ip_list = {}
    local threshold = os.time() - GATING_THRESHOLD
    for ip, timestamp in pairs(inflight_lookups) do
        if timestamp < threshold then table.insert(ip_list, ip) end
    end

    for _, ip in ipairs(ip_list) do
        minetest.log('action', '[anti_vpn] retiring expired lookup for ' .. ip)
        inflight_lookups[ip] = nil
    end
end

anti_vpn.async_worker = function()
    minetest.after(ASYNC_WORKER_DELAY, anti_vpn.async_worker)
    async_player_kick()
    async_inflight_lookup_prune()
end
