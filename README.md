# anti_vpn
Minetest mod to block connections from known VPN egress IPs

## Usage

1. Register for a "free tier" API KEY at https://vpnapi.io/.  This entitles
   you to make 1000 lookups "per day".  Read their terms and conditions.

1. Install this mod into your world.

1. Add the following to your `minetest.conf` file:

   ```
   anti_vpn.provider.vpnapi.apikey = YOUR_PRIVATE_API_KEY_HERE.
   anti_vpn.provider.vpnapi.url = https://vpnapi.io
   ```

1. Restart your Minetest server.

## Theory of Operation

The `anti_vpn` mod registers three callbacks:

1. `on_prejoinplayer` - Called before a player even authenticates.  Is passed
    their username and IP address.
1. `on_playerjoin` - Called after the player is logged in and about to spawn in
    the world.
1.  `after` - used to running periodic functions.

When a player prejoins, the mod instantly checks the VPN lookup cache.  If the
IP address belongs to a known VPN, the prejoin is rejected.  If the IP address
is unknown to the cache, then a background lookup (external http request) is
initiated, and the prejoin is allowed to proceed.

When a player joins, the same lookup is performed, and if the player's IP is
a VPN endpoint, then the player is kicked.

When the HTTP request is finished, the cache is updated, but no players are
instantly kicked.  The HTTP response can arrive before, during or after a
player has logged in, and its easier to just catch these players during the
periodic worker (via `minetest.after()`).

The periodic callback checks the IP address for each connected player, and
kicks any that map to a VPN.

## Misc

1. Check logs by looking for the string `anti_vpn`:

   `$ grep -a anti_vpn ~/.minetest/debug.log`

1. A cache of IPs is in `${WORLD}/mod_storage/anti_vpn` (JSON format).

## Manual testing.

1. Edit the `local testdata_player_ip` table near the top of `api.lua`.  Add
   a test username and an IP that you would like the `anti_vpn` mod to think
   that they are coming from, even though the real network will use the real
   IP address.  Ex:

   ```
   local testdata_player_ip = {
     vpn_user = '185.253.162.14',
     lan_user = '10.0.0.1',
     non_vpn_user = '67.84.231.116',
   }
   ```

1. To avoid consuming calls via your APIKEY, and you test during development
   by using a small (included) python web server that pretends to be
   "vpnapi.io".

   1. Create a directory called `testdata` and populate it with a few
      manual lookups.  Ex:

      ```
      $ mkdir testdata
      $ export APIKEY=xxxxxxxxxxxx
      $ for IP in 1.1.1.1 8.8.8.8 185.253.162.14; do \
          wget -q -O testdata/${IP}.json \
            https://vpnapi.io/api/${IP}?key=${APIKEY}; \
        done
      ```

   1. Edit `minetest.conf` and change the `anti_vpn.provider.vpnapi.url` to
      point to "http://localhost:48888".

   1. Run the python script.  It runs in the foreground.

   1. Edit `anti_vpn/api.lua` and add some fake user/IP mappings to
      `testdata_player_ip` (see above).

   1. Start a minetest server.

   1. Connect to the minetest server and conduct your testing.
