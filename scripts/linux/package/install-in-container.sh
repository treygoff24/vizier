#!/usr/bin/env bash
set -euo pipefail
version=$1
mode=$2
export DEBIAN_FRONTEND=noninteractive
# Ubuntu's minimal Docker image strips docs and man pages via dpkg exclusions.
# Include this package's files so the fixture verifies the actual payload.
printf 'path-include=/usr/share/doc/vizier/*\npath-include=/usr/share/man/man1/vizier.1.gz\n' > /etc/dpkg/dpkg.cfg.d/zz-vizier-package-proof
apt-get update -qq
# Suppress desktop recommendations in this headless proof; Depends come from apt.
apt-get install -y --no-install-recommends "/artifacts/vizier_${version}_amd64.deb" python3
for resource in /usr/share/doc/vizier/NOTICE /usr/share/doc/vizier/LICENSE \
    /usr/share/applications/net.praxient.vizier.desktop \
    /usr/share/vizier/sounds/start.wav /usr/share/vizier/sounds/stop.wav \
    /usr/share/vizier/sounds/cancel.wav /usr/share/vizier/sounds/problem.wav; do
    [[ -s $resource ]] || { echo "Missing installed resource: $resource" >&2; exit 1; }
done
grep -qx 'ExecStart=/usr/bin/vizier daemon' /usr/lib/systemd/user/vizier.service
useradd --create-home --shell /bin/bash tester
# shellcheck disable=SC1091
echo "INSTALL $(. /etc/os-release && printf '%s' "$PRETTY_NAME")"
dpkg-query -W -f='${Package} ${Version}\n' vizier libc6 libsqlite3-0 libcurl4t64 libsystemd0
runuser -u tester -- python3 /opt/package/smoke.py /usr/bin/vizier
if [[ $mode == both ]]; then
    runuser -u tester -- python3 /opt/package/smoke.py "/artifacts/Vizier-${version}-x86_64.AppImage"
fi
