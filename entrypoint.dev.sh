#!/bin/sh
set -e

is_empty_dir() {
  [ ! -d "$1" ] && return 0
  [ -z "$(ls -A "$1" 2>/dev/null)" ]
}

# 1) 应用目录初始化（首次运行从内置备份拷贝）
if is_empty_dir /app/www; then
  echo "[init] /app/www is empty. Seeding from /usr/src/www ..."
  mkdir -p /app
  cp -a /usr/src/www /app/
  chown -R www:www /app/www
else
  echo "[init] /app/www not empty. Skip seeding."
fi

# 2) 准备 crontab 目录 & 权限（Alpine/BusyBox 严格要求）
addgroup -S crontab 2>/dev/null || true
mkdir -p /var/spool/cron/crontabs
chown root:crontab /var/spool/cron/crontabs
chmod 1730 /var/spool/cron/crontabs

CRON_DIR="/var/spool/cron/crontabs"
SRC="/usr/src/cron/www"   # 现在直接用“成品”而不是 .tpl
DST="$CRON_DIR/www"

# 3) 若用户 crontab 为空，则安装默认任务（不做任何 key 检测/替换）
if [ ! -s "$DST" ] && [ -f "$SRC" ]; then
  echo "[init] Installing default crontab from $SRC ..."
  cp "$SRC" "$DST"
fi

# 4) 最终确保用户 crontab 权限/行尾合规
if [ -f "$DST" ]; then
  chown www:crontab "$DST"
  chmod 600 "$DST"
  # 确保最后有换行（BusyBox 否则可能忽略最后一行）
  tail -c1 "$DST" | od -An -t x1 | grep -q '0a' || printf '\n' >> "$DST"
fi

# 5) 启动 crond（后台），再以前台方式启动 supervisord 维持容器
crond -l 8
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
