import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

import type { Credential, CredentialInfo, CredentialStore } from '@earendil-works/pi-ai';

export function defaultPiAuthPath(): string {
  return join(homedir(), '.pi', 'agent', 'auth.json');
}

export function defaultPiSettingsPath(): string {
  return join(homedir(), '.pi', 'agent', 'settings.json');
}

/** Persistent Pi credential file used by the coding-agent CLI (`~/.pi/agent/auth.json`). */
export class JsonFileCredentialStore implements CredentialStore {
  private chain: Promise<unknown> = Promise.resolve();

  constructor(private readonly filePath: string) {}

  private enqueue<T>(task: () => T | Promise<T>): Promise<T> {
    const run = this.chain.then(task, task);
    this.chain = run.then(
      () => undefined,
      () => undefined
    );
    return run;
  }

  private load(): Record<string, Credential> {
    if (!existsSync(this.filePath)) return {};
    const parsed = JSON.parse(readFileSync(this.filePath, 'utf8')) as Record<string, Credential>;
    return parsed && typeof parsed === 'object' ? parsed : {};
  }

  private save(all: Record<string, Credential>): void {
    writeFileSync(this.filePath, `${JSON.stringify(all, null, 2)}\n`, { mode: 0o600 });
  }

  read(providerId: string): Promise<Credential | undefined> {
    return this.enqueue(() => this.load()[providerId]);
  }

  list(): Promise<readonly CredentialInfo[]> {
    return this.enqueue(() =>
      Object.entries(this.load()).map(([providerId, credential]) => ({
        providerId,
        type: credential.type
      }))
    );
  }

  modify(
    providerId: string,
    fn: (current: Credential | undefined) => Promise<Credential | undefined>
  ): Promise<Credential | undefined> {
    return this.enqueue(async () => {
      const all = this.load();
      const next = await fn(all[providerId]);
      if (next !== undefined) {
        all[providerId] = next;
        this.save(all);
      }
      return next ?? all[providerId];
    });
  }

  delete(providerId: string): Promise<void> {
    return this.enqueue(() => {
      const all = this.load();
      delete all[providerId];
      this.save(all);
    });
  }
}

export function listAuthProviders(filePath: string): string[] {
  if (!existsSync(filePath)) return [];
  try {
    const parsed = JSON.parse(readFileSync(filePath, 'utf8')) as Record<string, unknown>;
    return Object.keys(parsed);
  } catch {
    return [];
  }
}
