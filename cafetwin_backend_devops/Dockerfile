# ============================================================
# CaféTwin Backend — Production Dockerfile
# Author : Harsimranjeet Singh (SCI6284)
# Sprint : Week 7 — Backend Containerisation & Cloud Deployment
# ============================================================

FROM node:20-alpine AS production

LABEL maintainer="Harsimranjeet Singh <SCI6284@mysci.edu.au>"
LABEL description="CaféTwin backend API — Express + PostgreSQL"

WORKDIR /app

# Copy dependency manifests first for layer caching
COPY package.json package-lock.json ./

# Install production dependencies only (no devDependencies)
RUN npm install --omit=dev && \
    npm cache clean --force

# Copy application source
COPY server.js simulate.js ./

# Create non-root user for security (ISO 27001 — least privilege)
RUN addgroup -S cafetwin && \
    adduser -S cafetwin -G cafetwin && \
    chown -R cafetwin:cafetwin /app

USER cafetwin

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget --no-verbose --tries=1 --spider http://localhost:3000/ || exit 1

CMD ["node", "server.js"]
