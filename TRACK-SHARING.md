# Sharing Custom Tracks

In the macOS track editor, click **Open**, then **Export** to export the
current editor track, including unsaved changes. Export does not save changes
to your local library. You can also use Shift+Cmd+S.

Send the resulting `.slideways-track` file through AirDrop, chat, email, or
a download link. Recipients can double-click it in Finder with the packaged
Slideways app installed, or choose **Open > Import** in the editor
(Shift+Cmd+O). An import preview appears before anything is saved.

Confirming **Import** saves a new local copy and opens it in the editor.
Canceling leaves the library unchanged. Each import gets a new ID, even if
the same file was imported before, so existing tracks are never overwritten.
Unsaved editor changes require confirmation before replacement. Document
opening does not interrupt an active race or online session. When opening
several files together, only the first is offered for import.

## File Format

Files are UTF-8 JSON, limited to 1 MiB, with this envelope:

```json
{
  "format": "slideways-track",
  "version": 1,
  "track": { "id": "custom-example", "name": "Example", "controlPoints": [] }
}
```

The abbreviated track above illustrates the envelope, not a playable track.
The payload uses the existing `TrackDefinition` Codable representation and
contains all track geometry, theme, surfaces, bridges, paint, and objects.
No external assets are needed. The payload ID is replaced on import; the
download's filename is irrelevant. Invalid geometry, excessive collection
sizes, unsupported formats or versions, and oversized files are rejected.
Tracks must also fit the local editor's limits, so loading a saved import
cannot silently alter its content.

Local Application Support files remain in their existing JSON format. This
exchange format is separate from local persistence, allowing future format
versions without changing existing saved tracks.

## Distribution

Files can be hosted at ordinary HTTPS URLs without a service or account.
A future community catalog can index these files with author information,
previews, and download links; no catalog or publishing backend is included.
Online races already transmit their track to participants, but do not
automatically add it to their local library.

## Verification

Run `swift run SlicksSim --editor` for persistence and sharing regression
checks. The native debug harness supports `SLIDEWAYS_SHARING_TEST=1` with
`SLIDEWAYS_SNAPSHOT_DIR` and an isolated `SLIDEWAYS_TRACKS_DIR` to capture
the browser, import preview, and imported editor state.