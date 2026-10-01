#!/bin/bash
# Démarre l'écran virtuel, le bureau, le son puis kycontroller.
# Le conteneur s'arrête dès qu'un de ces processus meurt (Docker le relance).
set -euo pipefail

# Lancé en root : rend les volumes (créés par Docker au nom de root au premier
# lancement) à l'utilisateur kyber, puis abandonne root pour tout le reste.
# --keep-groups conserve les groupes ajoutés par group_add (GPU).
if [ "$(id -u)" = 0 ]; then
    for dir in /home/kyber /home/kyber/SteamLibrary; do
        if [ -d "$dir" ] && [ "$(stat -c %u "$dir")" != 1000 ]; then
            chown kyber:kyber "$dir"
        fi
    done
    exec setpriv --reuid=kyber --regid=kyber --keep-groups \
        env HOME=/home/kyber USER=kyber LOGNAME=kyber "$0" "$@"
fi

PORT="${KYBER_PORT:-8090}"
RESOLUTION="${SCREEN_RESOLUTION:-1920x1080}"
ENCODER="${KYBER_ENCODER:-x264}"
LAYOUT="${KEYBOARD_LAYOUT:-fr}"
VARIANT="${KEYBOARD_VARIANT:-}"
BASIC_AUTH="${KYBER_BASIC_AUTH:-true}"

if [ "$BASIC_AUTH" = true ]; then
    : "${KYBER_USER:?KYBER_USER manquant (voir .env.example)}"
    : "${KYBER_PASSWORD:?KYBER_PASSWORD manquant (voir .env.example)}"
elif [ -z "${KYBER_OIDC_ISSUER:-}" ] && [ -z "${KYBER_JWT_PUBLIC_KEY_FILE:-}" ]; then
    echo "Aucune méthode de connexion : KYBER_BASIC_AUTH=true, KYBER_OIDC_* ou KYBER_JWT_PUBLIC_KEY_FILE (voir .env.example)" >&2
    exit 1
fi

RUN_DIR=/run/kyber
TLS_DIR="$HOME/.config/kyber/tls"
export XDG_RUNTIME_DIR="$RUN_DIR/xdg"
# Un "docker restart" garde le système de fichiers du conteneur : on repart
# d'un état propre (pid de PulseAudio, sockets, verrou X d'avant l'arrêt)
rm -rf "$XDG_RUNTIME_DIR" /tmp/.X0-lock /tmp/.X11-unix/X0 /tmp/.ICE-unix
mkdir -p -m 700 "$XDG_RUNTIME_DIR" "$TLS_DIR"

# Certificat HTTPS de la page, généré une fois puis conservé dans le volume.
# (Le certificat de test livré par Kyber a sa clé privée dans son dépôt.)
# Supprimer cert.pem pour le régénérer après un changement de KYBER_TLS_SAN.
if [ ! -s "$TLS_DIR/cert.pem" ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=kyber" \
        -addext "subjectAltName=${KYBER_TLS_SAN:-IP:127.0.0.1}" \
        -keyout "$TLS_DIR/key.pem" -out "$TLS_DIR/cert.pem" 2>/dev/null
fi

toml_str() { printf '"%s"' "$(printf %s "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }
toml_list() {
    local IFS=, out="" item
    for item in $1; do
        item="${item## }"; item="${item%% }"
        [ -n "$item" ] && out="${out:+$out, }$(toml_str "$item")"
    done
    printf '[ %s ]' "$out"
}

cat > "$RUN_DIR/kyber_config.toml" <<EOF
[kyavserver]
encoder = "$ENCODER"
grab_backend = "xcb"

[kycontroller]
port = $PORT
listen_mode = "ipv4"
tls_cert = "$TLS_DIR/cert.pem"
tls_key = "$TLS_DIR/key.pem"

[kycontroller.security]
trusted_origins = []
same_site = true

EOF

# Jetons signés (JWT), surtout pour le client natif. Kyber l'active par défaut
# avec une clé de développement publique : désactivé, sauf clé publique RSA
# fournie (RS256 : seul le détenteur de la clé privée peut signer un jeton).
if [ -n "${KYBER_JWT_PUBLIC_KEY_FILE:-}" ]; then
    [ -s "$KYBER_JWT_PUBLIC_KEY_FILE" ] || {
        echo "KYBER_JWT_PUBLIC_KEY_FILE : clé introuvable ($KYBER_JWT_PUBLIC_KEY_FILE)" >&2; exit 1; }
    cat >> "$RUN_DIR/kyber_config.toml" <<EOF

[kycontroller.auth.jwt]
enabled = true
algorithm = "RS256"
key = { file = $(toml_str "$KYBER_JWT_PUBLIC_KEY_FILE") }
EOF
else
    printf '\n[kycontroller.auth.jwt]\nenabled = false\n' >> "$RUN_DIR/kyber_config.toml"
fi

# Connexion par identifiants (par défaut)
if [ "$BASIC_AUTH" = true ]; then
    cat >> "$RUN_DIR/kyber_config.toml" <<EOF

[kycontroller.auth.basic]
enabled = true
logins = [ { username = $(toml_str "$KYBER_USER"), password = "$(printf %s "$KYBER_PASSWORD" | sha256sum | cut -d' ' -f1)" } ]
EOF
else
    printf '\n[kycontroller.auth.basic]\nenabled = false\n' >> "$RUN_DIR/kyber_config.toml"
fi

# Connexion OIDC (facultative) : Keycloak, Authentik... (voir README)
if [ -n "${KYBER_OIDC_ISSUER:-}" ]; then
    : "${KYBER_OIDC_CLIENT_ID:?KYBER_OIDC_CLIENT_ID manquant}"
    : "${KYBER_OIDC_ALLOWED_EMAILS:?KYBER_OIDC_ALLOWED_EMAILS manquant}"
    cat >> "$RUN_DIR/kyber_config.toml" <<EOF

[kycontroller.auth.oidc]
enabled = true
issuer = $(toml_str "$KYBER_OIDC_ISSUER")
client_id = $(toml_str "$KYBER_OIDC_CLIENT_ID")
identity_claim = "email"
allowed_identifiers = $(toml_list "$KYBER_OIDC_ALLOWED_EMAILS")
EOF
else
    printf '\n[kycontroller.auth.oidc]\nenabled = false\n' >> "$RUN_DIR/kyber_config.toml"
fi

# Préférences XFCE au premier lancement : panneau par défaut sans la question
# d'accueil, pas de compositeur (inutile sur Xvfb, coûte du CPU)
XFCONF="$HOME/.config/xfce4/xfconf/xfce-perchannel-xml"
mkdir -p "$XFCONF"
[ -f "$XFCONF/xfce4-panel.xml" ] || cp /etc/xdg/xfce4/panel/default.xml "$XFCONF/xfce4-panel.xml"
[ -f "$XFCONF/xfwm4.xml" ] || cat > "$XFCONF/xfwm4.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="use_compositing" type="bool" value="false"/>
  </property>
</channel>
EOF

Xvfb "$DISPLAY" -screen 0 "${RESOLUTION}x24" -nolisten tcp -dpi 96 &
for _ in $(seq 50); do xset q >/dev/null 2>&1 && break; sleep 0.1; done
xset q >/dev/null
xset s off
setxkbmap -layout "$LAYOUT" ${VARIANT:+-variant "$VARIANT"}

# Sortie son virtuelle : kyavserver capture le moniteur de la sortie par défaut
pulseaudio -n --daemonize=no --exit-idle-time=-1 --realtime=no --high-priority=no \
    --load="module-native-protocol-unix" \
    --load="module-null-sink sink_name=kyber sink_properties=device.description=Kyber" &
for _ in $(seq 50); do pactl info >/dev/null 2>&1 && break; sleep 0.1; done

dbus-run-session -- xfce4-session &

kycontroller &

wait -n
echo "Un processus s'est arrêté, arrêt du conteneur" >&2
exit 1
