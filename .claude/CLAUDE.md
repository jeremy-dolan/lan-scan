# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`lan-scan` is a single self-contained Python 3 executable (stdlib only,
no third-party packages) that discovers and enriches devices on the local network and
presents them in a curses TUI. There is no build step, no dependency install, no test
suite, and no linter config — edit the script and run it.

## Running

```
Usage: lan-scan [OPTIONS]

Options:
  -h, --help          Show this help and exit.
  --new-scan          Run a new scan in the TUI (skips the new/previous prompt).
  --load-previous     Load the previously-saved scan in the TUI (skips the
                      prompt). Exits 1 if there is no saved scan.
  --print             Run a scan and print results to stdout (no TUI, no
                      interactive prompt). Saves the run like the TUI does.
  --print-previous    Print the previously-saved scan (no scan, no TUI, no
                      save). Exits 1 if there is no saved scan.
  --setup-sudoers     Print the sudoers entry needed for passwordless ARP
                      discovery via nmap.

Default (no options): interactive prompt for new scan vs. load previous, then
the curses TUI.
```

These are mutually exclusive (`_MODE_FLAGS`).

### Driving / testing the TUI headlessly
There is a project skill, **`run-lan-scan`** (`.claude/skills/run-lan-scan/`), for
exercising the app without a live scan. Its `smoke.sh` launches the TUI under tmux in
review mode (`--load-previous`), walks list → detail popup → help popup, and dumps each
screen to a text file (the headless equivalent of a screenshot). Use it for any UI change.
A live scan can't run in a sandbox (sudo needs a tty, multicast needs a real LAN), so the
skill always replays a saved run. The skill doc also shows how to import the script as a
module (it imports cleanly — everything is gated under `if __name__ == "__main__"`) to call
pure functions like `resolve_name` / `resolve_device_kind` / the IPP and packet parsers
directly.

### External runtime dependencies (all optional/degrading)
- **`nmap`** — used for the active ARP sweep (`sudo -n nmap -sn -PR -oG - <subnet>`).
  Missing nmap or unconfigured sudo just skips that one stage; the multicast scans
  still run. `--setup-sudoers` prints the exact NOPASSWD entry.
- **`arp`** command — reads the kernel ARP cache for MAC addresses.
- **Wireshark `manuf` file** — downloaded once on first run to `~/.cache/lan-scan/manuf`
  for MAC→vendor OUI lookups; falls back to a small built-in table if the download fails.

### Sudoers entry is now subnet-agnostic (regex)
The NOPASSWD recipe no longer hardcodes a subnet. `ARP_SUDOERS_ARGS` is a **regex** that
matches `-sn -PR -oG - <any-IPv4>/<prefix>`, so the emitted sudoers line keeps working when
the network changes — no regeneration needed. This relies on sudo's command-arg regex
matching, which requires **sudo >= 1.9.10**. `ARP_SUDOERS_ARGS` **must stay in sync with the
exact command `discover_arp` runs** (and with the recipe-matching in
`_arp_requires_sudo_passwd_auth`) — change one, change all three.

### ARP sweep window for wide subnets
For masks wider than `ARP_SWEEP_MAX_PREFIX`, the sweep targets a bounded window around the
local IP instead of the full range — sweeping a campus-sized subnet is pointless (almost
nothing is reachable at layer 2) and slow. See `_arp_sweep_subnet` / `_get_local_prefixlen`.

### Cache / persistence
Everything lives under `~/.cache/lan-scan/`: the `manuf` OUI database and `history/*.json`
(one file per run, ISO-8601 timestamp filename, pruned to `HISTORY_MAX=50`). Each scan is
saved so the next scan can diff against it and review mode can rehydrate the exact display.

## Architecture

Three layers in one file: the `Device` data model, the `NetworkDiscovery` engine, and the
`CursesUI` presenter, wired together by `main()`.

### `Device` and the "each source writes only its own field" rule
This is the central design constraint. A device's identity is assembled from many
independent, often-contradictory sources (mDNS, SSDP, UPnP XML, NetBIOS, HTTP banners,
vendor APIs, reverse DNS). To avoid sources clobbering each other, **`Device` stores a
separate field per source** (e.g. `mdns_a_name`, `upnp_friendly_name`, `roku_friendly_name`,
`netbios_name`) and never merges them at write time. The display name and device-kind are
chosen at *render* time by `resolve_name()` and `resolve_device_kind()`, which apply a
documented priority order over those fields. When adding a new data source, give it its own
`Device` field and slot it into the priority ladder in those two resolvers — do not overwrite
an existing field. `_manufacturer_is_redundant()` is a guard used during kind resolution so a
device isn't labeled e.g. "Philips Philips Hue" when the manufacturer name is already a
prefix of the model.

Services are likewise kept per-source (`ssdp_services`, `mdns_services`, `wsd_services`) so
identical short names from different protocols don't collide; `Device.services` is the merged
read-only view.

### `NetworkDiscovery` — the engine (asyncio)
`discover()` orchestrates the whole pipeline and is the entry point. Two phases:

1. **Discovery** (run concurrently via `asyncio.gather`): `discover_mdns`, `discover_ssdp`,
   `discover_wsd` (three UDP multicast scans that accrue devices into `self.devices` as
   packets arrive), plus `discover_arp` (the external nmap sweep that lands all at once).
2. **Enrichment** (sequential, each operates on already-discovered devices):
   `fetch_device_descriptions` (UPnP XML), `enrich_wsd` (DPWS WS-Transfer Get against the
   `wsd_xaddrs` collected during discovery, for ThisModel/ThisDevice metadata),
   `populate_mac_addresses`, `enrich_roku` (Roku ECP), `enrich_hue` (Philips Hue
   `/api/config`), `enrich_netbios`, `enrich_http_banners`, `enrich_ipp` (IPP
   `Get-Printer-Attributes` on port 631, runs after the banner probe so it can use
   the open-631 signal), `populate_rdns`.

Progress is reported through an `on_progress(msg, key, final)` callback so the same engine
drives both the live curses ticker and plain `--print` stdout. `key` lets a consumer rewrite
a stage's line in place; `final` marks the settled value (plain stdout prints only finals).

HTTPS/ipps probes (the 443/8443 banner grab, plus WSD and IPP over TLS) all go through
`_unverified_tls_context()`, which **deliberately disables cert verification** — LAN devices
ship self-signed certs with mismatched hostnames, and we only read public metadata — and
imports `ssl` lazily so a Python build compiled without it still runs (TLS probes just fail
closed). Don't "fix" either of those. IPP is the one binary application protocol here:
`_build_ipp_get_printer_attributes` / `_parse_ipp_response` hand-roll the RFC 8010 encoding,
in the same struct-based style as the mDNS and NetBIOS packet builders.

Diffing: `apply_diff()` marks devices absent from the previous run as `is_new` and records
`missing_devices` (present last time, gone now). `load_from()` rehydrates a saved run for
review mode. A diff only runs when the saved run's subnet matches the current subnet.

### `CursesUI` — the presenter
`run(stdscr)` drives discovery (or loads a cached run in review mode), then a modal event
loop: a device list, a scrollable per-device detail popup (ENTER), and a help popup (`?`).
The detail popup ends with a probe-status section (`_format_probe_status`) summarizing which
enrichment probes ran / found something for that device. Review mode (`review_timestamp`
set) skips the live scan and the post-scan diff. The UI never mutates discovery state —
counters are pure display sugar.

**Rendering is double-buffered to avoid flicker.** Draw methods (`_draw_list`, `_draw_detail`,
`_draw_help`) use `stdscr.erase()` (not `clear()`) and stage with `stdscr.noutrefresh()` (not
`refresh()`); the event loop flushes once per frame with `curses.doupdate()`. This stages the
list and any popup into the virtual screen and lets curses compute a minimal diff, instead of
blanking and repainting on every scroll keystroke. Keep new drawing on this stage-then-flush
pattern — don't sprinkle in `refresh()`/`clear()`.

### `main()` — dispatch and the sudo/curses ordering constraint
Anything that prints to a cooked terminal (the `manuf` download, the interactive sudo
authorization prompt) **must happen before curses takes over the screen**. Hence the startup
menu can return `'scan_after_prompt'`: it bails out of curses so `check_and_authorize_sudo`
can prompt in cooked mode, then re-enters a fresh `curses.wrapper` to run the scan. Sudo
authorization is deferred until the user actually chooses "New scan" so reviewing past scans
never prompts.

Whether to prompt at all is decided silently by `_arp_requires_sudo_passwd_auth()` (no
prompt when nmap is missing, no subnet, creds already cached, or the NOPASSWD recipe is
installed). One non-obvious trap, called out there: don't probe with `sudo -l <cmd>` — it
only echoes the matching policy line, it doesn't evaluate whether the command would run.
