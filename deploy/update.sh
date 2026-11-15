#!/bin/sh
# Move the running Pendenz to a release or to the images of one commit. Run it on the host, from
# anywhere:
#   /srv/pendenz/update.sh 1.2.0              a release (v1.2.0 works too)
#   /srv/pendenz/update.sh latest             the newest release
#   /srv/pendenz/update.sh <full commit sha>  any commit on main
# It pulls the image, backs up, switches .env to the new digest and restarts. If the new
# containers do not become healthy it puts the previous images back. The database is never
# restored automatically, and an older image does not start on a database that a newer one has
# migrated: then the way back is the backup taken before the update.
#
# Settings, from the environment or from .env next to this script:
#   PENDENZ_HOME          the folder with compose.yaml and .env (default: this script's folder)
#   PENDENZ_IMAGE_PREFIX  the image name without -api (default: ghcr.io/unveroleone/pendenz)
#   PENDENZ_SOURCE_URL    the repo the images must have been built from
#                         (default: https://github.com/unveroleone/pendenz)
# A fork that publishes its own images sets the last two.
set -eu
umask 077

usage="Usage: update.sh <version> | latest | <full commit sha>"
wanted=${1:-}
wanted=${wanted#v}
case "$wanted" in
"") echo "$usage" >&2 && exit 1 ;;
latest) ;;
*[!a-f0-9]*)
    # A version such as 1.2.0 or 1.3.0-rc.1.
    case "$wanted" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "$usage" >&2 && exit 1 ;;
    esac
    case "$wanted" in *[!0-9A-Za-z.-]*) echo "$usage" >&2 && exit 1 ;; esac
    ;;
*) [ ${#wanted} -eq 40 ] || { echo "Use the full 40-character commit sha." >&2; exit 1; } ;;
esac

live=${PENDENZ_HOME:-$(cd "$(dirname "$0")" && pwd)}
cd "$live"
[ -f .env ] && [ -f compose.yaml ] || { echo "Missing .env or compose.yaml in $live." >&2; exit 1; }
# A plain value from .env, without running the file as a script. Quotes around it are dropped;
# a comment after the value is not.
setting() { sed -n "s/^[[:space:]]*$1=//p" .env | tail -n 1 | sed "s/^[\"']//; s/[\"'][[:space:]]*$//; s/[[:space:]]*$//"; }
prefix=${PENDENZ_IMAGE_PREFIX:-$(setting PENDENZ_IMAGE_PREFIX)}
prefix=${prefix:-ghcr.io/unveroleone/pendenz}
source_url=${PENDENZ_SOURCE_URL:-$(setting PENDENZ_SOURCE_URL)}
source_url=${source_url:-https://github.com/unveroleone/pendenz}
# docker compose reads COMPOSE_FILE from .env by itself, so a tunnel or an override stays on.
compose() { docker compose --project-directory "$live" "$@"; }

for service in api; do
    image="$prefix-$service:$wanted"
    docker pull --quiet "$image" >/dev/null
    label() { docker image inspect --format "{{ index .Config.Labels \"$1\" }}" "$image"; }
    [ "$(label org.opencontainers.image.source)" = "$source_url" ] ||
        { echo "The $service image was not built from $source_url." >&2; exit 1; }
    # A commit sha has to match the image's label; a version or latest takes the commit from it.
    revision=$(label org.opencontainers.image.revision)
    case "$revision" in
    *[!a-f0-9]* | "") echo "The $service image carries no commit." >&2 && exit 1 ;;
    esac
    [ ${#wanted} -ne 40 ] || [ "$revision" = "$wanted" ] ||
        { echo "The $service image does not carry this commit." >&2; exit 1; }
    pinned=$(docker image inspect --format '{{ index .RepoDigests 0 }}' "$image")
    eval "${service}_image=\$pinned"
done

# A first installation has no database yet, so there is nothing to back up.
if [ -f data/pendenz.db ]; then
    [ -f backup.env ] || { echo "Missing backup.env; refusing to update without a backup." >&2; exit 1; }
    compose --profile backup run --rm backup
fi

cp .env .env.previous
set_image() {
    grep -q "^$1=" .env || echo "$1=" >>.env
    sed "s|^$1=.*|$1=$2|" .env >.env.next && mv .env.next .env
}
set_image PENDENZ_API_IMAGE "$api_image"

# --remove-orphans takes away a container of a service that compose.yaml no longer has, such as
# the separate MCP container of versions before the MCP endpoint moved into the API.
healthy() {
    compose up -d --remove-orphans --wait --wait-timeout 120 &&
        compose exec -T api curl -fsS -o /dev/null http://127.0.0.1:8080/readyz &&
        [ "$(compose exec -T api curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/api/items)" = 401 ]
}
if healthy; then
    echo "$revision" >last-deployed-sha
    rm -f .env.previous
    version=$(label org.opencontainers.image.version)
    [ "$version" != "$revision" ] || version=
    echo "Pendenz now runs ${version:+$version, }$revision."
else
    echo "The new containers are not healthy. Putting the previous images back." >&2
    mv .env.previous .env
    compose up -d --wait --wait-timeout 120 ||
        echo "The previous containers did not start either. Check 'docker compose logs' in $live." >&2
    echo "The database was not restored. Check the migrations before any manual restore." >&2
    exit 1
fi
