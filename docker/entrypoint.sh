#!/usr/bin/env bash
# Entrypoint for the lua-resty-taos test container:
#   1. pin the container hostname to loopback so taosd can resolve its FQDN
#   2. start taosd (TDengine server) in the background
#   3. wait until the server accepts connections
#   4. start nginx (with the test endpoints) in the foreground
set -e

# --- 1. FQDN pinning -------------------------------------------------------
# TDengine 2.4 resolves its own FQDN from the hostname; inside a container
# the hostname is not resolvable.  Rewrite /etc/hosts so the hostname maps
# to loopback (taosd will then bind 127.0.0.1:6030).  Note: /etc/hosts is a
# bind mount, so `sed -i` (which renames) fails; rewrite the file instead.
HOST="$(hostname)"
{
    echo "127.0.0.1 localhost"
    echo "::1 localhost ip6-localhost ip6-loopback"
    echo "127.0.0.1 ${HOST}"
} > /etc/hosts

# --- 2. start taosd --------------------------------------------------------
mkdir -p /var/lib/taos /var/log/taos
taosd >/var/log/taos/taosd.console.log 2>&1 &

# --- 3. wait for the server ------------------------------------------------
ready=0
for i in $(seq 1 60); do
    if taos -s "show databases" >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 1
done
if [ "$ready" != "1" ]; then
    echo "taosd did not become ready in time; last log lines:" >&2
    tail -20 /var/log/taos/taosd.console.log >&2 || true
    exit 1
fi
echo "taosd is ready (127.0.0.1:6030)"

# --- 4. nginx in the foreground --------------------------------------------
exec /usr/local/openresty/nginx/sbin/nginx -g 'daemon off;'
