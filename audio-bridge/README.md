# Audio Bridge (experimental)
A small FastAPI + yt-dlp + FFmpeg service intended to **test** audio acquisition separately from the legacy iOS 9 app. It does not change DNSBlock or the Central da Casa. It is **not yet integrated** into the iPad app and cannot guarantee that YouTube will serve every track.

## Deployment without a computer
1. Create a Docker-compatible web service on a hosting provider from this GitHub repository, using **audio-bridge** as the root directory.
2. Configure the secret environment variable `AUDIO_BRIDGE_TOKEN` with a long random value. Never commit it.
3. Configure the provider's HTTP port to `8080` (or supply `PORT`).
4. Test `https://YOUR-HOST/health` and expect `{"status":"ok","service":"audio-bridge"}`.
5. Test authenticated `GET /audio?url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3DVIDEO_ID` with header `Authorization: Bearer YOUR_TOKEN`. The response is a temporary M4A file or a diagnostic HTTP status.

**Limitations:** Some hosts sleep, require billing, or block YouTube requests. YouTube may return HTTP 403, require PO tokens, or change its formats. The API does not circumvent those restrictions. yt-dlp downloads may be inconsistent, and usage must respect platform terms and content rights. Use HTTPS only. Never expose an unauthenticated downloader.

## Planned iPad integration
The native Central will send the selected video URL to the bridge, store the returned M4A in its private temporary directory, play it with AVAudioPlayer, delete it after playback/stop/switch, and preserve the file while paused. For now, the original app remains unchanged. API tokens should be stored in iOS Keychain, not the repository.
