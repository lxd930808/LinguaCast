/**
 * Redacting logger. Secret values are registered at config load and scrubbed
 * from every message. Output never contains bearer tokens, App credentials
 * (lca_/lcr_), JWTs or signed URL query parameters.
 */

export type LogLevel = 'debug' | 'info' | 'warn' | 'error';

export interface Logger {
  debug(message: string, fields?: Record<string, unknown>): void;
  info(message: string, fields?: Record<string, unknown>): void;
  warn(message: string, fields?: Record<string, unknown>): void;
  error(message: string, fields?: Record<string, unknown>): void;
}

const SIGNED_URL_QUERY = /([?&])(X-Amz-[^=&\s]+|Signature|Expires|Policy|Key-Pair-Id)=[^&\s]*/g;
const APP_CREDENTIAL = /\blc[ar]_[A-Za-z0-9_-]{16,}/g;
const JWT_LIKE = /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*/g;

export class RedactingLogger implements Logger {
  private secrets: string[] = [];

  constructor(private readonly sink: (line: string) => void = (line) => process.stdout.write(line + '\n')) {}

  registerSecret(value: string | undefined | null): void {
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
    out = out.replace(APP_CREDENTIAL, '[REDACTED]');
    out = out.replace(JWT_LIKE, '[REDACTED]');
    return out;
  }

  private emit(level: LogLevel, message: string, fields?: Record<string, unknown>): void {
    const safeFields = fields
      ? Object.fromEntries(
          Object.entries(fields).map(([key, value]) => [key, typeof value === 'string' ? this.redact(value) : value])
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
