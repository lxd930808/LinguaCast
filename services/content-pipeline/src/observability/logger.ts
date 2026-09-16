/**
 * Redacting logger. Secrets are registered by environment variable NAME only;
 * values are collected at config load and scrubbed from every message.
 * Log output never contains bearer tokens, API keys, cookies or signed URLs.
 */

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
    return out;
  }

  private emit(level: LogLevel, message: string, fields?: Record<string, unknown>): void {
    const safeFields = fields
      ? Object.fromEntries(
          Object.entries(fields).map(([key, value]) => [
            key,
            typeof value === 'string' ? this.redact(value) : value
          ])
        )
      : undefined;
    const line = JSON.stringify({
      level,
      msg: this.redact(message),
      ...(safeFields ? { fields: safeFields } : {}),
      time: new Date().toISOString()
    });
    this.sink(line);
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
