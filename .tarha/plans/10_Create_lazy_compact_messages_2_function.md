# Step 10: Create lazy_compact_messages/2 function

## Description
Add a function that compacts messages only when needed. It takes the current messages and a target ratio (e.g., 0.5), then uses the existing compaction logic to reduce message size. This is the core function that gets called lazily when a context error occurs.

## Files
`src/coding_agent_ollama.erl`

## Status
pending
