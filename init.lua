-- Minetest Anti-VPN
-- license: Apache 2.0
--
-- Attempts to prevent player logins from suspected VPN IP addresses.
--
--
local ERROR_COLOR = minetest.get_color_escape_sequence '#FF8080'

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
            minetest.chat_send_player(pname, ERROR_COLOR ..
                                          'invalid IP address: ' .. parts[2])
        end
        return
    elseif (parts[1] == 'flush') then
        anti_vpn.flush_mod_storage()
        minetest.chat_send_player(pname, 'anti_vpn data flushed to storage.')
        return
    elseif (parts[1] == 'cleanup') then
        anti_vpn.cleanup()
        minetest.chat_send_player(pname, 'anti_vpn cleanup initiated.')
        return
    elseif (parts[1] == 'mode') then
        if (type(parts[2]) == 'string') then
            local msg = anti_vpn.set_operating_mode(parts[2])
            minetest.chat_send_player(pname, msg)
        else
            minetest.chat_send_player(pname, 'anti_vpn operating mode: ' ..
                                          anti_vpn.get_operating_mode())
        end
        return
    end

    minetest.chat_send_player(pname, ERROR_COLOR ..
                                  'Unrecognized anti_vpn command: ' .. param)
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
