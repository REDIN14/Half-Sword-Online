HALF SWORD MULTIPLAYER MOD - CONFIGURATION & GUIDE
===================================================

HOW TO CONNECT
--------------
1. HOSTING:
   - Press F5 to Host "Arena" (Cutting Map)
   - Press F6 to Host "Abyss"

2. JOINING:
   - Open the file "server_ip.txt" in this folder.
   - Type the Host's IP address (e.g., 192.168.1.5 or 25.43.x.x).
   - Save the file.
   - In game, Press F8 to Connect.

PLAYING WITH FRIENDS (NETWORK)
------------------------------
A) SAME WI-FI / HOUSE (LAN):
   - Works automatically!
   - Host: Find your Local IPv4 (Task Manager > Ethernet > IPv4 address).
   - Client: Put that IP into "server_ip.txt".

B) DIFFERENT HOUSES (INTERNET):
   - OPTION 1 (Easiest): Use Radmin VPN, Hamachi, ZeroTier, or WireGuard.
     1. Both install the app and join the same "Network" (or tunnel).
     2. Use the VPN IP address (e.g., 10.x.x.x) in "server_ip.txt".
   
   - OPTION 2 (Advanced): Port Forwarding.
     1. Host must forward UDP Port 7777 in their router settings.
     2. Host gives Client their Public IP (search "what is my ip" on google).

TROUBLESHOOTING
---------------
- If F5 crashes: Restart game and try again (rare).
- If F8 doesn't connect: Check if Host has firewall blocking "Unreal Engine" or "Half Sword".
- Press F7 to Disconnect.
