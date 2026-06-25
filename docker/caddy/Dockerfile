# docker/caddy/Dockerfile — Caddy + caddy-dns/cloudflare(DNS-01 必需;官方镜像不含此模块)
FROM caddy:2-builder AS builder
RUN xcaddy build --with github.com/caddy-dns/cloudflare

FROM caddy:2
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
