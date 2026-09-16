import { sanitizePublicText } from '../domain/types.js';

export type LogLevel = 'debug' | 'info' | 'warn' | 'error';

export interface Logger {
  debug(message: string, fields?: Record<string, unknown>): void;
  info(message: string, fields?: Record<string, unknown>): void;
  warn(message: string, fields?: Record<string, unknown>): void;
  error(message: string, fields?: Record<string, unknown>): void;
}

const SIGNED_URL_QUERY = /([?&])(X-Amz-[^=&\s]+|Signature|Expires|Policy|Key-Pair-Id)=[^&\s]*/g;

export class RedactingLogger implements Logger {
  private secrets: string[] = [];

  constructor(private readonly sink: (line: string) => void = (line) => process.stdout.write(line + '\n')) {}

  registerSecret(value: string | undefined): void {
    if (value && value.length >= 8 && !this.secrets.includes(value)) {
      this.secrets.push(value);
    }
  }

  redact(text: string): string {
    let out = text;
    for (const secret of this.secrets) {
      out = out.split(secret).join('[REDACTED]');
    }
    out = out.replace(SIGNED_URL_QUERY, '$1$2=[REDACTED]');
    out = out.replace(/Bearer\s+\S+/gi, 'Bearer [REDACTED]');
    out = out.replace(/X-Auth-Key:\s*\S+/gi, 'X-Auth-Key: [REDACTED]');
    out = out.replace(/X-Auth-Date:\s*\S+/gi, 'X-Auth-Date: [REDACTED]');
    out = out.replace(/Authorization:\s*[A-Fa-f0-9]{16,}/gi, 'Authorization: [REDACTED]');
    out = out.replace(/("(?:text|markdown|prompt|query)"\s*:\s*")[^"]{40,}/gi, '$1[REDACTED_TEXT]');
    return sanitizePublicText(out);
  }

  private emit(level: LogLevel, message: string, fields?: Record<string, unknown>): void {
    const safeFields = fields
      ? Object.fromEntries(
          Object.entries(fields).map(([key, value]) => {
            if (typeof value !== 'string') return [key, value];
            if (['text', 'markdown', 'prompt', 'query', 'userText'].includes(key) && value.length > 24) {
              return [key, `[REDACTED_TEXT len=${value.length}]`];
            }
            return [key, this.redact(value)];
          })
        )
      : undefined;
    this.sink(
      JSON.stringify({
        level,
        msg: this.redact(message),
        ...(safeFields ? { fields: safeFields } : {}),
        time: new Date().toISOString()
      })
    );
  }

  debug(message: string, fields?: Record<string, unknown>): void {
    this.emit('debug', message, fields);
  }
  info(message: string, fields?: Record<string, unknown>): void {
    this.emit('info', message, fields);
  }
  warn(message: string, fields?: Record<string, unknown>): void {
    this.emit('warn', message, fields);
  }
  error(message: string, fields?: Record<string, unknown>): void {
    this.emit('error', message, fields);
  }
}
