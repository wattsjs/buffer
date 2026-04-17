# Buffer macOS App - Implemented Features Inventory
## Features Missing or Underspecified in README.md

### Core Features Present in Code But Not Documented

#### 1. **Recording/DVR System** (Not mentioned in README)
Complete TV recording subsystem with multiple recording modes:
- **Scheduled recordings**: Record programs at specific times (from EPG)
- **Live tee recordings**: Record while watching without extra server connections
- **Recording states**: scheduled, startingUp, recording, completed, failed, cancelled
- **Stream capture**: Captures video codec, resolution, frame rate, audio codec
- **Byte tracking**: Real-time byte counter and final file size tracking
- **Status tracking**: Live byte counts, actual start/end times, error messages
- **Playback**: Play in-progress or completed recordings directly

**Files**: 
- `Models/Recording.swift` - Recording model with detailed metadata
- `Services/RecordingManager.swift` - Recording lifecycle management
- `Services/RecordingPlayback.swift` - Recording playback handler
- `Views/RecordingsView.swift` - UI for managing recordings by status (Recording/Scheduled/Past)

#### 2. **Recording Advanced Features** (Not mentioned in README)
- **Pre-roll/post-roll padding**: Configurable start-early and stop-late (0-300s and 0-600s)
- **Mac wake-from-sleep**: Schedule Mac to wake before recordings (120s lead time before pre-roll)
- **Power assertion**: Prevents idle sleep during active recordings
- **Output folder selection**: User-selectable output with security-scoped bookmarks
- **Recording output format**: MPEG-TS (.ts) files grouped by channel name

**Files**:
- `Views/SettingsView.swift` - RecordingsSettingsTab with padding/output/wake settings
- `Services/RecordingManager.swift` - Wake event scheduling via IOPMSchedulePowerEvent

#### 3. **Program Search** (Mentioned as "EPG with search" but missing detail)
Separate from EPG browsing - interactive search with fuzzy matching:
- **Program search**: Full-text fuzzy search across program titles
- **Channel search**: Find channels by name
- **Score-based ranking**: Results ranked by match quality
- **Real-time filtering**: Debounced search (140ms debounce)
- **Background indexing**: Async search task without blocking UI
- **Current program indicator**: Shows which programs are now-playing

**Files**:
- `Views/ProgramSearchView.swift` - ProgramSearchController with fuzzy matching algorithm
- `ContentView.swift` - Command+F keyboard shortcut to focus search

#### 4. **Sync Scheduling** (Not mentioned in README)
Automatic background sync with granular control:
- **Separate intervals**: Different refresh rates for playlist vs EPG
- **Configurable durations**: 1hr, 2hr, 4hr, 6hr, 12hr, 24hr options
- **Silent sync option**: Background EPG refresh without UI interruption
- **Scope control**: Full sync (all data) vs EPG-only
- **Manual trigger**: One-click "Refresh Now" with sync status display
- **Auto-sync on launch**: EPG syncs automatically on app startup if cache empty

**Files**:
- `Views/SettingsView.swift` - SyncSettingsTab with interval pickers
- `Models/SyncInterval.swift` - SyncInterval enum with configurable hours
- `ContentView.swift` - Startup sync logic and scheduler management

#### 5. **Live Sports Integration** (Documented as feature but implementation details missing)
Full ESPN integration with advanced filtering and categorization:
- **Multiple sports**: 11 sports across 20+ leagues (NFL, NBA, MLB, NHL, MLS, UCL, F1, UFC, PGA, Cricket, Rugby, etc.)
- **Real-time scores**: Live game status with inning/quarter/period detail
- **Team info**: Team names, abbreviations, scores, logos, records
- **Tournament support**: Named tournaments (e.g. "Barcelona Open" for tennis)
- **Event grouping**: Live Now, Up Next, Later Today, Tomorrow, This Week, Finished
- **Venue information**: Stadium/venue names for events
- **Broadcast networks**: Multiple broadcast channels per event
- **Sport filtering**: Filter view by selected sports (checkbox selection, multi-select)
- **Hide finished**: Toggle to hide completed events
- **Live/Finished badges**: Visual status indicators on event cards
- **Home page integration**: Live events shown on Home view in scrollable carousel
- **Auto-refresh**: Background polling with configurable intervals
- **ESPN API integration**: Fetches from ESPN scoreboard API with 1-day lookback + 7-day forward

**Files**:
- `Services/ESPNClient.swift` - ESPN API client with league support
- `Models/SportEvent.swift` - SportEvent, League, Sport, EventStatus, SportTimeGroup models
- `ViewModels/SportsViewModel.swift` - Sports data management and filtering
- `Views/SportsView.swift` - Sports browsing with sport/time filtering
- `Views/HomeView.swift` - Home page with live sports carousel

#### 6. **Program Reminders** (Documented but underspecified)
Notification-based reminders for upcoming programs:
- **Set reminders**: Right-click program in EPG to set reminder
- **Configurable lead time**: Minutes before program starts (in minutes)
- **Notification delivery**: macOS notifications at scheduled time
- **Auto-open on notification**: Click notification to open and play channel
- **List management**: View all upcoming reminders with relative time
- **Cancellation**: Cancel individual reminders or all at once
- **Persistence**: Reminders survive app restart

**Files**:
- `Models/ProgramReminder.swift` - ProgramReminder with configurable lead time
- `Services/NotificationManager.swift` - Notification scheduling and delivery
- `Views/RemindersView.swift` - Reminders list with live time updates
- `Views/ReminderContextMenu.swift` - Reminder creation UI

#### 7. **Multiple Playlists** (Not mentioned in README)
Full support for managing multiple IPTV accounts:
- **Add/edit/delete playlists**: Full CRUD operations
- **Playlist switching**: Quick switch between active playlists in sidebar
- **Playlist duplication**: Copy existing playlist config
- **Active indicator**: Visual checkmark on active playlist
- **Playlist info**: Name, type (Xtream/M3U), last sync time
- **Per-playlist cache**: Separate channel/EPG data for each account

**Files**:
- `Models/ServerConfig.swift` - Server/playlist configuration model
- `Views/SettingsView.swift` - PlaylistsSettingsTab with full playlist management UI

#### 8. **Server/Account Management** (Not mentioned in README)
Detailed server account status and validation:
- **Account status display**: Channels count, guide status, connections/max, expiry date
- **Connection testing**: Test Xtream/M3U connection before saving
- **Xtream specifics**: Auth validation, account expiry tracking, trial indicator
- **M3U handling**: Playlist validation, file parsing
- **Guide status**: EPG reachability probe (reachable/unavailable/not configured)
- **Last checked timestamp**: When account status was last verified

**Files**:
- `Models/ServerAccountStatus.swift` - Account status tracking
- `Services/XtreamClient.swift` - Xtream API client
- `Services/M3UParser.swift` - M3U playlist parsing
- `Views/SettingsView.swift` - ServerConnectionTester with detailed feedback

#### 9. **Playback Settings** (Documented as "configurable" but missing detail)
- **Network buffer**: Configurable seconds of buffering (slider, 0+ range)
- **External player**: Optional playback via VLC, IINA, or Infuse instead of built-in
- **Buffer reasoning**: Explains stutter vs latency tradeoff in UI

**Files**:
- `Views/SettingsView.swift` - PlaybackSettingsTab with buffer stepper and player picker
- `Services/ExternalPlayer.swift` - External player launch logic

#### 10. **Channel Group Management** (Documented but implementation details missing)
- **Group browsing**: View channels organized by broadcast group/category
- **Hide groups**: Right-click folder to hide from sidebar
- **Reorder groups**: Drag-drop groups in sidebar to reorder
- **Show hidden**: Separate "Hidden" section with un-hide buttons
- **Favorite channels**: Separate Favorites section in sidebar

**Files**:
- `Views/ChannelSidebarView.swift` - Sidebar with group management (hide, reorder, show hidden)
- `Views/EPGGridView.swift` - Group-filtered channel browsing

#### 11. **Catchup/Rewind Details** (Documented vaguely as "Catchup/rewind playback")
Multiple catchup format support with varying playback windows:
- **Xtream format**: `/timeshift/{user}/{pass}/{mins}/{Y-m-d:H-M}/{id}.ts`
- **M3U standard**: Template-based with `${start}/${end}/${duration}` placeholders
- **M3U append**: Source appended to live URL with substitutions
- **M3U shift**: Query params `?utcstart=&utcend=` added to live URL
- **Window duration**: Per-channel rewind window in days (1-30+ days possible)
- **Per-channel support**: Rewind availability varies by channel/provider
- **Catchup scrubber**: Step-slider in player to seek within catchup window

**Files**:
- `Models/Channel.swift` - CatchupInfo model with kind and days
- `Services/CatchupURLBuilder.swift` - URL construction for all catchup formats
- `Views/PlayerView.swift` - Catchup scrubber UI (catchupScrubOffset state)

#### 12. **Multi-View Player Windows** (Documented but lacking layout detail)
Five distinct multi-view layout modes:
- **Single**: Full screen for one channel
- **1+2**: One large (left) + two stacked small (right)
- **2x2 grid**: Four channels in 2x2 grid
- **3x3 grid**: Nine channels in 3x3 grid  
- **Focused + Thumbnails**: Large focused + scrollable thumbnail sidebar

**Files**:
- `Views/PlayerGridView.swift` - Layout computation with 5 layout modes
- `Views/MultiViewLayoutMenu.swift` - Layout selection menu
- `Models/PlayerSession.swift` - PlayerSession with layout and slot management

#### 13. **Player Chrome/Fullscreen Features** (Not mentioned in README)
- **Chrome toggle**: Show/hide player controls with keyboard (F for fullscreen)
- **Chrome pinning**: "Pin" button to keep controls visible
- **Auto-hide**: Controls hide after inactivity (timed dismiss)
- **Media info expansion**: Toggle expanded/collapsed program details panel
- **User preference persistence**: Chrome state saved to UserDefaults

**Files**:
- `Views/PlayerView.swift` - PlayerChromeState with mediaInfoDisplay and isPinned
- `Views/KeyboardShortcutsView.swift` - Documents F key for fullscreen toggle

#### 14. **Recent Channels** (Not mentioned in README)
Track and display recently watched channels:
- **Auto-tracking**: Channels tracked when opened
- **Home display**: Recently Watched section on Home view
- **Recency order**: Most recent first
- **Empty state**: Placeholder when no recents exist

**Files**:
- `Views/HomeView.swift` - Recently Watched section with channel cards
- `ContentView.swift` - openChannel() calls viewModel.addRecent(channel)

#### 15. **EPG Visual Details** (Not mentioned in README)
- **Now line**: Red vertical line showing current time in EPG grid
- **Aired shading**: Visual distinction for programs that have already ended
- **12-hour timeline**: Scrollable program guide shows 12 hours at a time
- **Current program highlight**: Programs currently playing marked distinctly
- **Program time labels**: Start/end times displayed on each program

**Files**:
- `Views/EPGGridView.swift` - Timeline layout with nowX calculation and airdate shading
- `Views/EPGScrollGrid.swift` - EPG grid rendering with time header

#### 16. **Keyboard Shortcuts** (Documented but incomplete)
- **Space**: Play/pause
- **Left arrow**: Seek back 10 seconds
- **Right arrow**: Seek forward 10 seconds
- **F**: Toggle fullscreen
- **Cmd+F**: Search programs
- **Cmd+?**: Show shortcuts window

**Files**:
- `Views/PlayerView.swift` - Keyboard event handling for playback
- `Views/KeyboardShortcutsView.swift` - Shortcuts reference UI

#### 17. **User Feedback System** (Not mentioned in README)
Toast notifications and banner feedback:
- **Sync feedback**: Progress messages during playlist/EPG sync
- **Error feedback**: Contextual error messages with suggestions
- **Toast system**: App feedback center with auto-dismiss
- **Loading stages**: Detailed sync status (Connecting, downloading, parsing, etc.)

**Files**:
- `Views/AppFeedbackBanner.swift` - Feedback banner UI
- `Services/AppFeedbackCenter.swift` - Feedback notification management
- `ContentView.swift` - Feedback display and animation

#### 18. **Live Status in Player** (Not mentioned in README)
- **Live pill**: Red indicator showing "LIVE" status for live channels
- **Live latching**: Sticky live state that only flips when drifting >max(2×buffer, buffer+5s) behind
- **Live button**: Jump to live edge button in player chrome
- **In-progress recording indicator**: Shows recording is ongoing

**Files**:
- `Views/PlayerView.swift` - liveLatched state and live-edge logic

#### 19. **Stream Proxy** (Not mentioned in README)
Internal proxy for stream management:
- **Connection sharing**: Multiple players/recorders share broadcaster connection
- **Live-tee support**: Recording tees off proxy, not requiring separate connection
- **Bandwidth optimization**: Reduces provider connection load

**Files**:
- `Services/StreamProxy.swift` - Stream proxy implementation

#### 20. **Data Caching System** (Not mentioned in README)
Persistent local caching of playlist/EPG data:
- **Per-server cache**: Separate caches for different IPTV accounts
- **Cache invalidation**: Schema-versioned for safety
- **Offline availability**: Cached data available without network
- **Cache keys**: Deterministic keys for consistent lookups

**Files**:
- `Services/DataCache.swift` - Caching layer with cache key generation

#### 21. **Image Loading and Logo Analysis** (Not mentioned in README)
- **Logo caching**: Downloaded channel logos cached locally
- **Color analysis**: Extracts dominant color from channel logos for UI theming
- **Async loading**: Non-blocking image fetches

**Files**:
- `Services/ImageLoader.swift` - Image cache and async loading
- `Services/LogoColorAnalyzer.swift` - Dominant color extraction from logos

---

## Summary of Feature Gaps

### **Major Gaps (Significant Features Not Mentioned)**
1. **Recording/DVR System** - Complete implementation with scheduled/live recording, playback, and advanced features
2. **Program Search** - Separate full-text search interface with fuzzy matching
3. **Sync Scheduling** - Automatic background sync with configurable intervals
4. **Multiple Playlists** - Full support for managing multiple IPTV accounts
5. **Server Account Management** - Status display, connection testing, guide validation
6. **Recording Features** - Wake-from-sleep, padding, output folder selection

### **Minor Gaps (Mentioned but Underspecified)**
1. **Sports Integration** - Missing 11 sports, 20+ leagues, team info, filtering details
2. **Buffering Settings** - Specific slider range and tradeoff explanation
3. **EPG Display** - Now-line, aired shading, 12-hour timeline
4. **Multi-view Layouts** - 5 specific layout modes (1+2, 2x2, 3x3, focused, etc.)
5. **Group Management** - Reordering and hiding capabilities
6. **Catchup Formats** - 4 different format types and window duration details

### **Undocumented Features**
- Channel recents tracking
- User feedback/toast system
- Live status latching in player
- Stream proxy optimization
- Data caching system
- Logo color analysis

---

## Recommendation

**Update README to include:**

1. Add "Recordings" section with scheduled and live recording capabilities
2. Expand "Electronic Program Guide" to detail search, sync scheduling, and visual elements
3. Expand "Live sports" to list supported sports and leagues
4. Add "Multiple Playlists" as separate feature
5. Add "Server/Account Status" features
6. Add "Catchup/Rewind" format details
7. Expand "Multi-view" with layout details
8. Add section on "Program Reminders and Notifications"

