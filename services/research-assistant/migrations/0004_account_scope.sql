-- V18 WP03: account-scoped global memory. Upgrade-only; earlier files are frozen.
-- Global preferences become "global within one account". Existing rows inherit
-- the owner of the research they came from; orphans stay with the pre-V18
-- selfhost owner and are never assigned to a signed-in account.

ALTER TABLE v2_memory_entries ADD COLUMN owner_scope TEXT;

UPDATE v2_memory_entries
   SET owner_scope = COALESCE(
     (SELECT r.owner_scope FROM v2_researches r WHERE r.research_id = v2_memory_entries.research_id),
     (SELECT r.owner_scope FROM v2_researches r WHERE r.research_id = v2_memory_entries.source_research_id),
     'selfhost'
   )
 WHERE owner_scope IS NULL;

CREATE INDEX v2_memory_entries_owner_scope ON v2_memory_entries(owner_scope, scope, status);
