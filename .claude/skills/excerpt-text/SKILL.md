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
        printf "---\nfilepath: %s\nsearch_string: %s\ncontext_lines: %s\n", fname, search_string, context_lines > out
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
5. Read through the chunked files one by one in sequence. Each chunk has YAML frontmatter with `filepath`, `search_string`, `context_lines`, and (for PDFs) `page_start`/`page_end`. The body text has page prefixes stripped for clean copy-paste. If a file matches the user's filtering criteria then copy it into the EXCERPT_DIR and move on to the next file.
6. When no more files are left to read, the job is done.

# tips for debugging
- This search term is useful for getting a small, workable result that actually does have some files with multiple matches: `rga -C 3 --rga-adapters=-zip --heading "become ever|be ever"`
