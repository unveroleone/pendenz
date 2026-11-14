FROM rust:1.96-bookworm AS build
WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY server ./server
ARG CARGO_BUILD_JOBS=2
RUN cargo build --locked --release --jobs ${CARGO_BUILD_JOBS}

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl sqlite3 restic \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -g 10001 pendenz && useradd -u 10001 -g pendenz -M pendenz \
    && mkdir /data /backups && chown pendenz:pendenz /data /backups
COPY --from=build /build/target/release/pendenz /usr/local/bin/pendenz
COPY deploy/backup.sh /usr/local/bin/pendenz-backup
RUN chmod 755 /usr/local/bin/pendenz-backup
USER 10001:10001
ENV DATABASE_URL=sqlite:///data/pendenz.db PENDENZ_BIND=0.0.0.0:8080 PENDENZ_AUTH_MODE=token
EXPOSE 8080
ENTRYPOINT ["pendenz"]
