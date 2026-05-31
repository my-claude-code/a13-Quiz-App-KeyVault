#!/bin/bash
set -euo pipefail
exec > /var/log/app-setup.log 2>&1

echo "==> Waiting for apt lock to clear..."
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 2; done

echo "==> Installing system packages..."
DEBIAN_FRONTEND=noninteractive apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    python3 python3-pip python3-venv nginx git curl \
    certbot python3-certbot-nginx

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

echo "==> Configuring nginx on port 80 (temporary, before cert)..."
cat > /etc/nginx/sites-available/quiz-app <<'NGINX_EOF'
server {
    listen 80;
    server_name ${domain};

    location / {
        proxy_pass         http://127.0.0.1:5000;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_read_timeout 60s;
    }
}
NGINX_EOF

ln -sf /etc/nginx/sites-available/quiz-app /etc/nginx/sites-enabled/quiz-app
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl restart nginx

echo "==> Waiting for DNS: ${domain} to resolve to this VM..."
i=0
until curl -sf --max-time 5 "http://${domain}" >/dev/null 2>&1; do
    i=$((i+1))
    echo "Attempt $i — DNS not resolving yet, retrying in 30s..."
    sleep 30
done
echo "DNS resolving after $i attempt(s)."

echo "==> Obtaining Let's Encrypt certificate for ${domain}..."
certbot --nginx \
    --non-interactive \
    --agree-tos \
    --email admin@${domain} \
    -d ${domain} \
    --redirect

echo "==> Enabling certbot auto-renewal..."
systemctl enable certbot.timer
systemctl start certbot.timer

echo "==> Setup complete. App running at https://${domain}"
