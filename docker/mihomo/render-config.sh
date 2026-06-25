#!/bin/sh
# Render the mihomo config template, substituting __JMS_SUBSCRIPTION_URL__ with
# the JMS_SUBSCRIPTION_URL env var. Pure POSIX-shell string substitution (no
# sed/regex) so URL specials (& ? = /) are treated literally.
#
#   usage: JMS_SUBSCRIPTION_URL=... render-config.sh [template] [out]
#          out defaults to '-' (stdout).
#
# Used by the mihomo service in docker-compose.prod.yml at container start, and
# handy for local preview: JMS_SUBSCRIPTION_URL=... docker/mihomo/render-config.sh
set -eu

TPL="${1:-$(dirname "$0")/config.template.yaml}"
OUT="${2:--}"
: "${JMS_SUBSCRIPTION_URL:?JMS_SUBSCRIPTION_URL not set}"

render() {
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *__JMS_SUBSCRIPTION_URL__*)
        printf '%s\n' "${line%%__JMS_SUBSCRIPTION_URL__*}${JMS_SUBSCRIPTION_URL}${line#*__JMS_SUBSCRIPTION_URL__}"
        ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$TPL"
}

if [ "$OUT" = "-" ]; then render; else render > "$OUT"; fi
