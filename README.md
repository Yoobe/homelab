# homelab
Docs, scripts and useful notes for managing my homelab (public).

## Overview
- **Purpose**: Central place for documentation, scripts and small tools I use to run and maintain my homelab.

## Tools
- **General**: See the tools index for details: [tools/README.md](tools/README.md#L1).
- **Postfix UI**: Lightweight HTTP viewer for Postfix queue status and quick troubleshooting — see [tools/postfix-ui/README.md](tools/postfix-ui/README.md#L1).
- **Traefik autogen**: Scans Proxmox container descriptions to generate Traefik dynamic configuration and DNS overrides — see [tools/traefik/README.md](tools/traefik/README.md#L1).

## Contact / Author
- Yoo

## Open-source tools
This is a non-exhaustive list of open-source tools I am testing or using in my homelab, and may be useful for others looking for self-hosted solutions. 

My homelab is running on Proxmox VE, and I use Traefik as a reverse proxy to route traffic to various services. I also have a local DNS server for internal name resolution.

Services include:

- AdGuard Home — DNS ad-blocking and local DNS.
- Authentik — identity provider / SSO.
- Cloudreve — cloud storage / drive.
- ComfyUI — self-hosted AI UI tooling.
- Coolify — self-hosted app deployment platform.
- Directus — headless CMS / data platform.
- Filestash — web file manager.
- Gatus — simple health-checking and monitoring.
- Home Assistant — home automation platform.
- Immich — self-hosted photo management.
- InfluxDB — time-series database (metrics/storage).
- Jellyfin — self-hosted media server.
- MariaDB — open-source relational database (MySQL-compatible).
- Matomo — web analytics (self-hosted).
- n8n — workflow automation / integrations.
- NodeBB — forum platform.
- Ollama — local LLM runtime.
- OpenWebUI — self-hosted AI UI tooling.
- Outline — collaborative docs / knowledge base.
- Passbolt — self-hosted password manager.
- Portainer — container management UI.
- PostgreSQL — open-source relational database.
- PrivateBin — encrypted pastebin.
- Rclone — cloud storage sync tool.
- Syncthing — peer-to-peer file synchronization.
- Traefik — reverse proxy and ingress (dynamic config autogen in `tools/traefik`).
- Uptime Kuma — self-hosted status uptime monitor.
- Vaultwarden — lightweight Bitwarden-compatible server.
- Webmin — web-based system administration.
- WordPress — CMS and blogging platform.
