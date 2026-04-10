# Step 4: Add compact_and_retry/5 function

## Description
Create a function that wraps the chat API call with retry-on-context-error logic:
1. Call the Ollama API
2. If error and is_context_error, call lazy_compact_messages
3. Retry the API call with compacted messages (max 1-2 retries)
4. If still fails after compaction, return error to caller

## Files
src/coding_agent_session.erl

## Status
in_progress
