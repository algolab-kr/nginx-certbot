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
# 기존 app.conf가 있으면 덮어쓰기 전에 백업해 둔다(직접 수정분 유실 방지).
# 배포별 라우팅(proxy_pass 등)은 app.conf가 아니라 data/nginx/server-locations/ 의
# *.conf.template 에 넣는다(아래에서 렌더링됨). app.conf.template은 generic하게 유지.
if [ -e "$nginx_conf" ]; then
  cp "$nginx_conf" "$nginx_conf.bak"
  echo "Backed up existing $nginx_conf to $nginx_conf.bak"
fi
sed -e "s|\${DOMAIN}|${public_domains[0]}|g" \
    "$nginx_template" > "$nginx_conf"
echo


# 배포별 location 스니펫(server-locations/*.conf.template)을 렌더링한다.
# 백엔드 private IP는 이 호스트에서 자동 감지해 ${HOST_PRIVATE_IP} 자리에 주입한다.
# (docs 접근 허용 IP 같은 배포별 값은 *.conf.template 안에 직접 적어 둔다 — 레포에 안 올라감.)
locations_dir="./data/nginx/server-locations"
shopt -s nullglob
location_templates=("$locations_dir"/*.conf.template)
shopt -u nullglob
if [ ${#location_templates[@]} -ne 0 ]; then
  # 호스트(EC2)의 private IP 자동 감지. HOST_PRIVATE_IP 환경변수로 덮어쓸 수 있음.
  host_private_ip="${HOST_PRIVATE_IP:-}"
  if [ -z "$host_private_ip" ]; then
    # 1) EC2 IMDSv2 → 2) IMDSv1 → 3) 로컬 인터페이스 순으로 시도
    imds_token=$(curl -s -m 2 -X PUT "http://169.254.169.254/latest/api/token" \
      -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null)
    if [ -n "$imds_token" ]; then
      host_private_ip=$(curl -s -m 2 -H "X-aws-ec2-metadata-token: $imds_token" \
        "http://169.254.169.254/latest/meta-data/local-ipv4" 2>/dev/null)
    fi
    [ -z "$host_private_ip" ] && host_private_ip=$(curl -s -m 2 \
      "http://169.254.169.254/latest/meta-data/local-ipv4" 2>/dev/null)
    [ -z "$host_private_ip" ] && host_private_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  fi
  if ! echo "$host_private_ip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
    echo "Error: failed to detect host private IP (got '$host_private_ip')." >&2
    echo "       Set it explicitly and re-run, e.g.: HOST_PRIVATE_IP=10.0.1.32 ./init-letsencrypt.sh" >&2
    exit 1
  fi
  echo "### Rendering server-locations snippets (HOST_PRIVATE_IP=$host_private_ip) ..."
  for tmpl in "${location_templates[@]}"; do
    out="${tmpl%.template}"
    sed -e "s|\${HOST_PRIVATE_IP}|$host_private_ip|g" "$tmpl" > "$out"
    echo "  $(basename "$tmpl") -> $(basename "$out")"
  done
  echo
fi


echo "### Starting nginx ..."
docker compose up --force-recreate -d nginx
echo

echo "### Deleting dummy/stale certificate lineages for $public_domains ..."
# base 이름과 접미사 계보(-0001, -0002 ...)를 모두 제거해 certbot이 --cert-name으로
# 깨끗하게 base 이름($public_domains)에 재발급하도록 한다.
# 주의: 글롭은 컨테이너 셸에서 확장되도록 sh -c 안에 둔다. 사설 CA 계보
# (ai-api-dev.internal... 등 다른 이름)는 이 글롭에 안 걸리므로 안전하다.
docker compose run --rm --entrypoint sh certbot -c "\
  rm -Rf /etc/letsencrypt/live/$public_domains /etc/letsencrypt/live/$public_domains-* \
         /etc/letsencrypt/archive/$public_domains /etc/letsencrypt/archive/$public_domains-* \
         /etc/letsencrypt/renewal/$public_domains.conf /etc/letsencrypt/renewal/$public_domains-*.conf"
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
    --cert-name ${public_domains[0]} \
    $staging_arg \
    $email_arg \
    $domain_args \
    $key_args \
    --agree-tos \
    --force-renewal" certbot
echo

echo "### Reloading nginx ..."
docker compose exec nginx nginx -s reload
