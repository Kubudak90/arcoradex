// Builds the self-contained HTML rendering of the ArcoraDEX litepaper.
// Usage: npm install && node build.mjs
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { marked } from 'marked';

const here = dirname(fileURLToPath(import.meta.url));
const mdPath = join(here, 'arcoradex-litepaper.md');
const htmlPath = join(here, 'arcoradex-litepaper.html');

const md = readFileSync(mdPath, 'utf8');
const body = marked.parse(md);

const css = `
  :root { color-scheme: light; }
  body {
    font-family: Georgia, "Times New Roman", serif;
    line-height: 1.6; color: #1a1a1a; background: #ffffff;
    max-width: 820px; margin: 0 auto; padding: 56px 32px;
  }
  h1, h2, h3 { font-family: -apple-system, Segoe UI, Roboto, sans-serif; line-height: 1.25; }
  h1 { font-size: 2rem; border-bottom: 2px solid #1a1a1a; padding-bottom: .3em; }
  h2 { font-size: 1.4rem; margin-top: 2.4em; border-bottom: 1px solid #ccc; padding-bottom: .2em; }
  h3 { font-size: 1.12rem; margin-top: 1.6em; }
  code { font-family: "SF Mono", Menlo, Consolas, monospace; font-size: .88em;
    background: #f3f3f3; padding: .1em .35em; border-radius: 3px; }
  pre { background: #f6f8fa; padding: 14px 16px; border-radius: 6px; overflow-x: auto; }
  pre code { background: none; padding: 0; }
  table { border-collapse: collapse; width: 100%; margin: 1.2em 0; font-size: .92rem;
    font-family: -apple-system, Segoe UI, Roboto, sans-serif; }
  th, td { border: 1px solid #d0d0d0; padding: 7px 10px; text-align: left; }
  th { background: #f3f3f3; }
  blockquote { border-left: 3px solid #bbb; margin: 1em 0; padding: .2em 1em; color: #444; }
  a { color: #0b5fa5; }
  hr { border: none; border-top: 1px solid #ddd; margin: 2em 0; }
  @media print {
    body { max-width: none; padding: 0; font-size: 11pt; }
    h1, h2 { page-break-after: avoid; }
    h3 { page-break-after: avoid; }
    pre, table, blockquote { page-break-inside: avoid; }
    a { color: #1a1a1a; text-decoration: none; }
  }
`;

const html = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>ArcoraDEX — Technical Litepaper</title>
<style>${css}</style>
</head>
<body>
${body}
</body>
</html>
`;

writeFileSync(htmlPath, html);
console.log('wrote', htmlPath, `(${html.length} bytes)`);
