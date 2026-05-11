param(
  [string]$Server = "192.168.2.22",
  [string]$User = "root"
)

scp "traefik-autogen.sh" "$User@$Server`:/usr/local/bin/traefik-autogen.sh"
ssh "$User@$Server" "chmod 755 /usr/local/bin/traefik-autogen.sh"
scp "traefik-autogen.env" "$User@$Server`:/etc/traefik/import.env"
ssh "$User@$Server" "chmod 640 /etc/traefik/import.env"
