#!/bin/sh
# Entrypoint: provision the changelog index in /data, then run the bot.
# The bot holds changelog.db open, so after a background refresh we
# SIGTERM ourselves and let the container restart policy re-run us
# with the fresh index. Set CHANGLEOG_REFRESH_DAYS=0 to disable.
set -eu

CHANGELOG_URL="https://raw.githubusercontent.com/Octachron/ocaml-changelog-analyzer/refs/heads/main/refs/changes.json"
REFRESH_DAYS="${CHANGLEOG_REFRESH_DAYS:-3}"

build_index() {
  echo "entrypoint: fetching changelog and building index…"
  rm -rf /data/.changelog.build
  mkdir -p /data/.changelog.build
  curl -fsSL "$CHANGELOG_URL" -o /data/.changelog.build/changelog.json
  (cd /data/.changelog.build && python3 /usr/local/lib/ocabot/import_changelog.py import)
  mv /data/.changelog.build/changelog.db /data/changelog.db
  mv /data/.changelog.build/changelog.json /data/changelog.json
  rm -rf /data/.changelog.build
  echo "entrypoint: changelog index built"
}

if [ ! -f /data/changelog.db ] || [ ! -f /data/changelog.json ]; then
  build_index
fi

if [ "$REFRESH_DAYS" -gt 0 ]; then
  (
    while :; do
      sleep "$((REFRESH_DAYS * 86400))" || exit 0
      if build_index; then
        echo "entrypoint: restarting bot to pick up fresh changelog"
        kill -TERM 1
      fi
    done
  ) &
fi

exec /usr/local/bin/ocabot "$@"
