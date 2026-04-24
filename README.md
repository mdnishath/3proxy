# ClientFlow Proxy Farm — client (France PC)

Windows-side code that turns a laptop with 2+ USB Wi-Fi dongles (each connected
to an SFR pocket router) into a residential-4G SOCKS5 egress point. Local
3proxy binds each adapter, reverse SSH tunnels the listener to the VPS, and
a rotation agent lets the VPS panel force a new 4G IP on demand.

```
customer → panel (VPS) → VPS 3proxy chain → reverse SSH tunnel → this laptop → 3proxy bound per adapter → pocket router → SFR 4G → Internet (French IP)
```

The VPS-side panel lives in a separate tree (`/opt/proxy-panel/`); this repo
is the PC-side only.

---

## Quick start (fresh laptop)

Plug in at least two USB Wi-Fi adapters, connect each to a different pocket
router's SSID, then open an **Administrator PowerShell** and run:

```powershell
git clone https://github.com/mdnishath/3proxy.git C:\temp\proxy-farm-src
cd C:\temp\proxy-farm-src

# Place the VPS SSH key before fresh-setup runs (copied via AnyDesk / USB):
Copy-Item <source>\panel_id_ed25519 .\keys\panel_id_ed25519

# Install / reinstall
powershell -ExecutionPolicy Bypass -File .\fresh-setup.ps1
```

`fresh-setup.ps1` will:

1. Kill any stale `3proxy` / `ssh` / `tunnel-loop` / rotation-agent processes
2. Delete the previous `ProxyFarm` scheduled task
3. Copy all scripts to `C:\proxy-farm\`
4. Write the canonical `config\adapters.json` + `config\passwd`
5. Generate a random `keys\agent-secret.txt` (if missing)
6. Register a new `ProxyFarm` scheduled task (`ONSTART`, hidden, run whether
   logged on or not — falls back to `ONLOGON` + Windows auto-login if no
   password supplied)
7. Set all saved Wi-Fi profiles to auto-connect
8. Launch everything now via `launcher.vbs` → `start-all.ps1`

At the end it prints `ROTATION_AGENT_SECRET=<hex>` — **copy that into the VPS
panel's `.env`** so the panel can authenticate to this laptop's rotation agent.

## What runs after install

- **3proxy** — local SOCKS5 listener per adapter slot on `127.0.0.1:51081+slot`
- **tunnel-loop.bat × N** — one reverse SSH tunnel per adapter, `VPS:40000+slot → PC:51080+slot`
- **agent.ps1** — HTTP listener on `127.0.0.1:8901` for rotation commands
- **tunnel-loop.bat (agent)** — reverse tunnel `VPS:40101 → PC:8901`

All started hidden (no desktop cmd-window flashes).

## IP rotation

For each pocket router you want to rotate:

1. Log into the router admin UI once via Chrome DevTools, capture the login
   payload (`/goform/login` → `{username:"<hash>", password:"<hash>"}` — see
   `rotate-router.ps1` header for the step-by-step).
2. Edit `C:\proxy-farm\config\routers.json` (seeded from `routers.json.example`
   on first install) and fill in that slot's `username_hash` + `password_hash`.
3. In the panel admin UI → server edit → enable rotation, set agent URL to
   `http://127.0.0.1:40101`, and router key to the slot number (e.g. `1`).
4. Click 🔄 **Rotate IP** on the server's detail page.

The agent will disable the other adapter, log into the router, toggle
`dialup_dataswitch` off → wait → on → log out, then re-enable the other
adapter. Takes ~30 seconds. Default cooldown is 10 minutes per slot because
SFR carrier caches the session-to-IP mapping for 1–5 minutes.

## Layout

| Path | What |
|---|---|
| `fresh-setup.ps1` | Canonical installer (admin) — replaces old `install.ps1` |
| `enable-autostart.ps1` | One-shot fix for autostart / Wi-Fi profile issues |
| `install.ps1` | Old interactive 2-adapter installer (kept for reference only) |
| `start-all.ps1` | Dynamic starter — adapter auto-detect, slot map, launch everything hidden |
| `start-all.bat` | Thin wrapper that invokes `start-all.ps1` |
| `stop-all.bat` | Stops 3proxy / ssh / tunnel-loop / agent |
| `tunnel-loop.bat` | SSH reverse tunnel with auto-reconnect loop |
| `launcher.vbs` | Invisible launcher used by the scheduled task |
| `run-hidden.vbs` | Generic hidden-process wrapper |
| `agent.ps1` | HTTP control agent (rotation commands from the panel) |
| `rotate-router.ps1` | Core rotation (login → disconnect → connect → logout) |
| `rotate-runner.ps1` | Wraps rotate-router.ps1 with task-state JSON |
| `bin/` | 3proxy binaries (compiled Windows build + DLL plugins) |
| `config/routers.json.example` | Template for rotation creds |
| `keys/` | SSH key + agent secret — NOT in git, see `keys/README.md` |

## Files intentionally not in git

See `.gitignore`. The short list:

- `keys/panel_id_ed25519` — transfer separately
- `keys/agent-secret.txt` — regenerated per install
- `config/routers.json` — filled in after DevTools capture
- `config/passwd`, `config/3proxy.cfg`, `config/adapters.json` — written by `fresh-setup.ps1` / `start-all.ps1`
- `logs/` — runtime only
