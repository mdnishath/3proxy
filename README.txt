====================================================================
  ClientFlow Proxy Farm — Client Laptop Install (France)
====================================================================

WHAT THIS DOES
--------------
Turns the laptop into a 2-way mobile proxy source. Two USB Wi-Fi
adapters (each joined to a different 4G pocket router) provide egress
IPs. The laptop opens two SSH reverse tunnels to the central VPS
(144.79.218.148) so customers connecting to the VPS automatically
route out through the laptop's pocket routers.

No customer ever sees the laptop directly — they only see the VPS
address. The laptop runs 24/7 and auto-recovers if the internet
hiccups.

PREREQUISITES
-------------
  - Windows 10 (or 11), x64
  - 4 GB RAM, any CPU (tiny footprint: ~30 MB RAM in use)
  - 2 USB Wi-Fi adapters plugged in (via powered hub recommended)
  - Each adapter already connected to its pocket router's Wi-Fi SSID
  - Administrator privileges (one-time, for the installer)
  - Internet access (any path — home ISP works fine)

INSTALL (one time)
------------------
  1. Copy this entire folder to the laptop (any location; desktop
     is fine). Easiest via AnyDesk file transfer.
  2. Right-click  install.ps1  → "Run with PowerShell" as Admin.
     Or: open PowerShell as Admin, cd into this folder, run:
       Set-ExecutionPolicy -Scope Process Bypass
       .\install.ps1
  3. When prompted (only if >2 Wi-Fi adapters found), pick which two
     are the pocket routers.
  4. Done. The installer:
       - Creates C:\proxy-farm\
       - Excludes that folder from Windows Defender
       - Generates 3proxy.cfg bound to the two adapter IPs
       - Registers scheduled task "ProxyFarm" (runs at every boot)
       - Starts the service immediately

VERIFY
------
Open a second PowerShell window on the laptop:
  Get-Process 3proxy, ssh

Expected: three processes (one 3proxy + two ssh tunnels).

Check logs:
  Get-Content C:\proxy-farm\logs\tunnel-40001.log -Wait
  Get-Content C:\proxy-farm\logs\tunnel-40002.log -Wait

On the central VPS you should see both tunnel ports listening:
  ss -tlnp | grep -E ":40001|:40002"

COMMON COMMANDS
---------------
  C:\proxy-farm\start-all.bat       (manually start)
  C:\proxy-farm\stop-all.bat        (manually stop)
  schtasks /run /tn "ProxyFarm"     (trigger scheduled task)
  schtasks /delete /tn "ProxyFarm"  (remove auto-start)

WHAT CUSTOMERS SEE
------------------
In the admin panel at https://panel.client-flow.xyz, two new servers
named "pc-fr-router-1" and "pc-fr-router-2" appear. Customers assigned
to them get credentials like:

  SOCKS5: 144.79.218.148:52101:<panel_user>:<panel_pass>
  HTTP:   144.79.218.148:52111:<panel_user>:<panel_pass>

Traffic flows:
  customer --> VPS:52101 (auth with panel cred)
           --> internal chain to 127.0.0.1:40001
           --> SSH tunnel to laptop:51081
           --> 3proxy egress via Router 1 Wi-Fi adapter
           --> pocket router 4G
           --> internet

The external IP seen by Google/Gmail is the pocket router's 4G IP,
NOT the VPS IP.

TROUBLESHOOTING
---------------
  "Only 1 Wi-Fi adapter found"
     → Plug in both USB adapters, make sure both are connected to a
       pocket router's SSID (open Wi-Fi menu, confirm each shows its
       own SSID), then re-run install.ps1.

  "Tunnel keeps reconnecting in the log"
     → Normal during the first minute. If persistent, check that
       outbound port 22 to 144.79.218.148 is not blocked by any
       firewall on the laptop or the pocket router.

  "Customer sees VPS IP instead of pocket router IP"
     → Tunnel is down. On VPS:
         ss -tlnp | grep -E ":40001|:40002"
       If empty: tunnels are not active. Trigger restart:
         schtasks /run /tn "ProxyFarm"

SECURITY NOTES
--------------
  - C:\proxy-farm\keys\panel_id_ed25519 is an SSH private key that
    only accepts the port forwarding commands above. It cannot be
    used for shell access.
  - Windows Defender is NOT disabled globally — only C:\proxy-farm
    is excluded (3proxy.exe is flagged as false-positive HackTool).
  - Outbound SSH to VPS (port 22) is the only network change.
