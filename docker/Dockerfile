# lua-resty-taos test environment.
#
# Stage 1 builds the TDengine 2.4.0.12 server + client library from source
# (there are no official 2.4.x prebuilt packages for this version), stage 2
# is the runtime: OpenResty + libtaos + this library + nginx endpoints.
#
# NOTE: TDengine 2.4 only published x86_64 binaries, so the image must be
# built and run with --platform linux/amd64 (auto-emulated on arm64 hosts).

# syntax=docker/dockerfile:1

# ---------------- Stage 1: build TDengine ----------------
FROM openresty/openresty:1.21.4.1-3-buster AS taos-build

# Debian buster reached EOL (2024-06) and its mirrors were removed; point
# apt at the archive and skip the expired-Release check.
RUN set -eux; \
    if [ -f /etc/apt/sources.list ]; then \
        sed -i \
            -e 's|^deb http://deb.debian.org/debian|deb http://archive.debian.org/debian|' \
            -e 's|^deb http://security.debian.org/debian-security|deb http://archive.debian.org/debian-security|' \
            -e '/buster-updates/d' \
            /etc/apt/sources.list; \
    fi; \
    if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
        sed -i -e 's|deb.debian.org|archive.debian.org|g' \
               -e '/-updates/d' \
               /etc/apt/sources.list.d/debian.sources; \
    fi; \
    echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until; \
    apt-get update \
    && apt-get install -y --no-install-recommends \
        git gcc g++ make cmake flex pkg-config \
        libarchive-dev unixodbc-dev \
    && rm -rf /var/lib/apt/lists/*

# Shallow clone of the pinned release tag (full clone is several GB).
RUN git clone --depth 1 --branch ver-2.4.0.12 \
        https://github.com/taosdata/TDengine.git /tmp/TDengine \
    && cd /tmp/TDengine \
    && git submodule update --init --recursive \
    && mkdir debug && cd debug \
    && cmake .. \
    && cmake --build . -- -j4 \
    && make install

# ---------------- Stage 2: runtime ----------------
FROM openresty/openresty:1.21.4.1-3-buster

# Debian buster is EOL; point apt at the archive and install the `resty`
# CLI from the (still live) openresty repo.
RUN set -eux; \
    if [ -f /etc/apt/sources.list ]; then \
        sed -i \
            -e 's|^deb http://deb.debian.org/debian|deb http://archive.debian.org/debian|' \
            -e 's|^deb http://security.debian.org/debian-security|deb http://archive.debian.org/debian-security|' \
            -e '/buster-updates/d' \
            /etc/apt/sources.list; \
    fi; \
    echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid-until; \
    apt-get update \
    && apt-get install -y --no-install-recommends openresty-resty \
    && rm -rf /var/lib/apt/lists/*

# TDengine server + client library (installed under /usr/local/taos).
COPY --from=taos-build /usr/local/taos /usr/local/taos

# `make install` only drops the versioned lib (libtaos.so.2.4.0.12), so
# create the soname links the loader and LuaJIT FFI expect.
RUN ln -sf /usr/local/taos/driver/libtaos.so.2.4.0.12 /usr/local/taos/driver/libtaos.so.1 \
    && ln -sf /usr/local/taos/driver/libtaos.so.1 /usr/local/taos/driver/libtaos.so \
    && ln -sf /usr/local/taos/driver/libtaos.so /usr/local/lib/libtaos.so \
    && ln -sf /usr/local/taos/bin/taosd /usr/local/bin/taosd \
    && ln -sf /usr/local/taos/bin/taos /usr/local/bin/taos \
    && mkdir -p /var/lib/taos /var/log/taos /etc/taos

COPY docker/taos.cfg /etc/taos/taos.cfg
COPY docker/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY docker/entrypoint.sh /entrypoint.sh

# The library sources and test scripts (also mounted read-write by
# docker-compose for live iteration).
COPY lib /usr/local/lvhuan/lua-resty-taos/lib
COPY test.lua test1.lua /usr/local/lvhuan/lua-resty-taos/

RUN chmod +x /entrypoint.sh

ENV LD_LIBRARY_PATH=/usr/local/taos/driver

EXPOSE 6030 6041 8080

ENTRYPOINT ["/entrypoint.sh"]
