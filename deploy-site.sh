#!/usr/bin/env bash
# =============================================================================
#  WordPress & Node Deployer  v13-universal  —  优化版: CentOS/Ubuntu 通用 + 自动判断 package manager
# =============================================================================
set -Eeuo pipefail; IFS=$'\n\t'
trap 'echo "\u274c Error line $LINENO"; exit 1' ERR
[[ $# -lt 2 || $# -gt 3 ]] && { echo "\u7528\u6cd5: $0 <slug> <domain> [wordpress|node]"; exit 1; }
SLUG=$1; DOMAIN=$2; TYPE=${3:-wordpress}

# -------- 相关路径和选择随机端口 ------------------------
BASE="/sites/$SLUG"; PORT=$(shuf -i 8200-8999 -n1)
mkdir -p "$BASE/logs" "$BASE/data/uploads" "$BASE/data/themes" "$BASE/data/plugins" "$BASE/data/languages"

# -------- 判断 package manager --------------------------------------------------
if command -v apt >/dev/null; then
  PM="apt"; UPDATE="apt update"
elif command -v yum >/dev/null; then
  PM="yum"; UPDATE="yum makecache"
else
  echo "\u274c 未找到 apt 或 yum\uff0c\u8bf7手动安装 docker/nginx/certbot"; exit 1
fi

# -------- 生成 docker-compose.yml ---------------------------------------------
cat >"$BASE/docker-compose.yml"<<YML
services:
YML

if [[ $TYPE == wordpress ]]; then
cat >>"$BASE/docker-compose.yml"<<YML
  db_${SLUG}:
    image: mysql:5.7
    container_name: db_${SLUG}
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: root
      MYSQL_DATABASE: ${SLUG}_db
    volumes:
      - db_${SLUG}:/var/lib/mysql

  wp_${SLUG}:
    image: wordpress:php8.1-apache
    container_name: wp_${SLUG}
    restart: unless-stopped
    depends_on: [db_${SLUG}]
    environment:
      WORDPRESS_DB_HOST: db_${SLUG}:3306
      WORDPRESS_DB_USER: root
      WORDPRESS_DB_PASSWORD: root
      WORDPRESS_DB_NAME: ${SLUG}_db
      WORDPRESS_TABLE_PREFIX: wp_${SLUG}_
    volumes:
      - ./data/themes:/var/www/html/wp-content/themes
      - ./data/plugins:/var/www/html/wp-content/plugins
      - ./data/uploads:/var/www/html/wp-content/uploads
      - ./data/languages:/var/www/html/wp-content/languages
      - ./php.ini:/usr/local/etc/php/conf.d/90-custom.ini
    ports: ["${PORT}:80"]
    healthcheck:
      test: ["CMD","apache2ctl","-t"]
      interval: 10s
      timeout: 3s
      retries: 40

volumes:
  db_${SLUG}: {}
YML
else
cat >>"$BASE/docker-compose.yml"<<YML
  node_${SLUG}:
    image: node:18-alpine
    container_name: node_${SLUG}
    restart: unless-stopped
    command: sh -c "npm i -g serve && echo '<h1>${SLUG}</h1>' > index.html && serve -s -l 3000 ."
    ports: ["${PORT}:3000"]
    healthcheck:
      test: ["CMD","wget","-qO-","http://localhost:3000/"]
      interval: 10s
      timeout: 3s
      retries: 30
YML
fi

# -------- php.ini 自定义 ---------------------------------------------------
cat > "$BASE/php.ini" <<CONF
memory_limit = 2048M
upload_max_filesize = 2048M
post_max_size = 2048M
max_execution_time = 1000
max_input_time = 1000
max_input_vars = 10000
CONF

# -------- 启动 docker 容器 ------------------------------------------------
cd "$BASE"
docker compose up -d --remove-orphans
SVC=$([[ $TYPE == wordpress ]] && echo wp_${SLUG} || echo node_${SLUG})

for i in {1..120}; do
  [[ $(docker inspect -f '{{.State.Health.Status}}' "$SVC" 2>/dev/null) == healthy ]] && break
  sleep 5; printf '.'
done; echo

# -------- WordPress 初始化 --------------------------------------------------
if [[ $TYPE == wordpress ]]; then
docker exec wp_${SLUG} bash -c '
  command -v wp >/dev/null || {
    curl -sSLO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    chmod +x wp-cli.phar && mv wp-cli.phar /usr/local/bin/wp
  }

  wp core install --url=https://'"$DOMAIN"' --title='"$SLUG"' \
    --admin_user=admin --admin_password=123456 --admin_email=admin@'"$DOMAIN"' \
    --skip-email --allow-root || true

  wp language core install zh_CN --activate --allow-root
  wp option update WPLANG zh_CN --allow-root
  wp site switch-language zh_CN --allow-root

  wp theme install https://raw.githubusercontent.com/chenjianhuan/woodmart-china/main/woodmart.zip --activate --allow-root || true

  curl -fsSL -o /var/www/html/wp-content/languages/themes/woodmart-zh_CN.mo https://raw.githubusercontent.com/chenjianhuan/woodmart-china/main/woodmart-zh_CN.mo
  curl -fsSL -o /var/www/html/wp-content/languages/themes/woodmart-zh_CN.po https://raw.githubusercontent.com/chenjianhuan/woodmart-china/main/woodmart-zh_CN.po

  wp plugin install woocommerce loco-translate --activate --allow-root

  for plugin in woocommerce loco-translate js_composer revslider; do
    wp language plugin install "$plugin" zh_CN --allow-root || true
  done

  for url in \
    https://github.com/chenjianhuan/woodmart-china/raw/main/woodmart-core.zip \
    https://github.com/chenjianhuan/woodmart-china/raw/main/js_composer.zip \
    https://github.com/chenjianhuan/woodmart-china/raw/main/revslider.zip; do

    filename=$(basename "$url")
    tmp="/tmp/$filename"

    echo "\ud83d\udce6 \u4e0b\u8f7d\u63d2\u4ef6: $filename"
    curl -fsSL "$url" -o "$tmp" && \
      wp plugin install "$tmp" --activate --allow-root || \
      echo "\u274c \u63d2\u4ef6\u5b89\u88c5\u5931\u8d25: $filename"
  done

  chown -R www-data:www-data /var/www/html
'
fi

# -------- Nginx 配置 -----------------------------------------------------------
mkdir -p /etc/nginx/sites-enabled
rm -f "/etc/nginx/sites-enabled/${SLUG}.conf"
cat >"/etc/nginx/sites-enabled/${SLUG}.conf"<<N
server {
  listen 80;
  server_name ${DOMAIN} www.${DOMAIN};
  client_max_body_size 2048M;
  location / {
    proxy_pass http://127.0.0.1:${PORT};
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }
}
N
nginx -t && nginx -s reload

# -------- HTTPS 证书 ------------------------------------------------------------
if ! command -v certbot >/dev/null; then
  echo "\ud83d\udce6 \u672a\u68c0\u6d4b\u5230 certbot\uff0c\u6b63\u5728\u5b89\u88c5..."
  $UPDATE && $PM install -y certbot python3-certbot-nginx
fi

if certbot certificates 2>/dev/null | grep -q "Domains: .*${DOMAIN}"; then
  echo "\u2705 \u8bc1\u4e66\u5df2\u5b58\u5728\uff0c\u8df3\u8fc7\u7533\u8bf7"
else
  certbot --nginx -d ${DOMAIN} -d www.${DOMAIN} -m admin@${DOMAIN} --agree-tos --non-interactive --redirect || {
    echo "\u274c \u81ea\u52a8\u7533\u8bf7\u8bc1\u4e66\u5931\u8d25"
  }
fi


# -------- 完成 ---------------------------------------------------------------
echo "\ud83c\udf89  \u90e8\u7f72\u5b8c\u6210 \u2794 https://${DOMAIN}  (\u540e\u53f0: /wp-admin  admin / 123456)"

