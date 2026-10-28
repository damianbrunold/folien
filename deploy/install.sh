#!/bin/sh
# Installs folien as a systemd service. Run as root on the target
# host from the app directory: sudo deploy/install.sh. Idempotent: rerun it
# to deploy a new version (the config in /etc is kept).
#
#   /opt/folien               the app (replaced on each install)
#   /etc/folien/config.scm    the config (created once, then yours)
#
# The service runs as the system user folien. Set SCM to the scm
# launcher if it is not /usr/local/bin/scm.
set -eu

APP=folien
SCM=${SCM:-/usr/local/bin/scm}
SRC="$(cd "$(dirname "$0")/.." && pwd)"

id -u "$APP" >/dev/null 2>&1 ||
  useradd --system --home-dir /nonexistent --no-create-home \
          --shell /usr/sbin/nologin "$APP"

# The app: code, static files and data, owned by root, readable by all.
rm -rf "/opt/$APP.new"
mkdir -p "/opt/$APP.new"
cp -r "$SRC/bin" "$SRC/src" "$SRC/static" "$SRC/migrations" "$SRC/deploy" \
      "$SRC/config.example.scm" "/opt/$APP.new/"
rm -rf "/opt/$APP"
mv "/opt/$APP.new" "/opt/$APP"

# The config: created from config.example.scm on the first install only,
# with a fresh session secret and HTTPS-only cookies. Set db-password in it.
mkdir -p "/etc/$APP"
if [ ! -f "/etc/$APP/config.scm" ]; then
  "$SCM" "/opt/$APP/bin/init-config.scm" "/etc/$APP/config.scm"
  sed -i -e 's|^(define secure-cookies? #f)|(define secure-cookies? #t)|' \
         -e 's|^(define data-dir "var")|(define data-dir "/var/lib/folien")|' \
         "/etc/$APP/config.scm"
  NEW_CONFIG=1
fi
chown root:"$APP" "/etc/$APP/config.scm"
chmod 640 "/etc/$APP/config.scm"

for unit in "$APP.service" \
            "$APP-health.service" "$APP-health.timer" \
            "$APP-restart.service" "$APP-restart.timer"; do
  sed "s|/usr/local/bin/scm|$SCM|" "$SRC/deploy/systemd/$unit" \
    > "/etc/systemd/system/$unit"
done

systemctl daemon-reload
systemctl enable "$APP.service" "$APP-health.timer" "$APP-restart.timer"

if [ -n "${NEW_CONFIG:-}" ]; then
  echo "Set the database settings in /etc/$APP/config.scm, then:"
  echo "  sudo -u $APP $SCM /opt/$APP/bin/seed-admin.scm --config /etc/$APP/config.scm <name>"
  echo "  sudo systemctl start $APP.service $APP-health.timer $APP-restart.timer"
  exit 0
fi

systemctl restart "$APP.service"
systemctl start "$APP-health.timer" "$APP-restart.timer"

echo "Installed. Config: /etc/$APP/config.scm. Logs: journalctl -u $APP -f"
