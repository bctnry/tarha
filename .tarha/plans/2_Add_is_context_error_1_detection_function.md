# Step 2: Add is_context_error/1 detection function

## Description
Add a helper function in coding_agent_ollama.erl to detect if an error is a "context too long" error. Pattern match against known Ollama error formats (e.g., `{http_error, 400, Body}` where Body contains "context" or "length exceeded"). Return true/false.

## Files
src/coding_agent_ollama.erl

## Status
completed
