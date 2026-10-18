#!/usr/bin/env bash
set -euo pipefail
server="${1:?Usage: deploy.sh user@host /path/to/token-hashes.json nginx-site-file}"
tokens="${2:?Pass a JSON array of SHA-256 access-key hashes}"
site="${3:?Pass the existing HTTPS nginx site filename (no path)}"
[[ "$site" =~ ^[a-zA-Z0-9._-]+$ ]] || exit 2
root="$(cd "$(dirname "$0")" && pwd)"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
python3 -m venv "$stage/venv"
"$stage/venv/bin/pip" install --quiet --target "$stage/vendor" -r "$root/requirements.txt"
# websockets has a pure-Python fallback; don't ship host-specific speedups.
find "$stage/vendor" -name '*.so' -delete
cp "$root/server.py" "$root/clipy-relay.service" "$root/nginx.conf" "$stage/"
cp "$tokens" "$stage/tokens.json"
chmod 600 "$stage/tokens.json"
COPYFILE_DISABLE=1 tar --no-xattrs --exclude='__pycache__' -czf "$stage/deploy.tgz" -C "$stage" server.py clipy-relay.service nginx.conf tokens.json vendor
remote_stage=$(ssh "$server" 'umask 077; mktemp -d /tmp/clipy-relay-deploy.XXXXXX')
scp -q "$stage/deploy.tgz" "$server:$remote_stage/deploy.tgz"
ssh "$server" "sudo bash -s -- '$remote_stage' '$site'" <<'REMOTE'
set -euo pipefail
stage="$1"
site="/etc/nginx/sites-available/$2"
trap 'rm -rf "$stage"' EXIT
tar -xzf "$stage/deploy.tgz" -C "$stage"
id clipy-relay >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin clipy-relay
install -d -m 755 /opt/clipy-relay
install -d -m 750 -o root -g clipy-relay /etc/clipy-relay
if test -f /opt/clipy-relay/server.py; then cp -p /opt/clipy-relay/server.py /opt/clipy-relay/server.py.previous; fi
install -m 644 "$stage/server.py" /opt/clipy-relay/server.py
cp -R "$stage/vendor" /opt/clipy-relay/
chown -R root:root /opt/clipy-relay
chmod -R a+rX /opt/clipy-relay
install -m 640 -o root -g clipy-relay "$stage/tokens.json" /etc/clipy-relay/tokens.json
install -m 644 "$stage/clipy-relay.service" /etc/systemd/system/clipy-relay.service
install -m 644 "$stage/nginx.conf" /etc/nginx/snippets/clipy-relay.conf
cp -p "$site" "$stage/site.backup"
python3 - "$site" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
include='    include /etc/nginx/snippets/clipy-relay.conf;'
if include not in s:
    # Install alongside an existing WSS service in the intended TLS server.
    marker='    include /etc/nginx/snippets/wifiadb.conf;'
    if s.count(marker) != 1: raise SystemExit('Expected exactly one existing WSS include; inspect site manually')
    open(p,'w').write(s.replace(marker, marker+'\n'+include))
PY
if ! nginx -t; then cp -p "$stage/site.backup" "$site"; exit 1; fi
systemctl daemon-reload
systemctl enable --now clipy-relay
systemctl restart clipy-relay
systemctl is-active --quiet clipy-relay
systemctl reload nginx
systemctl show clipy-relay -p ActiveState -p MemoryCurrent
REMOTE
