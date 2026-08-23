import { BG, type BgConfig } from 'bgutils-js';
import { JSDOM } from 'jsdom';

export interface WebPoTokenResult {
  binding: string;
  placeholderPoToken: string;
  poToken: string;
}

/**
 * Generate a Web PO token bound to visitor/content identifier.
 * Adapted from googlevideo examples/downloader/utils/webpo-helper.ts.
 */
export async function generateWebPoToken(
  contentBinding: string
): Promise<WebPoTokenResult> {
  const requestKey = 'O43z0dpjhgX20SCx4KAo';
  if (!contentBinding) {
    throw new Error('Could not get visitor data');
  }

  const dom = new JSDOM();
  Object.assign(globalThis, {
    window: dom.window,
    document: dom.window.document
  });

  const bgConfig: BgConfig = {
    fetch: (input: string | URL | globalThis.Request, init?: RequestInit) =>
      fetch(input, init),
    globalObj: globalThis,
    identifier: contentBinding,
    requestKey
  };

  const bgChallenge = await BG.Challenge.create(bgConfig);
  if (!bgChallenge) {
    throw new Error('Could not get BotGuard challenge');
  }

  const interpreterJavascript =
    bgChallenge.interpreterJavascript.privateDoNotAccessOrElseSafeScriptWrappedValue;
  if (!interpreterJavascript) {
    throw new Error('Could not load BotGuard VM');
  }
  new Function(interpreterJavascript)();

  const poTokenResult = await BG.PoToken.generate({
    program: bgChallenge.program,
    globalName: bgChallenge.globalName,
    bgConfig
  });

  // generatePlaceholder/cold-start has a hard ~118 byte binding limit and breaks
  // on modern long visitorData. Real PO tokens do not share that limit.
  let placeholderPoToken = '';
  try {
    placeholderPoToken = BG.PoToken.generatePlaceholder(contentBinding);
  } catch {
    placeholderPoToken = '';
  }

  return {
    binding: contentBinding,
    placeholderPoToken,
    poToken: poTokenResult.poToken
  };
}
