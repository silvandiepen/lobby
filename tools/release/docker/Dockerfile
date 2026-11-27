# syntax=docker/dockerfile:1
# Lobby Server as a container image, for a NAS or any computer that runs Docker.
#
#   docker build -f tools/release/docker/Dockerfile -t lobby-server .     (from the repository)
#
# Built for linux/amd64 and linux/arm64. Alpine with ffmpeg, the server with its production
# dependencies, and lobby-direct as a static program. It runs as the image's user `node`
# (uid 1000). Everything Lobby keeps is in /lobby; media is mounted read-only beside it.
# compose.yaml next to this file shows how it is run. No image is published.

ARG NODE_IMAGE=node:24.22.3-alpine3.24@sha256:116b800c3754b440ee0aa3ed2f20f5bf3d99a554bfd9adeea09ea8017f6e85f5
ARG RUST_IMAGE=rust:1.90-alpine3.22@sha256:b4b54b176a74db7e5c68fdfe6029be39a02ccbcfe72b6e5a3e18e2c61b57ae26

# lobby-direct, as tools/build-direct-pi.sh builds it.
FROM ${RUST_IMAGE} AS direct
RUN apk add --no-cache musl-dev gcc
WORKDIR /src
COPY apps/direct/ ./
ENV CARGO_TARGET_DIR=/build SOURCE_DATE_EPOCH=0 \
    RUSTFLAGS="-C target-feature=+crt-static --remap-path-prefix=/usr/local/cargo=cargo --remap-path-prefix=/src=src"
RUN cargo build --release --locked --bin lobby-direct && cp /build/release/lobby-direct /lobby-direct

# The server's production dependencies, exactly as package-lock.json has them.
FROM ${NODE_IMAGE} AS dependencies
WORKDIR /build
COPY package.json package-lock.json ./
COPY apps/server/package.json apps/server/
COPY apps/introducer/package.json apps/introducer/
COPY tools/release/package.json tools/release/
RUN npm ci --omit=dev --workspace=apps/server --include-workspace-root=false \
      --ignore-scripts --no-audit --no-fund \
 && rm -rf node_modules/.bin node_modules/@lobby node_modules/.package-lock.json

FROM ${NODE_IMAGE}
RUN apk add --no-cache ffmpeg tini tzdata \
 && mkdir -p /lobby \
 && chown node:node /lobby
COPY apps/server/package.json /opt/lobby/app/package.json
COPY apps/server/src /opt/lobby/app/src
COPY --from=dependencies /build/node_modules /opt/lobby/app/node_modules
COPY --from=direct /lobby-direct /opt/lobby/bin/lobby-direct
COPY --chmod=0755 tools/release/docker/entrypoint.sh /opt/lobby/entrypoint.sh
ENV LOBBY_CONFIG=/lobby/lobby.config.json \
    LOBBY_SUPERVISED=1 \
    NODE_ENV=production
USER node
WORKDIR /lobby
VOLUME /lobby
EXPOSE 8674
HEALTHCHECK --interval=60s --timeout=5s --start-period=60s \
  CMD node -e "const c=JSON.parse(require('fs').readFileSync(process.env.LOBBY_CONFIG,'utf8'));fetch('http://127.0.0.1:'+(c.port||8674)+'/v1/server').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"
ENTRYPOINT ["/sbin/tini", "--", "/opt/lobby/entrypoint.sh"]
CMD ["serve"]
