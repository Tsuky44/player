# Stage 1: Build the Go binary
#
# Le compilateur tourne sur la machine qui construit (BUILDPLATFORM) et vise
# l'architecture de l'image (TARGETARCH) : Go compile en croisé, donc l'image
# arm64 ne coûte pas une compilation émulée.
FROM --platform=$BUILDPLATFORM golang:1.27-alpine AS builder

ARG TARGETARCH
# La version annoncée sur /api/ping. Voir buildinfo.
ARG VERSION=dev

WORKDIR /app

# Copy dependency definition and checksums
COPY go.mod go.sum ./

# Download dependencies (will use Docker cache unless go.mod or go.sum change!)
RUN go mod download

# Copy all source files
COPY . .

# Build a statically-linked binary (pure Go, CGO disabled) for the image's
# architecture — amd64 unless the build asks for another platform.
RUN CGO_ENABLED=0 GOOS=linux GOARCH=${TARGETARCH:-amd64} go build \
    -ldflags="-w -s -X project-player/server/buildinfo.Version=${VERSION}" -o media-server .

# Stage 2: Final lightweight runtime image
#
# Épinglée : `latest` changeait de version d'Alpine — et donc de FFmpeg — sans
# que rien ne change ici. Monter de version doit être un changement voulu.
FROM alpine:3.24

# Install basic dependencies (ca-certificates, tzdata, ffmpeg)
# su-exec : quitter root au démarrage quand PUID est réglé (docker-entrypoint.sh).
#
# mesa-vulkan-swrast : le Vulkan logiciel dont le filtre libplacebo de FFmpeg a
# besoin pour appliquer la couche RPU d'un Dolby Vision profil 5 sur un hôte
# sans GPU (ADR-0060). Il pèse ~240 Mo — LLVM — et ne se charge que dans le
# FFmpeg d'une telle session.
RUN apk --no-cache add ca-certificates tzdata ffmpeg su-exec mesa-vulkan-swrast

# Les pilotes VAAPI : sans eux, FFmpeg ne voit pas le circuit vidéo d'un
# processeur Intel ou AMD même quand /dev/dri est passé au conteneur, et tout
# le décodage comme tout l'encodage restent sur les cœurs (ADR-0023).
# intel-media-driver sert les Intel depuis la 5e génération, libva-intel-driver
# ceux d'avant, mesa-va-gallium les AMD. Les deux premiers n'existent que pour
# x86_64. ~47 Mo, chargés seulement par un FFmpeg qui ouvre le périphérique.
RUN apk --no-cache add mesa-va-gallium \
    && if [ "$(apk --print-arch)" = "x86_64" ]; then \
         apk --no-cache add intel-media-driver libva-intel-driver; \
       fi

WORKDIR /app

# Copy the compiled binary from the builder stage
COPY --from=builder /app/media-server .

# Create the data directory (where the database lives). /app/downloads starts
# empty: the installers are no longer baked into the image but fetched from the
# GitHub Release of the server's version (ADR-0062). The folder stays for an
# installer the admin uploads by hand, which wins over the Release.
RUN mkdir -p /app/data /app/downloads

# Le `sed` retire les fins de ligne Windows : l'image se construit aussi depuis
# un poste Windows (publish-image.ps1), où le script arrive en CRLF et ne
# trouverait plus son interpréteur (« /bin/sh^M »).
COPY docker-entrypoint.sh /app/docker-entrypoint.sh
RUN sed -i 's/\r$//' /app/docker-entrypoint.sh && chmod +x /app/docker-entrypoint.sh

# Default port
EXPOSE 8080

# /api/ping ne touche ni la base ni le disque des médias : il dit seulement que
# le processus répond. Le démarrage laisse le temps d'ouvrir la base.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3     CMD wget -q -O /dev/null http://127.0.0.1:8080/api/ping || exit 1

# Configure default paths inside container
ENV MOVIES_DIR=/media/Films \
    SERIES_DIR=/media/Series

# Run the media server with database pointing to the persistent volume
ENTRYPOINT ["/app/docker-entrypoint.sh", "-port", "8080", "-db", "/app/data/player.db"]
