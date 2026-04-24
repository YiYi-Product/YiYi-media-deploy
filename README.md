# YiYi Deploy

This repository contains only the files required to deploy YiYi from prebuilt
container images. It does not contain application source code.

## First Deploy

```bash
git clone git@github.com:leG09/YiYi-deploy.git /opt/YiYi
cd /opt/YiYi
cp .env.example .env
```

Edit `.env` and set at least:

```dotenv
YIYI_SERVER_HOST=your.server.ip.or.domain
YIYI_DB_PASSWORD=change_me_in_production
YIYI_SERVICE_TOKEN=change_me_to_a_random_secret
```

If a value contains `$`, wrap it in single quotes so Docker Compose does not
interpret it as an environment variable:

```dotenv
YIYI_DB_PASSWORD='abc$123$t'
```

If the GHCR images are private, log in on the server with a token that has
`read:packages` permission:

```bash
echo "$GITHUB_TOKEN" | docker login ghcr.io -u leG09 --password-stdin
```

Start services:

```bash
docker compose pull
docker compose up -d
```

## Update

```bash
cd /opt/YiYi
./deploy/update.sh
```

## Files

```text
docker-compose.yml
.env.example
deploy/postgres-init.sh
deploy/update.sh
data/
```

The `data/` directory is created by Docker volumes on the server and should not
be committed.
