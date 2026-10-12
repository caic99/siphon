#!/bin/sh
# Stands in for `ssh -N -D 127.0.0.1:PORT ... target` in tests: serves SOCKS5 on
# PORT like a real dynamic forward would. A target of "fail-host" exits like
# ssh does when it cannot connect; "slow-host" delays binding to exercise the
# readiness timeout.
port=""; target=""
while [ $# -gt 0 ]; do
  case "$1" in
    -D) port="${2##*:}"; shift 2 ;;
    -o|-p|-i|-l) shift 2 ;;
    -*) shift ;;
    *) target="$1"; shift ;;
  esac
done
case "$target" in
  fail-host) echo "ssh: connect to host fail-host port 22: No route to host" >&2; exit 255 ;;
  slow-host) sleep 20 ;;
esac
exec /usr/bin/python3 "$(dirname "$0")/socks5-server.py" "$port"
