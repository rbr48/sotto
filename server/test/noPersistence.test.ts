import { execFileSync, spawn, type ChildProcess } from 'node:child_process';
import { mkdtempSync, readdirSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { newIdentity, TestClient } from './helpers.js';

/**
 * Runs the real server process in empty working, temp and home directories,
 * pushes traffic through it (logins, delivered and queued messages), stops it
 * and checks that it wrote nothing. Production adds a read-only container
 * filesystem on top of this.
 */
describe('no persistence', () => {
  const root = mkdtempSync(join(tmpdir(), 'sotto-nopersist-'));
  const build = join(root, 'build');
  const watched = ['cwd', 'tmp', 'home'].map((name) => join(root, name));
  let child: ChildProcess;
  let port = 0;

  beforeAll(async () => {
    execFileSync('npx', ['tsc', '-p', 'tsconfig.build.json', '--outDir', join(build, 'dist')], {
      cwd: resolve(__dirname, '..'),
    });
    symlinkSync(resolve(__dirname, '../node_modules'), join(build, 'node_modules'));
    for (const dir of watched) execFileSync('mkdir', ['-p', dir]);
    child = spawn(process.execPath, [join(build, 'dist/index.js')], {
      cwd: watched[0],
      env: {
        PATH: process.env.PATH,
        PORT: '0',
        HOST: '127.0.0.1',
        TMPDIR: watched[1],
        HOME: watched[2],
      },
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    port = await new Promise<number>((resolvePort, reject) => {
      child.stdout!.on('data', (chunk: Buffer) => {
        const match = /listening on port (\d+)/.exec(chunk.toString());
        if (match) resolvePort(Number(match[1]));
      });
      child.once('exit', (code) => reject(new Error(`server exited with ${code}`)));
    });
  }, 60_000);

  afterAll(() => {
    child?.kill('SIGKILL');
    rmSync(root, { recursive: true, force: true });
  });

  it('writes nothing to disk while relaying', async () => {
    const url = `ws://127.0.0.1:${port}/relay`;
    const alice = newIdentity();
    const bob = newIdentity();
    const a = await TestClient.login(url, alice);
    expect((await a.next()).type).toBe('ready');
    a.send({ type: 'send', to: bob.id, body: 'held-while-offline', ref: '1' });
    expect((await a.next()).status).toBe('queued');
    const b = await TestClient.login(url, bob);
    expect((await b.next()).type).toBe('ready');
    expect((await b.next()).body).toBe('held-while-offline');
    b.send({ type: 'send', to: alice.id, body: 'reply' });
    expect((await a.next()).body).toBe('reply');
    await Promise.all([a.close(), b.close()]);

    await new Promise<void>((done) => {
      child.once('exit', () => done());
      child.kill('SIGTERM');
    });
    for (const dir of watched) expect(readdirSync(dir), dir).toEqual([]);
  });
});
