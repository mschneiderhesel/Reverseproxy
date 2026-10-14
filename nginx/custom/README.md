# Eigene nginx-Konfigurationen

Alles, was hier als `*.conf` liegt, wird in den `http {}`-Block eingebunden.
Nur nötig für Sonderfälle, die über `SERVICES` nicht abbildbar sind.
Zertifikat, TLS-Einstellungen und WebSocket-Map gelten automatisch.

Beispiel `custom/frigate.conf`:

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name frigate.meinhaus.duckdns.org;
    include /etc/nginx/snippets/security-headers.conf;

    location / {
        set $upstream http://192.168.178.20:5000;
        proxy_pass $upstream;
        include /etc/nginx/snippets/proxy.conf;
    }
}
```

Wichtig: Den Hostnamen zusätzlich in `EXTRA_DOMAINS` eintragen, damit er im
Zertifikat landet und Port 80 auf HTTPS weiterleitet.
