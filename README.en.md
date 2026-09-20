# koreader-easytier

**English** | [简体中文](README.md)

Control a standalone [EasyTier](https://github.com/EasyTier/EasyTier) mesh-VPN node from a
[KOReader](https://github.com/koreader/koreader)-powered e-reader (Kindle, Kobo, PocketBook):
start/stop, configure, and inspect peers and routes.

The plugin does **not** embed EasyTier. It starts and stops the `easytier-core` process, turns your
settings into its command line, and shows node state — TUN devices, privileges and architecture stay on
EasyTier's side. Think of it as a remote control.

## Features

* One-tap **start / stop** in the menu; the checkbox reflects whether the process is really alive, and the label shows its PID
* **Settings**: network name / secret, initial nodes, DHCP or a fixed IP, shared subnets, listeners,
  port forwards, RPC portal, hostname / instance name, TUN interface, MTU, default protocol, log level,
  extra arguments, binary directory
* **Four pages**: status (`node info` / `peer` / `route`), runtime log, environment diagnostics, and KOReader's `crash.log`
* **Automation**: start with KOReader, start after Wi-Fi connects, restart automatically if the process dies
* **Gestures and profiles**: four actions (toggle / start / stop / status)
* **Kindle niceties**: opens the Kindle firewall for the tunnel interface on start and removes the rule on stop

The UI follows KOReader's language: English is the source language, Chinese is translated automatically.

## Requirements

* A jailbroken Kindle, Kobo or PocketBook with KOReader installed (on Kindle, KOReader runs as root —
  that is what makes TUN, routing and iptables possible)
* Another machine running an EasyTier node with the same network name and secret, or a public shared node
* EasyTier binaries (not bundled): take `easytier-core` and `easytier-cli` out of the official
  `easytier-linux-armv7-*.zip` and put them in `/mnt/us/easytier/bin/`

## Installation

1. Download `easytier.koplugin.zip` from the [latest release](https://github.com/WanderSu/koreader-easytier/releases/latest) and unzip it
2. Copy `easytier.koplugin/` into KOReader's `plugins/` directory (on Kindle: `/mnt/us/koreader/plugins/`)
3. Put `easytier-core` and `easytier-cli` in place as described above — `tools/prepare-device.sh`
   downloads and lays them out for you
4. Restart KOReader

## Usage

Menu **Network → EasyTier mesh networking**:

1. **Settings → Network name / Network secret**: every node in the network must use exactly the same values
2. **Initial node**: the address to connect to on start, comma separated. This can be your own node or a
   public shared node such as `tcp://public.easytier.top:11010`
3. **Node IP**: leaving DHCP on is easiest; turn it off to set something like `10.144.144.x` yourself
4. Tap **Start EasyTier**, then open **Status** to see `peer` and `route`

When more than one device joins, use the same network name/secret **and the same initial node list** on all of them.

### Two run modes

| Mode | What it does | When to use |
| --- | --- | --- |
| **TUN** (default) | Creates a virtual interface and routes the whole device by virtual IP | Devices with `/dev/net/tun`; KOReader's OPDS, Calibre and sync can use virtual IPs directly |
| **Proxy** | `--no-tun` + SOCKS5, no virtual interface | Kernels without TUN support; point an app's SOCKS5 proxy at `127.0.0.1:<port>` |

Port forwarding works in both modes and needs no proxy support at all: map a service from the virtual
network onto a local port and reach it at `127.0.0.1:<local port>` — handy for Calibre/OPDS on your LAN.

### Troubleshooting

| Symptom | What to do |
| --- | --- |
| `easytier-core` not found | Follow the directory list in **Tools → Installation**, or point **Advanced → Binary directory** at the right place |
| It will not start | **Tools → View log** shows the last lines; **Tools → Run diagnostics** dumps environment, architecture, binaries and kernel TUN support in one go |
| Connected, but nothing is reachable | ① check `peer` / `route` in Status; ② check the firewall rule shows as applied; ③ reaching the other side's LAN also needs that side to share its subnets |
| No `/dev/net/tun` | Switch to **Proxy** mode, or map what you need with a port forward |
| Peers show the wrong name | Peers see the **hostname** (`--hostname`), not the instance name; neither may contain spaces |
| It keeps running after I quit KOReader | By design: `easytier-core` is an independent process and quitting KOReader does not kill it. Use **Stop EasyTier** in the menu to stop it |
| I do not want it to auto-start | Turn off **Automation → Start EasyTier with KOReader** — that switch alone decides whether KOReader starts it on launch |

## Compatibility

| Device | Status |
| --- | --- |
| Kindle Paperwhite 6 (armv7l, firmware 5.19) | Verified: mesh, status, log and diagnostics pages work |
| Other Kindle / Kobo / PocketBook | Untested. Needs a Linux-based device that runs KOReader and has `/dev/net/tun` |
| Devices without TUN | Use **Proxy** mode or port forwarding |

EasyTier's official Linux armv7 build is a statically linked 32-bit ARM binary with no extra library
dependencies, so it runs straight from the device's user partition.

## License and credits

* This plugin is released under **AGPL-3.0**, see `LICENSE`.
* [EasyTier](https://github.com/EasyTier/EasyTier) is an independent LGPL-3.0 project. This plugin
  contains no EasyTier code and only drives the `easytier-core` / `easytier-cli` binaries you provide.
* The plugin API usage is modelled on KOReader's own SSH and KeepAlive plugins.

## Development

```bash
tests/run-all.sh [path/to/easytier-core]     # unit tests, no KOReader required
python tools/i18n_extract.py --missing       # list strings missing from et_i18n.lua
python tools/i18n_apply.py                   # apply the et_i18n.lua table to the sources
```

* UI strings are English by default (gettext msgids); the Chinese table lives in `easytier.koplugin/et_i18n.lua`
* The plugin only emits long CLI options, verified one by one against EasyTier **v2.6.4** sources;
  re-check them before bumping the supported EasyTier version
