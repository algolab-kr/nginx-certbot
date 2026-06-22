#!/bin/bash

if ! docker compose version >/dev/null 2>&1; then
  echo 'Error: "docker compose" (Docker Compose V2) is not installed.' >&2
  exit 1
fi

# Public 도메인: Let's Encrypt(webroot, HTTP-01)로 발급. 공인 인터넷에서 도달 가능해야 함.
# 첫 번째 항목이 nginx 기본 server_name(${DOMAIN})으로 사용됩니다.
public_domains=(example.org www.example.org)
# Private 도메인: 사설 CA로 발급. 공인 CA로는 발급 불가한 내부 전용 도메인(예: private hosted zone).
# 비워두면 내부 인증서 발급을 건너뜁니다. 예: (internal.example.org admin.internal.example.org)
private_domains=()
rsa_key_size=4096
key_type="ecdsa" # "ecdsa" (recommended) or "rsa"
elliptic_curve="secp384r1"
data_path="./data/certbot"
email="" # Adding a valid address is strongly recommended
staging=0 # Set to 1 if you're testing your setup to avoid hitting request limits
internal_ca_days=3650 # 사설 CA 인증서 유효기간(일)
internal_cert_days=825 # 사설 서버 인증서 유효기간(일)

if [ ${#public_domains[@]} -eq 0 ]; then
  echo "Error: public_domains is empty. At least one public domain is required." >&2
  exit 1
fi

if [ -d "$data_path" ]; then
  read -p "Existing data found for $public_domains. Continue and replace existing certificate? (y/N) " decision
  if [ "$decision" != "Y" ] && [ "$decision" != "y" ]; then
    exit
  fi
fi


if [ ! -e "$data_path/conf/options-ssl-nginx.conf" ] || [ ! -e "$data_path/conf/ssl-dhparams.pem" ]; then
  echo "### Downloading recommended TLS parameters ..."
  mkdir -p "$data_path/conf"
  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf > "$data_path/conf/options-ssl-nginx.conf"
  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot/certbot/ssl-dhparams.pem > "$data_path/conf/ssl-dhparams.pem"
  echo
fi

echo "### Creating dummy certificate for $public_domains ..."
path="/etc/letsencrypt/live/$public_domains"
mkdir -p "$data_path/conf/live/$public_domains"
docker compose run --rm --entrypoint "\
  openssl req -x509 -nodes -newkey rsa:$rsa_key_size -days 1\
    -keyout '$path/privkey.pem' \
    -out '$path/fullchain.pem' \
    -subj '/CN=localhost'" certbot
echo


# 내부 전용 도메인은 사설 CA로 인증서를 발급한다. private_domains가 비어 있으면 건너뛴다.
if [ ${#private_domains[@]} -ne 0 ]; then
  internal_primary="${private_domains[0]}"
  internal_live="/etc/letsencrypt/live/$internal_primary"
  mkdir -p "$data_path/conf/ca"
  mkdir -p "$data_path/conf/live/$internal_primary"

  # 1) 사설 CA가 없으면 생성한다(있으면 재사용 — 클라이언트에 한 번만 신뢰시키면 됨).
  if [ ! -e "$data_path/conf/ca/ca-cert.pem" ]; then
    echo "### Creating internal Certificate Authority ..."
    docker compose run --rm --entrypoint "\
      openssl req -x509 -nodes -newkey rsa:$rsa_key_size -days $internal_ca_days \
        -keyout '/etc/letsencrypt/ca/ca-key.pem' \
        -out '/etc/letsencrypt/ca/ca-cert.pem' \
        -subj '/CN=Internal CA' \
        -addext 'basicConstraints=critical,CA:TRUE' \
        -addext 'keyUsage=critical,keyCertSign,cRLSign'" certbot
    echo
  fi

  # 2) 모든 private 도메인을 SAN으로 묶는다.
  san=""
  for d in "${private_domains[@]}"; do
    san="${san}${san:+,}DNS:$d"
  done

  # 3) 서버 키 + CSR 생성 후 사설 CA로 서명, fullchain(서버 + CA) 구성.
  echo "### Issuing internal certificate for ${private_domains[*]} ..."
  internal_cmd="\
    openssl req -nodes -newkey rsa:$rsa_key_size \
      -keyout $internal_live/privkey.pem \
      -out /tmp/internal.csr \
      -subj /CN=$internal_primary \
      -addext subjectAltName=$san \
      -addext basicConstraints=critical,CA:FALSE \
      -addext keyUsage=critical,digitalSignature,keyEncipherment \
      -addext extendedKeyUsage=serverAuth && \
    openssl x509 -req -in /tmp/internal.csr \
      -CA /etc/letsencrypt/ca/ca-cert.pem \
      -CAkey /etc/letsencrypt/ca/ca-key.pem \
      -CAcreateserial -days $internal_cert_days -copy_extensions copyall \
      -out $internal_live/cert.pem && \
    cat $internal_live/cert.pem /etc/letsencrypt/ca/ca-cert.pem > $internal_live/fullchain.pem"
  docker compose run --rm --entrypoint sh certbot -c "$internal_cmd"
  echo
fi


echo "### Generating nginx config for ${public_domains[0]} ..."
nginx_template="./data/nginx/app.conf.template"
nginx_conf="./data/nginx/app.conf"
if [ ! -e "$nginx_template" ]; then
  echo "Error: template $nginx_template not found." >&2
  exit 1
fi
sed -e "s|\${DOMAIN}|${public_domains[0]}|g" \
    "$nginx_template" > "$nginx_conf"
echo


echo "### Starting nginx ..."
docker compose up --force-recreate -d nginx
echo

echo "### Deleting dummy certificate for $public_domains ..."
docker compose run --rm --entrypoint "\
  rm -Rf /etc/letsencrypt/live/$public_domains && \
  rm -Rf /etc/letsencrypt/archive/$public_domains && \
  rm -Rf /etc/letsencrypt/renewal/$public_domains.conf" certbot
echo


echo "### Requesting Let's Encrypt certificate for $public_domains ..."
#Join $public_domains to -d args
domain_args=""
for domain in "${public_domains[@]}"; do
  domain_args="$domain_args -d $domain"
done

# Select appropriate email arg
case "$email" in
  "") email_arg="--register-unsafely-without-email" ;;
  *) email_arg="--email $email" ;;
esac

# Enable staging mode if needed
if [ $staging != "0" ]; then staging_arg="--staging"; fi

# Select key type arguments
case "$key_type" in
  ecdsa) key_args="--key-type ecdsa --elliptic-curve $elliptic_curve" ;;
  *)     key_args="--key-type rsa --rsa-key-size $rsa_key_size" ;;
esac

docker compose run --rm --entrypoint "\
  certbot certonly --webroot -w /var/www/certbot \
    $staging_arg \
    $email_arg \
    $domain_args \
    $key_args \
    --agree-tos \
    --force-renewal" certbot
echo

echo "### Reloading nginx ..."
docker compose exec nginx nginx -s reload
