# Caddy direct-relay front-end (production topology)

Since 2026-07-02 the phone connects **directly to the home Mac Mini** through
Caddy, instead of bouncing through the EC2 Apache reverse proxy. This removed
the EC2↔home Tailscale **DERP relay** that was dropping the WebSocket every
20-60 seconds. The direct path is rock-stable.

```
phone → wss://meta.kangatnewyork.com:9443/vc-relay/?token=…
      → router (public 9443 → 192.168.0.99:9443)
      → Caddy on the Mac Mini (Let's Encrypt TLS)
      → 127.0.0.1:8765  relay
```

## Why port 9443 and not 443

The home's public 443 is already forwarded to a different machine (a website /
MUD server). One public port maps to one internal host, so the Mac Mini uses a
different public port, 9443. (Trade-off: some locked-down public Wi-Fi blocks
non-443 ports; if that ever bites, the only real fix is to free up 443 for the
Mac Mini.)

## One-time setup

1. **DNS**: A record `meta.kangatnewyork.com` → home public IP (currently
   `108.46.78.197`, static so far — add DDNS if it starts changing).
2. **Router port-forward** (NOT DMZ — just these two):
   - public TCP **80** → `192.168.0.99:80`  (Let's Encrypt HTTP-01 renewal)
   - public TCP **9443** → `192.168.0.99:9443`  (relay traffic)
3. **Install Caddy**: `brew install caddy`
4. Copy `Caddyfile` → `/opt/homebrew/etc/Caddyfile`
5. Install the LaunchDaemon (see header comment in `com.hithe.caddy.plist`).
   Caddy fetches the cert automatically on first start (watch
   `~/.hermes/voice-companion/caddy.log` for "certificate obtained successfully").

## Operations

```bash
# status / logs
sudo launchctl print system/com.hithe.caddy | head -20
tail -f ~/.hermes/voice-companion/caddy.log

# restart after a Caddyfile edit
sudo launchctl kickstart -k system/com.hithe.caddy

# validate a Caddyfile change before applying
caddy validate --config /opt/homebrew/etc/Caddyfile
```

## Security posture

- Only Caddy is internet-facing; the relay listens on loopback and is gated by
  the shared token (?token=…). Mismatched tokens are closed with code 4401.
- Only two ports are forwarded; the Mac Mini is **not** in the router DMZ.
- TLS is a real Let's Encrypt cert (auto-renews via HTTP-01 on port 80).

## Cert renewal note

Let's Encrypt renews ~30 days before expiry via HTTP-01, so **port 80 must stay
forwarded** to the Mac Mini for renewals to succeed. If renewal ever fails,
check that public 80 still reaches `192.168.0.99:80`.
