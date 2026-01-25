FROM alpine:latest
RUN apk add --no-cache tor netcat-openbsd

COPY torrc /etc/tor/torrc
RUN mkdir -p /var/lib/tor && chown -R tor /var/lib/tor
USER tor
ENTRYPOINT ["tor"]
CMD ["-f", "/etc/tor/torrc"]
