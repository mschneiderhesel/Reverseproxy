#!/bin/sh
set -eu
. /usr/local/lib/services.sh

CERT_NAME=${CERT_NAME:-smarthome}
LE_DIR=/etc/letsencrypt/live/$CERT_NAME
SELF_DIR=/etc/nginx/selfsigned
RUNTIME=/etc/nginx/runtime
CONF=/etc/nginx/conf.d
LAN_CIDRS=${LAN_CIDRS:-192.168.0.0/16 10.0.0.0/8 fc00::/7}
RATE_LIMIT=${RATE_LIMIT:-20r/s}
RATE_BURST=${RATE_BURST:-100}
CLIENT_MAX_BODY_SIZE=${CLIENT_MAX_BODY_SIZE:-100m}

log() { echo "[proxy] $*"; }

[ -n "${SERVICES:-}" ] || die "SERVICES ist leer – bitte in Portainer setzen (siehe README)."
SERVICE_LIST=$(parse_services)
DOMAINS=$(all_domains)

# IPv6-Listener nur, wenn der Container IPv6 hat
LISTEN6=""
if [ -s /proc/net/if_inet6 ]; then LISTEN6=1; fi
listen() { # $1 = "80" | "443 ssl" ...
    echo "    listen $1;"
    [ -z "$LISTEN6" ] || echo "    listen [::]:$1;"
}

# ---- 1. Platzhalter-Zertifikat, damit nginx vor dem ersten Let's-Encrypt-Lauf startet
if [ ! -s "$SELF_DIR/fullchain.pem" ]; then
    log "Erzeuge temporäres selbstsigniertes Zertifikat"
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 30 \
        -subj "/CN=placeholder" -keyout "$SELF_DIR/privkey.pem" -out "$SELF_DIR/fullchain.pem" 2>/dev/null
fi

cert_state() {
    if [ -s "$LE_DIR/fullchain.pem" ] && [ -s "$LE_DIR/privkey.pem" ]; then
        echo "le:$(cat "$LE_DIR/fullchain.pem" | sha256sum | cut -c1-16)"
    else
        echo "self"
    fi
}
write_cert_conf() {
    if [ "$1" = self ]; then d=$SELF_DIR; else d=$LE_DIR; fi
    printf 'ssl_certificate     %s/fullchain.pem;\nssl_certificate_key %s/privkey.pem;\n' "$d" "$d" > "$RUNTIME/cert.conf"
}

# ---- 2. Basic Auth
: > "$RUNTIME/htpasswd"
if [ -n "${BASIC_AUTH_USERS:-}" ]; then
    set -f
    for cred in $(printf '%s' "$BASIC_AUTH_USERS" | tr ',;\n' '   '); do
        user=${cred%%:*}; pass=${cred#*:}
        [ -n "$user" ] && [ "$user" != "$cred" ] && [ -n "$pass" ] || die "BASIC_AUTH_USERS: Eintrag muss user:passwort sein"
        printf '%s:%s\n' "$user" "$(openssl passwd -6 "$pass")" >> "$RUNTIME/htpasswd"
    done
    set +f
fi
chown root:nginx "$RUNTIME/htpasswd"; chmod 640 "$RUNTIME/htpasswd"
if echo "$SERVICE_LIST" | awk '{print "|"$3"|"}' | grep -q '|auth|' && [ ! -s "$RUNTIME/htpasswd" ]; then
    die "Ein Dienst nutzt 'auth', aber BASIC_AUTH_USERS ist leer."
fi

# ---- 3. Konfiguration generieren
rm -f "$CONF"/*.conf

{
    echo "# generiert – nicht editieren"
    echo "limit_req_zone  \$binary_remote_addr zone=perip:10m rate=$RATE_LIMIT;"
    echo "limit_conn_zone \$binary_remote_addr zone=connperip:10m;"
    echo "limit_req_status  429;"
    echo "limit_conn_status 429;"
    echo "client_max_body_size $CLIENT_MAX_BODY_SIZE;"
    echo
    echo "map \$host \$known_host {"
    echo "    default 0;"
    for d in $DOMAINS; do echo "    $d 1;"; done
    echo "}"
} > "$CONF/00-global.conf"

{
    echo "allow 127.0.0.1;"
    for c in $LAN_CIDRS; do echo "allow $c;"; done
    echo "deny all;"
} > /etc/nginx/snippets/lan-only.conf

{
    echo "# Port 80: nur ACME-Challenge + Redirect auf HTTPS für bekannte Hosts"
    echo "server {"
    listen "80 default_server"
    echo "    server_name _;"
    echo "    location ^~ /.well-known/acme-challenge/ { root /var/www/certbot; default_type text/plain; }"
    echo "    location = /nginx-health { access_log off; allow 127.0.0.1; deny all; return 200 'ok'; }"
    echo "    location / {"
    echo "        if (\$known_host) { return 301 https://\$host\$request_uri; }"
    echo "        return 444;   # unbekannter Host / Zugriff per IP: Verbindung kommentarlos schließen"
    echo "    }"
    echo "}"
    echo
    echo "# Port 443: unbekannte Hostnamen (Scanner, Zugriff per IP) bekommen gar kein TLS"
    echo "server {"
    listen "443 ssl default_server"
    echo "    server_name _;"
    echo "    ssl_reject_handshake on;"
    echo "}"
} > "$CONF/10-default.conf"

echo "$SERVICE_LIST" | while read -r host upstream opts; do
    {
        echo "server {"
        listen "443 ssl"
        echo "    http2 on;"
        echo "    server_name $host;"
        echo "    include /etc/nginx/snippets/security-headers.conf;"
        case "|$opts|" in *"|lan|"*)  echo "    include /etc/nginx/snippets/lan-only.conf;";; esac
        case "|$opts|" in *"|auth|"*)
            echo "    auth_basic \"Restricted\";"
            echo "    auth_basic_user_file $RUNTIME/htpasswd;";;
        esac
        echo "    limit_conn connperip 100;"
        echo "    location / {"
        echo "        limit_req zone=perip burst=$RATE_BURST nodelay;"
        echo "        set \$upstream $upstream;"
        echo "        proxy_pass \$upstream;"
        echo "        include /etc/nginx/snippets/proxy.conf;"
        echo "    }"
        echo "}"
        echo
    } >> "$CONF/20-services.conf"
    log "Dienst: https://$host -> $upstream ${opts#-}"
done

STATE=$(cert_state)
write_cert_conf "$STATE"
log "Zertifikat: $STATE"
nginx -t

# ---- 4. Watcher: sobald certbot ein (neues) Zertifikat ablegt -> nginx neu laden
(
    while sleep 60; do
        NEW=$(cert_state)
        if [ "$NEW" != "$STATE" ]; then
            write_cert_conf "$NEW"
            if nginx -t 2>/dev/null; then
                nginx -s reload && log "Neues Zertifikat aktiv ($NEW), nginx neu geladen"
                STATE=$NEW
            else
                log "WARNUNG: Konfigtest mit neuem Zertifikat fehlgeschlagen, behalte altes"
                write_cert_conf "$STATE"
            fi
        fi
    done
) &

exec nginx -g 'daemon off;'
