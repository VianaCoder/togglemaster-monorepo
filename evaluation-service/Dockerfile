# =============================================================================
# Stage 1: Builder
# =============================================================================
FROM golang:1.25-alpine AS builder


WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o evaluation-service .

# =============================================================================
# Stage 2: Runtime (minimal image)
# =============================================================================
FROM alpine:3.19

RUN apk --no-cache add ca-certificates tzdata

WORKDIR /app

COPY --from=builder /app/evaluation-service .

EXPOSE 8004

CMD ["./evaluation-service"]
