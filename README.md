# Smart-Home Reverse Proxy (nginx + Let's Encrypt)

Ein abgesicherter HTTPS-Zugang zu allen Smart-Home-Diensten (Home Assistant,
Node-RED, Zigbee2MQTT, Grafana, …) – gebaut direkt aus diesem GitHub-Repo in
Portainer. Zertifikate holt und **erneuert er vollautomatisch** über
Let's Encrypt; du musst nie wieder ein Zertifikat anfassen.

```
 Internet ──► Router (Port 80 + 443 weitergeleitet) ──► Docker-Host
                                                         │
                         ┌───────────────────────────────┴──────────────┐
                         │  smarthome-proxy (nginx)                      │
                         │   :80  → nur ACME-Challenge + Redirect HTTPS  │
                         │   :443 → TLS, Auth, LAN-Sperre, Rate-Limit    │
                         └──────┬───────────────┬──────────────┬─────────┘
                                ▼               ▼              ▼
                         Home Assistant     Node-RED      Zigbee2MQTT …
                         192.168.x.x:8123   :1880         :8080

  smarthome-proxy-certbot: holt das Zertifikat, prüft alle 12 h auf Erneuerung,
  nginx übernimmt neue Zertifikate automatisch (ohne Neustart).
```

## Wie das Zertifikat „nie abläuft"

Let's-Encrypt-Zertifikate sind bewusst kurzlebig (aktuell max. 90 Tage, künftig
kürzer). Statt eines langen Zertifikats sorgt dieser Stack dafür, dass immer
rechtzeitig ein neues da ist:

1. Beim ersten Start erzeugt nginx ein temporäres Platzhalter-Zertifikat, damit
   er überhaupt starten kann.
2. Der certbot-Container holt per HTTP-01-Challenge ein echtes Zertifikat für
   alle Hostnamen (ein Zertifikat mit allen Namen).
3. certbot prüft alle 12 Stunden und erneuert automatisch, sobald das
   Zertifikat in die Erneuerungsphase kommt (ca. 30 Tage vor Ablauf).
4. nginx prüft jede Minute, ob ein neues Zertifikat vorliegt, und lädt es
   unterbrechungsfrei nach (`nginx -s reload`).
5. Sicherheitsnetz: Der certbot-Container wird in Portainer **„unhealthy"**,
   falls das Zertifikat jemals weniger als 7 Tage gültig ist. (Let's Encrypt
   verschickt seit 2025 keine Ablauf-Mails mehr.)

Zertifikate und Account liegen im Volume `letsencrypt` und überleben
Redeploys/Updates.

## Voraussetzungen

### 1. DynDNS-Hostnamen – einer pro Dienst

Jeder Dienst bekommt einen eigenen Hostnamen (z. B. `ha.meinhaus.duckdns.org`).
Pfad-basiert (`/homeassistant`) geht nicht, weil Home Assistant & Co. das nicht
unterstützen.

| Anbieter | Subdomains? | Hinweis |
|---|---|---|
| **DuckDNS** (kostenlos, empfohlen) | ✅ automatisch | `meinhaus.duckdns.org` → `ha.meinhaus.duckdns.org`, `nodered.meinhaus.duckdns.org` usw. zeigen automatisch auf dieselbe IP |
| deSEC / dynv6 (kostenlos) | ✅ | Wildcard-Eintrag `*` anlegen |
| Eigene Domain (IONOS, Strato, …) | ✅ | `*.home.deinedomain.de` als CNAME auf deinen DynDNS-Namen |
| **DynDNS (dyn.com / Oracle Dyn)** | ✅ | Im Dyn-Account beim Hostnamen **„Wildcard" aktivieren** → `ha.meinhaus.dyndns.org` usw. funktionieren. Alternativ je Dienst einen eigenen Host anlegen (`meinha.dyndns.org`, `meinnodered.dyndns.org`, …) – zählt aber gegen das Host-Kontingent |
| MyFRITZ!, No-IP Free | ❌ meist nur 1 Name | Dann entweder nur **einen** Dienst veröffentlichen oder zusätzlich DuckDNS nutzen |

Test: `nslookup ha.meinhaus.duckdns.org` muss deine öffentliche IP liefern.

### 2. Portweiterleitung im Router

| Extern | → Intern (Docker-Host) | Wozu |
|---|---|---|
| TCP 80 | 80 | Zertifikat ausstellen/erneuern + Redirect auf HTTPS |
| TCP 443 | 443 | eigentlicher Zugriff |

Port 80 muss dauerhaft offen bleiben, sonst schlägt die Erneuerung fehl. Auf
Port 80 wird nichts außer der Let's-Encrypt-Challenge und einem Redirect
ausgeliefert.

> **Kein DS-Lite?** Bei reinen IPv6-/DS-Lite-Anschlüssen (z. B. manche Kabel-
> Anbieter) gibt es keine eigene öffentliche IPv4 – Portweiterleitungen auf IPv4
> funktionieren dann nicht. Bitte vorher prüfen.

### 3. Ports 80/443 auf dem Docker-Host frei

Kein anderer Container darf 80/443 belegen. (Portainer selbst läuft auf 9443 –
passt.)

## Deployment in Portainer

1. **Stacks → Add stack**
2. Name: `smarthome-proxy`
3. Build method: **Repository**
   - Repository URL: `https://github.com/mschneiderhesel/Reverseproxy`
   - Repository reference: `refs/heads/main`
   - Compose path: `docker-compose.yml`
   - Bei privatem Repo: *Authentication* aktivieren, GitHub-Benutzer +
     Personal Access Token (nur `repo:read`) eintragen.
4. **Environment variables** → *Advanced mode* → Inhalt von
   [`stack.env.example`](stack.env.example) einfügen und anpassen.
5. **Empfehlung für den ersten Start:** `LE_STAGING=1` setzen. So testest du
   ohne Let's-Encrypt-Limits. Wenn im Log von `smarthome-proxy-certbot`
   „Zertifikat vorhanden" steht: auf `LE_STAGING=0` ändern und **Update the
   stack** – das Test-Zertifikat wird automatisch durch ein echtes ersetzt.
6. **Deploy the stack.**

Logs prüfen: *Containers → smarthome-proxy-certbot → Logs*.

### Änderungen & Updates

- Dienste hinzufügen/ändern: Umgebungsvariablen im Stack ändern → *Update the
  stack*. Das Zertifikat wird automatisch um neue Hostnamen erweitert.
- nginx-Sicherheitsupdates: *Update the stack* mit **„Re-pull image and
  redeploy"** – dann wird mit dem aktuellen `nginx:stable-alpine` neu gebaut.

## Konfiguration (Umgebungsvariablen)

| Variable | Pflicht | Standard | Beschreibung |
|---|---|---|---|
| `SERVICES` | ✅ | – | `host=ziel[|option…]`, mehrere durch Komma. Siehe unten. |
| `LE_EMAIL` | empfohlen | – | E-Mail für den Let's-Encrypt-Account |
| `LE_STAGING` | | `0` | `1` = Test-Zertifikate (nicht vertrauenswürdig, keine Limits) |
| `BASIC_AUTH_USERS` | bei `auth` | – | `user:passwort`, mehrere durch Komma |
| `LAN_CIDRS` | | `192.168.0.0/16 10.0.0.0/8 fc00::/7` | Netze, die bei `lan` erlaubt sind. Am besten exakt dein Heimnetz, z. B. `192.168.178.0/24` |
| `EXTRA_DOMAINS` | | – | Zusätzliche Hostnamen fürs Zertifikat (für eigene Configs in `nginx/custom/`) |
| `RATE_LIMIT` / `RATE_BURST` | | `20r/s` / `100` | Anfragen pro IP |
| `CLIENT_MAX_BODY_SIZE` | | `100m` | Max. Upload-Größe (Backups, Firmware) |
| `HTTP_PORT` / `HTTPS_PORT` | | `80` / `443` | Host-Ports (nur ändern, wenn der Router extern 80/443 auf andere interne Ports mappt) |
| `PROXY_SUBNET` | | `172.30.250.0/24` | Docker-Netz des Proxys (für `trusted_proxies`) |
| `TZ` | | `Europe/Berlin` | Zeitzone für Logs |

### `SERVICES` im Detail

```
ha.meinhaus.duckdns.org=http://192.168.178.10:8123,
nodered.meinhaus.duckdns.org=http://192.168.178.10:1880|auth,
z2m.meinhaus.duckdns.org=http://192.168.178.10:8080|auth|lan,
proxmox.meinhaus.duckdns.org=https://192.168.178.2:8006|lan
```

(In Portainer alles in **einer** Zeile, Kommas trennen die Einträge.)

- **Ziel**: `http://IP:Port` oder `https://IP:Port` (selbstsignierte
  Zertifikate am Ziel werden akzeptiert). Containernamen gehen auch, wenn der
  Ziel-Container im Netzwerk `smarthome-proxy` hängt.
- **`|auth`** – zusätzliche Passwortabfrage (Basic Auth). Sinnvoll für alles
  **ohne eigenen guten Login** (Node-RED, Zigbee2MQTT, ESPHome, …). Nicht für
  Home Assistant verwenden – das bricht die Companion-App.
- **`|lan`** – nur aus dem Heimnetz erreichbar, aus dem Internet `403`.
  Ideal für Admin-Oberflächen (Proxmox, Router, Portainer), die zwar ein gültiges
  Zertifikat bekommen sollen, aber nicht ins Internet gehören.
  Damit das aus dem LAN funktioniert, muss dein Router/DNS die Hostnamen intern
  auf die **LAN-IP** des Docker-Hosts auflösen (FritzBox: DNS-Rebind-Schutz
  Ausnahme + lokaler DNS-Eintrag, oder Pi-hole/AdGuard „Local DNS").

Passwörter: Kein `,` verwenden; ein `$` muss in Portainer als `$$` geschrieben
werden.

## Home Assistant einrichten

Home Assistant blockiert Proxys, denen es nicht vertraut. In
`configuration.yaml` ergänzen und HA neu starten:

```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 172.30.250.0/24    # Docker-Netz des Proxys (PROXY_SUBNET)
    - 192.168.178.5      # LAN-IP des Docker-Hosts, falls HA auf einem anderen Gerät läuft
```

Danach in HA unter *Einstellungen → System → Netzwerk* als
„Internet-URL" `https://ha.meinhaus.duckdns.org` eintragen.

## Was der Proxy zur Absicherung tut

- **Nur HTTPS** (TLS 1.2/1.3, moderne Cipher, HTTP/2), Port 80 leitet um.
- **HSTS** und Sicherheits-Header (`nosniff`, `SAMEORIGIN`, `Referrer-Policy`).
- **Zugriffe per IP oder unbekanntem Hostnamen** werden verworfen – kein TLS-
  Handshake, kein Zertifikat, keine Info für Port-Scanner (`ssl_reject_handshake`
  bzw. HTTP `444`).
- **Rate-Limiting** und Verbindungslimit pro IP (Brute-Force, Flooding).
- **Timeouts** gegen Slowloris-artige Angriffe, `server_tokens off`.
- `X-Forwarded-For` wird **neu gesetzt**, gefälschte Header vom Client werden
  nicht durchgereicht.
- Optional pro Dienst: **Basic Auth** (`auth`) und **LAN-only** (`lan`).
- Container laufen mit `no-new-privileges`, Zertifikate sind im nginx-Container
  read-only eingebunden.

### Weitere Empfehlungen

- Home Assistant: **2-Faktor-Auth** aktivieren und das `ip_ban`-Feature nutzen
  (`http: ip_ban_enabled: true, login_attempts_threshold: 5`).
- Nur veröffentlichen, was wirklich von unterwegs gebraucht wird; alles andere
  mit `|lan` oder gar nicht eintragen. Für reine Admin-Zugriffe von unterwegs
  ist ein VPN (WireGuard, z. B. über die FritzBox) noch sicherer.
- Ausbaustufe: CrowdSec/fail2ban auf die nginx-Logs, Geo-Blocking.

## Sonderfälle: eigene nginx-Konfiguration

Für Dienste, die mehr brauchen als `SERVICES` bietet, eine Datei
`nginx/custom/<name>.conf` ins Repo legen – siehe
[`nginx/custom/README.md`](nginx/custom/README.md).

## Fehlersuche

| Symptom | Ursache / Lösung |
|---|---|
| certbot-Log: `Timeout during connect` / `Connection refused` | Port 80 nicht (korrekt) weitergeleitet, oder DS-Lite |
| certbot-Log: `DNS problem: NXDOMAIN` | Hostname existiert nicht – Subdomains beim DynDNS-Anbieter prüfen |
| certbot-Log: `too many failed authorizations` / `rateLimited` | Zu viele Fehlversuche – 1 h warten, bis dahin mit `LE_STAGING=1` testen |
| Browser warnt „Zertifikat ungültig" | Noch das Platzhalter- oder Staging-Zertifikat aktiv → certbot-Log prüfen |
| Home Assistant: `400 Bad Request` | `trusted_proxies` fehlt (siehe oben) |
| `403` bei `lan`-Dienst im Heimnetz | Hostname wird intern auf die öffentliche IP aufgelöst → lokalen DNS-Eintrag auf die LAN-IP setzen bzw. `LAN_CIDRS` prüfen |
| nginx-Container startet nicht | Log lesen: Fehler in `SERVICES` werden mit klarer Meldung angezeigt |

Zertifikat manuell prüfen:

```sh
docker exec smarthome-proxy-certbot certbot certificates
```

## Aufbau des Repos

```
docker-compose.yml        Stack-Definition für Portainer
stack.env.example         Vorlage für die Umgebungsvariablen
common/services.sh        Parser für SERVICES (von beiden Containern genutzt)
nginx/
  Dockerfile
  entrypoint.sh           generiert die Config, Platzhalter-Zertifikat, Zertifikats-Watcher
  nginx.conf              globale Einstellungen + TLS
  snippets/               Proxy- und Security-Header-Bausteine
  custom/                 eigene *.conf für Sonderfälle
certbot/
  Dockerfile              inkl. Healthcheck auf Restlaufzeit
  entrypoint.sh           Ausstellung + Erneuerungsschleife
```
