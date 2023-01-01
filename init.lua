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
                 '[anti_vpn]  minetest.request_http_api() failed.  Add ' ..
                     mod_name .. ' to secure.http_mods.')
else
    anti_vpn.init(http_api)
    minetest.register_on_prejoinplayer(anti_vpn.on_prejoinplayer)
    minetest.register_on_joinplayer(anti_vpn.on_joinplayer)
    minetest.after(5, anti_vpn.async_worker)
end
