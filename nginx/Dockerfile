FROM nginx:stable-alpine

# openssl: Platzhalter-Zertifikat + Passwort-Hashes für Basic Auth
RUN apk add --no-cache openssl \
 && rm -f /etc/nginx/conf.d/default.conf \
 && mkdir -p /etc/nginx/runtime /etc/nginx/selfsigned /var/www/certbot

COPY nginx/nginx.conf    /etc/nginx/nginx.conf
COPY nginx/snippets/    /etc/nginx/snippets/
COPY nginx/custom/      /etc/nginx/custom/
COPY common/services.sh /usr/local/lib/services.sh
COPY nginx/entrypoint.sh /usr/local/bin/proxy-entrypoint.sh
RUN chmod +x /usr/local/bin/proxy-entrypoint.sh

EXPOSE 80 443

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD wget -qO- http://127.0.0.1/nginx-health >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/proxy-entrypoint.sh"]
