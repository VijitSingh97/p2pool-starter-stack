FROM ubuntu:24.04
RUN apt-get update && apt-get install -y wget ca-certificates libgomp1 && rm -rf /var/lib/apt/lists/*

RUN wget https://github.com/SChernykh/p2pool/releases/download/v4.13/p2pool-v4.13-linux-x64.tar.gz \
    && tar xzf p2pool-v4.13-linux-x64.tar.gz \
    && mv p2pool-v4.13-linux-x64/p2pool /usr/local/bin/p2pool \
    && chmod +x /usr/local/bin/p2pool \
    && rm -rf p2pool-*

WORKDIR /root
ENTRYPOINT ["p2pool"]
