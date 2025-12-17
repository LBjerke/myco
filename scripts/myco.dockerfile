FROM alpine:3.19
RUN apk add --no-cache ca-certificates libstdc++ musl-dev
COPY zig-out/bin/myco /usr/local/bin/myco
RUN mkdir -p /var/lib/myco
ENTRYPOINT ["/usr/local/bin/myco"]
