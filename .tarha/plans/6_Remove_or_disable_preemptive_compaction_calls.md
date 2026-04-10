# Step 6: Remove or disable preemptive compaction calls

## Description
Remove or comment out the preemptive maybe_compact_session calls in do_ask and do_ask_stream. The compaction should now only happen reactively when context errors occur. Optionally keep the collapse_session for extreme cases as a safety net.

## Files
src/coding_agent_session.erl

## Status
pending
