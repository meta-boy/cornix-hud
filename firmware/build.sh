#!/usr/bin/env bash
# Build Cornix ZMK firmware locally in the same container ZMK's CI uses.
# Needs the board module and HUD add-on checked out at ./zmk:
#   git clone -b stock-keymap https://github.com/meta-boy/zmk-keyboard-cornix zmk
#   ./build.sh            build left and right
#   ./build.sh left       build one half
# Output: out/cornix_left.uf2, out/cornix_right.uf2
set -euo pipefail
cd "$(dirname "$0")"

# The build image is public, so run with an empty Docker config (a missing
# credential helper in ~/.docker/config.json otherwise blocks the pull). That
# config also names the Docker context, so point at colima when it is running.
export DOCKER_CONFIG="${DOCKER_CONFIG_OVERRIDE:-$PWD/.docker}"
colima_sock="$HOME/.colima/default/docker.sock"
[ -z "${DOCKER_HOST:-}" ] && [ -S "$colima_sock" ] && export DOCKER_HOST="unix://$colima_sock"
mkdir -p "$DOCKER_CONFIG" out ws
[ -f "$DOCKER_CONFIG/config.json" ] || echo '{}' > "$DOCKER_CONFIG/config.json"

IMAGE=zmkfirmware/zmk-build-arm:stable
[ $# -eq 0 ] && set -- left right

for half in "$@"; do
  docker run --rm \
    -v "$PWD/ws:/ws" -v "$PWD/config:/ws/config" -v "$PWD/zmk:/cornix:ro" \
    -e SHIELD="$([ "$half" = left ] && echo raw_hid_adapter)" \
    -w /ws "$IMAGE" bash -c "
      set -e
      [ -d .west ] || { west init -l config && west update --fetch-opt=--filter=tree:0; }
      west zephyr-export >/dev/null
      west build -p -s zmk/app -d build/$half -b cornix_$half//zmk -- \
        -DZMK_CONFIG=/ws/config -DZMK_EXTRA_MODULES=/cornix \${SHIELD:+-DSHIELD=\$SHIELD}
    "
  cp "ws/build/$half/zephyr/zmk.uf2" "out/cornix_$half.uf2"
  echo "built out/cornix_$half.uf2"
done
