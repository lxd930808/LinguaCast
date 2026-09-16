export interface WebHit {
  title: string;
  url: string;
  snippet: string;
  publishedAt: string | null;
  site: string;
}

export interface WebSearchProvider {
  readonly name: string;
  search(query: string, options: { locale?: string; limit: number }): Promise<WebHit[]>;
}

export class StaticWebSearchProvider implements WebSearchProvider {
  readonly name: string;
  constructor(
    name: string,
    private readonly handler: (query: string, options: { locale?: string; limit: number }) => Promise<WebHit[]>
  ) {
    this.name = name;
  }

  search(query: string, options: { locale?: string; limit: number }): Promise<WebHit[]> {
    return this.handler(query, options);
  }
}
