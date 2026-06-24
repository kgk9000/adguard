# adguard

Minimal-privilege [AdGuard Home](https://github.com/AdguardTeam/AdGuardHome)
deployment for the always-on Mac mini — network-wide DNS ad/tracker blocking
behind the eero (single-NAT), managed as code.

## Design

- Runs as a **dedicated unprivileged launchd daemon** (`_adguardhome`), **never root**.
  macOS lets a non-root process bind port 53, so there's no `setcap`, no port-redirect,
  and no reason to grant root — the canned `AdGuardHome -s install` (which installs a
  *root* daemon) is deliberately **not** used.
- `KeepAlive` → launchd relaunches the process within seconds if it dies. That's our
  process-level failover (a restart keeps blocking, vs. leaking unfiltered queries).
- Whole-mini outage is covered separately by **secondary DNS = `1.1.1.1` on the eero**:
  clients fall back after a timeout. We accept the occasional unfiltered query — there's
  no second machine to act as a blocking secondary.
- Release is **pinned and checksum-verified**; `make update` bumps `AGH_VERSION`.
- The **admin UI binds to `127.0.0.1`** and is shared to the tailnet only via `make serve`
  (Tailscale Serve, never Funnel). DNS listens on the LAN (`:53`); the panel does not.
- The binary and runtime state are **not** committed (see `.gitignore`); the repo holds
  only the Makefile, the launchd plist template, and these docs.

## Config ownership (read this)

AdGuard Home **rewrites `AdGuardHome.yaml` itself** every time you change a setting in the
web UI. This repo intentionally does **not** track that file: AGH owns the live config and
you configure via the UI. If you later want git to be the source of truth, commit the yaml
and manage config *only* by editing the file + `make restart` — don't mix the two, and keep
the admin password hash out of the repo.

## Deploy (run on the mini)

    git clone <this-repo> ~/adguard && cd ~/adguard
    make install      # create svc user, download+verify, install daemon, start

`make install` will prompt for `sudo` (creating the service user, writing the LaunchDaemon,
loading it). The AdGuard Home **process** that results is unprivileged.

Then open the setup wizard **from the mini itself** at `http://localhost:3000`. On the
first screen:

- **Admin Web Interface** → bind to **`127.0.0.1`** (loopback only — not exposed on the LAN).
- **DNS server** → bind to **All interfaces**, port **`53`** (devices must be able to reach it).

Then set the admin login, pick upstreams (e.g. `1.1.1.1`, `9.9.9.9`), and choose blocklists.

### Admin UI access — tailnet only

The admin UI is loopback-bound, so nothing on the LAN or the internet can reach it directly.
Expose it to your tailnet (and nothing else) via Tailscale Serve:

    make serve         # tailscale serve --bg 3000  ->  https://<mini>.<tailnet>.ts.net/
    make serve-status  # show the exact URL
    make unserve       # stop sharing

Prereqs: Tailscale installed and logged in on the mini, and HTTPS/MagicDNS enabled for the
tailnet. `serve` is tailnet-private — we never use `funnel` (which is public). On macOS the
`tailscale` CLI may need `sudo` unless you've run `tailscale set --operator=$(whoami)`.

### Point DNS at the mini

**eero app → Settings → Network Settings → DNS**:

| | value |
|---|---|
| primary   | the mini's reserved IP (`192.168.7.24`) |
| secondary | `1.1.1.1` |

Renew device leases (or reboot them) to pick up the new resolver.

## Common tasks

    make status     # launchd state + confirm :53 is owned by _adguardhome, not root
    make logs       # tail the service log (agh.log / agh.err)
    make update     # after bumping AGH_VERSION at the top of the Makefile
    make restart
    make uninstall  # remove daemon, keep data
    make purge      # also delete /usr/local/AdGuardHome

## Verify it is NOT running as root

    make status
    # the :53 listener must show USER = _adguardhome

## Vars (override on the command line)

| var | default | meaning |
|-----|---------|---------|
| `AGH_VERSION` | `v0.107.77` | pinned release |
| `PREFIX` | `/usr/local/AdGuardHome` | install + working dir |
| `SVC_USER` | `_adguardhome` | unprivileged service account |
| `SVC_UID` / `SVC_GID` | `450` | pick a free id if it's taken |
