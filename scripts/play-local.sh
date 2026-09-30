#!/bin/zsh
# Opens two copies of Slideways on this Mac to try online play alone: host in one, then
# join from the other (it's listed under GAMES NEARBY; type the host's code).
#
# Usage: scripts/play-local.sh [--autopilot] [--lag MS] [--loss FRACTION] [--build]
#   --autopilot   the AI drives the second copy's kart, so you can race it from the first
#   --lag MS      delay each copy's outgoing packets by MS milliseconds (one way)
#   --loss F      drop this fraction of packets, e.g. 0.05
#   --build       rebuild the app first (it's built automatically if missing)
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/Slideways.app"
autopilot=0
build=0
net=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --autopilot) autopilot=1 ;;
        --lag) net+=(--env "SLIDEWAYS_NET_LAG_MS=${2:?--lag needs milliseconds}"); shift ;;
        --loss) net+=(--env "SLIDEWAYS_NET_LOSS=${2:?--loss needs a fraction like 0.05}"); shift ;;
        --build) build=1 ;;
        -h|--help) sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1 (try --help)" >&2; exit 1 ;;
    esac
    shift
done

if [[ $build == 1 || ! -d "$APP" ]]; then
    zsh scripts/build-app.sh --native
fi

# First copy: host from it, and drive with the keyboard.
open -n "${net[@]}" "$APP"
sleep 1.5
# Second copy: joins. Only the focused window gets the keyboard, so --autopilot lets the AI
# race this one while you drive the first.
second=("${net[@]}")
(( autopilot )) && second+=(--env SLIDEWAYS_AUTOPILOT=1)
open -n "${second[@]}" "$APP"

echo "Two copies of Slideways are open."
echo "In one: ONLINE > HOST A GAME. In the other: ONLINE > JOIN under GAMES NEARBY, after typing the code in CODE."
