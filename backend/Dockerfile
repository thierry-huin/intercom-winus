FROM node:20-bookworm-slim

# mediasoup needs python3, make, g++ to compile its C++ worker
RUN apt-get update && apt-get install -y --no-install-recommends \
    python3 build-essential libopus-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY package*.json ./
RUN npm install --production

COPY src/ ./src/
RUN mkdir -p /app/db

# mediasoup RTP ports + HTTP
EXPOSE 3000 10000-10200/udp

CMD ["node", "src/server.js"]
