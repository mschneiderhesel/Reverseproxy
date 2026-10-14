#!/bin/sh
set -eu
. /usr/local/lib/services.sh

CERT_NAME=${CERT_NAME:-smarthome}
WEBROOT=/var/www/certbot
RENEW_INTERVAL=${RENEW_INTERVAL:-12h}
RETRY_INTERVAL=${RETRY_INTERVAL:-30m}
LE_PROD=https://acme-v02.api.letsencrypt.org/directory
LE_STAGE=https://acme-staging-v02.api.letsencrypt.org/directory

log() { echo "[certbot] $(date '+%F %T') $*"; }
# sauber beenden bei "docker stop" (sh als PID 1 ignoriert SIGTERM sonst)
trap 'exit 0' TERM INT
pause() { sleep "$1" & wait $!; }

parse_services >/dev/null || exit 1   # validiert SERVICES, bricht mit klarer Meldung ab
DOMAINS=$(all_domains)
if [ -z "$DOMAINS" ]; then
    echo "FEHLER: SERVICES ist in diesem Container leer." >&2
    echo "        In Portainer unter Stacks -> <Stack> -> Environment variables setzen" >&2
    echo "        (nicht am einzelnen Container) und 'Update the stack' klicken." >&2
    # nicht im Sekundentakt neu starten und das Log fluten
    pause 300
    exit 1
fi

DOMAIN_ARGS=""
for d in $DOMAINS; do DOMAIN_ARGS="$DOMAIN_ARGS -d $d"; done

if [ -n "${LE_EMAIL:-}" ]; then
    EMAIL_ARGS="--email $LE_EMAIL --no-eff-email"
else
    EMAIL_ARGS="--register-unsafely-without-email"
fi

if [ "${LE_STAGING:-0}" = 1 ]; then SERVER=$LE_STAGE; else SERVER=$LE_PROD; fi

# Wechsel Staging -> Produktion: vorhandenes Test-Zertifikat sofort ersetzen
EXTRA=""
RENEWAL_CONF=/etc/letsencrypt/renewal/$CERT_NAME.conf
if [ -f "$RENEWAL_CONF" ] && ! grep -q "server = $SERVER" "$RENEWAL_CONF"; then
    log "ACME-Server hat sich geändert (Staging/Produktion) – erzwinge neues Zertifikat"
    EXTRA="--force-renewal"
fi

obtain() {
    # --keep-until-expiring: nur ausstellen, wenn nötig (neu, Domains geändert, bald fällig)
    # shellcheck disable=SC2086
    certbot certonly --webroot -w "$WEBROOT" \
        --cert-name "$CERT_NAME" $DOMAIN_ARGS \
        --server "$SERVER" \
        --non-interactive --agree-tos $EMAIL_ARGS \
        --key-type ecdsa --keep-until-expiring --expand $EXTRA
}

log "Domains: $(echo $DOMAINS)"
log "Warte kurz, bis nginx Port 80 bedient ..."
pause 10

until obtain; do
    log "Zertifikat konnte nicht ausgestellt werden. Prüfen: DNS zeigt auf deine IP? Port 80 im Router weitergeleitet?"
    log "Neuer Versuch in $RETRY_INTERVAL (Let's-Encrypt-Limits schonen)"
    pause "$RETRY_INTERVAL"
done
EXTRA=""
log "Zertifikat vorhanden. nginx übernimmt es automatisch innerhalb von 60 s."

# Dauerschleife: certbot erneuert selbstständig, sobald fällig (ca. 30 Tage vor Ablauf)
while :; do
    pause "$RENEW_INTERVAL"
    log "Prüfe Erneuerung ..."
    certbot renew --non-interactive || log "WARNUNG: Erneuerung fehlgeschlagen, nächster Versuch in $RENEW_INTERVAL"
    openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$CERT_NAME/fullchain.pem" | sed 's/^/[certbot] gültig bis: /'
done
