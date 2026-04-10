# Step 7: Add configuration option for compaction mode

## Description
Add a config option (e.g., compaction_mode: lazy | preemptive) to allow users to choose between lazy and preemptive compaction. Default to lazy. This provides flexibility if preemptive works better for some use cases.

## Files
src/coding_agent_config.erl, config.example.yaml

## Status
pending
