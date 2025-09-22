#!/bin/sh
set -e

is_empty_dir() {
  # 不存在视为空；存在但没有任何可见文件也为空
  [ ! -d "$1" ] && return 0
  [ -z "$(ls -A "$1" 2>/dev/null)" ]
}

detect_cron_key() {
  # 1) 环境变量优先
  if [ -n "$CRON_KEY" ]; then
    echo "$CRON_KEY"
    return 0
  fi

  # 2) 用 PHP 从常见配置中读取 $conf['cronkey']
  CRON_KEY_PHP=$(/usr/bin/php82 -r '
    error_reporting(0);
    chdir("/app/www");
    @include "config.php";
    @include "includes/common.php";
    @include "includes/config.php";
    if (isset($conf) && isset($conf["cronkey"])) {
      echo $conf["cronkey"];
    }
  ' 2>/dev/null || true)

  if [ -n "$CRON_KEY_PHP" ]; then
    echo "$CRON_KEY_PHP"
    return 0
  fi

  # 3) grep 源码兜底（匹配形如 $conf["cronkey"] = "xxx";）
  CRON_KEY_GREP=$(grep -RhoE "\$conf\[['\"]cronkey['\"]\]\s*=\s*['\"][^'\"]+['\"]" /app/www 2>/dev/null \
    | head -n1 \
    | sed -E "s/.*=\s*['\"]([^'\"]+)['\"].*/\1/")

  if [ -n "$CRON_KEY_GREP" ]; then
    echo "$CRON_KEY_GREP"
    return 0
  fi

  # 4) 实在没有就返回空串
  echo ""
  return 0
}

render_cron() {
  CK="$1"
  TPL="$2"
  OUT="$3"
  # 用 PHP 做安全替换，避免 sed 分隔符/转义问题
  /usr/bin/php82 -r '
    $ck = $argv[1];
    $tpl = @file_get_contents($argv[2]);
    if ($tpl === false) { fwrite(STDERR, "[error] Failed to read template\n"); exit(1); }
    $out = str_replace("__CRON_KEY__", $ck, $tpl);
    if (@file_put_contents($argv[3], $out) === false) { fwrite(STDERR, "[error] Failed to write cron file\n"); exit(1); }
  ' "$CK" "$TPL" "$OUT"
}

# 1) 应用目录初始化：若 /app/www 为空，则从内置备份 /usr/src/www 拷贝
if is_empty_dir /app/www; then
  echo "[init] /app/www is empty. Seeding from /usr/src/www ..."
  mkdir -p /app
  cp -a /usr/src/www /app/
  chown -R www:www /app/www
else
  echo "[init] /app/www not empty. Skip seeding."
fi

# 2) Cron 初始化：若 crontab 挂载为空，则从 /usr/src/cron/www.tpl 渲染并安装
CRON_DIR="/var/spool/cron/crontabs"
TPL="/usr/src/cron/www.tpl"
OUT="$CRON_DIR/www"
mkdir -p "$CRON_DIR"

if [ ! -s "$OUT" ] && [ -f "$TPL" ]; then
  CK="$(detect_cron_key)"
  if [ -z "$CK" ]; then
    echo "[warn] 未能自动探测到 \$conf['cronkey']；将写入空 key（任务会因 key 不匹配而不生效）。"
    echo "[hint] 可通过 -e CRON_KEY=实际值 覆盖，或保证配置文件可被检测到。"
  else
    # 为安全不直接打印明文，可按需改为 echo "$CK"
    echo "[init] 检测到 cronkey（长度 ${#CK}）"
  fi

  render_cron "$CK" "$TPL" "$OUT"
  chown www:root "$OUT"
  chmod 600 "$OUT"
else
  echo "[init] Cron for 'www' already present or template missing. Skip."
fi

exec "$@"
