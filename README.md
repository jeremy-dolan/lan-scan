# lan-scan

See what's on the local network.

`lan-scan` discovers local devices via mDNS, SSDP, WS-Discovery, and an ARP
sweep, then enriches each device with UPnP device descriptions, HTTP banners,
NetBIOS NBSTAT, IPP Get-Printer-Attributes, reverse DNS, and a few
vendor-specific pokes (Roku, Philips Hue, ...). Results are browseable in a
curses TUI or can be printed to stdout; scans are cached for later review and
for highlighting differences between scans.

## Requirements

- Python 3 (standard library only!)
- Optional: `sudo` + `nmap` for active ARP sweep (see below)
- Optional: Internet access to download MAC address OUI database (one time)

## Usage

```bash
lan-scan                # interactively scan or review previous scans
lan-scan --print        # scan and print results to stdout (non-interactive)
lan-scan --help         # view all options
```

In the TUI: `↑` `↓` or `j` `k` to select, `ENTER` for device details, `?` for
help, `q` to quit. Devices new since the last saved run are highlighted in
green; devices missing since the last run are listed dimmed at the bottom.

Scans (and MAC OUI database) are cached under `~/.cache/lan-scan/`.

## How it works

lan-scan runs several discovery protocols against the local subnet, then
enriches each discovered host with follow-up probes. Each UDP multicast socket
joins its group (`IP_ADD_MEMBERSHIP`) and bounded-waits for replies. Multicast
on Wi-Fi is lossy, so each query is sent twice with a 0.3 s gap.

### Discovery

**mDNS / Bonjour / zeroconf** (UDP `224.0.0.251:5353`)  
Sends a `_services._dns-sd._udp.local` meta-query (asks every responder to list
all its advertised service types), plus a seed list of common types:
`_airplay._tcp`, `_raop._tcp` (AirPlay audio), `_hap._tcp` / `_homekit._tcp`
(HomeKit), `_googlecast._tcp`, `_spotify-connect._tcp`, `_printer._tcp`,
`_ipp._tcp`, `_smb._tcp`, `_afpovertcp._tcp`, `_ssh._tcp`, `_sftp-ssh._tcp`,
`_device-info._tcp`, `_sonos._tcp`, `_soco._tcp`, `_http._tcp`, `_https._tcp`.
Any service type the meta-query surfaces that wasn't pre-listed gets a follow-up
PTR query during the second half of the scan window. Used by Apple devices,
Chromecast, HomeKit accessories, AirPrint printers, most network speakers, and
anything implementing zeroconf.

**SSDP / UPnP discovery** (UDP `239.255.255.250:1900`)  
Sends `M-SEARCH * HTTP/1.1` (HTTP-over-UDP) with two STs: `ssdp:all` and
`upnp:rootdevice` (some devices only answer the narrower one). Replies carry a
`LOCATION` header pointing at an XML device description, which is HTTP-fetched in
the enrichment phase and rendered as a device/service tree in the detail popup.
SSDP itself is just the discovery leg of UPnP. Used by routers / IGDs, Sonos,
Roku, smart TVs, NAS boxes, media servers, and most "DLNA" gear.

**WS-Discovery** (UDP `239.255.255.250:3702`)  
Sends a SOAP-over-UDP `<Probe>` envelope. ProbeMatch responses carry qualified
Types (e.g. `tds:Device`) and XAddrs (HTTP endpoint URLs for follow-up SOAP
metadata queries — ONVIF `GetDeviceInformation`, etc.). Used by Windows Function
Discovery, ONVIF IP cameras, and most networked printers/scanners.

**ARP sweep** (link-layer, local subnet)  
Runs `sudo nmap -sn -PR <subnet>` to send an ARP request to every host on the
local subnet and capture who replies. Catches the large class of devices that
ignore all multicast (cheap IoT gadgets, smart plugs, doorbells) which sit
silently on the LAN until something polls them. Requires `nmap` and `sudo`
authorization; run `lan-scan --setup-sudoers` for passwordless setup; without
nmap and sudo authorization, lan-scan will skip the ARP sweep.

### Enrichment (per discovered host)

**UPnP device description** (HTTP GET on each SSDP `LOCATION` URL)  
Parses `<friendlyName>`, `<manufacturer>`, `<modelName>`, `<UDN>`, and the nested
`<deviceList>` / `<serviceList>` tree. Rendered as the hierarchical view in the
device-details popup.

**NetBIOS NBSTAT name query** (UDP 137)  
Returns the host's NetBIOS name list and workgroup/domain.

**HTTP banner grabs** (TCP 80, 8080, 8008, 631, 443, 8443)  
Connects, sends `GET /`, extracts the `Server:` header and HTML `<title>`.

**IPP Get-Printer-Attributes** (TCP 631)  
On hosts that look like printers, asks for make and model, admin info/location,
and live state. (Model is often the only identity source for printers that are
silent on mDNS.)

**Reverse DNS**  
Asks the configured resolver for a PTR record on each host's IP. Useful when DHCP
hands out a local DNS server for devices to coordinate names.

**Vendor-specific pokes** (Roku, Hue, ...)  
Triggered on hosts that look like a known vendor's gear (mDNS service type, OUI,
or SSDP model string). Roku ECP: `GET /query/device-info` on TCP 8060 for
friendly name / model / serial. Hue: `GET /api/config` on TCP 80 for bridge
metadata (model, firmware, API version, bridge ID, MAC).
