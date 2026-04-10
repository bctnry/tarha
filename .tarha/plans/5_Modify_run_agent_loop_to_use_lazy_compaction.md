# Step 5: Modify run_agent_loop to use lazy compaction

## Description
Update run_agent_loop to use the new retry-with-compaction logic. Instead of calling coding_agent_ollama:chat_with_tools_cancellable directly, call through the new wrapper that handles context errors with automatic retry.

## Files
src/coding_agent_session.erl

## Status
pending
