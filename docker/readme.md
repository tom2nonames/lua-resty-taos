# Test environment

`docker-compose.yaml` builds and runs a **real** test environment:

* TDengine **2.4.0.12** server (`taosd`) compiled from source (the release
  tag ships no prebuilt packages), and
* OpenResty 1.21.4.1 with this driver, exposing test endpoints over HTTP.

One container runs both, so the driver talks to a genuine TDengine server
on `127.0.0.1:6030`.

```bash
# build (compiles TDengine from source; takes a while) and start
docker compose up --build -d

# HTTP smoke test through the driver (create db/table, insert, select)
curl http://127.0.0.1:8080/test

# client + server versions
curl http://127.0.0.1:8080/version

# run the project's own integration test script inside the container
docker compose exec taos resty --errlog-level debug \
    /usr/local/lvhuan/lua-resty-taos/test.lua

# open a shell in the container
docker compose exec taos /bin/bash
```

## Verified against a live stack (2026-08)

* `GET /version` -> client/server `2.4.0.12`
* `GET /test` -> 7/7 steps ok (connect, drop/create/use database,
  create table, insert 2 rows affected=2, select 2 rows); first row
  converted correctly (`ts=1567296000001`, `speed=0`, `owner="robotspace"`)
* `test.lua` -> connect, create stable/table, batch insert, aggregation
  query and **sync subscribe + consume** all pass: the subscription
  delivered 302 rows (2 pre-inserted + 300 live-inserted) with correct
  TIMESTAMP/INT/DOUBLE conversion
* nginx error log: zero `[error]` lines across all of the above

## Notes

* The image must run as `linux/amd64`: TDengine 2.4 only ships x86_64
  binaries.  On arm64 hosts (e.g. Apple Silicon) Docker emulates it.
* `./lib` and the test scripts are mounted read-write, so library changes
  are picked up without rebuilding the image (nginx workers need a reload
  for `init`-time FFI cdef changes: `docker compose exec taos
  /usr/local/openresty/nginx/sbin/nginx -s reload`).
* The private base image in the original Dockerfile
  (`reg.docker.lhdrr.com:8081/lvhuan/openresty:1.21.4.1rc1`) is not
  publicly reachable, so it is replaced by the public
  `openresty/openresty:1.21.4.1-3-buster`.
* Debian buster reached EOL (2024-06): the Dockerfile points apt at
  `archive.debian.org` and installs the `resty` CLI (`openresty-resty`)
  from the still-live OpenResty repo.
* `taos.cfg` sets `fqdn 127.0.0.1`: taosd must use an IP literal as its
  local endpoint, otherwise the unresolvable container hostname breaks the
  mnode handshake (`Unable to establish connection` / redirect loops).
* The TDengine native port `:6030` is mapped for convenience but taosd
  binds loopback, so host-side `6030` access is not available; run the
  client inside the container (as above).

## Known issue: random segfaults in this emulated environment

The TDengine **2.4.0.12** client library is unstable when this stack runs
under x86 emulation (OrbStack on arm64): tightly-looped or even repeated
`taos_*` calls (query/consume/subscribe) randomly segfault **even with
plain bare-FFI usage and with the unmodified baseline driver** (500-query
loops crash ~1 in 5 runs; consume loops more often).  This is a
client-under-emulation problem, not a driver bug — the same calls are
stable in the native-x86 nginx worker (`/test` runs 7/7, error log
clean).

Consequences baked into the driver code:

* **No `ffi.gc` finalizers on TDengine handles.**  Attaching any
  finalizer (C function or closure) to a TAOS handle measurably increases
  the segfault rate under tight loops (verified with bare FFI).  All
  handles are released by explicit `close()`/`free()`/`unsubscribe()`
  calls instead.
* The memory-leak fixes that are safe are in place:
  * `consume()` now releases the `taos_consume()` result set with
    `taos_free_result()` — required per the official `demoSubscribe.c`
    and the fix for "nginx memory grows forever" in subscription polling
    loops;
  * the async keep-alive list on the driver is bounded (callbacks remove
    their wrapper once fired, and `close()` clears it);
  * result sets are released even when conversion raises (pcall-guarded).

