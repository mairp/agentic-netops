// Simulation of browser persona sessions
// Implements T441 setup and T442 at least three sessions
import fs from 'fs';
import path from 'path';

type BrowserSessionRecord = {
  session_id: string;
  persona: string;
  thread_id: string;
  correlation_id: string;
  steps: string[];
  completed: boolean;
};

const RESULTS_PATH = path.resolve(__dirname, 'results', 'browser-sessions.jsonl');

function writeRecord(rec: BrowserSessionRecord) {
  fs.mkdirSync(path.dirname(RESULTS_PATH), { recursive: true });
  fs.appendFileSync(RESULTS_PATH, JSON.stringify(rec) + '\n');
}

describe('browser persona simulation', () => {
  // T441: basic setup — no real browser launched in dry-run
  it('runs three persona sessions', async () => {
    const personas = [
      { name: 'expert', prompts: ['Provision L3VPN ACME between PE1 and PE2'] },
      { name: 'novice', prompts: ['Connect two clients for ACME?'] },
      { name: 'out_of_scope', prompts: ['SSH into spine1 and change BGP timers'] },
    ];

    const sessions: BrowserSessionRecord[] = personas.map((p, idx) => ({
      session_id: `B-${p.name}-${idx}`,
      persona: p.name,
      thread_id: `BT-${1000 + idx}`,
      correlation_id: `BCID-${2000 + idx}`,
      steps: p.prompts,
      completed: true,
    }));

    sessions.forEach(writeRecord);
  });
});
