#!/bin/bash
# Usage: ./deploy.sh [server] [user]
SERVER="${1:-192.168.2.22}"
USER="${2:-root}"

# Copy script
scp traefik-autogen.sh "$USER@$SERVER:/usr/local/bin/traefik-autogen.sh"
ssh "$USER@$SERVER" "chmod 755 /usr/local/bin/traefik-autogen.sh"

# Copy env file to the canonical path (assumes /etc/traefik exists on target)
scp traefik-autogen.env "$USER@$SERVER:/etc/traefik/traefik-autogen.env"
ssh "$USER@$SERVER" "chmod 640 /etc/traefik/traefik-autogen.env"
