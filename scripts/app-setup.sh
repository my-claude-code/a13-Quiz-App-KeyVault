#!/bin/bash
set -euo pipefail
exec > /var/log/app-setup.log 2>&1

echo "==> Waiting for apt lock to clear..."
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 2; done

echo "==> Installing system packages..."
DEBIAN_FRONTEND=noninteractive apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-pip python3-venv nginx git curl

echo "==> Cloning app from GitHub..."
git clone ${github_repo} /opt/quiz-app
cd /opt/quiz-app

echo "==> Creating virtual environment and installing packages..."
python3 -m venv venv
source venv/bin/activate
pip install --quiet -r requirements.txt
pip install --quiet gunicorn

echo "==> Writing .env..."
cat > .env <<'ENV_EOF'
ENTRA_CLIENT_ID=${entra_client_id}
ENTRA_CLIENT_SECRET=${entra_client_secret}
ENTRA_TENANT_ID=${entra_tenant_id}
REDIRECT_URI=https://${domain}/auth/callback
FLASK_SECRET_KEY=${flask_secret_key}
DATABASE_URL=postgresql+psycopg2://quizadmin:${db_password}@${pg_host}:5432/quiz?sslmode=require
ENV_EOF

echo "==> Waiting for PostgreSQL at ${pg_host}..."
i=0
until python3 -c "
import psycopg2
psycopg2.connect(host='${pg_host}', user='quizadmin', password='${db_password}', database='quiz', sslmode='require').close()
" 2>/dev/null; do
    i=$((i+1))
    echo "Attempt $i — PostgreSQL not ready, retrying in 15s..."
    sleep 15
done
echo "PostgreSQL ready after $i attempt(s)."

echo "==> Initialising database schema..."
python3 -c "from app import create_app; create_app()"

echo "==> Creating systemd service for gunicorn..."
cat > /etc/systemd/system/quiz-app.service <<'SVC_EOF'
[Unit]
Description=Quiz App (gunicorn)
After=network.target

[Service]
User=root
WorkingDirectory=/opt/quiz-app
Environment=PATH=/opt/quiz-app/venv/bin
ExecStart=/opt/quiz-app/venv/bin/gunicorn -w 2 -b 127.0.0.1:5000 app:app
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
SVC_EOF

systemctl daemon-reload
systemctl enable quiz-app
systemctl start quiz-app

echo "==> Pulling TLS certificate and key from Key Vault..."
KV_NAME="${kv_name}"

# Get access token using VM managed identity
ACCESS_TOKEN=$(curl -sf \
  -H "Metadata: true" \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://vault.azure.net" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# Pull TLS certificate
curl -sf \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "https://$KV_NAME.vault.azure.net/secrets/quiz-tls-cert?api-version=7.4" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['value'])" \
  > /etc/ssl/certs/quiz-app.crt

# Pull TLS private key
curl -sf \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "https://$KV_NAME.vault.azure.net/secrets/quiz-tls-key?api-version=7.4" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['value'])" \
  > /etc/ssl/private/quiz-app.key

chmod 600 /etc/ssl/private/quiz-app.key
echo "TLS certificate and key retrieved from Key Vault."

echo "==> Configuring nginx for ${domain}..."
cat > /etc/nginx/sites-available/quiz-app <<'NGINX_EOF'
server {
    listen 443 ssl;
    server_name ${domain};

    ssl_certificate     /etc/ssl/certs/quiz-app.crt;
    ssl_certificate_key /etc/ssl/private/quiz-app.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    location / {
        proxy_pass         http://127.0.0.1:5000;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_read_timeout 60s;
    }
}

server {
    listen 80;
    server_name ${domain};
    return 301 https://$host$request_uri;
}
NGINX_EOF

ln -sf /etc/nginx/sites-available/quiz-app /etc/nginx/sites-enabled/quiz-app
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl restart nginx

echo "==> Setup complete. App running at https://${domain}"
