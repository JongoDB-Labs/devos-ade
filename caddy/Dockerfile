# Caddy with a DNS provider plugin, built only for own-domain remote access (compose.domain.yaml): Caddy needs
# it to prove control of your domain to Let's Encrypt over DNS (DNS-01), which also works for a wildcard and
# without any inbound port. Local-only and Tailscale installs keep the stock caddy image from compose.yaml.
#
# Cloudflare is built in. Another provider (https://github.com/caddy-dns): change DNS_PLUGIN to its module at a
# pinned version, the `dns` line in caddy/remote-domain.caddy, and the token variable in compose.domain.yaml.
ARG CADDY_VERSION=2.11.9
FROM caddy:2.11.9-builder-alpine@sha256:86e132d1d6db8850352b2dbc15f82a4cb25363ac305ee41e11405873e5931f37 AS build
ARG CADDY_VERSION
ARG DNS_PLUGIN=github.com/caddy-dns/cloudflare@v0.2.4
RUN xcaddy build "v${CADDY_VERSION}" --with "${DNS_PLUGIN}"

FROM caddy:2.11.9-alpine@sha256:003a97808e781aa9f7e75cc2f43d34d461099031faf5e20faefb9f61126836f0
COPY --from=build /usr/bin/caddy /usr/bin/caddy
# compose runs Caddy as 65534 with cap_add NET_BIND_SERVICE, like the stock image (whose binary carries this
# file capability). A new caddy-data volume copies /data's owner, so certificates are writable for 65534.
RUN setcap cap_net_bind_service=+ep /usr/bin/caddy \
 && mkdir -p /data/caddy /config/caddy && chown -R 65534:65534 /data /config && chmod 700 /data /config
