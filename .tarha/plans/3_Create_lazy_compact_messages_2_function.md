# Step 3: Create lazy_compact_messages/2 function

## Description
Create the two-step lazy compaction function in coding_agent_session.erl:
1. Take the first N messages (e.g., first 5-10) and summarize them into a single "summary message"
2. Combine that summary message with the remaining messages and create a full conversation summary
3. Return compacted messages list for retry
This is different from current approach - it creates a comprehensive summary rather than keeping recent messages verbatim.

## Files
src/coding_agent_session.erl

## Status
completed
