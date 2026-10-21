# "test" stage: CI builds it first, and a failing test fails the build
FROM node:24.22.0-alpine AS test
WORKDIR /app
COPY server.js server.test.js ./
RUN node --test

FROM node:24.22.0-alpine
ARG VERSION=dev
ENV VERSION=$VERSION PORT=8080 NODE_ENV=production
WORKDIR /app
COPY server.js ./
USER node
EXPOSE 8080
CMD ["node", "server.js"]
