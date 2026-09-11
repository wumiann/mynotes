# syntax=docker/dockerfile:1

FROM node:22-slim AS build
WORKDIR /app
RUN npm install -g pnpm@10
COPY package.json pnpm-workspace.yaml pnpm-lock.yaml ./
COPY server/package.json server/
COPY web/package.json web/
RUN pnpm install --frozen-lockfile
COPY . .
RUN pnpm --filter web build \
 && pnpm --filter server build \
 && pnpm --filter server deploy --prod --legacy /out

FROM node:22-slim
ENV NODE_ENV=production \
    PORT=8322 \
    DATA_DIR=/data
WORKDIR /app
COPY --from=build /out/package.json ./package.json
COPY --from=build /out/node_modules ./node_modules
COPY --from=build /app/server/dist ./dist
COPY --from=build /app/web/dist ./web-dist
VOLUME ["/data"]
EXPOSE 8322
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
  CMD node -e "fetch('http://127.0.0.1:8322/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "dist/index.js"]
