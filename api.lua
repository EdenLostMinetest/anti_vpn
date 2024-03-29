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

-- For testing.  Normally this table should be empty.
-- Map a player name (string) to an IPV4 address (string).
local testdata_player_ip = {}

-- Passed from `init.lua`.  It can only be obtained from there.
local http_api = nil

-- Operating mode (string).  Values are "off", "dryrun", "enforce".
-- https://github.com/EdenLostMinetest/anti_vpn/issues/3
local operating_mode = 'enforce'

-- Cache of vpnapi.io lookups, in mod_storage().
-- Key = IP address.
-- Value = table:
--   'asn' (string) autonomous system number.
--   'blocked' (boolean).
--   'country' (string) two-letter country code.
--   'created' (seconds since unix epoch).
--   'provider' (string) internal name for where this data came from.
local ip_data = {}

-- Queue of IP addresses that we need to lookup.
-- Key = IP.  Value = timestamp submitted (used for pruning stale entries).
local ip_queue = {}

-- Count of outstanding HTTP requests.
local active_requests = 0

-- Allow/Deny/Lockdown info, per player.
-- Key = player name
-- Value = table:
--  'banned' (bool) outright ban the player.
--  'bypass' (bool) always allow the player.
local player_data = {}

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

local IPV4_PATTERN = '^(%d+)%.(%d+)%.(%d+)%.(%d+)$'

anti_vpn.is_valid_ip = function(ip)
    local octets = {string.match(ip, IPV4_PATTERN)}
    local count = 0

    for _, v in ipairs(octets) do
        if v == nil then return false end
        local x = tonumber(v) or 257
        if (x < 0) or (x > 255) then return false end
        count = count + 1
    end

    return count == 4
end

-- https://www.rfc-editor.org/rfc/rfc1918
local function is_private_ip(ip)
    local a, b, c, d = string.match(ip, IPV4_PATTERN)
    if a and b and c and d then
        a, b = tonumber(a), tonumber(b)
        return (a == 10) -- 10.0.0.0/8
        or ((a == 172) and (b >= 16) and (b <= 31)) -- 172.16.0.0/12
        or ((a == 192) and (b == 168)) -- 192.168.0.0/16
        or (a == 127) -- loopback
    end
    return false
end

local function get_kick_text(pname, ip)
    return
        'Connections from VPNs are not allowed.  Your IP address is ' .. ip ..
            '. ' .. (minetest.settings:get('anti_vpn.kick_text') or '')
end

local function kick_player(pname, ip)
    if operating_mode == 'enforce' then
        minetest.kick_player(pname, get_kick_text(pname, ip))
        minetest.log('warning',
                     '[anti_vpn] kicking player ' .. pname .. ' from ' .. ip)
    end
end

anti_vpn.get_player_ip = function(pname)
    return testdata_player_ip[pname] or minetest.get_player_ip(pname)
end

-- Returns text suitable for sending to player via chat message.
anti_vpn.set_operating_mode = function(mode)
    local valid_modes = {off = true, dryrun = true, enforce = true}
    if valid_modes[mode] == nil then
        return 'set_operating_mode("' .. mode .. '") is an invalid mode.' ..
                   'Valid modes are "off", "dryrun", "enforce".'
    end

    local msg = 'Changing anti_vpn operating mode from ' .. operating_mode ..
                    ' to ' .. mode
    minetest.log('action', '[anti_vpn] ' .. msg)
    operating_mode = mode
    mod_storage:set_string('operating_mode', mode)
    return msg
end

-- Returns raw operating mode string ("off", "dryrun", "enforce")
anti_vpn.get_operating_mode = function()
    return operating_mode
end

-- Returns table:
--   [1] (bool) "found" - Was the IP found in the ip_data?
--   [2] (bool) "blocked" - Should we reject the user from this IP address?
anti_vpn.lookup = function(pname, ip)
    assert(type(pname) == 'string')
    assert(type(ip) == 'string')

    if operating_mode == 'off' then return true, false end

    if player_data[pname] and player_data[pname].bypass then
        return true, false
    end

    if is_private_ip(ip) then return true, false end

    if ip_data[ip] == nil then return false, false end

    return true, ip_data[ip]['blocked']
end

anti_vpn.add_override_ip = function(ip, blocked)
    if not anti_vpn.is_valid_ip(ip) then return end

    local asn = ip_data[ip] and ip_data[ip]['asn'] or ''
    local country = ip_data[ip] and ip_data[ip]['country'] or ''

    ip_data[ip] = {
        asn = asn,
        blocked = blocked,
        country = country,
        created = os.time(),
        provider = 'manual'
    }

    ip_queue[ip] = nil

    anti_vpn.flush_mod_storage()
end

anti_vpn.delete_ip = function(ip)
    if not anti_vpn.is_valid_ip(ip) then return end

    ip_data[ip] = nil
    ip_queue[ip] = nil

    anti_vpn.flush_mod_storage()
end

-- Called on demand, and from async timer, to serially process the ip_queue.
local function process_ip_queue()
    if operating_mode == 'off' then return end

    -- Only one request at a time please.
    if active_requests > 0 then return end

    -- Is the ip_queue empty?
    if next(ip_queue) == nil then return end

    -- Is the HTTP API properly loaded?
    if http_api == nil then
        minetest.log('error', '[anti_vpn] http_api failed to allocate.  Add ' ..
                         minetest.get_current_modname() ..
                         ' to secure.http_mods.')
        return
    end

    local ip = next(ip_queue)

    active_requests = active_requests + 1

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
            local blocked = false

            -- Expected keys are 'vpn', 'proxy', 'tor', 'relay'.
            -- We'll reject the IP if any are true.
            for k, v in pairs(tbl.security) do blocked = blocked or v end

            local asn =
                tbl['network'] and tbl.network.autonomous_system_number or ''
            local country = tbl['location'] and tbl.location.country_code or ''

            ip_data[ip] = ip_data[ip] or {}
            ip_data[ip]['asn'] = asn
            ip_data[ip]['blocked'] = blocked
            ip_data[ip]['country'] = country
            ip_data[ip]['created'] = os.time()
            ip_data[ip]['provider'] = 'vpnapi'

            anti_vpn.flush_mod_storage()
            ip_queue[ip] = nil

            -- Make the log message somewhat parseable w/ "awk", in case we
            -- need to reconstruct our database from just the log files.
            minetest.log('action',
                         '[anti_vpn] HTTP response: ip:' .. ip .. ' blocked:' ..
                             tostring(blocked) .. ' asn:' .. asn .. ' country:' ..
                             country)
        else
            ip_queue[ip] = nil

            minetest.log('error', '[anti_vpn] HTTP request failed for ' .. ip)
            minetest.log('error', dump(result))
        end

        active_requests = active_requests - 1

        -- Start a new lookup immediately, if we have one, and if previous
        -- was successful.
        if result.succeeded then process_ip_queue() end
    end)
end

-- If IP is in ip_data, do nothing.  If not, queue up a remote lookup.
-- Returns nothing.
anti_vpn.enqueue_lookup = function(ip)
    if not anti_vpn.is_valid_ip(ip) then return end

    -- Don't bother looking up private/LAN IPs.
    if is_private_ip(ip) then return end

    -- If IP is already cached, then do nothing.
    if ip_data[ip] ~= nil then return end

    -- If IP is already queued, then do nothing.
    if ip_queue[ip] ~= nil then return end

    ip_queue[ip] = os.time();
    minetest.log('action', '[anti_vpn] Queueing request for ' .. ip)

    process_ip_queue()
end

-- prejoin must return either 'nil' (allow the login) or a string (reject login
-- with the string as the error message).
anti_vpn.on_prejoinplayer = function(pname, ip)
    if operating_mode == 'off' then return nil end

    ip = testdata_player_ip[pname] or ip -- Hack for testing.
    local found, blocked = anti_vpn.lookup(pname, ip)
    if found and blocked then
        minetest.log('warning',
                     '[anti_vpn] blocking player ' .. pname .. ' from ' .. ip ..
                         ' mode=' .. operating_mode)
        if operating_mode == 'enforce' then
            return get_kick_text(pname, ip)
        else
            return nil
        end
    end

    if not found then anti_vpn.enqueue_lookup(ip) end

    return nil
end

anti_vpn.on_joinplayer = function(player, last_login)
    local pname = player:get_player_name()
    local ip = anti_vpn.get_player_ip(pname) or ''
    local found, blocked = anti_vpn.lookup(pname, ip)
    if found and blocked then kick_player(pname, ip) end
    if not found then anti_vpn.enqueue_lookup(ip) end
end

anti_vpn.flush_mod_storage = function()
    local json_ip_data = minetest.write_json(ip_data)
    local json_players = minetest.write_json(player_data)

    mod_storage:set_string('ip_data', json_ip_data)
    mod_storage:set_string('players', json_players)

    -- For debugging.  mod_storage is powerful, but our data ends up being
    -- double encoded as a JSON payload, stringified, as a JSON value in a
    -- map.  Its a PITA to analyze offline.  See README.md for `jq` recipes.
    if minetest.settings:get_bool('anti_vpn.debug.json', false) then
        local dir = minetest.get_worldpath()
        minetest.safe_file_write(dir .. '/anti_vpn_ip_data.json', json_ip_data)
        minetest.safe_file_write(dir .. '/anti_vpn_players.json', json_players)
    end
end

anti_vpn.init = function(http_api_provider)
    http_api = http_api_provider

    operating_mode = (mod_storage:contains('operating_mode') and
                         mod_storage:get_string('operating_mode')) or 'enforce'
    minetest.log('action', '[anti_vpn] operating_mode: ' .. operating_mode)

    local json = mod_storage:get('ip_data')
    ip_data = json and minetest.parse_json(json) or {}
    minetest.log('action',
                 '[anti_vpn] Loaded ' .. count_keys(ip_data) .. ' IP lookups.')

    json = mod_storage:get('players')
    player_data = json and minetest.parse_json(json) or {}
    minetest.log('action',
                 '[anti_vpn] Loaded ' .. count_keys(player_data) .. ' players.')

    apikey = minetest.settings:get('anti_vpn.provider.vpnapi.apikey')
    if apikey == nil then
        -- TODO: try a text file, so that we don't need to store it in the main
        -- config file, which might end up in a source code repo.
        minetest.log('error', '[anti_vpn] Failed to lookup vpnapi.io api key.')
    end

    vpnapi_url = minetest.settings:get('anti_vpn.provider.vpnapi.url') or
                     DEFAULT_URL

    -- Temp code.  We changed the key from 'vpn' to 'blocked'.
    -- TODO: Remove once production server is updated.
    local converted = false
    for k, v in pairs(ip_data) do
        if v['vpn'] ~= nil then
            minetest.log('action', '[anti_vpn] converting ' .. k)
            v['blocked'] = v['vpn']
            v['vpn'] = nil
            converted = true
        end
    end
    if converted then anti_vpn.flush_mod_storage() end
end

local function async_player_kick()
    if operating_mode ~= 'enforce' then return end

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

anti_vpn.async_worker = function()
    minetest.after(ASYNC_WORKER_DELAY, anti_vpn.async_worker)
    async_player_kick()
    process_ip_queue()
end

-- Misc functions to "clean" the database.
anti_vpn.cleanup = function()
    for ip, v in pairs(ip_data) do
        -- Do stuff here.
    end
end

-- Returns a string for use in a chat message.
anti_vpn.get_stats_string = function()
    local total = 0
    local blocked = 0

    for ip, v in pairs(ip_data) do
        total = total + 1
        if v.blocked then blocked = blocked + 1 end
    end

    local perc = (total and (100.0 * blocked / total)) or 0.0
    return 'anti_vpn stats: total: ' .. total .. ', blocked: ' .. blocked ..
               ' (' .. string.format('%.4f', perc) .. '%)'
end
