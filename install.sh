#!/bin/bash
# =====================================================================
#  FENIX PANEL - INSTALADOR COMPLETO DE UN SOLO LINK (repo publico)
#  Instala: panel + Nginx + SSL Let's Encrypt + pm2 + backup diario
#           + boton "GENERAR APK" conectado + generador de APK listo.
#
#  El backup del panel y el APK base van CIFRADOS (7z AES-256).
#  Solo se pide la clave una vez al instalar. NO pongas secretos
#  en este archivo: es publico.
# =====================================================================
set -uo pipefail

DOMAIN="${DOMAIN:-panel.sistems.cloud}"
EMAIL="${EMAIL:-EDUARD@GMAIL.COM}"
GH_REPO="eduardleetch-svg/FENIX-PANEL-PUBLIC"
GH_BRANCH="main"
PANEL_ENC_FILE="panel.7z"
APK_ENC_FILE="apk.7z"
PATCH_FILE="panel-patch.tar.gz"
APP_DIR="/opt/dtunnel"
APKGEN_HOME="/opt/apk-generator"
APP_PORT=3000

G='\e[1;32m'; R='\e[1;31m'; Y='\e[1;33m'; N='\e[0m'
ok()   { echo -e "${G}✔ $*${N}"; }
warn() { echo -e "${Y}⚠ $*${N}"; }
die()  { echo -e "${R}✘ $*${N}"; exit 1; }
step() { echo -e "\n${Y}==> $*${N}"; }

[ "$(id -u)" -eq 0 ] || die "Ejecuta como root."

step "0/9  IP de esta VPS y descarga de los archivos cifrados"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null 2>&1
apt-get install -y curl dnsutils >/dev/null 2>&1
apt-get install -y p7zip-full >/dev/null 2>&1 || apt-get install -y 7zip >/dev/null 2>&1
SZ="$(command -v 7z || command -v 7zz || true)"
[ -n "$SZ" ] || die "No pude instalar 7z."

SERVER_IP="$(curl -fsS4 --max-time 10 https://api.ipify.org || curl -fsS4 --max-time 10 https://ifconfig.me)"
[[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "No pude detectar la IP publica."
ok "IP detectada: $SERVER_IP  |  Dominio: $DOMAIN"

WORK="$(mktemp -d)"
HTTP=$(curl -sSL -w '%{http_code}' -o "$WORK/$PANEL_ENC_FILE" \
    "https://raw.githubusercontent.com/${GH_REPO}/${GH_BRANCH}/${PANEL_ENC_FILE}")
[ "$HTTP" = "200" ] || die "No pude bajar $PANEL_ENC_FILE (HTTP $HTTP). Revisa que el repo sea publico y el archivo exista."
ok "Backup del panel descargado ($(du -h "$WORK/$PANEL_ENC_FILE" | cut -f1))"

# El APK base es opcional: si no esta en el repo, se instala el panel igual
# y el generador de APK se deja listo para correr "setup" mas tarde a mano.
HTTP_APK=$(curl -sSL -w '%{http_code}' -o "$WORK/$APK_ENC_FILE" \
    "https://raw.githubusercontent.com/${GH_REPO}/${GH_BRANCH}/${APK_ENC_FILE}" 2>/dev/null || echo 000)
HAVE_APK=0
if [ "$HTTP_APK" = "200" ]; then
    HAVE_APK=1
    ok "APK base descargado ($(du -h "$WORK/$APK_ENC_FILE" | cut -f1))"
else
    warn "No encontre $APK_ENC_FILE en el repo (no es critico, se omite el generador de APK)."
fi

PASS="${PASS:-}"
for intento in 1 2 3; do
    if [ -z "$PASS" ]; then read -rsp "Clave (panel y APK): " PASS </dev/tty; echo; fi
    rm -rf "$WORK/out"; mkdir -p "$WORK/out"
    if "$SZ" x -p"$PASS" -o"$WORK/out" -y "$WORK/$PANEL_ENC_FILE" >/dev/null 2>&1; then break; fi
    warn "Clave incorrecta ($intento/3)"; PASS=""
    [ "$intento" -eq 3 ] && die "Clave incorrecta. Saliendo."
done
BACKUP="$(find "$WORK/out" -type f \( -name '*.tar.gz' -o -name '*.tgz' -o -name '*.tar' \) | head -1)"
[ -n "$BACKUP" ] || die "El 7z no contiene un .tar.gz. Contenido: $(ls "$WORK/out")"
tar -tf "$BACKUP" >/dev/null 2>&1 || die "El backup extraido esta danado."
ok "Backup del panel descifrado"

BASE_APK=""
if [ "$HAVE_APK" = "1" ]; then
    mkdir -p "$WORK/out-apk"
    if "$SZ" x -p"$PASS" -o"$WORK/out-apk" -y "$WORK/$APK_ENC_FILE" >/dev/null 2>&1; then
        BASE_APK="$(find "$WORK/out-apk" -type f -iname '*.apk' | head -1)"
        [ -n "$BASE_APK" ] && ok "APK base descifrado" || warn "El 7z del APK no contiene un .apk, se omite."
    else
        warn "La clave no descifro $APK_ENC_FILE (¿se cifro con otra clave?). Se omite el generador de APK."
    fi
fi
unset PASS

# ---------------------------------------------------------------- DNS
step "DNS  $DOMAIN -> $SERVER_IP"
if dig +short A "$DOMAIN" @1.1.1.1 | grep -qw "$SERVER_IP"; then
    ok "DNS propagado"
else
    warn "El registro A de $DOMAIN aun no resuelve a $SERVER_IP (o no ha propagado). Continuo sin esperar; si Certbot falla mas adelante, revisa el DNS."
fi

# ---------------------------------------------------------------- 1
step "1/9  Paquetes base"
apt-get install -y curl ca-certificates gnupg build-essential python3 \
    nginx certbot python3-certbot-nginx sqlite3 ufw dnsutils cron \
    || die "Falló la instalación de paquetes."
ok "Paquetes instalados"

# ---------------------------------------------------------------- 2
step "2/9  Node.js 20"
if ! command -v node >/dev/null || [ "$(node -v | cut -d. -f1 | tr -d v)" -lt 18 ]; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - || die "No pude agregar el repo de NodeSource."
    apt-get install -y nodejs || die "No pude instalar Node.js."
fi
ok "Node $(node -v) / npm $(npm -v)"
npm install -g pm2 >/dev/null 2>&1 || die "No pude instalar pm2."
ok "pm2 $(pm2 -v)"

# ---------------------------------------------------------------- 3
step "3/9  Firewall (ESTA es la causa habitual de que falle el SSL dentro del VPS)"
ufw allow OpenSSH >/dev/null
ufw allow 80/tcp  >/dev/null
ufw allow 443/tcp >/dev/null
ufw --force enable >/dev/null
for p in 80 443; do
    iptables -C INPUT -p tcp --dport $p -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport $p -j ACCEPT
done
ok "Puertos 22, 80 y 443 abiertos (el 3000 queda cerrado al exterior)"

# ---------------------------------------------------------------- 4
step "4/9  Extrayendo el panel en $APP_DIR"
if [ -d "$APP_DIR" ]; then
    mv "$APP_DIR" "${APP_DIR}.old.$(date +%s)"
    warn "Había una instalación previa, se movió a ${APP_DIR}.old.*"
fi
mkdir -p "$APP_DIR"
TOP=$(tar -tf "$BACKUP" | sed 's|^\./||' | cut -d/ -f1 | sort -u | grep -v '^$')
if [ "$(echo "$TOP" | wc -l)" -eq 1 ] && tar -tf "$BACKUP" | sed 's|^\./||' | grep -q "^${TOP}/"; then
    tar -xf "$BACKUP" -C "$APP_DIR" --strip-components=1 || die "No pude extraer el backup."
else
    tar -xf "$BACKUP" -C "$APP_DIR" || die "No pude extraer el backup."
fi
[ -f "$APP_DIR/build/index.js" ] || die "El backup no contiene build/index.js (estructura: $(ls "$APP_DIR" | tr '\n' ' '))"
chmod 600 "$APP_DIR/.env"
ok "Panel extraído (se conserva tu .env y tu base de datos)"

# Boton "GENERAR APK" conectado al backend (codigo, no lleva secretos).
HTTP_PATCH=$(curl -sSL -w '%{http_code}' -o "$WORK/$PATCH_FILE" \
    "https://raw.githubusercontent.com/${GH_REPO}/${GH_BRANCH}/${PATCH_FILE}" 2>/dev/null || echo 000)
if [ "$HTTP_PATCH" = "200" ] && tar -tzf "$WORK/$PATCH_FILE" >/dev/null 2>&1; then
    tar -xzf "$WORK/$PATCH_FILE" -C "$APP_DIR" || die "No pude aplicar el parche del boton APK."
    ok "Boton GENERAR APK aplicado al panel"
else
    warn "No encontre $PATCH_FILE en el repo (no es critico, el panel queda sin ese boton)."
fi

# ---------------------------------------------------------------- 5
step "5/9  Dependencias, base de datos y compilacion"
cd "$APP_DIR"
npm install || die "Falló npm install."
npx prisma generate       || die "Falló prisma generate."
npx prisma migrate deploy || die "Falló prisma migrate deploy."
npx tsc --build            || die "Falló la compilación (tsc)."
npm prune --omit=dev >/dev/null 2>&1 || true

if ! grep -q "trustProxy" build/http.js; then
    sed -i 's/ignoreTrailingSlash: true }/ignoreTrailingSlash: true, trustProxy: true }/' build/http.js
    grep -q "trustProxy" build/http.js && ok "trustProxy activado" || warn "No pude activar trustProxy (no es crítico)"
fi

# ---------------------------------------------------------------- 6
step "6/9  Iniciando el panel con pm2"
pm2 delete DTunnel >/dev/null 2>&1 || true
pm2 start ecosystem.config.js || die "pm2 no pudo iniciar el panel."
pm2 save
pm2 startup systemd -u root --hp /root >/dev/null 2>&1 || true
sleep 4
if curl -fs -o /dev/null "http://127.0.0.1:${APP_PORT}/"; then
    ok "El panel responde en 127.0.0.1:${APP_PORT}"
else
    pm2 logs DTunnel --lines 30 --nostream
    die "El panel no responde en el puerto ${APP_PORT}."
fi

chmod +x scripts/backup-db.sh
( crontab -l 2>/dev/null | grep -v backup-db.sh ; echo "15 3 * * * $APP_DIR/scripts/backup-db.sh >> $APP_DIR/backups/backup.log 2>&1" ) | crontab -

# ---------------------------------------------------------------- 7
step "7/9  Nginx (HTTP) para $DOMAIN"
cat > /etc/nginx/sites-available/dtunnel <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    client_max_body_size 20m;

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 120s;
    }
}
EOF
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/dtunnel /etc/nginx/sites-enabled/dtunnel
nginx -t || die "Configuración de Nginx inválida."
systemctl enable nginx >/dev/null 2>&1
systemctl restart nginx || die "Nginx no arrancó."
ok "Nginx sirviendo el panel por HTTP"

# ---------------------------------------------------------------- 8
step "8/9  Certificado SSL"
if curl -fs -o /dev/null --max-time 8 -H "Host: $DOMAIN" "http://127.0.0.1/"; then
    ok "Nginx responde localmente en el puerto 80"
fi

if certbot --nginx -d "$DOMAIN" -m "$EMAIL" --agree-tos --no-eff-email \
        --redirect --non-interactive; then
    ok "Certificado emitido e instalado"
    systemctl enable --now certbot.timer >/dev/null 2>&1 || true
    certbot renew --dry-run >/dev/null 2>&1 && ok "Renovación automática verificada" || warn "El dry-run de renovación falló, revisa: certbot renew --dry-run"
else
    echo -e "\n${R}✘ Certbot falló. Diagnóstico:${N}"
    echo "--- ufw ---";        ufw status
    echo "--- puertos ---";    ss -tlnp | grep -E ':80 |:443 '
    echo "--- iptables INPUT ---"; iptables -S INPUT | head -20
    echo "--- nginx ---";      systemctl is-active nginx
    echo "--- log certbot ---"; tail -n 30 /var/log/letsencrypt/letsencrypt.log 2>/dev/null
    die "Copia toda esta salida y pásamela para verla."
fi

# ---------------------------------------------------------------- 9
step "9/9  Generador de APK"
mkdir -p "$APKGEN_HOME"
HTTP_GEN=$(curl -sSL -w '%{http_code}' -o "$APKGEN_HOME/apk-generator.sh" \
    "https://raw.githubusercontent.com/${GH_REPO}/${GH_BRANCH}/apk-generator.sh" 2>/dev/null || echo 000)
if [ "$HTTP_GEN" = "200" ]; then
    chmod +x "$APKGEN_HOME/apk-generator.sh"
    if [ -n "$BASE_APK" ]; then
        bash "$APKGEN_HOME/apk-generator.sh" setup "$BASE_APK" \
            && ok "Generador de APK listo (keystore creado en $APKGEN_HOME)" \
            || warn "El setup del generador fallo. Corre a mano: bash $APKGEN_HOME/apk-generator.sh setup <tu_apk>"
    else
        warn "apk-generator.sh instalado, pero falta el APK base. Corre a mano:"
        warn "  bash $APKGEN_HOME/apk-generator.sh setup /ruta/a/tu.apk"
    fi
else
    warn "No pude bajar apk-generator.sh (no es critico, el panel sigue funcionando)."
fi

rm -rf "$WORK"

echo
echo -e "${G}=====================================================${N}"
echo -e "${G}  LISTO ->  https://${DOMAIN}${N}"
echo -e "${G}=====================================================${N}"
curl -sI "https://${DOMAIN}" | head -5
echo
echo "Comandos útiles:"
echo "  pm2 status | pm2 logs DTunnel | pm2 restart DTunnel"
echo "  nginx -t && systemctl reload nginx"
echo "  certbot certificates"
[ -z "$BASE_APK" ] && [ "$HTTP_GEN" = "200" ] && echo "  bash $APKGEN_HOME/apk-generator.sh setup /ruta/a/tu.apk   (falta hacer esto)"
