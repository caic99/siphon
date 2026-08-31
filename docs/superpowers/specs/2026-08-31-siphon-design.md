# Siphon — tray-only proxy toggle

**Date:** 2026-08-31
**Replaces:** `~/Documents/tunnelmux/toggle-vpn-proxy.sh` (which stays in place, untouched)

## Problem

`toggle-vpn-proxy.sh` flips the HTTP/HTTPS proxy on whichever network service owns
the default route. It works, but it has to be run from a terminal, it reports state
only as stdout prose, and it must be re-run by hand after every network change — the
default route moves whenever the VPN connects or drops.

It also has a bug. On the VPN path it rebuilds the service's `Proxies` dictionary
with `d.init` … `set`, which replaces the dictionary wholesale and discards every
key it does not write: `ExceptionsList`, `ExcludeSimpleHostnames`, `FTPPassive`,
`SOCKS*`. Real services on this Mac carry all of those.

## Goals

- A menu bar app with no Dock icon and no windows, in the shape of Espresso.
- Live, honest status: the icon and menu show what the system *is*, never what the
  app assumes it set.
- Re-apply the proxy automatically when the default route moves.
- Choose between proxy servers without editing anything.
- Preserve every proxy key the app does not own.
- No site-specific hostname anywhere in the repository.

## Non-goals

- PAC / auto-proxy URLs, SOCKS, and per-service exception editing. `networksetup`
  and System Settings already do those; Siphon owns one switch.
- Replacing the shell script. It stays for scripted use.

## Architecture

Reads run in-process through SystemConfiguration; only writes need root, and those
shell out to the same commands the script used.

```
Sources/SiphonCore/          no AppKit, fully testable
  ProxyServer.swift          host+port value type, parsing, validation
  ProxyDictionary.swift      Proxies dict model + scutil command encoder
  NetworkState.swift         primary service, proxy reads, server discovery
  NetworkMonitor.swift       SCDynamicStore watcher, debounced
  Privilege.swift            sudo -n -> admin-prompt fallback, shell/AppleScript quoting
  ProxyPolicy.swift          pure decision function: state -> plan
  ProxyController.swift      persisted desired state, applies plans, tracks touched services
Sources/Siphon/              AppKit only
  main.swift                 NSApplication bootstrap, .accessory policy
  AppDelegate.swift          NSStatusItem, NSMenu, header row, actions
```

### Reading state

`State:/Network/Global/IPv4` yields `PrimaryService` (a UUID) and `PrimaryInterface`
in one unprivileged read — replacing the script's `route -n get default` plus its
scan of every service's IPv4 key. The service's display name comes from
`Setup:/Network/Service/<id>` → `UserDefinedName`, falling back to the interface
name. This is more correct than the script's hardware-port lookup: it picks the
service that actually owns the route, and it is the name `networksetup` expects.

Proxy state is read from `State:/…/Proxies` for tunnel interfaces
(`utun*`, `ppp*`, `tun*`, `tap*`) and `Setup:/…/Proxies` for physical ones —
the same split the script uses for writes.

### Writing state

- Tunnel: `sudo scutil`, fed the dictionary language on stdin. The dictionary is
  read first and re-emitted with only the six HTTP/HTTPS keys changed.
- Physical: `sudo networksetup -setwebproxy` / `-setsecurewebproxy` (and the
  `…state off` pair to disable), which touch only the web-proxy keys.

`scutil`'s `d.add` accepts double-quoted values and honours `\"`, so values
containing spaces round-trip. A literal backslash has no escape; keys whose values
contain one are reported as unpreservable rather than silently mangled.

### Privileges

`sudo -n` first — silent when a sudoers rule exists. Otherwise a native admin prompt
via `osascript … with administrator privileges`. Multiple commands are issued as one
privileged task so a single toggle never asks twice.

Automatic re-apply runs **only** when `sudo -n` works. A password dialog must never
appear unprompted, so without passwordless sudo the app marks the state pending
(orange menu bar tint) and waits for a click.

### State model

Three facts, never conflated:

| Fact | Source |
|---|---|
| `desired` | UserDefaults — the switch position the user chose |
| `actual` | read live from SystemConfiguration |
| `primary` | current default-route service, or none |

The UI always renders `actual`. When `desired` is on and `actual` is off, the header
says so and offers the fix.

### Re-apply policy

`ProxyPolicy.plan` is pure and covers the whole matrix:

- Already matching the selected server → nothing to do.
- Off, and we want it on → write (or await a click when sudo would prompt).
- On with a *different* host, on a service Siphon has not touched → refuse to
  overwrite automatically; report the foreign host. An explicit click overrides.
- Switch turned off → clear every service Siphon proxied, not just the current one,
  so a stale proxy cannot linger on Wi-Fi after the route moved to Ethernet.

Touched services are persisted as `{serviceID, name, isTunnel}` so they can be
cleared later without re-deriving an interface that may be gone.

Network-change callbacks are debounced 1.5 s; interface-up, address, and DNS
changes arrive as a burst.

### Server list

Nothing is hard-coded. At launch Siphon reads every
`(State|Setup):/Network/Service/<id>/Proxies` key plus `State:/Network/Global/Proxies`
and offers each configured `host:port` it finds, merged with servers the user has
added via **Custom…**. Selection and custom entries persist in UserDefaults. This
keeps site-specific hostnames out of the source while still working on first launch.

## Menu

```
  ⇢  Proxy On — proxy.example.com:3128
     USB 10/100/1000 LAN (en7)
  ─────────────────────────────────────
  Turn Proxy Off                     ⌘P
  ─────────────────────────────────────
  Proxy Server
    ✓ proxy.example.com:3128
      Custom…
  ─────────────────────────────────────
  ✓ Re-apply on Network Change
  ─────────────────────────────────────
  Quit Siphon                        ⌘Q
```

## Error handling

- No default route → header "No Network", toggle disabled.
- No server chosen → toggle disabled, header points at **Custom…**.
- Cancelled admin dialog → no state change, no alert. The user said no.
- Command failure → alert carrying the command's real stderr; `desired` unchanged.
- After every write the state is re-read and rendered, so a failed write is visible
  rather than assumed.

## Testing

`swift test` over `SiphonCore`:

- shell and AppleScript quoting, including embedded quotes and single quotes
- `ProxyDictionary` parsing: strings, numbers, arrays, dropped unrepresentable keys
- the `scutil` encoder: ordering, quoting, numeric and array forms
- `enabling` / `disabled` preserve unrelated keys
- interface classification and `proxyKey` selection
- `ProxyServer.parse` accept/reject cases
- `ProxyPolicy.plan` across the full matrix, both triggers

AppKit and the SystemConfiguration bridges stay thin and untested — the same
boundary Espresso draws.

## Build

`./make-app.sh` → `build/Siphon.app`, `LSUIElement`, ad-hoc signed, version from
`git describe`. Identical to Espresso and PostureGuard.
