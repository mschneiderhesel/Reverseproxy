FROM certbot/certbot:latest
# (openssl ist im Image bereits enthalten – wird für den Healthcheck genutzt)

COPY common/services.sh   /usr/local/lib/services.sh
COPY certbot/entrypoint.sh /usr/local/bin/certbot-loop.sh
RUN chmod +x /usr/local/bin/certbot-loop.sh

# "unhealthy" in Portainer, wenn das Zertifikat in < 7 Tagen abläuft
# (sollte nie passieren – certbot erneuert ca. 30 Tage vorher)
HEALTHCHECK --interval=1h --timeout=10s --start-period=1h --retries=1 \
  CMD openssl x509 -checkend 604800 -noout -in "/etc/letsencrypt/live/${CERT_NAME:-smarthome}/fullchain.pem"

ENTRYPOINT ["/usr/local/bin/certbot-loop.sh"]
