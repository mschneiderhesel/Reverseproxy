#!/bin/sh
# Gemeinsamer Parser für die SERVICES-Variable (nginx + certbot).
#
# Format (Einträge durch Komma, Semikolon, Leerzeichen oder Zeilenumbruch getrennt):
#   <hostname>=<upstream-url>[|option[|option...]]
# Beispiel:
#   ha.meinhaus.duckdns.org=http://192.168.178.10:8123,
#   nodered.meinhaus.duckdns.org=http://192.168.178.10:1880|auth|lan
#
# Optionen:
#   auth  -> HTTP Basic Auth (Benutzer aus BASIC_AUTH_USERS)
#   lan   -> nur aus dem Heimnetz erreichbar (LAN_CIDRS)

die() { echo "FEHLER: $*" >&2; exit 1; }

# Gibt pro Dienst eine Zeile "host upstream opts" aus (opts mit | getrennt, ggf. leer: "-")
parse_services() {
    set -f
    for entry in $(printf '%s' "${SERVICES:-}" | tr ',;\n\r\t' '     '); do
        case "$entry" in *=*) ;; *) die "SERVICES-Eintrag '$entry' hat kein '=' (Format host=http://ziel:port)";; esac
        host=$(printf '%s' "${entry%%=*}" | tr 'A-Z' 'a-z')
        rest=${entry#*=}
        upstream=${rest%%|*}
        opts=-
        case "$rest" in *"|"*) opts=${rest#*|};; esac

        printf '%s' "$host" | grep -Eq '^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$' \
            || die "Ungültiger Hostname '$host'"
        printf '%s' "$upstream" | grep -Eq '^https?://[][A-Za-z0-9._:-]+(/[^ ;{}]*)?$' \
            || die "Ungültiges Ziel '$upstream' für $host (erwartet http://ip:port)"
        for o in $(printf '%s' "$opts" | tr '|' ' '); do
            case "$o" in auth|lan|-) ;; *) die "Unbekannte Option '$o' bei $host (erlaubt: auth, lan)";; esac
        done
        echo "$host $upstream $opts"
    done
    set +f
}

# Alle Hostnamen fürs Zertifikat: SERVICES + EXTRA_DOMAINS, dedupliziert
all_domains() {
    {
        parse_services | cut -d' ' -f1
        printf '%s' "${EXTRA_DOMAINS:-}" | tr ',;\n\r\t' '     ' | tr ' ' '\n' | tr 'A-Z' 'a-z'
    } | grep -v '^$' | awk '!seen[$0]++'
}
