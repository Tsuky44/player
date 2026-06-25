package streaming

// The master playlist and all variant playlists are now generated natively by
// FFmpeg via -var_stream_map (see BuildFFmpegArgs). The handler reads and
// rewrites them, so no manual playlist construction is needed here.
