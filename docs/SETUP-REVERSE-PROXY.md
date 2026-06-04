# Setting up the public reverse proxy (Apache2 + Tailscale)

How to route Vision Companion relay traffic from the phone, through
`kangatnewyork.com` (Kang's AWS EC2 Ubuntu server running Apache2 +
Let's Encrypt + LINE Bot), across Tailscale into the home Hermes
Ubuntu Desktop machine where `relay_server.py` is listening.

This is the canonical deployment topology. (For a one-machine-only
fallback, see "Alternative: single-machine setup" at the bottom.)

---

## Goal architecture

```
[Galaxy S25 on any network]
  │  wss://kangatnewyork.com/vc-relay/?token=vcr_xxx
  ↓
[AWS EC2: kangatnewyork.com]
  │  Ubuntu 24.04, public IP
  │  Apache2 (Let's Encrypt for kangatnewyork.com), LINE Bot
  │  Tailscale client (peer with hermes-home)
  │  ProxyPass /vc-relay/ → ws://hermes:8765/  (via tailnet)
  ↓  (Tailscale mesh, encrypted)
[Home: hermes]
  │  Ubuntu Desktop 26.04, behind NAT, no public IP
  │  Hermes AI Agent
  │  relay_server.py listening on 0.0.0.0:8765 (tailnet-only effectively)
  │  Tailscale hostname: hermes  (IP: 100.84.89.83)
```

The phone speaks plain HTTPS/WSS to `kangatnewyork.com` — no
Tailscale on the phone, no certs to install on the phone, no special
networking required. Works on cellular and any public WiFi.

---

## Prerequisites Kang already has

These are working from the LINE Bot setup. Skip if so.

- AWS EC2 Ubuntu 24.04 with a public IP, reachable as `kangatnewyork.com`
- Apache2 running with TLS via Let's Encrypt for `kangatnewyork.com`
- Tailscale installed on both EC2 and the home Hermes machine
- Both machines visible in `tailscale status` from each other
- The home Hermes machine's tailnet hostname is `hermes`
  (IP `100.84.89.83`)

Confirm before continuing:

```bash
# On EC2:
tailscale status | grep hermes
# expected:  100.84.89.83  hermes  ...

tailscale ping hermes
# expected:  pong from hermes ... via direct/derp ...

# On Hermes:
tailscale status | grep ip-172-31-10-238
# expected:  100.72.173.56  ip-172-31-10-238  ...
```

If `tailscale ping hermes` works from EC2, the network layer is ready.

---

## Step 1 — Enable Apache WebSocket modules (on EC2)

```bash
sudo a2enmod ssl proxy proxy_http proxy_wstunnel rewrite headers
sudo systemctl restart apache2
apachectl -M 2>/dev/null | grep -E 'proxy_wstunnel|proxy_module|rewrite|headers'
```

You should see all four. If `proxy_wstunnel` is missing, the module
isn't installed (most Ubuntu 24.04 installs ship it; if not,
`sudo apt install libapache2-mod-proxy-html`).

---

## Step 2 — Generate the relay token (on Hermes)

Run this on the **Hermes** machine, not on EC2. The token is the
shared secret that authenticates the phone to relay_server.

```bash
echo "vcr_$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
```

Sample output: `vcr_a1B2c3D4e5F6g7H8i9J0kLmNoPqRsTuV`

Save this. You'll paste it into:
- `~/.hermes/voice-companion/config.yaml` (Hermes)
- the systemd drop-in for the relay-daemon unit (Hermes)
- the Android app's URL field (phone)

**EC2/Apache never sees the token** — it just proxies the bytes through.
The token check happens in relay_server.py on Hermes.

---

## Step 3 — Pick a URL path

The Vision Companion path must not collide with the LINE Bot path.
Default proposal: **`/vc-relay`**.

Confirm what your LINE Bot currently uses:

```bash
sudo grep -RIn 'ProxyPass\|<Location' /etc/apache2/sites-enabled/
```

Any path that doesn't match the LINE Bot's path is fine. The rest of
this doc assumes `/vc-relay` — substitute throughout if you pick
something else.

---

## Step 4 — Add the vhost rules (on EC2)

Edit the existing vhost file for `kangatnewyork.com`:

```bash
sudo nano /etc/apache2/sites-enabled/kangatnewyork.com-le-ssl.conf
# or whatever your existing vhost file is named
```

Find the existing `<VirtualHost *:443>` block (the one for
`kangatnewyork.com`). Add the following inside it, near the bottom but
**before** the `</VirtualHost>` close tag. **Don't touch existing LINE
Bot rules**:

```apache
    # ============================================================
    # Vision Companion (解語) WebSocket relay
    # ============================================================

    # WebSocket sessions stay open continuously while in use. Apache's
    # default 60s timeout would kill them, so bump it for this vhost.
    # If you've already set these for the LINE Bot, no harm in repeating.
    Timeout 86400
    ProxyTimeout 86400

    # Apache 2.4.47+ supports `upgrade=websocket` on ProxyPass. Ubuntu
    # 24.04 ships 2.4.58, so this just works.
    #
    # Target: the home Hermes machine via Tailscale. `hermes` is the
    # MagicDNS name; if MagicDNS isn't resolving on EC2, fall back to
    # the tailnet IP `100.84.89.83`.
    ProxyPass        /vc-relay/  ws://hermes:8765/  upgrade=websocket  timeout=86400
    ProxyPassReverse /vc-relay/  ws://hermes:8765/

    # Forward useful info to relay_server's log
    <Location "/vc-relay">
        RequestHeader set X-Forwarded-Proto "wss"
        RequestHeader set X-Real-IP "%{REMOTE_ADDR}s"
    </Location>
```

If MagicDNS isn't working from EC2 (you'd see `Could not resolve host:
hermes` in Apache error log), swap `hermes` for `100.84.89.83` in both
ProxyPass lines.

Test the syntax before reloading:

```bash
sudo apachectl configtest         # must print "Syntax OK"
sudo systemctl reload apache2
```

---

## Step 5 — Confirm the public WSS endpoint is alive

From any machine on the public internet (your laptop, your phone over
cellular):

```bash
curl -i https://kangatnewyork.com/vc-relay/
```

Expected: `HTTP/1.1 426 Upgrade Required`. That's correct — you tried
to HTTP-GET a WebSocket endpoint.

If you see `404`: the ProxyPass rules didn't take effect. Check:

```bash
sudo apachectl -S | grep vc-relay   # should show the proxy mapping
sudo tail -n 100 /var/log/apache2/error.log
```

If you see `502 Bad Gateway`:
- The Hermes daemon isn't running yet. Skip to step 6.
- Or MagicDNS isn't resolving. Try the IP form (Step 4).

If you see content from the LINE Bot: your path is colliding with the
LINE Bot's. Pick a different path.

---

## Step 6 — Wire the Hermes side (on Hermes)

### 6a. Add token to config.yaml (discoverable copy)

```bash
nano ~/.hermes/voice-companion/config.yaml
```

Set:

```yaml
relay_token: "vcr_a1B2c3D4e5F6g7H8i9J0kLmNoPqRsTuV"
```

### 6b. Pass the token to systemd via a drop-in

A drop-in keeps the token out of the main unit file so rotation is
easy:

```bash
mkdir -p ~/.config/systemd/user/relay-daemon.service.d/
cat > ~/.config/systemd/user/relay-daemon.service.d/token.conf <<'EOF'
[Service]
Environment=RELAY_TOKEN=vcr_a1B2c3D4e5F6g7H8i9J0kLmNoPqRsTuV
EOF
systemctl --user daemon-reload
systemctl --user restart relay-daemon
```

### 6c. Verify

```bash
journalctl --user -u relay-daemon -n 30 --no-pager
```

You should see:
```
INFO  relay: token auth enabled (token length=33)
INFO  relay: starting WebSocket server on 0.0.0.0:8765 (voice=N enrolled, face=M enrolled)
```

```bash
ss -lntp 2>/dev/null | grep 8765
```

Should show relay_server listening on `0.0.0.0:8765`. The tailnet
firewall (or lack thereof) means it's reachable from EC2 over Tailscale
but NOT from the public internet directly.

---

## Step 7 — Configure the Android app

On the Galaxy S25, in the Vision Companion Relay app:

| Field | Value |
|-------|-------|
| **Server URL** | `wss://kangatnewyork.com/vc-relay/?token=vcr_a1B2c3D4e5F6g7H8i9J0kLmNoPqRsTuV` |
| **Image FPS** | 0 to start (audio-only). Bump to 1-2 once you've verified the audio path. |
| **Glasses transport** | `Phone mic + camera (dev)` until Meta SDK arrives |
| **Auto-reconnect** | ON |
| **Log level** | INFO |

Tap **Test connection** → expect status to update to "Connected,
server says: session_started".

If it fails, see Troubleshooting below.

---

## Step 8 — End-to-end sanity check

With Apache reloaded, the Hermes daemon restarted, and the phone
configured, do this verification:

### From any external network with wscat

```bash
# Install wscat once: npm install -g wscat
wscat -c "wss://kangatnewyork.com/vc-relay/?token=vcr_..."
```

You should see Apache + Hermes accept the connection, then JSON arrive
within a second:

```json
{"event":"session_started","peer":"100.72.173.56:51822","voice_gallery_size":0,"face_gallery_size":0,"active":true,"timestamp":"..."}
```

The peer IP `100.72.173.56` is EC2's tailnet IP (Apache is the
immediate client from relay_server's POV). That's expected.

### On Hermes, simultaneously tailing the log

```bash
tail -f ~/.hermes/voice-companion/relay-daemon.log
```

You should see:
```
INFO  relay: client connecting peer=100.72.173.56:51822 path='/?token=vcr_...'
INFO  relay: token validated for peer=100.72.173.56:51822
INFO  relay: session opened peer=100.72.173.56:51822
```

If you also have the Android app running with the right URL, you
should see the connection from the phone (still showing as coming from
the EC2 tailnet IP, because Apache is the immediate WebSocket peer).
Speak; expect `speech segment ...` lines and a `speaker_identified`
event back. The phone should play the announced name.

---

## Troubleshooting

### `426 Upgrade Required` from curl but the phone can't connect

- Check the phone's URL has the trailing slash matching the
  `ProxyPass /vc-relay/` configuration. Apache is fussy here.
- Check the token in the URL matches what's in config.yaml and the
  systemd drop-in. The relay closes mismatched-token connections with
  code 4401.
- Check Hermes log for `rejecting peer=... token mismatch` or
  `rejecting peer=... no token in query string`.

### `502 Bad Gateway` from Apache

- relay_server isn't running on Hermes. `systemctl --user status
  relay-daemon` on Hermes.
- The Apache machine can't reach Hermes over Tailscale. `tailscale
  ping hermes` from EC2 must succeed.
- MagicDNS not resolving. Use the tailnet IP `100.84.89.83` directly
  in the ProxyPass instead of the hostname `hermes`.

### Apache log shows `proxy: HTTP: failed to make connection to backend`

Same root cause as 502. Network reachability between EC2 and Hermes via
Tailscale.

### Connection lasts ~60 seconds then drops

- Apache idle timeout. Confirm the `Timeout 86400` and `ProxyTimeout
  86400` lines are inside the `<VirtualHost>` block (or set globally).
  Also confirm `ProxyPass ... timeout=86400`.

### TLS handshake fails

- Cert not loaded by Apache: `sudo apachectl -S` should list the vhost
  with the `kangatnewyork.com` ServerName and the cert path.
- Cert expired: `sudo certbot certificates` to see expiry. Re-issue.

### The phone connects but no events come back

- Tail `~/.hermes/voice-companion/relay-daemon.log` on Hermes — is
  audio arriving? Look for `audio chunk samples=...` lines.
- If audio arrives but nothing is identified, the gallery is probably
  empty: `~/.hermes/voice-companion/.venv/bin/python ~/.hermes/voice-companion/scripts/enroll.py --list`.
- If the gallery has entries but no match: similarity threshold may be
  too tight. See `docs/USING-THE-APP.md` tuning section.

### Hermes log: `Tailscale can't reach the configured DNS servers`

This appeared in Kang's earlier `tailscale status`. It does NOT block
tailnet-to-tailnet traffic (MagicDNS uses Tailscale's own resolver),
but it can block:
- `apt update` / `apt install`
- Downloading models on first install
- Hermes Agent calls to external services

Fix later by setting reliable DNS in `/etc/systemd/resolved.conf` or
the Tailscale admin console's DNS settings.

### "I want to revert to Tailscale-direct (no public path)"

The Android app accepts any WebSocket URL. Switch to
`ws://hermes:8765/?token=vcr_...` and install Tailscale on the phone.
Both transport modes coexist; relay_server doesn't care which way the
connection arrived.

---

## Bandwidth and resource notes

Continuous audio uplink at 16kHz mono int16 = **32 KB/sec ≈ 1.2 GB/hour**.

- All of it crosses EC2's network interface (in and out via Tailscale
  to home).
- AWS charges for data egress (out from EC2). At ~$0.09/GB egress in
  most US regions: ~$0.11/hour of active use, $2.50/day if it ran 24/7.
  In practice the relay should be paused (`hithe off`) when not in use.
- If `Image FPS > 0`, add ~50-150 KB per frame.

If cost is a concern, consider:
- Pausing aggressively via `hithe off`
- Lowering `image_fps` to 0 except when explicitly asking for face ID
- Using a different EC2 region or carrier that doesn't charge egress

---

## Cohabitation with the LINE Bot

The vhost rules above ADD to your existing vhost; they don't replace
anything. The path namespace must not overlap. Common LINE webhook
paths (`/callback`, `/webhook`, `/line/...`) don't clash with
`/vc-relay`.

If you ever retire or move the LINE Bot, only the LINE Bot section of
the vhost needs touching; the `/vc-relay` rules stay as-is.

---

## Alternative: single-machine setup (Apache + Hermes on one box)

If you ever consolidate to one machine (e.g. moving Hermes onto the
EC2 box, or installing Apache on the home Hermes box), use this
ProxyPass target instead:

```apache
ProxyPass        /vc-relay/  ws://127.0.0.1:8765/  upgrade=websocket  timeout=86400
ProxyPassReverse /vc-relay/  ws://127.0.0.1:8765/
```

Everything else in this guide stays the same.

---

## Pending implementation work (cross-reference)

These are all in PR #1 / repo `main` at HEAD:

- [x] `relay_server.py` accepts `--token` and `RELAY_TOKEN` env var;
      rejects connections with wrong/missing token (close code 4401)
- [x] `run-relay.sh` reads `RELAY_TOKEN` and passes `--token`
- [x] `config.yaml` has the `relay_token` field documented
- [x] `hermes-skill/relay/SKILL.md` documents the rotate / read-token
      trigger phrases for Hermes-driven management
- [x] Android Settings uses a single `serverUrl` field instead of host+port
