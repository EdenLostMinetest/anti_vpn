-- Minetest Anti-VPN
-- license: Apache 2.0
--
-- Attempts to prevent player logins from suspected VPN IP addresses.
--
--
local mod_name = minetest.get_current_modname()
dofile(minetest.get_modpath(mod_name) .. '/api.lua')

local http_api = minetest.request_http_api()

if http_api == nil then
    minetest.log('error',
                 '[anti_vpn] minetest.request_http_api() failed.  Add ' ..
                     mod_name .. ' to secure.http_mods.')
    return
end

local function chat_cmd_handler(pname, param)
    local parts = param:split(' ')

    if (parts[1] == 'add') or (parts[1] == 'ip') then
        if anti_vpn.is_valid_ip(parts[2]) then
            anti_vpn.enqueue_lookup(parts[2])
        else
            minetest.chat_send_player(pname, 'invalid IP address: ' .. parts[2])
        end
        return
    end
end

anti_vpn.init(http_api)

minetest.register_chatcommand('anti_vpn', {
    privs = {staff = true},
    description = 'Issue commands to the anti_vpn mod.  See README for details.',
    params = '<command> <args>',
    func = chat_cmd_handler
})

minetest.register_on_prejoinplayer(anti_vpn.on_prejoinplayer)
minetest.register_on_joinplayer(anti_vpn.on_joinplayer)
minetest.after(5, anti_vpn.async_worker)

minetest.log('action', '[anti_vpn] loaded.')
