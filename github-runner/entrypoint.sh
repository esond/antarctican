#!/bin/bash
set -euo pipefail

sudo chown runner:docker /home/runner/_work

# Before the file cleanup: a leftover container that mounts _work can keep writing
# to it, and find then fails on a non-empty directory, which exits this script.
docker ps -aq | xargs -r docker rm -f
# Not system prune, which also deletes the build cache the filter below keeps.
docker network prune -f
# -a because a plain prune keeps named volumes.
docker volume prune -af
docker image prune -af --filter until=168h
docker builder prune -af --filter until=168h

sudo find /home/runner/_work /tmp /mnt/externals -mindepth 1 -delete
sudo rm -rf /home/runner/_diag
sudo find /home/runner -mindepth 1 -maxdepth 1 -name '.*' -exec rm -rf {} +

# Container jobs run the node in externals, through a bind mount the daemon resolves
# on its own filesystem.
sudo cp -a /home/runner/externals/. /mnt/externals/

path=${RUNNER_URL%/}
path=${path#https://github.com/}
case "$path" in
  */*) api="repos/$path" ;;
  *) api="orgs/$path" ;;
esac

token=$(curl -fsS -X POST \
  -H "Authorization: Bearer $GITHUB_PAT" \
  "https://api.github.com/$api/actions/runners/registration-token" | jq -r .token)
unset GITHUB_PAT

./config.sh --unattended --ephemeral --replace \
  --url "$RUNNER_URL" --token "$token" \
  --name "$RUNNER_NAME" --labels "$RUNNER_LABELS" --work _work
unset token

# A restarted dind gets a new network namespace and this container keeps the dead
# one, still "running" but offline. Exiting lets the restart policy rejoin it.
(while sleep 30; do docker info >/dev/null 2>&1 || kill -TERM 1; done) &

# exec drops this script's environment from PID 1 and lets run.sh handle SIGTERM
# itself (the image sets RUNNER_MANUALLY_TRAP_SIG=1).
exec ./run.sh
