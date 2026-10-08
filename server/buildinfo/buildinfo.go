// Package buildinfo dit quelle version du serveur tourne.
package buildinfo

// Version est posée à la compilation de l'image
// (`-ldflags "-X project-player/server/buildinfo.Version=…"`, voir le
// Dockerfile). Un binaire construit à la main reste « dev ».
var Version = "dev"
