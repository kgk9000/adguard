# adguard

Minimal-privilege [AdGuard Home](https://github.com/AdguardTeam/AdGuardHome)
deployment for the always-on Mac mini — network-wide DNS ad/tracker blocking
behind the eero (single-NAT), managed as code.

## Design

- Runs as a **dedicated unprivileged launchd daemon** (`_adguardhome`), **never root**.
  macOS lets a non-root process bind port 53, so there's no `setcap`, no port-redirect,
  and no reason to grant root — the canned `AdGuardHome -s install` (which installs a
  *root* daemon) is deliberately **not** used. AGH's broken first-launch "must be admin"
  check (it assumes Linux privileged-port rules) is sidestepped by shipping a **seed config**
  so it never thinks it's first-run; `--no-permcheck` then skips its steady-state file-perm
  migration (which would otherwise want root ownership). Binding works — macOS permits it.
- `KeepAlive` → launchd relaunches the process within seconds if it dies. That's our
  process-level failover (a restart keeps blocking, vs. leaking unfiltered queries).
- Whole-mini outage is covered separately by **secondary DNS = `1.1.1.1` on the eero**:
  clients fall back after a timeout. We accept the occasional unfiltered query — there's
  no second machine to act as a blocking secondary.
- Release is **pinned and checksum-verified**; `make update` bumps `AGH_VERSION`.
- The **admin UI binds to `127.0.0.1`** (loopback) — port 3000 is not open on any network,
  only reachable from on the mini. DNS listens on the LAN (`:53`); the admin panel does not.
- macOS's **app firewall** silently blocks incoming connections to the unsigned AGH daemon, so
  `:53` is unreachable on the LAN until the binary is allowlisted. `make firewall` (run by
  `make install`) does that via `socketfilterfw` — otherwise the eero's DNS forwards get
  dropped and clients fall back to the unfiltered secondary.
- The binary and runtime state are **not** committed (see `.gitignore`); the repo holds
  the Makefile, the launchd plist template, the seed `AdGuardHome.yaml`, and these docs.

## No wizard — seed config (read this)

AGH decides "first run" purely by whether `AdGuardHome.yaml` exists (literally one `os.Stat`).
No file → it shows the install wizard *and* runs the broken first-launch admin check. So we
**skip the wizard entirely** by shipping a seed `AdGuardHome.yaml`. With the file present, AGH
never thinks it's first-run, never runs that check, and starts as `_adguardhome`.

AGH **rewrites that file at runtime** (filter counts, any UI change), so the committed copy is
the *bootstrap seed*, not a live mirror. `make config` only drops it in **when absent** — it
will not clobber a running config. To re-assert the repo version, delete the live file first.

## Deploy (run on the mini)

    git clone <this-repo> ~/adguard && cd ~/adguard
    make install      # create svc user, download+verify, seed config, install daemon, start

`make install` will prompt for `sudo` (service user, LaunchDaemon, config). The AdGuard Home
**process** that results is unprivileged.

**There is no wizard.** `make install` seeds `AdGuardHome.yaml`, so AGH comes straight up
serving DNS on **`:53`** (all interfaces), admin UI on **`127.0.0.1:3000`** (loopback), with the
upstreams (`1.1.1.1`/`9.9.9.9`) and a blocklist baked into the seed. Tweak those in the
dashboard, or by editing the seed, afterward.

### Admin UI access (remote)

Port 3000 is loopback-bound — not open on any network, only reachable from on the mini. To
administer it remotely, get *inside* the mini and use its loopback; don't open the port. The
simplest way is an SSH tunnel (the mini is reachable via Tailscale, which is just an
authenticated path *into* the machine — not a port you expose):

    # from your laptop:
    ssh -L 3000:localhost:3000 <you>@<mini>
    # then browse http://localhost:3000 on the laptop

3000 stays closed to the network the whole time.

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
