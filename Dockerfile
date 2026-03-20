FROM rust:1-slim AS builder
WORKDIR /app
COPY Cargo.toml Cargo.lock ./
COPY src/ src/
RUN cargo build --release

FROM scratch
COPY --from=builder /app/target/release/rsmatrix /rsmatrix
ENTRYPOINT ["/rsmatrix"]
