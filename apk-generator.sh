#!/bin/bash
# =====================================================================
#  FENIX APK GENERATOR
#  Reempaqueta el APK base cambiando SOLO: paquete, nombre, icono,
#  ID del panel (assets/user_id.txt) y URL (assets/dtunnelmod.json).
#
#  Uso:
#    apk-generator.sh setup  /ruta/THE_FENIX.apk
#    apk-generator.sh build  --package com.cliente.vpn --name "CLIENTE VPN" \
#                            --icon logo.png --user-id <uuid> [--url https://panel...]
#  Imprime en la ULTIMA linea la ruta del APK generado.
# =====================================================================
set -uo pipefail

HOME_DIR="${APKGEN_HOME:-/opt/apk-generator}"
BASE="$HOME_DIR/base"
OUT="$HOME_DIR/out"
JAR="$HOME_DIR/apktool.jar"
KS="$HOME_DIR/keystore.jks"
KSPASS_FILE="$HOME_DIR/.ks-pass"
APKTOOL_URL="https://github.com/iBotPeaches/Apktool/releases/download/v2.10.0/apktool_2.10.0.jar"
DEFAULT_URL="${APKGEN_URL:-https://panel.sistems.cloud}"

die() { echo "ERROR: $*" >&2; exit 1; }

# ------------------------------------------------------------ setup
cmd_setup() {
    local apk="${1:-}"
    [ -f "$apk" ] || die "Uso: setup /ruta/THE_FENIX.apk"
    mkdir -p "$HOME_DIR" "$OUT"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1
    apt-get install -y default-jre-headless apksigner zipalign python3-pil curl unzip >/dev/null 2>&1 \
        || die "No pude instalar dependencias."
    [ -f "$JAR" ] || curl -fsSL -o "$JAR" "$APKTOOL_URL" || die "No pude bajar apktool."
    echo "Decodificando APK base (una sola vez)..."
    rm -rf "$BASE"
    java -jar "$JAR" d -s -f -o "$BASE" "$apk" >/dev/null 2>&1 || die "apktool no pudo decodificar el APK."
    [ -f "$BASE/AndroidManifest.xml" ] || die "Decodificacion incompleta."
    # paquete original, para reemplazarlo luego
    grep -o 'package="[^"]*"' "$BASE/AndroidManifest.xml" | head -1 | cut -d'"' -f2 > "$HOME_DIR/base-package.txt"
    if [ ! -f "$KS" ]; then
        head -c 24 /dev/urandom | base64 | tr -d '/+=' > "$KSPASS_FILE"; chmod 600 "$KSPASS_FILE"
        keytool -genkeypair -keystore "$KS" -storepass "$(cat "$KSPASS_FILE")" -keypass "$(cat "$KSPASS_FILE")" \
            -alias fenix -keyalg RSA -keysize 2048 -validity 36500 -dname "CN=FENIX PANEL" >/dev/null 2>&1 \
            || die "No pude crear el keystore."
        chmod 600 "$KS"
        echo "Keystore creado. HAZ RESPALDO de: $KS y $KSPASS_FILE"
    fi
    echo "Paquete base: $(cat "$HOME_DIR/base-package.txt")"
    echo "Setup OK en $HOME_DIR"
}

# ------------------------------------------------------------ build
cmd_build() {
    local PKG="" NAME="" ICON="" UID_="" URL="$DEFAULT_URL"
    while [ $# -gt 0 ]; do
        case "$1" in
            --package) PKG="${2:-}"; shift 2;;
            --name)    NAME="${2:-}"; shift 2;;
            --icon)    ICON="${2:-}"; shift 2;;
            --user-id) UID_="${2:-}"; shift 2;;
            --url)     URL="${2:-}"; shift 2;;
            *) die "Argumento desconocido: $1";;
        esac
    done
    [ -d "$BASE" ] || die "Falta el APK base. Ejecuta primero: setup"

    # ---- validaciones (todo lo que llega del usuario se valida aqui) ----
    [[ "$PKG" =~ ^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*){1,5}$ ]] && [ ${#PKG} -le 60 ] \
        || die "Paquete invalido (ej: com.cliente.vpn)."
    [[ "$UID_" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] \
        || die "ID de usuario invalido."
    [[ "$URL" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{2,5})?$ ]] || die "URL invalida."
    [ -n "$NAME" ] && [ ${#NAME} -le 30 ] || die "Nombre vacio o mayor a 30 caracteres."
    [ -f "$ICON" ] || die "Icono no encontrado."
    [ "$(stat -c %s "$ICON")" -le 5242880 ] || die "Icono mayor a 5 MB."

    mkdir -p "$OUT"
    local HASH
    HASH="$(printf '%s|%s|%s|%s|%s' "$PKG" "$NAME" "$UID_" "$URL" "$(sha256sum "$ICON" | cut -c1-16)" | sha256sum | cut -c1-16)"
    local FINAL="$OUT/${UID_}-${HASH}.apk"
    if [ -f "$FINAL" ]; then echo "(cache)"; echo "$FINAL"; return 0; fi

    # un solo build a la vez (consume CPU/RAM)
    exec 9>"$HOME_DIR/.lock"; flock 9

    W="$(mktemp -d "$HOME_DIR/work.XXXXXX")"
    trap 'rm -rf "${W:-}"' EXIT
    cp -r "$BASE" "$W/app"

    local OLDPKG; OLDPKG="$(cat "$HOME_DIR/base-package.txt")"
    export OLDPKG PKG NAME URL W
    python3 - <<'PY' || die "Fallo al editar los archivos del APK."
import os, re
from xml.sax.saxutils import escape
w=os.environ['W']+'/app'
old, new = os.environ['OLDPKG'], os.environ['PKG']
# 1) paquete en el manifest (incluye authorities y permisos que lo usan como prefijo)
p=w+'/AndroidManifest.xml'; s=open(p,encoding='utf-8').read()
s=s.replace(old,new); open(p,'w',encoding='utf-8').write(s)
# 2) nombre de la app
p=w+'/res/values/strings.xml'; s=open(p,encoding='utf-8').read()
name=escape(os.environ['NAME']).replace("'", "\\'").replace('"','\\"')
s2=re.sub(r'(<string name="app_name">)[^<]*(</string>)', lambda m: m.group(1)+name+m.group(2), s, count=1)
assert s2!=s or name in s, 'app_name no encontrado'
open(p,'w',encoding='utf-8').write(s2)
# 3) URL del panel (se conserva el resto del json)
import json
p=w+'/assets/dtunnelmod.json'; d=json.load(open(p,encoding='utf-8')); d['url']=os.environ['URL']
json.dump(d, open(p,'w',encoding='utf-8'), indent=4, ensure_ascii=False)
PY
    printf '%s' "$UID_" > "$W/app/assets/user_id.txt"

    # icono: SIEMPRE se convierte a PNG real (el original puede ser JPEG con extension .png)
    ICON_IN="$ICON" ICON_OUT="$W/app/res/drawable/ic_launcher.png" python3 - <<'PY' || die "Icono invalido (usa PNG o JPG)."
import os
from PIL import Image
im=Image.open(os.environ['ICON_IN']); im.load()
im=im.convert('RGBA'); w,h=im.size; s=max(w,h)
canvas=Image.new('RGBA',(s,s),(0,0,0,0)); canvas.paste(im,((s-w)//2,(s-h)//2))
canvas.resize((512,512), Image.LANCZOS).save(os.environ['ICON_OUT'],'PNG')
PY

    java -jar "$JAR" b -f -o "$W/built.apk" "$W/app" >"$W/apktool.log" 2>&1 \
        || { tail -5 "$W/apktool.log" >&2; die "apktool no pudo compilar."; }
    zipalign -p -f 4 "$W/built.apk" "$W/aligned.apk" || die "zipalign fallo."
    local PW; PW="$(cat "$KSPASS_FILE")"
    apksigner sign --ks "$KS" --ks-pass "pass:$PW" --key-pass "pass:$PW" \
        --min-sdk-version 21 --v1-signing-enabled true --v2-signing-enabled true --v3-signing-enabled true \
        --out "$W/signed.apk" "$W/aligned.apk" \
        || die "apksigner fallo."
    apksigner verify --min-sdk-version 21 "$W/signed.apk" >/dev/null 2>&1 || die "La firma no verifica."
    mv "$W/signed.apk" "$FINAL"
    echo "$FINAL"
}

case "${1:-}" in
    setup) shift; cmd_setup "$@";;
    build) shift; cmd_build "$@";;
    *) echo "Uso: $0 setup <apk> | build --package P --name N --icon I --user-id U [--url URL]"; exit 1;;
esac
