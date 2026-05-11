#!/bin/bash
SERVER="${1:-192.168.2.22}"
USER="${2:-root}"
scp traefik-autogen.sh "$USER@$SERVER:/usr/local/bin/traefik-autogen.sh"
ssh "$USER@$SERVER" "chmod 755 /usr/local/bin/traefik-autogen.sh"
scp traefik-autogen.env "$USER@$SERVER:/etc/traefik/import.env"
ssh "$USER@$SERVER" "chmod 640 /etc/traefik/import.env"
