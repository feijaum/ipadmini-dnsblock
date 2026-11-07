FROM node:22-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates ffmpeg python3-venv \
    && rm -rf /var/lib/apt/lists/* \
    && python3 -m venv /opt/audio \
    && /opt/audio/bin/pip install --no-cache-dir 'yt-dlp[default]'
WORKDIR /app
COPY server.py .
USER node
EXPOSE 8787
ENTRYPOINT ["/opt/audio/bin/python", "server.py", "--bind", "0.0.0.0"]
