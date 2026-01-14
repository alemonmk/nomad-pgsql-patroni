ARG PG_MAJOR=17

############################
# Build tools binaries in separate image
############################
FROM golang:1.25.5 AS tools

RUN mkdir -p ${GOPATH}/src/github.com/timescale/ \
    && cd ${GOPATH}/src/github.com/timescale/ \
    && git clone https://github.com/timescale/timescaledb-tune.git \
    && git clone https://github.com/timescale/timescaledb-parallel-copy.git \
    # Build timescaledb-tune
    && cd timescaledb-tune/cmd/timescaledb-tune \
    && git fetch && git checkout --quiet $(git describe --abbrev=0) \
    && go get -d -v \
    && go build -o /go/bin/timescaledb-tune \
    # Build timescaledb-parallel-copy
    && cd ${GOPATH}/src/github.com/timescale/timescaledb-parallel-copy/cmd/timescaledb-parallel-copy \
    && git fetch && git checkout --quiet $(git describe --abbrev=0) \
    && go get -d -v \
    && go build -o /go/bin/timescaledb-parallel-copy

############################
# Build Postgres extensions
############################
FROM postgres:17.7 AS ext_build
ARG PG_MAJOR

ENV DEBIAN_FRONTEND=noninteractive

RUN echo 'APT::Install-Recommends "false";' >> /etc/apt/apt.conf.d/01norecommend \
    && echo 'APT::Install-Suggests "false";' >> /etc/apt/apt.conf.d/01norecommend

RUN set -x \
    && apt-get update -y \
    && apt-get install -y git curl apt-transport-https ca-certificates build-essential cmake pkgconf libpq-dev postgresql-server-dev-${PG_MAJOR} \
    # PostGIS dependencies
    && apt-get install -y bison libgdal-dev libgeos-dev libjson-c-dev libpcre2-dev libproj-dev libprotobuf-c-dev protobuf-c-compiler libsfcgal-dev libxml2-dev libxml2-utils \
    # PGroonga WAL support dependency
    && apt-get install -y libgroonga-dev libmsgpack-dev \
    && mkdir /build \
    && cd /build

# Build pgvector
RUN set -x \
    && git clone --branch v0.8.1 https://github.com/pgvector/pgvector.git \
    && cd pgvector \
    && make clean \
    && make \
    && make install \
    && cd ..

# Build postgres-json-schema
RUN set -x \
    && git clone https://github.com/gavinwahl/postgres-json-schema \
    && cd postgres-json-schema \
    && make install \
    && cd ..

# Download pg_idkit
ARG IDKIT_VER="0.4.0"
RUN set -x \
    && curl -LO https://github.com/VADOSWARE/pg_idkit/releases/download/v${IDKIT_VER}/pg_idkit-${IDKIT_VER}-pg${PG_MAJOR}-gnu.tar.gz \
    && tar xf pg_idkit-${IDKIT_VER}-pg${PG_MAJOR}-gnu.tar.gz \
    && cp -r pg_idkit-${IDKIT_VER}/lib/postgresql/* /usr/lib/postgresql/${PG_MAJOR}/lib/ \
    && cp -r pg_idkit-${IDKIT_VER}/share/postgresql/extension/* /usr/share/postgresql/${PG_MAJOR}/extension/

# Build postgis
ARG POSTGIS_VER="3.6.1"
RUN set -x \
    && curl -LO https://download.osgeo.org/postgis/source/postgis-${POSTGIS_VER}.tar.gz \
    && tar xzf postgis-${POSTGIS_VER}.tar.gz \
    && cd postgis-${POSTGIS_VER} \
    && ./configure --without-interrupt-tests --without-phony-revision --enable-lto --datadir=/usr/share/postgresql-${PG_MAJOR}-postgis \
    && make clean \
    && make \
    && make install \
    && cd ..

# Build pg_cron
RUN set -x \
    && git clone --branch v1.6.7 https://github.com/citusdata/pg_cron.git \
    && cd pg_cron \
    && make clean \
    && make \
    && make install \
    && cd ..

# Build pgrouting
ARG PGROUTING_VER="4.0.0"
RUN set -x \
    && curl -L https://github.com/pgRouting/pgrouting/archive/v${PGROUTING_VER}.tar.gz -o pgrouting-${PGROUTING_VER}.tar.gz \
    && tar xf pgrouting-${PGROUTING_VER}.tar.gz \
    && cd pgrouting-${PGROUTING_VER} \
    && mkdir build && cd build \
    && cmake .. \
    && make \
    && make install \
    && cd ..

# Build timescaledb
ARG TIMESCALEDB_VER="2.24.0"
RUN set -x \
    && git clone --branch ${TIMESCALEDB_VER} https://github.com/timescale/timescaledb \
    && cd timescaledb \
    && ./bootstrap \
    && cd build && make && make install \
    && cd ..

ARG PGROONGA_VER="4.0.5"
RUN set -x \
    && git clone --branch ${PGROONGA_VER} --recursive https://github.com/pgroonga/pgroonga \
    && cd pgroonga \
    && make HAVE_MSGPACK=1 MSGPACK_PACKAGE_NAME=msgpack-c \
    && make install \
    && cd ..

############################
# Add Patroni
############################
FROM postgres:17.7
ARG PG_MAJOR
ARG POSTGIS_VERSION="3.6.1"

# Add extensions
COPY --from=tools /go/bin/* /usr/local/bin/
COPY --from=ext_build /usr/share/postgresql/${PG_MAJOR}/ /usr/share/postgresql/${PG_MAJOR}/
COPY --from=ext_build /usr/lib/postgresql/${PG_MAJOR}/ /usr/lib/postgresql/${PG_MAJOR}/

ENV PATH="/opt/venv/bin:$PATH"

ENV DEBIAN_FRONTEND=noninteractive

RUN set -x \
    && echo 'APT::Install-Recommends "false";' >> /etc/apt/apt.conf.d/01norecommend \
    && echo 'APT::Install-Suggests "false";' >> /etc/apt/apt.conf.d/01norecommend \
    && apt-get update -y \
    && apt-get upgrade -y \
    && apt-get install -y curl python3 python3-pip python3-venv \
    && apt-get install -y libgdal36 libgeos-c1v5 libjson-c5 libproj25 libprotobuf-c1 libsfcgal2 libmsgpack-c2 libgroonga0t64 \
    \
    && python3 -m venv /opt/venv \
    && pip install --no-cache-dir wheel \
    && pip install --no-cache-dir patroni[psycopg3,etcd3,consul]==4.1.0

RUN set -x \
    # Install WAL-G
    && curl -LO https://github.com/wal-g/wal-g/releases/download/v3.0.7/wal-g-pg-ubuntu-24.04-amd64 \
    && install -oroot -groot -m755 wal-g-pg-ubuntu-24.04-amd64 /usr/local/bin/wal-g \
    && rm wal-g-pg-ubuntu-24.04-amd64 \
    \
    # Install vaultenv
    && curl -LO https://github.com/channable/vaultenv/releases/download/v0.19.0/vaultenv-0.19.0-linux-musl \
    && install -oroot -groot -m755 vaultenv-0.19.0-linux-musl /usr/bin/vaultenv \
    && rm vaultenv-0.19.0-linux-musl

RUN mkdir -p /docker-entrypoint-initdb.d
COPY ./files/000_shared_libs.sh /docker-entrypoint-initdb.d/000_shared_libs.sh
COPY ./files/001_initdb_postgis.sh /docker-entrypoint-initdb.d/001_initdb_postgis.sh
COPY ./files/002_timescaledb_tune.sh /docker-entrypoint-initdb.d/002_timescaledb_tune.sh

COPY ./files/update-postgis.sh /usr/local/bin
COPY ./files/docker-initdb.sh /usr/local/bin

USER postgres
CMD ["patroni", "/secrets/patroni.yml"]
