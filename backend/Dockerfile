FROM node:20-bookworm-slim

# mediasoup needs python3, make, g++ to compile its C++ worker.
# openssl + the docker CLI + the compose plugin are required by
# services/infra-sync.js so the backend can rewrite .env, regenerate
# the self-signed certs, and recreate the coturn / nginx containers
# when the admin updates IPs.
#
# Note: Debian bookworm has no `docker-cli` package; the only apt option
# is the giant `docker.io` (full engine) or Docker's own apt repo. We
# pull the static CLI binary instead — it's the smallest possible drop
# (~50 MB) and pinning the version keeps builds reproducible.
ARG DOCKER_VERSION=26.1.4
ARG DOCKER_COMPOSE_VERSION=2.27.1
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 build-essential libopus-dev \
    openssl ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz" \
         | tar -xz -C /tmp \
    && install -m 0755 /tmp/docker/docker /usr/local/bin/docker \
    && rm -rf /tmp/docker \
    && mkdir -p /usr/local/lib/docker/cli-plugins \
    && curl -fsSL "https://github.com/docker/compose/releases/download/v${DOCKER_COMPOSE_VERSION}/docker-compose-linux-x86_64" \
         -o /usr/local/lib/docker/cli-plugins/docker-compose \
    && chmod +x /usr/local/lib/docker/cli-plugins/docker-compose \
    && docker --version \
    && docker compose version

WORKDIR /app

COPY package*.json ./
RUN npm install --production

COPY src/ ./src/
RUN mkdir -p /app/db

# mediasoup RTP ports + HTTP
EXPOSE 3000 10000-10200/udp

CMD ["node", "src/server.js"]
