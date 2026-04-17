# Buffer

A native macOS IPTV player built with SwiftUI and libmpv.

<img width="2344" height="1770" alt="Screenshot 2026-04-17 at 23 02 26@2x" src="https://github.com/user-attachments/assets/737e9d90-3225-4f89-9453-2fcd2193a60d" />

## Features

### Playlists and library

- Multiple IPTV playlists/accounts with Xtream Codes and M3U support
- XMLTV guide support with per-playlist caching and quick switching
- Server connection testing, guide reachability checks, and account status details
- Favorites, recently watched channels, and per-group hide/reorder controls

### Guide and discovery

- 12-hour Electronic Program Guide with current-program highlighting and a live now-line
- Fast program and channel search with fuzzy matching (`⌘F`)
- Program reminders with macOS notifications and one-click jump back into playback
- Configurable background sync for playlists and EPG data, plus manual refresh

### Playback

- Native libmpv playback with configurable network buffering
- Catchup/rewind playback for Xtream and common M3U catchup formats
- Five multi-view layouts: single, 1+2, 2×2, 3×3, and focused + thumbnails
- External player handoff for VLC, IINA, and Infuse
- Keyboard shortcuts for playback, seeking, fullscreen, search, and help

### Recording and sports

- Scheduled recordings from the guide and one-click live recording while watching
- Recording padding, wake-from-sleep support, and configurable output folder
- Playback for in-progress and completed recordings inside Buffer
- ESPN-powered live sports view with filters, live scores, and matched channel shortcuts
- Home dashboard with live sports, favorites, and recently watched channels
