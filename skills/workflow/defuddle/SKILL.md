---
name: defuddle
description: Use when the user gives a URL to read, summarize, or analyze, or wants online documentation, an article, a blog post, or any other standard web page. Use instead of WebFetch for HTML pages. Not for URLs ending in .md, which are already Markdown; fetch those directly.
license: LICENSE
---

# Defuddle

Use Defuddle CLI when the user wants clean Markdown extracted from a web page. It removes navigation, ads, and other page clutter.

Check availability with `defuddle --help`. If it is missing, explain the dependency and offer installation with `npm install -g defuddle`. Do not claim extraction succeeded if the tool is unavailable or returns an error.

## Usage

Always use `--md` for markdown output:

```bash
defuddle parse <url> --md
```

Save to file:

```bash
defuddle parse <url> --md -o content.md
```

Extract specific metadata:

```bash
defuddle parse <url> -p title
defuddle parse <url> -p description
defuddle parse <url> -p domain
```

## Output formats

| Flag | Format |
|------|--------|
| `--md` | Markdown (default choice) |
| `--json` | JSON with both HTML and markdown |
| (none) | HTML |
| `-p <name>` | Specific metadata property |
