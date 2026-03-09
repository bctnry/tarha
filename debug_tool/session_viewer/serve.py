#!/usr/bin/env python3
"""
Simple HTTP server for the session viewer with proper CORS headers.
This is useful if you encounter CORS issues with the standard Python http.server.

Usage:
    python3 serve.py [port]

Then open http://localhost:<port> in your browser.
"""

import http.server
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 3000

class CORSRequestHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type, Authorization, Accept')
        self.send_header('Access-Control-Max-Age', '86400')
        super().end_headers()

    def do_OPTIONS(self):
        self.send_response(204)
        self.end_headers()

if __name__ == '__main__':
    print(f"Serving session viewer at http://localhost:{PORT}")
    print("Press Ctrl+C to stop")
    http.server.HTTPServer(('', PORT), CORSRequestHandler).serve_forever()