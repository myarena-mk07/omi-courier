# Omi Courier

A small private iPhone app. It takes the audio from an Omi pendant over Bluetooth, keeps it in files on the
iPhone, and sends each file to a private server on Wi-Fi. It deletes a file only after the server confirms the
SHA-256 checksum.

- `Sources/Pendant.swift` Bluetooth link and audio packets
- `Sources/SegmentWriter.swift` audio files (`[UInt32 length][Opus packet]`, one run of audio for each file)
- `Sources/Uploader.swift` upload on Wi-Fi with a background session
- `Sources/Heartbeat.swift` status message to the server
- `.github/workflows/build.yml` makes an unsigned `.ipa`. The phone signs it at install.

The server address is not in the code and not in the app file. The app gets it one time from
`Documents/config.json` or from a pasted setup text.
