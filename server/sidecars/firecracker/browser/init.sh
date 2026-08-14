#!/bin/sh
set -eu

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mkdir -p /dev/shm /run/browser-service /tmp /data/.cache/fontconfig
mount -t tmpfs -o mode=1777,size=256m tmpfs /dev/shm
mount -t tmpfs -o mode=1777,size=128m tmpfs /tmp
chown -R 65534:65534 /data
chown 65533:65533 /run/browser-service
/usr/bin/busybox ip link set lo up

if [ -e /sys/class/net/eth0 ]; then
  /usr/bin/busybox ip link set eth0 up
  /usr/bin/busybox ip addr add 172.30.0.2/24 dev eth0
  /usr/bin/busybox ip route add default via 172.30.0.1 dev eth0
  /usr/bin/busybox rm -f /etc/resolv.conf
  printf 'nameserver 1.1.1.1\nnameserver 1.0.0.1\n' >/etc/resolv.conf
fi

/usr/bin/setpriv --reuid 65534 --regid 65534 --clear-groups \
  /usr/bin/env HOME=/data XDG_CACHE_HOME=/data/.cache \
  /headless-shell/headless-shell \
  --headless \
  --no-sandbox \
  --no-first-run \
  --no-default-browser-check \
  --block-new-web-contents \
  --disable-background-networking \
  --disable-component-update \
  --disable-default-apps \
  --disable-domain-reliability \
  --disable-extensions \
  --disable-sync \
  --disable-features=OptimizationHints \
  --metrics-recording-only \
  --mute-audio \
  --use-gl=angle \
  --use-angle=swiftshader \
  --remote-debugging-address=127.0.0.1 \
  --remote-debugging-port=9222 \
  --user-data-dir=/data \
  about:blank &
browser_pid=$!

/opt/browser/bridge &
bridge_pid=$!

shutdown() {
  kill "$browser_pid" "$bridge_pid" 2>/dev/null || true
  set +e
  wait "$browser_pid" 2>/dev/null
  wait "$bridge_pid" 2>/dev/null
}
trap shutdown EXIT INT TERM

while kill -0 "$browser_pid" 2>/dev/null && kill -0 "$bridge_pid" 2>/dev/null; do
  /usr/bin/busybox sleep 1
done

exit 125
