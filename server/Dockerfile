# Stage 1: Build the Go binary
FROM --platform=linux/amd64 golang:1.21-alpine AS builder

WORKDIR /app

# Copy dependency definition and checksums
COPY go.mod go.sum ./

# Download dependencies (will use Docker cache unless go.mod or go.sum change!)
RUN go mod download

# Copy all source files
COPY . .

# Build a statically-linked binary (pure Go, CGO disabled) for linux/amd64
# (matches the server architecture, even if built on a Mac arm64).
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-w -s" -o media-server .

# Stage 2: Final lightweight runtime image
FROM --platform=linux/amd64 alpine:latest

# Install basic dependencies (ca-certificates, tzdata, ffmpeg)
RUN apk --no-cache add ca-certificates tzdata ffmpeg

WORKDIR /app

# Copy the compiled binary from the builder stage
COPY --from=builder /app/media-server .

# Create the data directory (where the database lives)
RUN mkdir -p /app/data

# Installable client apps (APK / DMG / EXE) served on /api/downloads. Staged by
# publish-image.sh, which mixes what this host could build with what it pulled
# out of the previously published image — Flutter cannot cross-compile desktop
# targets, so no single machine produces all three.
COPY downloads/ /app/downloads/

# Default port
EXPOSE 8080

# Configure default paths inside container
ENV MOVIES_DIR=/media/Films \
    SERIES_DIR=/media/Series

# Run the media server with database pointing to the persistent volume
ENTRYPOINT ["./media-server", "-port", "8080", "-db", "/app/data/player.db"]
