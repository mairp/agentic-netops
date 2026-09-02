const fs = require('fs/promises');
const path = require('path');

const ROOT = '/root/ai-champion';
const EXERCISE_ROOT = path.join(ROOT, 'exercises');
const COURSE_FILES = path.join(ROOT, 'course-files');
const FILE_EXTRACTS = path.join(ROOT, 'course-file-extracts');
const USE_CASES = path.join(ROOT, 'use-cases');

const extraAssociations = new Map([
  [16, ['Core42_CRM-Extract_v1.xlsx']],
  [17, ['Core42_CRM-Extract_v1.xlsx']],
  [18, ['Core42_CRM-Extract_v1.xlsx']],
  [19, ['Core42_CRM-Extract_v1.xlsx']],
  [20, ['Core42_CRM-Extract_v1.xlsx']],
  [21, ['Core42_CRM-Extract_v1.xlsx']],
  [27, ['storm-research.skill']],
  [28, ['storm-research.skill']],
  [29, ['storm-research.skill']],
  [30, ['Core42_CRM-Extract_v1.xlsx']],
  [
    35,
    [
      'Core42_Policy-Pack_SYNTHETIC.docx',
      'Core42_MSA_Core42-Standard_SYNTHETIC.docx',
      'Core42_MSA_Client-Markup_SYNTHETIC.docx',
    ],
  ],
]);

function slugify(value) {
  return String(value || '')
    .toLowerCase()
    .replace(/&/g, ' and ')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 80) || 'untitled';
}

function filenameFromUrl(url) {
  return path.basename(new URL(url).pathname);
}

async function exists(filePath) {
  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
}

async function listFiles(dir) {
  try {
    return await fs.readdir(dir);
  } catch {
    return [];
  }
}

async function copyIfExists(source, destination, copied) {
  if (!(await exists(source))) return false;
  await fs.mkdir(path.dirname(destination), { recursive: true });
  await fs.copyFile(source, destination);
  copied.push(destination);
  return true;
}

async function copyExtractedCompanions(sourceFilename, destinationDir, copied) {
  const stem = sourceFilename.replace(/\.[^.]+$/, '');
  const suffix = path.extname(sourceFilename).toLowerCase();
  const extractFiles = await listFiles(FILE_EXTRACTS);

  if (suffix === '.xlsx') {
    for (const file of extractFiles.filter((item) => item.startsWith(`${stem}-`) && item.endsWith('.csv'))) {
      await copyIfExists(path.join(FILE_EXTRACTS, file), path.join(destinationDir, file), copied);
    }
    return;
  }

  const directByType = suffix === '.pdf'
    ? `${stem}.txt`
    : suffix === '.docx'
      ? `${stem}.md`
      : sourceFilename;
  await copyIfExists(path.join(FILE_EXTRACTS, directByType), path.join(destinationDir, directByType), copied);
}

async function copyUseCasePortfolio(destinationDir, copied) {
  const target = path.join(destinationDir, 'use-case-portfolio');
  await fs.mkdir(target, { recursive: true });
  const files = await listFiles(USE_CASES);
  for (const file of files.filter((item) => item.endsWith('.md') || item.endsWith('.json'))) {
    await copyIfExists(path.join(USE_CASES, file), path.join(target, file), copied);
  }
}

async function main() {
  const manifest = JSON.parse(await fs.readFile(path.join(ROOT, 'exercise-manifest.json'), 'utf8'));
  const rootFiles = await listFiles(ROOT);
  await fs.mkdir(EXERCISE_ROOT, { recursive: true });

  const folders = [];
  for (const exercise of manifest.exercises) {
    const number = String(exercise.num).padStart(2, '0');
    const folderName = `exercise-${number}-${slugify(exercise.title)}`;
    const folder = path.join(EXERCISE_ROOT, folderName);
    const docsOriginal = path.join(folder, 'documents', 'original');
    const docsExtracted = path.join(folder, 'documents', 'extracted');
    await fs.mkdir(folder, { recursive: true });

    const sourceExerciseFile = rootFiles.find((file) => file.startsWith(`exercise-${number}-`) && file.endsWith('.md'));
    if (!sourceExerciseFile) throw new Error(`Could not find markdown file for exercise ${number}`);

    const copied = [];
    await copyIfExists(path.join(ROOT, sourceExerciseFile), path.join(folder, 'exercise.md'), copied);

    const associated = new Set((exercise.files || []).map(filenameFromUrl));
    for (const file of extraAssociations.get(exercise.num) || []) associated.add(file);

    const documentSummary = [];
    for (const file of [...associated].sort()) {
      const originalCopied = await copyIfExists(path.join(COURSE_FILES, file), path.join(docsOriginal, file), copied);
      if (originalCopied) documentSummary.push(`documents/original/${file}`);
      const before = copied.length;
      await copyExtractedCompanions(file, docsExtracted, copied);
      for (const item of copied.slice(before)) {
        documentSummary.push(path.relative(folder, item));
      }
    }

    if ([33, 34].includes(exercise.num)) {
      const before = copied.length;
      await copyUseCasePortfolio(path.join(folder, 'documents'), copied);
      for (const item of copied.slice(before)) {
        documentSummary.push(path.relative(folder, item));
      }
    }

    const readme = `# Exercise ${number}: ${exercise.title}

Chapter: ${exercise.chapter}

Primary file:

- [exercise.md](./exercise.md)

Associated documents:

${documentSummary.length ? documentSummary.map((item) => `- [${item}](./${item})`).join('\n') : '- None'}
`;
    await fs.writeFile(path.join(folder, 'README.md'), readme, 'utf8');
    folders.push({ number: exercise.num, title: exercise.title, folderName, documents: documentSummary.length });
  }

  const index = `# Organized Exercise Folders

Source: \`/root/ai-champion/exercise-manifest.json\`

Each folder contains \`exercise.md\` and any associated original/downloaded documents plus extracted text, markdown, or CSV companions where available.

${folders.map((item) => `- [Exercise ${String(item.number).padStart(2, '0')}: ${item.title}](./${item.folderName}/) — ${item.documents} associated document file${item.documents === 1 ? '' : 's'}`).join('\n')}
`;
  await fs.writeFile(path.join(EXERCISE_ROOT, 'README.md'), index, 'utf8');

  await fs.writeFile(path.join(EXERCISE_ROOT, 'exercise-folder-manifest.json'), JSON.stringify({
    generatedAt: '2026-09-01',
    source: path.join(ROOT, 'exercise-manifest.json'),
    folders,
  }, null, 2) + '\n', 'utf8');

  console.log(JSON.stringify({
    exerciseFolders: folders.length,
    foldersWithDocuments: folders.filter((item) => item.documents > 0).length,
    totalAssociatedDocumentFiles: folders.reduce((sum, item) => sum + item.documents, 0),
    output: EXERCISE_ROOT,
  }, null, 2));
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
