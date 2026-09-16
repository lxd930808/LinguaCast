import { listAuthProviders } from '../agent/pi-credentials.js';
import type { ServiceConfig } from '../config/index.js';
import { KimiCodingWebSearchProvider, KIMI_CODING_PROVIDER_ID } from './kimi-search.js';
import type { WebSearchProvider } from './search-client.js';

export function normalizeWebProviderId(value: string): string {
  return value.trim().toLowerCase();
}

export function isKimiWebProvider(value: string): boolean {
  const id = normalizeWebProviderId(value);
  return id === 'kimi' || id === 'kimi-coding';
}

export function isWebSearchConfigured(config: ServiceConfig): boolean {
  if (isKimiWebProvider(config.webProvider)) {
    return listAuthProviders(config.piAuthPath).includes(KIMI_CODING_PROVIDER_ID);
  }
  return Boolean(config.webProvider && config.webApiKey);
}

export function createWebSearchProvider(config: ServiceConfig): WebSearchProvider | null {
  if (isKimiWebProvider(config.webProvider)) {
    return new KimiCodingWebSearchProvider({ authPath: config.piAuthPath });
  }
  return null;
}
