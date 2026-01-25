FROM ubuntu:24.04
RUN apt-get update && apt-get install -y wget bzip2 ca-certificates curl && rm -rf /var/lib/apt/lists/*

RUN wget https://downloads.getmonero.org/cli/monero-linux-x64-v0.18.4.4.tar.bz2 \
    && tar xvjf monero-linux-x64-v0.18.4.4.tar.bz2 \
    && mv monero-x86_64-linux-gnu-v0.18.4.4/monerod /usr/local/bin/monerod \
    && chmod +x /usr/local/bin/monerod \
    && rm -rf monero-*

WORKDIR /root
ENTRYPOINT ["monerod"]
