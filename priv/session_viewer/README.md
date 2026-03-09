# Session Viewer

A web-based debug tool for viewing and managing coding agent sessions.

## Features

- 📋 View all active sessions
- 📊 Session statistics (tokens, messages, tool calls)
- 💬 View conversation history
- 🔄 Auto-refresh capability
- ⏹ Halt sessions
- 📂 See open files per session

## Usage

### Step 1: Start the Coding Agent HTTP Server

```bash
./coder-http 8080
```

### Step 2: Open the Session Viewer

**Option A - Built-in viewer (Recommended, No CORS issues):**

The HTTP server now serves the session viewer directly. Simply open in your browser:

```
http://localhost:8080/viewer
```

This is the recommended method as it serves the viewer from the same origin as the API, eliminating CORS issues completely.

**Option B - Standalone Python server:**

```bash
python3 -m http.server 3000 --directory debug_tool/session_viewer
```
Then open: http://localhost:3000

Note: If using this method, you'll need to set the API URL to `http://localhost:8080` in the UI.

**Option C - Open directly (May have CORS issues):**

```bash
# Linux
xdg-open debug_tool/session_viewer/index.html

# macOS
open debug_tool/session_viewer/index.html

# Windows
start debug_tool/session_viewer/index.html
```

Note: Opening via `file://` protocol will cause CORS issues. Use Option A or B instead.

## CORS Troubleshooting

### The built-in viewer (Option A) eliminates all CORS issues

When you access `http://localhost:8080/viewer`, the viewer is served from the same origin as the API, so no CORS restrictions apply.

### CORS headers are still enabled for external access

The backend server includes these CORS headers:
- `Access-Control-Allow-Origin: *`
- `Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS`
- `Access-Control-Allow-Headers: Content-Type, Authorization, Accept, X-Requested-With, Origin, Cache-Control`
- `Access-Control-Max-Age: 86400`

### Verify CORS is working

```bash
# Test CORS preflight request
curl -X OPTIONS -i http://localhost:8080/sessions
# Should see: Access-Control-Allow-Origin: *

# Test a GET request
curl -i http://localhost:8080/sessions
# Should see CORS headers in response
```

## API Endpoints Used

The session viewer connects to these HTTP API endpoints:

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/sessions` | GET | List all sessions |
| `/sessions/active` | GET | List active sessions |
| `/status` | GET | Get agent status |
| `/session/:id` | GET | Get session details |
| `/session/:id/halt` | POST | Halt a session |
| `/session/:id/load` | POST | Load a saved session |

## Configuration

- **API URL**: Leave empty for same-origin access (when using built-in viewer), or set to `http://localhost:8080` for standalone
- **Auto-refresh**: Toggle automatic refresh every 5 seconds

## Session Card Info

Each session card displays:

- **Session ID** (truncated)
- **Status**: Idle (green) or Busy (yellow, pulsing)
- **Model**: Current AI model
- **Messages**: Number of messages in history
- **Tokens**: Estimated or actual token count
- **Tool Calls**: Number of tool invocations

## Session Detail Panel

Click on a session card or "Stats" button to see:

- Full session ID
- Model name
- Context window size
- Token usage breakdown
- Working directory
- Open files
- Full message history

## Development

The session viewer is a standalone HTML/CSS/JS application with no build step required.

```
priv/session_viewer/        # Built-in viewer (served via /viewer)
├── index.html    # Main HTML structure
├── style.css     # Styling
├── app.js        # Application logic
└── README.md     # This file

debug_tool/session_viewer/  # Standalone viewer (same files)
```

## Browser Compatibility

Works in modern browsers with:
- Fetch API
- ES6+ JavaScript
- CSS Grid/Flexbox