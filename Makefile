# AdGuard Home — minimal-privilege install for the always-on Mac mini.
# Runs as a dedicated UNPRIVILEGED launchd daemon (never root); KeepAlive auto-restarts it.
# Version is pinned and checksum-verified. `make update` bumps it.

AGH_VERSION ?= v0.107.77
PREFIX      ?= /usr/local/AdGuardHome
SVC_USER    ?= _adguardhome
SVC_UID     ?= 450
SVC_GID     ?= 450
ADMIN_PORT  ?= 3000

PLIST_LABEL := com.adguard.adguardhome
PLIST_DST   := /Library/LaunchDaemons/$(PLIST_LABEL).plist
WORK        := .work

# Auto-detect arch so this works on Apple Silicon or Intel.
ARCH := $(shell uname -m)
ifeq ($(ARCH),arm64)
GOARCH := arm64
else ifeq ($(ARCH),x86_64)
GOARCH := amd64
else
$(error unsupported architecture: $(ARCH))
endif

ASSET := AdGuardHome_darwin_$(GOARCH).zip
BASE  := https://github.com/AdguardTeam/AdGuardHome/releases/download/$(AGH_VERSION)
URL   := $(BASE)/$(ASSET)
CKURL := $(BASE)/checksums.txt

# Locate the tailscale CLI across the usual macOS spots: PATH, Homebrew (arm/intel),
# and the GUI/App Store app bundle. Override with `make serve TAILSCALE=/path`.
TS_CANDIDATES := $(shell command -v tailscale 2>/dev/null) \
                 /opt/homebrew/bin/tailscale \
                 /usr/local/bin/tailscale \
                 /Applications/Tailscale.app/Contents/MacOS/Tailscale
TAILSCALE     ?= $(firstword $(wildcard $(TS_CANDIDATES)))

.DEFAULT_GOAL := help

# Self-documenting: every target with a `## ` comment is listed automatically.
.PHONY: help
help: ## show this help
	@echo "AdGuard Home ($(AGH_VERSION), darwin/$(GOARCH))"
	@echo "vars: PREFIX=$(PREFIX) SVC_USER=$(SVC_USER) SVC_UID=$(SVC_UID)"
	@echo "tailscale: $(if $(TAILSCALE),$(TAILSCALE),NOT FOUND — install it or set TAILSCALE=)"
	@echo
	@grep -E '^[a-zA-Z_-]+:.*## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

.PHONY: fetch
fetch: # (internal) download + checksum-verify + unzip the pinned release
	@mkdir -p $(WORK)
	@echo ">> downloading $(ASSET) ($(AGH_VERSION), darwin/$(GOARCH))"
	curl -fSL -o $(WORK)/$(ASSET) $(URL)
	curl -fSL -o $(WORK)/checksums.txt $(CKURL)
	@echo ">> verifying checksum"
	@cd $(WORK) && grep "$(ASSET)" checksums.txt | shasum -a 256 -c -
	@cd $(WORK) && rm -rf AdGuardHome && unzip -oq $(ASSET)
	@echo ">> ok: $(WORK)/AdGuardHome/AdGuardHome"

.PHONY: service-user
service-user: # (internal) create the unprivileged _adguardhome account, idempotently
	@if dscl . -read /Users/$(SVC_USER) >/dev/null 2>&1; then \
	  echo ">> service user $(SVC_USER) already exists"; \
	else \
	  if dscl . -list /Users UniqueID | awk '{print $$2}' | grep -qx $(SVC_UID); then \
	    echo "!! UID $(SVC_UID) is taken — re-run with SVC_UID=<free id>"; exit 1; \
	  fi; \
	  echo ">> creating unprivileged service user $(SVC_USER) (uid $(SVC_UID))"; \
	  sudo dscl . -create /Groups/$(SVC_USER); \
	  sudo dscl . -create /Groups/$(SVC_USER) PrimaryGroupID $(SVC_GID); \
	  sudo dscl . -create /Users/$(SVC_USER); \
	  sudo dscl . -create /Users/$(SVC_USER) UniqueID $(SVC_UID); \
	  sudo dscl . -create /Users/$(SVC_USER) PrimaryGroupID $(SVC_GID); \
	  sudo dscl . -create /Users/$(SVC_USER) UserShell /usr/bin/false; \
	  sudo dscl . -create /Users/$(SVC_USER) RealName "AdGuard Home"; \
	  sudo dscl . -create /Users/$(SVC_USER) NFSHomeDirectory /var/empty; \
	  sudo dscl . -create /Users/$(SVC_USER) Password '*'; \
	fi

.PHONY: plist
plist: # (internal) render the LaunchDaemon plist and install it
	@echo ">> rendering $(PLIST_DST)"
	@mkdir -p $(WORK)
	@sed -e 's#@BIN@#$(PREFIX)/AdGuardHome#g' \
	     -e 's#@WORKDIR@#$(PREFIX)#g' \
	     -e 's#@USER@#$(SVC_USER)#g' \
	     com.adguard.adguardhome.plist.in > $(WORK)/$(PLIST_LABEL).plist
	sudo install -m 0644 -o root -g wheel $(WORK)/$(PLIST_LABEL).plist $(PLIST_DST)

.PHONY: install
install: service-user fetch plist ## create svc user, download+verify, install daemon, start
	@echo ">> installing binary to $(PREFIX)"
	sudo mkdir -p $(PREFIX)
	sudo cp $(WORK)/AdGuardHome/AdGuardHome $(PREFIX)/AdGuardHome
	sudo chmod 0755 $(PREFIX)/AdGuardHome
	sudo chown -R $(SVC_USER):$(SVC_GID) $(PREFIX)
	@echo ">> loading daemon"
	sudo launchctl load -w $(PLIST_DST)
	@echo ">> done — open the setup wizard at http://<mini-ip>:3000"

.PHONY: update
update: fetch ## download+verify pinned version, swap binary, restart
	@echo ">> swapping binary to $(AGH_VERSION)"
	-sudo launchctl unload -w $(PLIST_DST)
	sudo cp $(WORK)/AdGuardHome/AdGuardHome $(PREFIX)/AdGuardHome
	sudo chown $(SVC_USER):$(SVC_GID) $(PREFIX)/AdGuardHome
	sudo chmod 0755 $(PREFIX)/AdGuardHome
	sudo launchctl load -w $(PLIST_DST)
	@echo ">> updated — verify with: make status"

.PHONY: start
start: ## load (start) the daemon
	sudo launchctl load -w $(PLIST_DST)

.PHONY: stop
stop: ## unload (stop) the daemon
	sudo launchctl unload -w $(PLIST_DST)

.PHONY: restart
restart: stop start ## restart the daemon

.PHONY: status
status: ## launchd state + what's listening on :53
	@echo "--- launchd ---"
	@sudo launchctl list | grep $(PLIST_LABEL) || echo "(not loaded)"
	@echo "--- :53 listeners (USER should be $(SVC_USER), never root) ---"
	@sudo lsof -nP -iUDP:53 -iTCP:53 || echo "(nothing on :53)"

.PHONY: logs
logs: ## tail the service log (agh.log / agh.err)
	@tail -n 80 -f $(PREFIX)/agh.log $(PREFIX)/agh.err

# Bind the admin UI to 127.0.0.1 in the AGH wizard, then `serve` it to the tailnet only.
# `serve` = private (tailnet); `funnel` = public — we never funnel.
.PHONY: _need-tailscale
_need-tailscale: # (internal) fail clearly if the tailscale CLI wasn't found
	@test -n "$(TAILSCALE)" || { \
	  echo "!! tailscale CLI not found in PATH, Homebrew, or /Applications/Tailscale.app"; \
	  echo "   install it, or run: make $(MAKECMDGOALS) TAILSCALE=/full/path/to/tailscale"; \
	  exit 1; \
	}
	@echo ">> using tailscale: $(TAILSCALE)"

.PHONY: serve
serve: _need-tailscale ## expose the (loopback) admin UI to the tailnet only, https, persistent
	$(TAILSCALE) serve --bg $(ADMIN_PORT)
	@echo ">> admin UI shared on the tailnet — URL via: make serve-status"

.PHONY: serve-status
serve-status: _need-tailscale ## show tailscale serve config + the tailnet URL
	$(TAILSCALE) serve status

.PHONY: unserve
unserve: _need-tailscale ## stop sharing the admin UI on the tailnet
	$(TAILSCALE) serve reset

.PHONY: uninstall
uninstall: ## stop + remove daemon (keeps data)
	-sudo launchctl unload -w $(PLIST_DST)
	-sudo rm -f $(PLIST_DST)
	@echo ">> daemon removed (data kept in $(PREFIX)). Run 'make purge' to delete it."

.PHONY: purge
purge: uninstall ## uninstall + delete the install dir
	-sudo rm -rf $(PREFIX)
	@echo ">> removed $(PREFIX). To also delete the service user:"
	@echo "   sudo dscl . -delete /Users/$(SVC_USER); sudo dscl . -delete /Groups/$(SVC_USER)"
