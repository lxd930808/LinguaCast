/**
 * Thin facade around SABR fetch for job orchestration.
 * Keeps YouTube.js/googlevideo details out of the HTTP layer.
 */
export { fetchSabrTracks, type SabrFetchResult } from '../sabr/sabr-client.js';
