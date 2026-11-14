FROM node:24-bookworm-slim
RUN corepack enable && corepack prepare pnpm@12.11.2 --activate
WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY agent/package.json ./agent/package.json
RUN pnpm install --frozen-lockfile --prod --filter @pendenz/agent
COPY agent ./agent
USER 10001:10001
ENV HOST=0.0.0.0 PORT=8090
EXPOSE 8090
CMD ["node", "agent/http.mjs"]
