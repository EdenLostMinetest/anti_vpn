-- Minetest Anti-VPN
-- license: Apache 2.0
--
-- Attempts to prevent player logins from suspected VPN IP addresses.
--
--
local mod_name = minetest.get_current_modname()
local mod_path = minetest.get_modpath(mod_name)

local http_api = minetest.request_http_api()

if http_api == nil then
    minetest.log('error',
                 '[anti_vpn] minetest.request_http_api() failed.  Add ' ..
                     mod_name .. ' to secure.http_mods.')
    return
end

-- Must load the API first
dofile(mod_path .. '/api.lua')
dofile(minetest.get_modpath(mod_name) .. '/chat_commands.lua')

anti_vpn.init(http_api)

minetest.register_on_prejoinplayer(anti_vpn.on_prejoinplayer)
minetest.register_on_joinplayer(anti_vpn.on_joinplayer)
minetest.after(5, anti_vpn.async_worker)

minetest.log('action', '[anti_vpn] loaded.')
