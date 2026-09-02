const { chromium } = require('/root/agentflow/frontend/node_modules/playwright');
const fs = require('fs/promises');
const path = require('path');

const BASE = 'https://ai-campus-training.vercel.app';
const OUT = '/root/ai-champion';
const EMAIL = 'marlon.lopez@core42.ai';
const CODE = 'CORE42-SOV26';

const modules = [
  { id: 'welcome', label: 'Welcome' },
  { id: 'profile', label: 'You & your ARQ' },
  { id: 'guide', label: 'Hands-on AI practice' },
  { id: 'industry', label: 'AI in Tech' },
  { id: 'define', label: 'Use case definition' },
  { id: 'landscape', label: 'Use case portfolio' },
  { id: 'santander', label: 'Santander AI' },
  { id: 'vibe', label: 'Vibe Coding Lab' },
  { id: 'second-brain', label: 'Second brain' },
  { id: 'playground', label: 'AI Playground' },
];

const fallbackClusters = [
  {
    id: 'knowledge-memory',
    name: 'Institutional memory & knowledge',
    color: '#2E83C8',
    summary: 'The company brain five separate leaders asked for: product, decisions, meeting outputs and process documentation, retrievable rather than locked in individuals. The single most-requested capability in the discovery record.',
  },
  {
    id: 'commercial-engine',
    name: 'Commercial engine',
    color: '#1F8E4D',
    summary: 'RFP and proposal acceleration, CRM data quality and enrichment, and the executive reporting layer. Highest average impact of any cluster, and the one where data quality gates everything downstream.',
  },
  {
    id: 'contract-sovereignty',
    name: 'Contract, approval & sovereignty',
    color: '#C5A572',
    summary: 'Contract review and risk flagging, the approval-routing engine, and the jurisdiction-by-jurisdiction regulatory knowledge that lets commercial, legal and security give customers the same answer.',
  },
  {
    id: 'platform-operations',
    name: 'Infrastructure & platform operations',
    color: '#8E44AD',
    summary: 'The core business: turning sovereign compute into tokens at scale. Fleet utilisation, capacity planning, provisioning, incident response and the cost discipline that protects margin on the largest line.',
  },
  {
    id: 'security-assurance',
    name: 'Security operations & assurance',
    color: '#C8222F',
    summary: 'SOC triage and escalation, vulnerability handling, agent procurement and the evaluation work that makes an agent estate defensible with a very small security team.',
  },
];

function slugify(value) {
  return String(value || '')
    .toLowerCase()
    .replace(/&/g, ' and ')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 80) || 'untitled';
}

function clean(value) {
  return String(value || '').replace(/\r\n/g, '\n').trim();
}

function lines(value) {
  return clean(value).split('\n').map((line) => line.trim()).filter(Boolean);
}

function markdownList(items) {
  return items.length ? items.map((item) => `- ${item}`).join('\n') : '- None';
}

function parseSessionCookie(setCookie) {
  const [nameValue] = setCookie.split(';');
  const [name, ...rest] = nameValue.split('=');
  return {
    name,
    value: rest.join('='),
    domain: 'ai-campus-training.vercel.app',
    path: '/',
    httpOnly: true,
    secure: true,
    sameSite: 'Lax',
  };
}

function quadrant(usecase) {
  const impact = Number(usecase.impact_score || 0);
  const feasibility = Number(usecase.feasibility_score || 0);
  if (impact > 5 && feasibility > 5) return 'Strategic priority';
  if (impact > 5 && feasibility <= 5) return 'Big bet';
  if (impact <= 5 && feasibility > 5) return 'Quick win';
  return 'Defer / re-scope';
}

async function downloadFile(url, destination) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`Download failed ${response.status}: ${url}`);
  const buffer = Buffer.from(await response.arrayBuffer());
  await fs.writeFile(destination, buffer);
  return buffer.length;
}

async function main() {
  const dirs = {
    root: OUT,
    modules: path.join(OUT, 'module-docs'),
    usecases: path.join(OUT, 'use-cases'),
    downloads: path.join(OUT, 'course-files'),
    raw: path.join(OUT, 'raw-snapshots'),
  };
  await Promise.all(Object.values(dirs).map((dir) => fs.mkdir(dir, { recursive: true })));

  const login = await fetch(`${BASE}/api/core42/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ email: EMAIL, code: CODE }),
  });
  if (!login.ok) throw new Error(`Login failed: ${login.status} ${await login.text()}`);
  const sessionCookie = parseSessionCookie(login.headers.get('set-cookie'));

  const browser = await chromium.launch({ headless: true, args: ['--no-sandbox', '--disable-setuid-sandbox'] });
  const context = await browser.newContext({ viewport: { width: 1440, height: 1400 } });
  await context.addCookies([sessionCookie]);
  const page = await context.newPage();

  const allLinks = [];
  const promptBlocks = [];
  const moduleFiles = [];

  for (const mod of modules) {
    const url = `${BASE}/core42/${mod.id}`;
    await page.goto(url, { waitUntil: 'networkidle', timeout: 60000 });
    await page.waitForTimeout(700);

    const snapshot = await page.evaluate(({ id, label, url }) => {
      const norm = (value) => (value || '').replace(/\u00a0/g, ' ').replace(/[ \t]+\n/g, '\n').replace(/\n{3,}/g, '\n\n').trim();
      const main = document.querySelector('main') || document.body;
      const headings = [...main.querySelectorAll('h1,h2,h3,h4')]
        .map((el) => ({ level: Number(el.tagName.slice(1)), text: norm(el.innerText) }))
        .filter((item) => item.text);
      const links = [...main.querySelectorAll('a')]
        .map((a) => ({
          text: norm(a.innerText) || norm(a.getAttribute('aria-label')) || a.href,
          href: a.href,
          download: a.hasAttribute('download'),
        }))
        .filter((item) => item.href);
      const prompts = [...main.querySelectorAll('pre')].map((pre, index) => {
        const header = pre.previousElementSibling?.innerText || pre.parentElement?.innerText || '';
        const label = norm(header.split('\n').find((line) => /prompt|rulebook|copy|command/i.test(line)) || `Prompt block ${index + 1}`);
        return { label, text: pre.innerText };
      });
      return {
        id,
        label,
        url,
        title: document.title,
        headings,
        links,
        prompts,
        text: norm(main.innerText),
        html: document.documentElement.outerHTML,
      };
    }, { id: mod.id, label: mod.label, url });

    for (const link of snapshot.links) allLinks.push({ ...link, module: mod.id });
    for (const prompt of snapshot.prompts) promptBlocks.push({ ...prompt, module: mod.id, source: url });

    const filename = `module-${String(moduleFiles.length + 1).padStart(2, '0')}-${slugify(mod.id)}.md`;
    moduleFiles.push(filename);
    const md = `# ${mod.label}\n\nSource: ${url}\n\n## Headings\n\n${markdownList(snapshot.headings.map((h) => `${'#'.repeat(Math.min(h.level, 6))} ${h.text}`))}\n\n## Links\n\n${markdownList(snapshot.links.map((l) => `${l.text} - ${l.href}${l.download ? ' (download)' : ''}`))}\n\n## Copyable Blocks\n\n${snapshot.prompts.length ? snapshot.prompts.map((block, index) => `### ${block.label || `Block ${index + 1}`}\n\n\`\`\`text\n${clean(block.text)}\n\`\`\``).join('\n\n') : 'None'}\n\n## Visible Page Text\n\n${clean(snapshot.text)}\n`;
    await fs.writeFile(path.join(dirs.modules, filename), md, 'utf8');
    await fs.writeFile(path.join(dirs.raw, `${slugify(mod.id)}.html`), snapshot.html, 'utf8');
  }

  const [mapResponse, roomResponse] = await Promise.all([
    fetch(`${BASE}/api/map`, { headers: { cookie: `${sessionCookie.name}=${sessionCookie.value}` } }),
    fetch(`${BASE}/api/usecases`, { headers: { cookie: `${sessionCookie.name}=${sessionCookie.value}` } }),
  ]);
  if (!mapResponse.ok) throw new Error(`Map API failed: ${mapResponse.status}`);
  const mapData = await mapResponse.json();
  const roomData = roomResponse.ok ? await roomResponse.json() : { usecases: [] };
  const usecases = [...(mapData.cases || [])].sort((a, b) => {
    const aLabel = String(a.label || '');
    const bLabel = String(b.label || '');
    return aLabel.localeCompare(bLabel, undefined, { numeric: true }) || String(a.title).localeCompare(String(b.title));
  });

  const clusterList = (mapData.clusters || []).length ? mapData.clusters : fallbackClusters;
  const clusters = new Map(clusterList.map((cluster) => [cluster.id, cluster]));
  const usecaseFiles = [];
  for (const usecase of usecases) {
    const cluster = clusters.get(usecase.cluster_id);
    const label = usecase.label === '★'
      ? `room-${String(usecase.owner_name || usecase.participant_name || usecase.id).replace(/[^a-z0-9]+/gi, '-').toLowerCase()}`
      : String(usecase.label || usecase.id).toLowerCase();
    const filename = `use-case-${label}-${slugify(usecase.title)}.md`;
    usecaseFiles.push(filename);
    const kpis = Array.isArray(usecase.kpis) ? usecase.kpis.filter(Boolean) : [];
    const md = `# Use Case ${usecase.label || usecase.id}: ${usecase.title}\n\nSource: ${BASE}/core42/landscape\n\nType: ${usecase.source === 'participant' ? 'From this room' : usecase.is_super ? 'Work redesign' : 'Curated'}\n\n${usecase.owner_name || usecase.participant_name ? `Owner: ${usecase.owner_name || usecase.participant_name}\n\n` : ''}Cluster: ${cluster ? cluster.name : 'From this room'}\n\nQuadrant: ${quadrant(usecase)}\n\nImpact score: ${usecase.impact_score ?? 'n/a'}/10\n\nFeasibility score: ${usecase.feasibility_score ?? 'n/a'}/10\n\n## Description\n\n${clean(usecase.description)}\n\n## Impact\n\n${clean(usecase.impact) || 'Not specified'}\n\n## Feasibility\n\n${clean(usecase.feasibility) || 'Not specified'}\n\n${usecase.category ? `## Category\n\n${clean(usecase.category)}\n\n` : ''}${usecase.focus_area ? `## Focus Area\n\n${clean(usecase.focus_area)}\n\n` : ''}${usecase.targeted_entity ? `## Targeted Entity\n\n${clean(usecase.targeted_entity)}\n\n` : ''}${usecase.business_objective ? `## Business Objective\n\n${clean(usecase.business_objective)}\n\n` : ''}${usecase.future_state ? `## Future State\n\n${clean(usecase.future_state)}\n\n` : ''}${usecase.data_availability ? `## Data Needs\n\n${clean(usecase.data_availability)}\n\n` : ''}${usecase.risk ? `## Risks & Mitigation\n\n${clean(usecase.risk)}\n\n` : ''}${usecase.adoption_plan ? `## Adoption & Change Plan\n\n${clean(usecase.adoption_plan)}\n\n` : ''}## Success Metrics\n\n${markdownList(kpis)}\n`;
    await fs.writeFile(path.join(dirs.usecases, filename), md, 'utf8');
  }

  await fs.writeFile(path.join(dirs.usecases, 'use-cases.json'), JSON.stringify({
    extractedAt: '2026-09-01',
    source: `${BASE}/api/map`,
    total: usecases.length,
    clusters: clusterList,
    roomUsecases: roomData.usecases || [],
    usecases,
  }, null, 2) + '\n', 'utf8');

  const internalDownloadUrls = new Set();
  for (const link of allLinks) {
    if (link.href.startsWith(BASE) && (link.download || /\.(pdf|zip|csv|xlsx?|docx?|pptx?)($|\?)/i.test(link.href))) {
      internalDownloadUrls.add(link.href);
    }
  }

  try {
    const manifest = JSON.parse(await fs.readFile(path.join(OUT, 'exercise-manifest.json'), 'utf8'));
    for (const ex of manifest.exercises || []) {
      for (const file of ex.files || []) internalDownloadUrls.add(file);
    }
  } catch {
    // The broader extractor still works if the previous exercise-only manifest is absent.
  }

  const downloads = [];
  for (const url of [...internalDownloadUrls].sort()) {
    const pathname = new URL(url).pathname;
    const filename = path.basename(pathname);
    const destination = path.join(dirs.downloads, filename);
    const bytes = await downloadFile(url, destination);
    downloads.push({ filename, url, bytes });
  }

  const promptMd = `# Copyable Course Blocks\n\nExtracted: 2026-09-01\n\n${promptBlocks.map((block, index) => `## ${String(index + 1).padStart(2, '0')}. ${block.module}: ${block.label}\n\nSource: ${block.source}\n\n\`\`\`text\n${clean(block.text)}\n\`\`\``).join('\n\n')}\n`;
  await fs.writeFile(path.join(OUT, 'copyable-course-blocks.md'), promptMd, 'utf8');

  const indexMd = `# AI Campus Course Material Index\n\nExtracted: 2026-09-01\n\nAuthenticated source: ${BASE}/core42/welcome\n\n## Summary\n\n- Module documentation pages: ${moduleFiles.length}\n- Numbered hands-on exercises: 37\n- Use-case portfolio records: ${usecases.length}\n- Copyable non-exercise blocks: ${promptBlocks.length}\n- Downloaded course files: ${downloads.length}\n\n## Module Documentation\n\n${moduleFiles.map((file, index) => `- [${modules[index].label}](./module-docs/${file})`).join('\n')}\n\n## Exercises\n\n- [Exercise index](./exercise-index.md)\n\n## Use Cases\n\n- [Structured use-case JSON](./use-cases/use-cases.json)\n${usecaseFiles.map((file) => `- [${file.replace(/\\.md$/, '')}](./use-cases/${file})`).join('\n')}\n\n## Copyable Blocks\n\n- [Copyable course blocks](./copyable-course-blocks.md)\n- [Additional module prompts](./additional-module-prompts.md)\n\n## Downloaded Files\n\n${markdownList(downloads.map((file) => `[${file.filename}](./course-files/${file.filename}) - ${file.url} (${file.bytes} bytes)`))}\n\n## Raw Snapshots\n\nRaw authenticated HTML snapshots are in [raw-snapshots](./raw-snapshots).\n`;
  await fs.writeFile(path.join(OUT, 'course-material-index.md'), indexMd, 'utf8');
  await fs.writeFile(path.join(OUT, 'course-material-manifest.json'), JSON.stringify({
    extractedAt: '2026-09-01',
    modules: modules.map((mod, index) => ({ ...mod, file: moduleFiles[index] })),
    usecaseCount: usecases.length,
    usecaseFiles,
    copyableBlocks: promptBlocks.length,
    downloads,
  }, null, 2) + '\n', 'utf8');

  await browser.close();
  console.log(JSON.stringify({
    moduleDocs: moduleFiles.length,
    usecases: usecases.length,
    prompts: promptBlocks.length,
    downloads: downloads.length,
    out: OUT,
  }, null, 2));
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
