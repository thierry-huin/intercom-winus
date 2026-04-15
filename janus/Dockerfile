FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install build and runtime dependencies
RUN apt-get update && apt-get install -y \
    build-essential git automake libtool gengetopt pkg-config \
    libmicrohttpd-dev libjansson-dev libssl-dev libsrtp2-dev \
    libglib2.0-dev libopus-dev libogg-dev libconfig-dev \
    libnice-dev libwebsockets-dev \
    && rm -rf /var/lib/apt/lists/*

# Build Janus Gateway from source
RUN git clone --depth 1 https://github.com/meetecho/janus-gateway.git /tmp/janus \
    && cd /tmp/janus \
    && sh autogen.sh \
    && ./configure --prefix=/opt/janus \
        --disable-rabbitmq \
        --disable-mqtt \
        --disable-data-channels \
        --disable-plugin-echotest \
        --disable-plugin-streaming \
        --disable-plugin-videocall \
        --disable-plugin-videoroom \
        --disable-plugin-voicemail \
        --disable-plugin-recordplay \
        --disable-plugin-textroom \
        --disable-plugin-sip \
        --disable-plugin-nosip \
    && make -j$(nproc) \
    && make install \
    && rm -rf /tmp/janus

# Copy custom configuration
COPY etc/janus/ /opt/janus/etc/janus/

# HTTP API, WebSocket, RTP range
EXPOSE 8088 8188 10000-10200/udp

CMD ["/opt/janus/bin/janus"]
