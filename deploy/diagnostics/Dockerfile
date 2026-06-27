FROM oven/bun:1-alpine

WORKDIR /app
ENV NODE_ENV=production

COPY package.json bun.lock ./
RUN bun install --frozen-lockfile --production

COPY d.ps1 ./
COPY setup-vibemode-codex-desktop.ps1 ./
RUN mkdir -p scripts
COPY scripts/responses_image.py ./scripts/responses_image.py
COPY src/diagnostics ./src/diagnostics

CMD ["bun", "run", "diag:server"]
