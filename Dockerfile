# Dockerfile for Routa.js Next.js web application
# Uses multi-stage build for a minimal production image.
# Standalone output bundles all required files into .next/standalone/.

FROM node:22-alpine AS base

# ── Stage 1: install dependencies ────────────────────────────────────────
FROM base AS deps

# native add-ons (better-sqlite3) need build tools
RUN apk add --no-cache libc6-compat python3 make g++

WORKDIR /app

COPY package.json package-lock.json ./
COPY apps/desktop/package.json ./apps/desktop/package.json
COPY packages/office-render/package.json ./packages/office-render/package.json
COPY scripts/install ./scripts/install
COPY tools/hook-runtime ./tools/hook-runtime
COPY patches ./patches
RUN npm ci --legacy-peer-deps \
  --fetch-retries=5 \
  --fetch-retry-mintimeout=20000 \
  --fetch-retry-maxtimeout=120000 \
  --fetch-timeout=300000

# ── Stage 2: database schema migrator ────────────────────────────────────
FROM base AS migrator
WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules
COPY . .

USER node

CMD ["npm", "run", "db:push"]

# ── Stage 3: build ───────────────────────────────────────────────────────
FROM base AS builder
WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules
COPY . .

# Build in standalone mode and compile SQLite chunk modules for runtime use.
# `build:docker` sets ROUTA_DESKTOP_STANDALONE=1 (output: standalone) and then
# runs scripts/build-docker.mjs to esbuild the SQLite TS sources into the
# standalone chunks directory so ROUTA_DB_DRIVER=sqlite works at runtime.
RUN npm run build:docker

# ── Stage 4: production runner ────────────────────────────────────────────
FROM base AS runner
WORKDIR /app

ENV NODE_ENV=production
# Default to SQLite; override DATABASE_URL to use Postgres.
ENV ROUTA_DB_DRIVER=sqlite
ENV ROUTA_DB_PATH=/app/data/routa.db

RUN addgroup --system --gid 1001 nodejs \
 && adduser  --system --uid 1001 nextjs

# Standalone server + static assets
COPY --from=builder /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static
COPY --from=builder /app/public ./public

# Data directory for SQLite database
RUN mkdir -p /app/data && chown nextjs:nodejs /app/data

# Database migration tools for runtime schema push (Postgres support)
# Install globally to avoid standalone node_modules structure conflicts
RUN npm install -g drizzle-kit@0.31.9 drizzle-orm@^0.41.0 tsx@4.21.0 postgres@3.4.8

# Copy drizzle config and schema files for runtime migration.
# drizzle.config.ts references these via relative imports.
# We skip __tests__/, sqlite-schema.ts, sqlite-* files to keep the image lean.
COPY drizzle.config.ts ./
COPY src/core/db/schema.ts ./src/core/db/schema.ts
COPY src/core/db/pg-*.ts ./src/core/db/
COPY src/core/kanban/ ./src/core/kanban/
COPY src/core/models/ ./src/core/models/

# Entrypoint: run migration if postgres, then start server
COPY <<'EOF' /entrypoint.sh
#!/bin/sh
set -e

if [ "${ROUTA_DB_DRIVER}" = "postgres" ] && [ -n "${DATABASE_URL}" ]; then
  echo "[entrypoint] Running database migration..."
  cd /app
  echo "[entrypoint] Using drizzle-kit from: $(which drizzle-kit 2>/dev/null || echo '(not in PATH)')"
  if command -v drizzle-kit >/dev/null 2>&1; then
    drizzle-kit push --config=drizzle.config.ts
    echo "[entrypoint] Migration complete."
  else
    echo "[entrypoint] ERROR: drizzle-kit not found in PATH. Skipping migration."
  fi
fi

echo "[entrypoint] Starting Routa server..."
exec node /app/server.js
EOF
RUN chmod +x /entrypoint.sh

ENV HOME=/home/nextjs
ENV NODE_PATH=/usr/local/lib/node_modules
RUN mkdir -p /home/nextjs/.routa && chown -R nextjs:nodejs /home/nextjs

USER nextjs

EXPOSE 3000
ENV PORT=3000
ENV HOSTNAME=0.0.0.0

CMD ["/entrypoint.sh"]
