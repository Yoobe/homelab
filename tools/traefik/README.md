# Traefik autogen import script

**Overview**

**Goal**: Scan Proxmox container descriptions and automatically generate Traefik dynamic configuration and local DNS overrides so services become routable with minimal manual configuration.

**What it does**: Produces Traefik YAML files under `/etc/traefik/dynamic/` and syncs DNS records to AdGuard Home to point public and private domains to the correct targets.

**Features**

- **Automatic route generation**: Creates routers, services and middlewares for containers annotated in their description.
- **TLS-ready**: Routers are created with the `websecure` entrypoint and a cert resolver so Let’s Encrypt can be used.
- **Security mappings**: Container `security` tags map to middleware (OAuth, basic auth, internal-only, etc.).
- **WebSocket-safe**: Routes that require WebSocket upgrades are generated without the header-injection middleware and set `passHostHeader: true`.
- **AdGuard DNS sync**: Syncs public domains to the Traefik VIP and creates internal `.lan` records that point to container IPs for internal service discovery.
- **Credentials**: Use an external `import.env` for secrets.

**How container descriptions work**

The script looks for INI-style `[web]` sections inside the Proxmox VM/LXC `description` field. Each `[web]` subsection defines a route. Supported keys:

- **domain**: Hostname to route (FQDN). Creates a Traefik host rule.
- **port**: Destination port on the container (required for HTTP routes).
- **security**: One of `oauth`, `public`, `private`, `password`, `auth`. These map to the script's predefined middlewares: `oauth` -> `security-oauth`, `private` -> `allow-internal`, `password` -> `auth-basic`, `auth` -> `authentik`.
- **proto**: `http` or `https` (affects service scheme and serversTransport).
- **ip**: Override the container IP when tags do not provide it.
- **dns**: If present, treated as a DNS-only record (no Traefik route).
- **websocket**: `true` to enable WebSocket-friendly routing (skips headers).

# traefik-autogen (autogen for Traefik & Gatus)

Overview

This tool scans Proxmox VM/LXC descriptions and automatically generates:

- Traefik dynamic configuration (`/etc/traefik/dynamic/`)
- AdGuard Home DNS rewrite rules for public and internal `.lan` names
- Optional Gatus monitoring config (`autogen-pve.yml`) and deploys it to configured Gatus servers

Features

- Automatic route generation from INI-style `[web]` sections in VM/LXC descriptions
- TLS-aware routers and serversTransport entries for HTTPS backends
- Security mapping (`oauth`, `private`, `password`, `auth`) to middlewares
- `websocket=true` support to avoid header injection that breaks upgrades
- `nossh=true` to suppress SSH checks in Gatus for containers without SSH
- `healthpath` to support custom external health-check URLs for Sites group
- Gatus alerting support for `googlechat` and `telegram` (optional)
- Deterministic md5 check so Gatus is only restarted when config actually changes

Container description keys

Place an INI `[web]` section in the VM/LXC `description` field. Supported keys:

- `domain` — FQDN to route
- `port` — destination port
- `security` — `oauth|public|private|password|auth`
- `proto` — `http|https`
- `ip` — override backend IP
- `dns` — create DNS-only record (no Traefik route)
- `websocket` — `true` to keep upgrade headers
- `nossh` — `true` to skip SSH (`tcp://IP:22`) Gatus checks
- `healthpath` — path appended to the external Sites URL (e.g. `/api/health`)

Example

```ini
[web]
domain = app.example.com
port = 3000
security = oauth
proto = http
websocket = true
healthpath = /api/health
nossh = true
```

IP selection priority

1. Container tags (private LAN address)
2. `ip` in the `[web]` section
3. If neither yields a private IP, the script skips creating `.lan` records

Gatus monitoring

- Enable by setting `GATUS_SERVERS_RAW` in the env file (pipe-separated list).
- The script generates `autogen-pve.yml` with groups: `Internal`, `Sites`, `Hosts`, `SSH`.
- Alerts attach only if providers are configured. Supported provider names in this repo: `googlechat`, `telegram`.
- Default settings used: `failure-threshold: 5`, `success-threshold: 2`, `minimum-reminder-interval: 24h`.

Important environment variables (see `traefik-autogen.env.example`)

- `PVE_SERVERS_RAW` — newline-separated `alias|https://pve:8006/api2/json|PVEAPIToken=...`
- `ADGUARD_PRIMARY`, `ADGUARD_SECONDARY`, `ADGUARD_USER`, `ADGUARD_PASS`
- `DEFAULT_TRAEFIK_VIP` — optional override for Traefik sync target
- `GATUS_SERVERS_RAW` — pipe-separated Gatus server IPs
- `GATUS_CONFIG_DIR`, `GATUS_AUTOGEN_FILE`, `GATUS_SSH_USER`, `GATUS_SSH_PASS`
- `GATUS_GOOGLECHAT_WEBHOOK` — full incoming webhook URL for Google Chat (optional)
- `GATUS_TELEGRAM_TOKEN`, `GATUS_TELEGRAM_ID` — Telegram bot token and chat id (optional)

Files in this folder

- `traefik-autogen.sh` — main script
- `traefik-autogen.env.example` — environment template (copy to `traefik-autogen.env`)
- `deploy.ps1`, `deploy.sh` — deploy helpers
- `CONTRIBUTING.md`, `LICENSE`

Running and deployment

Copy and edit the example env file, then use the deploy helpers or run the script locally:

```powershell
cp traefik-autogen.env.example traefik-autogen.env
# edit values in traefik-autogen.env
.
# deploy from workstation
.\deploy.ps1

# or run locally for test
bash traefik-autogen.sh
```

Notes

- The script avoids restarting Gatus unless the generated config changed (stable md5), so routine cron runs do not reset Gatus alert state.
- Changes that alter the generated config (e.g. adding `nossh`, `healthpath`, or altering domains) will cause a Gatus restart on deploy.
- Keep `traefik-autogen.env` out of version control.

If you want, I can add a short `CHANGELOG.md` summarizing the recent feature additions (`nossh`, `healthpath`, Google Chat, Telegram, 24h reminder interval).
