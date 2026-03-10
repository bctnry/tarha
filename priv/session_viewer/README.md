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

### Method 1: Built-in Viewer (Recommended - No CORS issues)

The session viewer is built into the HTTP server. Just start the server and access:

```bash
./coder-http 8080
```

Then open: **http://localhost:8080/viewer**

This method has no CORS issues because the viewer and API are served from the same origin.

### Method 2: Standalone Server

If you want to run the viewer separately:

```bash
# Terminal 1: Start the HTTP server
./coder-http 8080

# Terminal 2: Serve the viewer
python3 -m http.server 3000 --directory debug_tool/session_viewer

# Open http://localhost:3000
```

Set API URL to `http://localhost:8080` in the viewer's input field.

### Method 3: Direct File Access (Not recommended - CORS issues)

Opening `index.html` directly with `file://` protocol will NOT work due to CORS restrictions.
Use Method 1 or Method 2 instead.

## API Endpoints Used

The session viewer connects to these HTTP API endpoints:

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/sessions` | GET | List all sessions |
| `/sessions/active` | GET | List active sessions |
| `/status` | GET | Get agent status |
| `/session/:id` | GET | Get session details |
| `/session/:id/halt` | POST | Halt a session |

## Configuration

- **API URL**: Change the API URL in the input field (leave empty for same-origin)
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
session_viewer/
├── index.html    # Main HTML structure
├── style.css     # Styling
├── app.js        # Application logic
└── README.md     # This file
```

## Browser Compatibility

Works in modern browsers with:
- Fetch API
- ES6+ JavaScript
- CSS Grid/Flexbox

## CORS Configuration

The HTTP server includes CORS headers on all responses:
- `Access-Control-Allow-Origin: *`
- `Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS`
- `Access-Control-Allow-Headers: Content-Type, Authorization, Accept, X-Requested-With, Origin, Cache-Control`

This allows the viewer to be served from a different origin than the API.