ARG GO_VERSION=1.24.2
ARG PG_MAJOR=17

############################
# Build tools binaries in separate image
############################
FROM golang:${GO_VERSION} AS tools

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
FROM postgres:17.4 AS ext_build
ARG PG_MAJOR

ENV DEBIAN_FRONTEND=noninteractive

RUN echo 'APT::Install-Recommends "false";' >> /etc/apt/apt.conf.d/01norecommend \
    && echo 'APT::Install-Suggests "false";' >> /etc/apt/apt.conf.d/01norecommend

RUN set -x \
    && apt-get update -y \
    && apt-get install -y git curl apt-transport-https ca-certificates build-essential cmake pkgconf libpq-dev postgresql-server-dev-${PG_MAJOR} \
    # PostGIS dependencies
    && apt-get install -y bison libgdal-dev libgeos-dev libjson-c-dev libpcre2-dev libproj-dev libprotobuf-c-dev protobuf-c-compiler libsfcgal-dev libxml2-dev libxml2-utils \
    && mkdir /build \
    && cd /build

# Build pgvector
RUN set -x \
    && git clone --branch v0.8.0 https://github.com/pgvector/pgvector.git \
    && cd pgvector \
    && make clean \
    && make\
    && make install \
    && cd /build

# Build postgres-json-schema
RUN set -x \
    && git clone https://github.com/gavinwahl/postgres-json-schema \
    && cd postgres-json-schema \
    && make install \
    && cd /build

# Download pg_idkit
RUN set -x \
    && curl -LO https://github.com/VADOSWARE/pg_idkit/releases/download/v0.2.4/pg_idkit-0.2.4-pg${PG_MAJOR}-gnu.tar.gz \
    && tar xf pg_idkit-0.2.4-pg${PG_MAJOR}-gnu.tar.gz \
    && cp -r pg_idkit-0.2.4/lib/postgresql/* /usr/lib/postgresql/${PG_MAJOR}/lib/ \
    && cp -r pg_idkit-0.2.4/share/postgresql/extension/* /usr/share/postgresql/${PG_MAJOR}/extension/

# Build postgis
RUN set -x \
    && curl -LO https://download.osgeo.org/postgis/source/postgis-3.5.2.tar.gz \
    && tar xzf postgis-3.5.2.tar.gz \
    && cd postgis-3.5.2 \
    && ./configure --without-interrupt-tests --without-phony-revision --enable-lto --datadir=/usr/share/postgresql-${PG_MAJOR}-postgis \
    && make clean \
    && make \
    && make install \
    && cd /build

# Build pg_cron
RUN set -x \
    && git clone https://github.com/citusdata/pg_cron.git \
    && cd pg_cron \
    && make clean \
    && make \
    && make install \
    && cd /build

# Build pgrouting
RUN set -x \
    && curl -L https://github.com/pgRouting/pgrouting/archive/v3.7.3.tar.gz -o pgrouting-3.7.3.tar.gz \
    && tar xf pgrouting-3.7.3.tar.gz \
    && cd pgrouting-3.7.3 \
    && mkdir build && cd build \
    && cmake .. \
    && make \
    && make install \
    && cd /build

# Build timescaledb
RUN set -x \
    && git clone https://github.com/timescale/timescaledb \
    && cd timescaledb && git checkout 2.19.3 \
    && ./bootstrap \
    && cd build && make \
    && make install

############################
# Add Patroni
############################
FROM postgres:17.4
ARG PG_MAJOR

# Add extensions
COPY --from=tools /go/bin/* /usr/local/bin/
COPY --from=ext_build /usr/share/postgresql/${PG_MAJOR}/ /usr/share/postgresql/${PG_MAJOR}/
COPY --from=ext_build /usr/lib/postgresql/${PG_MAJOR}/ /usr/lib/postgresql/${PG_MAJOR}/

ENV PATH="/opt/venv/bin:$PATH"

RUN set -x \
    && echo 'APT::Install-Recommends "false";' >> /etc/apt/apt.conf.d/01norecommend \
    && echo 'APT::Install-Suggests "false";' >> /etc/apt/apt.conf.d/01norecommend \
    && apt-get update -y \
    && apt-get upgrade -y \
    && apt-get install -y curl python3 python3-pip python3-venv \
    && apt-get install -y libgdal32 libgeos-c1v5 libjson-c5 libproj25 libprotobuf-c1 libsfcgal1 \
    \
    && python3 -m venv /opt/venv \
    && pip install --no-cache-dir wheel \
    && pip install --no-cache-dir patroni[psycopg3,etcd3,consul]==4.0.5

RUN set -x \
    # Install WAL-G
    && curl -LO https://github.com/wal-g/wal-g/releases/download/v3.0.7/wal-g-pg-ubuntu-24.04-amd64 \
    && install -oroot -groot -m755 wal-g-pg-ubuntu-24.04-amd64 /usr/local/bin/wal-g \
    && rm wal-g-pg-ubuntu-24.04-amd64 \
    \
    # Install vaultenv
    && curl -LO https://github.com/channable/vaultenv/releases/download/v0.18.0/vaultenv-0.18.0-linux-musl \
    && install -oroot -groot -m755 vaultenv-0.18.0-linux-musl /usr/bin/vaultenv \
    && rm vaultenv-0.18.0-linux-musl

RUN mkdir -p /docker-entrypoint-initdb.d
COPY ./files/000_shared_libs.sh /docker-entrypoint-initdb.d/000_shared_libs.sh
COPY ./files/001_initdb_postgis.sh /docker-entrypoint-initdb.d/001_initdb_postgis.sh
COPY ./files/002_timescaledb_tune.sh /docker-entrypoint-initdb.d/002_timescaledb_tune.sh

COPY ./files/update-postgis.sh /usr/local/bin
COPY ./files/docker-initdb.sh /usr/local/bin

USER postgres
CMD ["patroni", "/secrets/patroni.yml"]
