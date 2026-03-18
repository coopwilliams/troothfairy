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
3. Check that the temp file is under the reading budget. If not, repeat step 2 with a smaller `-C` value until it is.
	- ```bash
	  FILE=/tmp/my_session_id; OUT_PER_SECTION=150; \
			  SECTIONS=$(( $(grep -c '^--$' "$FILE") + 1 )); \
			  IN_TOK=$(( $(wc -c < "$FILE") / 4 )); \
			  OUT_TOK=$(( SECTIONS * OUT_PER_SECTION )); \
			  awk "BEGIN { \
			    in_cost  = $IN_TOK  / 1000000 * 0.80; \
			    out_cost = $OUT_TOK / 1000000 * 4.00; \
			    printf \"Sections : $SECTIONS\nInput tok : $IN_TOK  → %.6f USD\nOutput tok: $OUT_TOK  → %.6f USD\nTotal est : %.6f USD\n\", \
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
5. Process chunks sequentially from `/tmp/my_session_id_splits/`. Start with chunk 0001:
  - Use the Read tool (NOT bash loops) to read `/tmp/my_session_id_splits/0001`
  - Examine its frontmatter and body text. Does it match the user's criteria? Only you can judge.
  - If YES: use Bash to `mv /tmp/my_session_id_splits/0001 /path/to/EXCERPT_DIR/descriptive-name.md`. Do NOT edit the file.
  - If NO: use Bash to `rm /tmp/my_session_id_splits/0001`
  - Then repeat: read chunk 0002, decide, move/delete, then chunk 0003, etc.
  - Excerpt filenames cannot start with a dot or contain any of these characters: `[]#^|`
  - **CRITICAL:** Read one chunk at a time using the Read tool. Do NOT use bash loops, do NOT batch process, do NOT read all chunks upfront. Do NOT read from EXCERPT_DIR. Do NOT summarize or combine chunks. Do NOT edit or add frontmatter to files — move them verbatim. When done, the splits folder should be empty.
6. The job is complete when all chunks have been individually processed and the splits folder is empty.

# tips for debugging
- This search term is useful for getting a small, workable result that actually does have some files with multiple matches: `rga -C 3 --rga-adapters=-zip --heading "become ever|be ever"`
