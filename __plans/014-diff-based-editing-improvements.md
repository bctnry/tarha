# 014: Diff-Based Editing Improvements

**Priority**: Low  
**Impact**: More robust file editing, fewer failed edits  
**Complexity**: Low  
**Files affected**: `coding_agent_tools_file.erl`

## Problem

`edit_file` requires an exact `old_string` match. This fails on:
- Whitespace differences (tabs vs spaces, trailing whitespace)
- Encoding differences
- Line ending differences (CRLF vs LF)
- Partial matches where `old_string` appears multiple times without `replace_all`

## Current Behavior

```erlang
execute(<<"edit_file">>, #{<<"path">> := Path, <<"old_string">> := Old, <<"new_string">> := New}) ->
    case file:read_file(sanitize_path(Path)) of
        {ok, Content} ->
            case find_occurrences(Content, Old) of
                0 -> #{success => false, error => <<"old_string not found">>};
                N when N > 1 andalso not ReplaceAll -> 
                    #{success => false, error => <<"Multiple matches found">>};
                _ ->
                    %% Apply replacement
            end;
        {error, Reason} ->
            #{success => false, error => file:format_error(Reason)}
    end.
```

## Proposed Solution

### 1. Whitespace normalization for matching

```erlang
normalize_for_matching(Content) ->
    %% Normalize line endings to LF
    Content1 = binary:replace(Content, <<"\r\n">>, <<"\n">>, [global]),
    %% Normalize tabs to spaces (4-space convention)
    Content2 = binary:replace(Content1, <<"\t">>, <<"    ">>, [global]),
    %% Strip trailing whitespace from each line
    Lines = binary:split(Content2, <<"\n">>, [global]),
    iolist_to_binary([strip_trailing(L) || L <- Lines]).

strip_trailing(Line) ->
    case re:run(Line, <<"^(.*\\S)\\s*$">>, [{capture, [1], binary}]) of
        {match, [{_, Stripped}]} -> Stripped;
        nomatch -> <<>>
    end.
```

### 2. Fuzzy matching with tolerance

When exact match fails, try normalized matching:

```erlang
find_content_match(Content, OldStr, Opts) ->
    %% Try exact match first
    case find_occurrences(Content, OldStr) of
        N when N > 0 -> {ok, N, exact};
        0 ->
            %% Try normalized match
            NormalizedContent = normalize_for_matching(Content),
            NormalizedOld = normalize_for_matching(OldStr),
            case find_occurrences(NormalizedContent, NormalizedOld) of
                N when N > 0 ->
                    %% Find the match positions in the original content
                    {ok, N, fuzzy};
                0 ->
                    %% Try line-by-line matching
                    case find_line_match(Content, OldStr, Opts) of
                        {ok, N} -> {ok, N, line};
                        not_found -> not_found
                    end
            end
    end.
```

### 3. Hunk-based editing

Add support for multi-line hunks with context lines:

```erlang
%% New parameters for edit_file
%%
%% old_hunk: array of {line_content, type: "match" | "replace"}
%% This allows specifying context lines around the change
%%
%% Example:
%% {
%%   "path": "src/module.erl",
%%   "old_hunk": [
%%     {"line": "  case Value of", "type": "match"},
%%     {"line": "    ok -> {ok, Result}", "type": "replace"},
%%     {"line": "  end", "type": "match"}
%%   ],
%%   "new_lines": ["    ok -> {ok, Result, Extra}"]
%% }
```

### 4. Line-number based editing

Add a simpler alternative: specify line numbers directly.

```erlang
%% New parameters for edit_file
%%
%% start_line: first line to replace (1-indexed)
%% end_line: last line to replace (inclusive)
%% new_string: replacement content
%%
%% Example:
%% {
%%   "path": "src/module.erl",
%%   "start_line": 42,
%%   "end_line": 45,
%%   "new_string": "    case Value of\n        ok -> {ok, Result, Extra}\n    end"
%% }
```

### 5. Improved error messages

When matching fails, provide helpful context:

```erlang
#{success => false, 
  error => <<"old_string not found in src/module.erl">>,
  error_code => <<"not_found">>,
  details => #{
    closest_match => <<"  case Value of\n    ok -> Result">>,  %% Best fuzzy match
    closest_match_line => 42,                                    %% Line number
    diff_hint => <<"Whitespace difference: expected tabs, found spaces">>
  }}
```

### 6. Edit preview

Add a `dry_run` option:

```erlang
%% When dry_run is true, return the diff without applying the edit
execute(<<"edit_file">>, #{<<"dry_run">> := true} = Args) ->
    %% Compute the diff but don't write to file
    {ok, Content} = file:read_file(Path),
    NewContent = apply_edit(Content, OldStr, NewStr),
    Diff = compute_diff(Content, NewContent),
    #{success => true, diff => Diff, lines_changed => count_changes(Diff)}.
```

### 7. Automatic context expansion

When `old_string` is too short (under 20 chars) and matches multiple locations, automatically expand the context:

```erlang
expand_context(Content, MatchPos, MatchLen, ExpandLen) ->
    Start = max(1, MatchPos - ExpandLen),
    End = min(byte_size(Content), MatchPos + MatchLen + ExpandLen),
    binary:part(Content, Start, End - Start).
```

## Implementation Steps

1. Implement `normalize_for_matching/1` with CRLF, tab, and trailing whitespace normalization
2. Implement `find_content_match/3` with exact → normalized → line-by-line fallback
3. Add `start_line`/`end_line` parameters to `edit_file` tool schema
4. Add `dry_run` parameter to `edit_file` tool schema
5. Implement line-number based editing
6. Implement edit preview (diff computation without write)
7. Enhance error messages with closest match and diff hints
8. Add `expand_context/4` for short match strings
9. Update `coding_agent_tools:tools/0` with new parameters
10. Write tests for each matching strategy (exact, normalized, line-by-line)
11. Write tests for line-number editing and dry-run mode

## Edge Cases

- **CRLF files on Linux**: Normalization must handle both line ending styles
- **Unicode content**: BOM characters, multi-byte characters in match strings
- **Binary files**: `edit_file` should reject binary content
- **Empty old_string**: Should insert at beginning (or specified line)
- **Empty new_string**: Should delete the matched content
- **Multiple matches with normalization**: If normalization makes them identical, require `replace_all`

## Success Metrics

- `edit_file` success rate improves by reducing whitespace-related failures
- Line-number editing works as a reliable fallback
- Error messages help the LLM self-correct
- `dry_run` allows safe edit preview