# Publish procedure — for the lead, after review

## Status (updated 2026-09-10)

- **Steps 1–2** (publish `battle-royale-s2` and `build-and-submit`, verify
  no red links) — run and verified. Both pages return HTTP 200 live; see
  `AUDIT.md`'s 2026-09-09 changelog entry.
- **Step 3** (repoint the seven `[[battle-royale]]` red links) — run and
  verified. See `AUDIT.md`'s 2026-09-09 changelog entry: all seven pages
  (`modes`, `glory`, `glory-season-2`, `deeds`, `achievements`,
  `patch-notes`, `main`) were repointed to `[[battle-royale-s2]]`, and zero
  bare `[[battle-royale]]` occurrences remain (checked via the wiki API,
  post-publish).
- **Step 4** — both hand-edits are done. `modes`'s two stale sections
  (`### battle-royale-s2 duo pairing`, `### Ground items on
  battle-royale-s2`) were already absent by the start of this task.
  `submitting-a-policy`'s `### Platform-side push (not exercised or
  verified)` section was removed 2026-09-10 (task `wiki-step4`), verified
  by fetching the live body before the edit, PUTting the edited body with
  that revision as `base_revision_id`, then fetching again and diffing
  before vs. after: the only change was that one section's removal (89 →
  79 lines).

Mechanism per memory `paintbot-wiki-lane`: plain PUT to the wiki API, token
from `~/.softmax/credentials.yaml`, **curl only** (Python `urllib` gets a
Cloudflare 403), rate limit 30 revisions/60s. The procedure below remains
the runbook for the next publish.

## 1. Publish the two new pages

```bash
TOKEN=$(python3 -c "
import yaml
d = yaml.safe_load(open('$HOME/.softmax/credentials.yaml'))
print(d['tokens']['https://softmax.com/api'])
")

publish_new() {
  local slug="$1" title="$2" file="$3"
  python3 -c "
import json
print(json.dumps({
  'title': '$title',
  'body': open('$file').read(),
  'base_revision_id': None,
  'idempotency_key': '$slug-p2wiki-$(date +%s)'
}))
" > /tmp/publish-$slug.json
  curl -s -X PUT \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    --data @/tmp/publish-$slug.json \
    "https://softmax.com/api/observatory/v2/wikis/paintbot/pages/$slug"
  echo
  sleep 2.2
}

publish_new battle-royale-s2 "Battle royale (Season 2)" \
  docs/wiki/battle-royale-s2.md
publish_new build-and-submit "Build and submit" \
  docs/wiki/build-and-submit.md
```

(Adjust the two `title` strings if the lead prefers different sidebar text
— they're free text, the slug in the URL is what `[[wikilinks]]` resolve
against.)

## 2. Verify the publish

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "https://softmax.com/api/observatory/v2/wikis/paintbot/pages/battle-royale-s2" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['current_revision']['body'][:200])"
```

Then in a browser: `https://softmax.com/paintbot/wiki/battle-royale-s2` and
`https://softmax.com/paintbot/wiki/build-and-submit` should both render
(not 404, not the create-new-page prompt), and every `[[wikilink]]` on them
that points at an existing page (e.g. `[[modes]]`, `[[damage-and-health]]`,
`[[ranks]]`, `[[glory-season-2]]`, `[[submitting-a-policy]]`,
`[[baseline-policy]]`, `[[policies]]`, `[[action-mask]]`) should render
**blue**, not red. `[[glory-season-2]]` etc. already exist, so no red links
are expected from either new page.

## 3. Repoint the seven `[[battle-royale]]` red links (optional, do after step 2)

This needs each page's *current* `current_revision_id` fetched fresh at
publish time (an edit conflict trap otherwise — see `conventions.md`'s
"merge, don't clobber" rule), so it's a fetch-edit-put loop, not a canned
diff:

```bash
for slug in modes glory glory-season-2 deeds achievements patch-notes main; do
  curl -s -H "Authorization: Bearer $TOKEN" \
    "https://softmax.com/api/observatory/v2/wikis/paintbot/pages/$slug" \
    > /tmp/wiki-$slug.json
  python3 -c "
import json
d = json.load(open('/tmp/wiki-$slug.json'))
body = d['current_revision']['body']
new_body = body.replace('[[battle-royale|battle royale]]', '[[battle-royale-s2|battle royale]]').replace('[[battle-royale]]', '[[battle-royale-s2]]')
if new_body == body:
    print('$slug: no occurrence found, skipping')
else:
    payload = {
        'title': d['title'],
        'body': new_body,
        'base_revision_id': d['current_revision_id'],
        'idempotency_key': '$slug-repoint-br-$(date +%s)'
    }
    open('/tmp/publish-$slug.json', 'w').write(json.dumps(payload))
    print('$slug: prepared')
"
  if [ -f /tmp/publish-$slug.json ]; then
    curl -s -X PUT -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      --data @/tmp/publish-$slug.json \
      "https://softmax.com/api/observatory/v2/wikis/paintbot/pages/$slug"
    echo
    rm /tmp/publish-$slug.json
    sleep 2.2
  fi
done
```

**Read each diff before trusting it** — a couple of these pages (`deeds`,
`achievements`) use the aliased form in prose and the bare form in a table
cell; the two `.replace()` calls above cover both, but confirm nothing else
on the page said `battle-royale` in a way this blind replace shouldn't have
touched (e.g. the literal engine ruleset name in a "not the classic ladder"
sentence that should stay as prose, not become a link). This step is lower
priority than steps 1–2 and safe to defer.

## 4. `modes` and `submitting-a-policy` cleanup (optional, do last)

Delete `modes`'s `### battle-royale-s2 duo pairing` and `### Ground items on
battle-royale-s2` sections, and `submitting-a-policy`'s `### Platform-side
push (not exercised or verified)` section plus its two Gaps bullets — per
RESTRUCTURE-PLAN.md. These are hand-edits (not a mechanical find-replace);
fetch each page the same way as step 3, edit the body, PUT with the fetched
`current_revision_id`.

## What "done" looks like

- `https://softmax.com/paintbot/wiki/battle-royale-s2` renders the new page.
- `https://softmax.com/paintbot/wiki/build-and-submit` renders the new page.
- The wiki's own page-list endpoint
  (`GET /api/observatory/v2/wikis/paintbot/pages`) shows 42 entries, not 40.
- At least one previously-red `[[battle-royale]]` link (e.g. on the live
  `modes` page) now renders blue.
