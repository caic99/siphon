# Siphon ⇢

A tiny native macOS menu bar app that points your traffic through an HTTP proxy —
and keeps pointing it there when the default route moves.

It replaces a shell script that had to be re-run by hand after every VPN connect
or drop.

## Features

- **Native everything**: an `NSStatusItem` with a real `NSMenu` — no Dock icon,
  no windows, no Electron. All state is read in-process through
  SystemConfiguration; the only subprocesses are the privileged writes.
- **Honest status**: the icon and header show what the system *is*, read back
  from SystemConfiguration after every write — never what the app assumed it set.
- **Follows the route**: when the default route moves — a VPN connecting, an
  Ethernet cable going in — the proxy is re-applied to whichever service now
  owns it. Turning the switch off clears every service Siphon proxied, so a
  stale proxy can't linger on Wi-Fi after you've moved to Ethernet.
- **Keeps your exception lists**: Siphon owns six keys (the HTTP and HTTPS
  enable flags, hosts, and ports) and carries the rest of each service's proxy
  dictionary through untouched — `ExceptionsList`, `ExcludeSimpleHostnames`,
  `FTPPassive`, SOCKS.
- **Won't stomp a proxy it didn't set**: if a service already has a different
  proxy enabled, automatic re-apply stops and says so. An explicit click still
  goes through.
- **No password surprises**: automatic re-apply runs only when passwordless
  `sudo` is available. Otherwise the menu bar icon turns orange and waits for
  a click, so an admin dialog never appears unprompted.
- **No hard-coded servers**: the menu lists the proxies already configured on
  this Mac, plus every one you have used or added under **Custom…** — so
  switching away from a server does not lose it.

## Build & run

Requires macOS 13+ and the Xcode command line tools.

```bash
./make-app.sh
open build/Siphon.app
```

The bundle is ad-hoc signed. To start Siphon at login, add it in
System Settings → General → Login Items.

## Scripting

Siphon keeps the shell script's scriptability. These run headlessly and exit:

```bash
Siphon --server H[:P]   # pick a proxy server; applies at once if already on
Siphon --on        # route the current service through the selected proxy
Siphon --off       # turn it off, here and on any service Siphon proxied
Siphon --toggle    # flip whichever way the current service is set
Siphon --probe     # report what Siphon sees; changes nothing
```

`--probe` is the first thing to reach for when the menu says something
surprising — it prints the resolved service, which store its proxies live in,
every key being preserved, the servers it discovered, and whether passwordless
sudo is available.

```bash
./build/Siphon.app/Contents/MacOS/Siphon --probe
```

## How it works

`State:/Network/Global/IPv4` names the service that owns the default route and
its interface, in one unprivileged read. Proxy settings are then read from — and
written to — whichever store that kind of service uses:

| Interface | Proxies live in | Written with |
|---|---|---|
| `utun*`, `ppp*`, `tun*`, `tap*` | `State:/Network/Service/<id>/Proxies` | `scutil` |
| everything else | `Setup:/Network/Service/<id>/Proxies` | `networksetup` |

VPN tunnels have no `networksetup` service, which is why they take the dynamic
store route. Both need root, so writes go through `sudo -n` when a sudoers rule
allows it and a native admin prompt otherwise. All the commands for one toggle
are issued as a single privileged task, so it asks at most once.

## Passwordless toggling

Automatic re-apply is deliberately limited to the passwordless path — a dialog
that appears while you're away from the keyboard is worse than a proxy that
waits. To grant it, add a scoped rule:

```bash
echo "$USER ALL=(root) NOPASSWD: /usr/sbin/scutil, /usr/sbin/networksetup" | sudo tee /etc/sudoers.d/siphon
```

Note what that grants: passwordless root for those two binaries, which is broad —
`scutil` can write anywhere in the dynamic store. Skip it if you'd rather type a
password per toggle; everything except unattended re-apply still works.

## Tests

```bash
swift test                        # unit tests, plus round-trips against real scutil and /bin/sh
SIPHON_ROOT_TESTS=1 swift test    # also exercises the privileged scutil write path
```

The privileged tests write to a dynamic-store key for a service ID that does not
exist and remove it afterwards, so nothing on the machine is affected. They need
passwordless sudo and are skipped without it.

## Verify

```bash
scutil <<< "show State:/Network/Global/Proxies"   # what the system is using
scutil <<< "show State:/Network/Global/IPv4"      # which service owns the route
```

## Notes

- HTTP and HTTPS only. PAC/auto-proxy URLs, SOCKS, and exception editing stay
  with `networksetup` and System Settings; Siphon owns one switch.
- Turning the proxy off clears the enable flags and leaves host and port in
  place, matching `networksetup -setwebproxystate off`.
- A proxy dictionary value containing a literal backslash can't be expressed in
  `scutil`'s command language. Siphon reports such keys rather than mangling
  them.

## License

MIT
