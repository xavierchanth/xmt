import { readdir, readFile, stat } from "node:fs/promises";
import path from "node:path";
import process from "node:process";

const root = process.cwd();
const requestedScanRoots = process.argv.slice(2);
const defaultScanRoots = ["README.md", "AGENTS.md", "docs", "repo"];
const requestedDocsRoots = (process.env.DOCS_ROOTS ?? "docs")
  .split(",")
  .map((entry) => entry.trim())
  .filter(Boolean);

async function exists(entry) {
  try {
    await stat(entry);
    return true;
  } catch {
    return false;
  }
}

const scanRoots = (requestedScanRoots.length > 0 ? requestedScanRoots : defaultScanRoots).map(
  (entry) => path.resolve(root, entry),
);
const presentScanRoots = (
  await Promise.all(scanRoots.map(async (entry) => ((await exists(entry)) ? entry : null)))
).filter(Boolean);
const documentationRoots = (
  await Promise.all(
    requestedDocsRoots.map(async (entry) => {
      const resolved = path.resolve(root, entry);
      return (await exists(resolved)) ? resolved : null;
    }),
  )
).filter(Boolean);

if (presentScanRoots.length === 0) {
  console.error("No documentation scan roots exist.");
  process.exit(1);
}

async function markdownFiles(entry) {
  const entryStat = await stat(entry);
  if (entryStat.isFile()) return entry.endsWith(".md") ? [entry] : [];

  const children = await readdir(entry, { withFileTypes: true });
  const nested = await Promise.all(
    children
      .filter((child) => !child.name.startsWith("."))
      .map((child) => markdownFiles(path.join(entry, child.name))),
  );
  return nested.flat();
}

function proseLines(markdown) {
  const lines = markdown.split("\n");
  let fence = null;

  return lines.map((line) => {
    const marker = line.match(/^\s*(`{3,}|~{3,})/u)?.[1];
    if (marker) {
      if (fence === null) fence = marker[0];
      else if (marker[0] === fence) fence = null;
      return "";
    }
    if (fence !== null) return "";
    return line.replace(/`[^`]*`/gu, "");
  });
}

function slugify(heading) {
  return heading
    .trim()
    .toLowerCase()
    .replace(/<[^>]+>/gu, "")
    .replace(/[^\p{Letter}\p{Number}\s_-]/gu, "")
    .replace(/\s+/gu, "-");
}

function headingAnchors(lines) {
  const occurrences = new Map();
  const anchors = new Set();

  for (const line of lines) {
    const heading = line.match(/^#{1,6}\s+(.+?)\s*#*$/u)?.[1];
    if (!heading) continue;
    const base = slugify(heading);
    const occurrence = occurrences.get(base) ?? 0;
    occurrences.set(base, occurrence + 1);
    anchors.add(occurrence === 0 ? base : `${base}-${occurrence}`);
  }

  return anchors;
}

function markdownLinks(lines) {
  const links = [];
  const pattern = /!?\[[^\]]*\]\(([^)\s]+)(?:\s+["'][^"']*["'])?\)/gu;
  for (const match of lines.join("\n").matchAll(pattern)) links.push(match[1]);
  return links;
}

function display(file) {
  return path.relative(root, file) || ".";
}

function isExternal(destination) {
  return /^[a-z][a-z0-9+.-]*:/iu.test(destination) || destination.startsWith("//");
}

function isDocumentationPage(file) {
  return documentationRoots.some(
    (docsRoot) => file === docsRoot || file.startsWith(`${docsRoot}${path.sep}`),
  );
}

function isWithinRepository(file) {
  return file === root || file.startsWith(`${root}${path.sep}`);
}

// A page opens with a paragraph when the first non-blank line after its H1 is prose:
// not a heading, list item, table row, blockquote, code fence, or HTML block.
function opensWithParagraph(rawLines, headingIndex) {
  for (let index = headingIndex + 1; index < rawLines.length; index += 1) {
    const line = rawLines[index].trim();
    if (line === "") continue;
    return !/^(#{1,6}\s|[-*+]\s|\d+[.)]\s|\||>|`{3,}|~{3,}|<)/u.test(line);
  }
  return false;
}

const files = [
  ...new Set(
    (await Promise.all(presentScanRoots.map(markdownFiles)))
      .flat()
      .map((entry) => path.resolve(entry)),
  ),
].sort();
const parsed = new Map();
const errors = [];

async function parseFile(file) {
  const markdown = await readFile(file, "utf8");
  const rawLines = markdown.split("\n");
  const lines = proseLines(markdown);
  const headings = lines
    .map((line, index) => {
      const match = line.match(/^(#{1,6})\s+(.+?)\s*#*$/u);
      return match ? { level: match[1].length, text: match[2], index } : null;
    })
    .filter(Boolean);

  const document = {
    rawLines,
    lines,
    headings,
    anchors: headingAnchors(lines),
    links: markdownLinks(lines),
    targets: new Set(),
  };
  parsed.set(file, document);
  return document;
}

async function parseIfNeeded(file) {
  return parsed.get(file) ?? (await parseFile(file));
}

for (const file of files) {
  const document = await parseIfNeeded(file);
  const { headings, rawLines, lines } = document;

  const h1s = headings.filter((heading) => heading.level === 1);
  if (h1s.length !== 1) {
    errors.push(`${display(file)}: expected exactly one H1; found ${h1s.length}`);
  }

  let previousLevel = 0;
  for (const heading of headings) {
    if (previousLevel > 0 && heading.level > previousLevel + 1) {
      errors.push(
        `${display(file)}: heading level jumps from H${previousLevel} to H${heading.level}`,
      );
    }
    previousLevel = heading.level;
  }

  if (h1s.length === 1 && !opensWithParagraph(rawLines, h1s[0].index)) {
    errors.push(`${display(file)}: H1 is not followed by an opening paragraph`);
  }

  for (const heading of headings) {
    if (/^(table of contents|contents)$/iu.test(heading.text.trim())) {
      errors.push(`${display(file)}: manual table-of-contents heading "${heading.text.trim()}"`);
    }
  }

  for (const line of lines) {
    if (/^\s*(?:[*_>-]\s*)*(?:\*\*|__|\*|_)?last[ -]updated\b/iu.test(line)) {
      errors.push(`${display(file)}: forbidden "last updated" metadata line`);
      break;
    }
  }
}

for (const file of [...parsed.keys()]) {
  const document = parsed.get(file);
  for (const rawDestination of document.links) {
    if (isExternal(rawDestination)) continue;

    const [rawTarget, rawFragment] = rawDestination.split("#", 2);
    const decodedTarget = decodeURIComponent(rawTarget.split("?", 1)[0]);
    let target = decodedTarget ? path.resolve(path.dirname(file), decodedTarget) : file;

    try {
      if ((await stat(target)).isDirectory()) target = path.join(target, "README.md");
    } catch {
      errors.push(`${display(file)}: missing local link target ${rawDestination}`);
      continue;
    }

    target = path.resolve(target);
    if (!(await exists(target))) {
      // The link resolved to a directory without a README.md index.
      errors.push(`${display(file)}: missing local link target ${rawDestination}`);
      continue;
    }

    document.targets.add(target);

    if (rawFragment && target.endsWith(".md")) {
      // Parse link targets that were not scanned, so fragments into pages outside the
      // scan roots are validated too. Stay inside the repository.
      const targetDocument = isWithinRepository(target)
        ? await parseIfNeeded(target)
        : parsed.get(target);
      const fragment = decodeURIComponent(rawFragment).toLowerCase();
      if (targetDocument && !targetDocument.anchors.has(fragment)) {
        errors.push(`${display(file)}: missing heading ${rawDestination}`);
      }
    }
  }
}

// Reachability: every documentation page must be reachable by following links from its
// documentation root index, traversing documentation pages only.
const documentationPages = new Set([...parsed.keys()].filter(isDocumentationPage));
const reached = new Set();
const queue = [];

for (const docsRoot of documentationRoots) {
  const index = path.join(docsRoot, "README.md");
  if (!documentationPages.has(index)) {
    errors.push(`${display(index)}: documentation root index is missing`);
    continue;
  }
  reached.add(index);
  queue.push(index);
}

while (queue.length > 0) {
  const file = queue.shift();
  for (const target of parsed.get(file)?.targets ?? []) {
    if (!documentationPages.has(target) || reached.has(target)) continue;
    reached.add(target);
    queue.push(target);
  }
}

for (const file of [...documentationPages].sort()) {
  if (!reached.has(file)) {
    errors.push(`${display(file)}: page is not reachable from its documentation index`);
  }
}

if (errors.length > 0) {
  console.error(`Documentation check failed with ${errors.length} error(s):`);
  for (const error of errors.sort()) console.error(`- ${error}`);
  process.exit(1);
}

console.log(
  `Documentation check passed for ${files.length} Markdown files ` +
    `(${documentationPages.size} documentation pages, all reachable from their index).`,
);
