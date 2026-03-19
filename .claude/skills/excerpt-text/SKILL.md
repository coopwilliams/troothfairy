---
name: excerpt-text
description: Cheaply and accurately extracting text matching the request, from files of various types. Useful for when exact text quotes are required, sourced from a directory that is too large to read under a given budget.
---

# Instructions
Follow the "Steps" section below. Remember that this is NOT a summarization task -- it's a Search-and-Filter task. Your job is to follow the steps to create files that might contain what the user wants and then copy over the ones that meet the inclusion criteria. 

# Definitions
EXCERPT_DIR : query-specific kebabcase filepath in the obsidian vault under the `_EXCERPTS` Directory. For example, a search about duck reproduction would place excerpt files into `/my-obsidian-vault/_EXCERPTS/duck-reproduction/`

SEARCH_DIR : The directory in which the search should be performed. If the agent lacks access, simply report back.

READING_BUDGET : user specified, or default USD 0.20

The steps:
1. Using system tools, generate a short random number as a session id.
2. Ripgrep all the files in the search directory and output the result to a randomly named temp file. The `--heading` flag groups results by file, placing the full filepath on its own line above each group.
	- ```bash
	rga -C 15 --heading --rga-adapters=-zip "my_search_term" SEARCH_DIR > /tmp/my_session_id
	```
3. Check that the temp file is under the reading budget. If not, repeat step 2 with a smaller `-C` value until it is. The chunk count formula accounts for both `--` separators and filepath-change splits. Pricing is Haiku 4.5: $1.00/MTok in, $5.00/MTok out.
	- ```bash
	  FILE=/tmp/my_session_id; \
			  CHUNKS=$(( $(grep -c '^--$' "$FILE") + $(grep -c '^/' "$FILE") )); \
			  IN_TOK=$(( $(wc -c < "$FILE") / 4 + CHUNKS * 70 )); \
			  OUT_TOK=$(( CHUNKS * 10 )); \
			  awk "BEGIN { \
			    in_cost  = $IN_TOK  / 1000000 * 1.00; \
			    out_cost = $OUT_TOK / 1000000 * 5.00; \
			    printf \"Chunks   : $CHUNKS\nInput tok: $IN_TOK  → %.6f USD (haiku)\nOutput tok: $OUT_TOK  → %.6f USD (haiku)\nTotal est: %.6f USD\n\", \
			      in_cost, out_cost, in_cost + out_cost; }"
	  ```
4. Split the temp file into a folder of chunks. With `--heading`, the format is:
	- Filepath on its own line (absolute path starting with `/`)
	- Content lines below it
	- `--` separating sections within the same file
	- Blank line then new filepath when the file changes
	```bash
	mkdir -p /tmp/my_session_id_splits && awk -v search_string="my_search_term" -v context_lines=15 '
function flush(    out, pg) {
    gsub(/^\n+/, "", buf)
    gsub(/\n+$/, "", buf)
    if (buf != "") {
        n++
        out = "/tmp/my_session_id_splits/" sprintf("%04d", n)
        printf "---\nagent-added: true\nfilepath: \"%s\"\nsearch_string: \"%s\"\ncontext_lines: %s\n", fname, search_string, context_lines > out
        if (page_start > 0) {
            printf "page_start: %d\npage_end: %d\n", page_start, page_end > out
        }
        printf "---\n\n%s\n", buf > out
        close(out)
        buf = ""
        page_start = 0
        page_end = 0
    }
}
/^--$/ { flush(); next }
/^\// { flush(); fname = $0; next }
/^$/ && buf == "" { next }
{
    line = $0
    if (match(line, /^Page [0-9]+: ?/)) {
        pg = int(substr(line, 6))
        if (page_start == 0 || pg < page_start) page_start = pg
        if (pg > page_end) page_end = pg
        line = substr(line, RSTART + RLENGTH)
    }
    buf = buf line "\n"
}
END { flush() }
' /tmp/my_session_id
	```
5. Evaluate chunks in parallel using the Anthropic API. You do NOT read any chunks yourself. Instead, run a bash script that sends curl requests to the Messages API in parallel. Each call sends one chunk and the inclusion criteria to Haiku, which responds with `yes - descriptive-kebab-filename` or `no`.
	- Source the `.env` file in the project root to get `ANTHROPIC_API_KEY`.
	- Set `CRITERIA` to a concise version of the user's inclusion criteria.
	- Set `SID` to your session id, `SPLITS` to `/tmp/${SID}_splits`, `RESULTS` to `/tmp/${SID}_results`.
	- ```bash
	  source /path/to/orb/.env
	  SPLITS="/tmp/my_session_id_splits"
	  RESULTS="/tmp/my_session_id_results"
	  CRITERIA="my inclusion criteria"
	  BATCH=10

	  mkdir -p "$RESULTS"
	  files=("$SPLITS"/*)
	  total=${#files[@]}
	  for (( i=0; i<total; i+=BATCH )); do
	    pids=()
	    for (( j=i; j<i+BATCH && j<total; j++ )); do
	      chunk="${files[$j]}"
	      name=$(basename "$chunk")
	      (
	        body=$(jq -n --arg criteria "$CRITERIA" --arg chunk "$(cat "$chunk")" '{
	          model: "claude-haiku-4-5",
	          max_tokens: 100,
	          messages: [{role: "user", content: ("Does this text match the criteria? Criteria: " + $criteria + "\n\n" + $chunk + "\n\nIf YES: respond with exactly: yes - descriptive-kebab-case-filename\nIf NO: respond with exactly: no\nNothing else.")}]
	        }')
	        v=$(curl -s https://api.anthropic.com/v1/messages \
	          -H "Content-Type: application/json" \
	          -H "x-api-key: $ANTHROPIC_API_KEY" \
	          -H "anthropic-version: 2023-06-01" \
	          -d "$body" | jq -r '.content[0].text' | head -1 | tr -d '\r')
	        printf '%s' "$v" > "$RESULTS/$name"
	      ) &
	      pids+=($!)
	    done
	    for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
	  done
	  ```
	- Anything other than a line starting with `yes - ` is treated as NO. This is conservative — it may miss a chunk on API failure, but never moves irrelevant content.
	- If you get an auth error, check that `.env` contains `ANTHROPIC_API_KEY=sk-ant-...` and that the account has credits.
6. Collect results: move YES chunks to the vault's EXCERPT_DIR with the haiku-suggested filename, delete NO chunks.
	- ```bash
	  for chunk in "$SPLITS"/*; do
	    name=$(basename "$chunk")
	    result=$(cat "$RESULTS/$name" 2>/dev/null)
	    if printf '%s' "$result" | grep -q '^yes - '; then
	      slug=$(printf '%s' "$result" | sed 's/^yes - //')
	      mv "$chunk" "$EXCERPT_DIR/${slug}.md"
	    else
	      rm "$chunk"
	    fi
	  done
	  rm -rf "$RESULTS"
	  ```
	- Excerpt filenames cannot start with a dot or contain any of these characters: `[]#^|`
	- Do NOT edit chunk files — move them verbatim.
	- Verify the splits folder is empty when done.
7. The job is complete when the splits folder is empty. Report which files were saved to EXCERPT_DIR.

# tips for debugging
- This search term is useful for getting a small, workable result that actually does have some files with multiple matches: `rga -C 3 --rga-adapters=-zip --heading "become ever|be ever"`
