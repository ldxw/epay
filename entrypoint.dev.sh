#!/bin/sh
set -e

PHP_BIN="${PHP_BIN:-/usr/bin/php82}"
[ -x "$PHP_BIN" ] || PHP_BIN="/usr/bin/php"

is_empty_dir() {
  [ ! -d "$1" ] && return 0
  [ -z "$(ls -A "$1" 2>/dev/null)" ]
}

detect_cron_key() {
  # 1) 环境变量优先
  if [ -n "${CRON_KEY:-}" ]; then
    echo "$CRON_KEY"; return 0
  fi
  # 2) PHP 读取配置
  "$PHP_BIN" -r '
    error_reporting(0);
    if (!isset($_SERVER["HTTP_USER_AGENT"])) $_SERVER["HTTP_USER_AGENT"]="CLI";
    chdir("/app/www");
    @include "config.php";
    @include "includes/common.php";
    @include "includes/config.php";
    if (isset($conf) && isset($conf["cronkey"])) echo $conf["cronkey"];
  ' 2>/dev/null || true
}

render_cron() {
  CK="$1"; TPL="$2"; OUT="$3"
  # 用 PHP 替换占位符，避免 sed 转义问题
  "$PHP_BIN" -r '
    $ck = $argv[1];
    $in = $argv[2]; $out = $argv[3];
    $tpl = @file_get_contents($in);
    if ($tpl === false) { fwrite(STDERR, "[error] read template failed\n"); exit(1); }
    $body = str_replace("__CRON_KEY__", $ck, $tpl);
    if (@file_put_contents($out, $body) === false) { fwrite(STDERR, "[error] write cron failed\n"); exit(1); }
  ' "$CK" "$TPL" "$OUT"
}

# 1) 初始化应用目录（首次运行从内置备份拷贝）
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
TPL="/usr/src/cron/www.tpl"
OUT="$CRON_DIR/www"

# 3) 若用户 crontab 为空，用模板渲染安装（占位符 __CRON_KEY__）
if [ ! -s "$OUT" ] && [ -f "$TPL" ]; then
  CK="$(detect_cron_key || true)"
  if [ -z "$CK" ]; then
    echo "[warn] 未能自动探测到 \$conf['cronkey']，先写入空 key（任务会因 key 不匹配而不生效）。"
    echo "[hint] 可通过 -e CRON_KEY=实际值 覆盖，或保证配置文件可被检测到。"
  else
    echo "[init] 检测到 cronkey（长度 ${#CK}）"
  fi
  render_cron "$CK" "$TPL" "$OUT"
fi

# 4) 最终确保用户 crontab 权限/行尾合规
if [ -f "$OUT" ]; then
  chown www:crontab "$OUT"
  chmod 600 "$OUT"
  # 确保最后有换行（BusyBox 否则可能忽略最后一行）
  tail -c1 "$OUT" | od -An -t x1 | grep -q '0a' || printf '\n' >> "$OUT"
fi

# 5) 启动 crond（后台），然后以前台方式启动 supervisord 维持容器
crond -l 8
exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
