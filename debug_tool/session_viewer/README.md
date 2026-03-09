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

**Option A - Using the included serve.py (Recommended for CORS):**
```bash
python3 debug_tool/session_viewer/serve.py 3000
```
Then open: http://localhost:3000

**Option B - Using Python's built-in http.server:**
```bash
python3 -m http.server 3000 --directory debug_tool/session_viewer
```
Then open: http://localhost:3000

**Option C - Open directly in browser:**
```bash
# Linux
xdg-open debug_tool/session_viewer/index.html

# macOS
open debug_tool/session_viewer/index.html

# Windows
start debug_tool/session_viewer/index.html
```

## CORS Troubleshooting

If you see CORS errors in your browser console, try these solutions:

### 1. Use the included serve.py script

The `serve.py` script includes proper CORS headers:
```bash
python3 debug_tool/session_viewer/serve.py 3000
```

### 2. The coding-agent HTTP server already has CORS enabled

The backend server (`coder-http`) includes these CORS headers:
- `Access-Control-Allow-Origin: *`
- `Access-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS`
- `Access-Control-Allow-Headers: Content-Type, Authorization, Accept, X-Requested-With, Origin, Cache-Control`
- `Access-Control-Max-Age: 86400`

### 3. Common CORS issues

| Error | Solution |
|-------|----------|
| "Failed to fetch" | Make sure the HTTP server is running (`./coder-http 8080`) |
| "CORS policy blocked" | Use `serve.py` or ensure both servers are on localhost |
| "Network error" | Check if the API URL is correct in the UI |

### 4. Verify CORS is working

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

- **API URL**: Change the API URL in the input field (default: `http://localhost:8080`)
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
├── serve.py      # Python server with CORS headers
└── README.md     # This file
```

## Browser Compatibility

Works in modern browsers with:
- Fetch API
- ES6+ JavaScript
- CSS Grid/Flexbox