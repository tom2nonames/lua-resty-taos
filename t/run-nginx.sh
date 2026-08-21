#!/usr/bin/env bash
# Run the test::nginx suite (needs an OpenResty nginx binary and
# Test::Nginx::Socket).  Example:
#
#     ./t/run-nginx.sh
#
# Override the nginx binary with TEST_NGINX_BINARY.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if ! command -v nginx >/dev/null 2>&1 && [ ! -x /usr/local/openresty/nginx/sbin/nginx ]; then
    echo "error: no nginx (OpenResty) binary found on PATH" >&2
    echo "hint: PATH=/usr/local/openresty/nginx/sbin:\$PATH ./t/run-nginx.sh" >&2
    exit 2
fi

export TEST_NGINX_BINARY="${TEST_NGINX_BINARY:-$(command -v nginx || echo /usr/local/openresty/nginx/sbin/nginx)}"

exec prove -v "$ROOT"/t/*.t
