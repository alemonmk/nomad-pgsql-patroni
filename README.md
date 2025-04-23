# nomad-pgsql-patroni

A simple container running Postgres and Patroni useful for dropping directly into a Hashicorp environment (Nomad + Consul + Vault).

It also comes pre-baked with some tools and extensions.

### Tools

| Name | Version | Link |
|--|--|--|
| WAL-G | 3.0.7 | https://github.com/wal-g/wal-g |
| Patroni | 4.0.5 | https://github.com/zalando/patroni |
| vaultenv | 0.18.0 | https://github.com/channable/vaultenv |

### Extensions

| Name | Version | Link |
|--|--|--|
| Timescale | 2.19.3 | https://www.timescale.com |
| PostGIS | 3.5.2 | https://postgis.net |
| pg_cron | 1.6.4 | https://github.com/citusdata/pg_cron |
| pg_idkit | 0.2.4 | https://github.com/VADOSWARE/pg_idkit |
| pgRouting | 3.7.3 | https://pgrouting.org |
| postgres-json-schema | 0.1.1 | https://github.com/gavinwahl/postgres-json-schema |
| vector | 0.8.0 | https://github.com/ankane/pgvector |

### Still running an older Postgres version?

These branches are *mostly* supported containing older versions. If I get behind on a point release feel free to raise an issue :thumbsup:

- [`pg-14`](https://github.com/ccakes/nomad-pgsql-patroni/tree/pg-14)
- [`pg-13`](https://github.com/ccakes/nomad-pgsql-patroni/tree/pg-13)
- [`pg-12`](https://github.com/ccakes/nomad-pgsql-patroni/tree/pg-12)

## Usage

```hcl
job "postgres-16" {
  type = "service"
  datacenters = ["dc1"]

  group "group" {
    count = 1

    network {
      port api { to = 8080 }
      port pg { to = 5432 }
    }

    task "db" {
      driver = "docker"

      template {
        data = <<EOL
scope: postgres
name: pg-{{env "node.unique.name"}}
namespace: /nomad

restapi:
  listen: 0.0.0.0:{{env "NOMAD_PORT_api"}}
  connect_address: {{env "NOMAD_ADDR_api"}}

consul:
  host: localhost
  register_service: true

# bootstrap config
EOL

        destination = "/secrets/patroni.yml"
      }

      config {
        image = "ghcr.io/ccakes/nomad-pgsql-patroni:16.2-1.tsdb_gis"

        ports = ["api", "pg"]
      }

      resources {
        memory = 1024
      }
    }
  }
}

```

## Testing

An example `docker-compose` file and patroni config is included to see this running.
```shell
$ docker-compose -f docker-compose.test.yml up
```
