#!/bin/sh
# Régénère security/seccomp-steam.json : le profil seccomp par défaut de Docker
# (projet moby, licence Apache-2.0) auquel on ajoute les appels système dont le
# bac à sable de Proton a besoin sans CAP_SYS_ADMIN.
#
# Usage : security/make-seccomp.sh [version de Docker, par défaut celle installée]
set -eu

version="${1:-$(docker version --format '{{.Server.Version}}')}"
url="https://raw.githubusercontent.com/moby/moby/docker-v${version}/vendor/github.com/moby/profiles/seccomp/default.json"

curl -fsSL "$url" \
    | jq '.syscalls += [{"names": ["unshare", "clone", "mount", "umount2", "pivot_root", "setns"], "action": "SCMP_ACT_ALLOW"}]' \
    > "$(dirname "$0")/seccomp-steam.json"

echo "security/seccomp-steam.json généré depuis Docker ${version}"
