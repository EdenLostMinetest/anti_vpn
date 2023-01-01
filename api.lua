-- Minetest Chat Anti-VPN
-- license: Apache 2.0
--
-- Our namespace.
anti_vpn = {}

local DEFAULT_URL = 'http://localhost:48888'
local USER_AGENT = 'MineTest-AntiVpn-v0.1' -- TODO: Add github URL.
local DEFAULT_TIMEOUT = 10
local ASYNC_WORKER_DELAY = 5

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

    if http_api == nil then
        minetest.log('error', '[anti_vpn] http_api failed to allocate.  Add ' ..
                         minetest.get_current_modname() ..
                         ' to secure.http_mods.')
        return
    end

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
            minetest.log('action', '[anti_vpn] ' .. dump(tbl))

            local ip = tbl.ip
            local vpn = false

            -- Expected keys are 'vpn', 'proxy', 'tor', 'relay'.
            -- We'll reject the IP if any are true.
            for k, v in pairs(tbl.security) do vpn = vpn or v end

            cache[ip] = cache[ip] or {}
            cache[ip]['vpn'] = vpn
            cache[ip]['created'] = os.time()

            anti_vpn.flush_mod_storage()

        else
            minetest.log('error',
                         '[anti_vpn] HTTP request failed: ' .. dump(result))
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

-- anti_vpn.cache_insert = function(ip, vpn, provider)
--    cache[ip] = {vpn = vpn, provider = provider, created = os.time()}
--    anti_vpn.flush_mod_storage()
-- end

-- Not strictly needed yet, but will hbe useful when we add admin chat commands
-- for adding/removing VPN entries, ASN blocking, user allow-listing, etc...
anti_vpn.async_worker = function()
    minetest.after(ASYNC_WORKER_DELAY, anti_vpn.async_worker)

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
