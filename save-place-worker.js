/**
 * Cloudflare Worker — Geo Memory Proxy
 *
 * POST /save      → create a new Place in Notion (Discover flow)
 * POST /check-in  → create a Visit record linked to an existing Place
 *
 * Both endpoints trigger a GitHub Actions workflow_dispatch to refresh
 * places.json immediately after the Notion write.
 *
 * Secrets required (Cloudflare dashboard → Worker → Settings → Variables):
 *   NOTION_TOKEN        — Notion integration token
 *   VISITS_DATABASE_ID  — Notion Visits database ID (set after running create_visits_db.py)
 *   GITHUB_PAT          — GitHub personal access token with repo + workflow scope
 */

const ALLOWED_ORIGIN     = 'https://cauldronpass.github.io';
const PLACES_DATABASE_ID = '3edc903daeaa41eaa82f93fb0ec55e60';
const VISITS_DATABASE_ID = 'ecd8cdc617e74c78b090afc5092cbdee';
const NOTION_VERSION     = '2022-06-28';
const GITHUB_OWNER      = 'Cauldronpass';
const GITHUB_REPO       = 'geo-memory';
const GITHUB_WORKFLOW   = 'update_places.yml';
const GITHUB_BRANCH     = 'main';

// ── CORS ──────────────────────────────────────────────────────────────────────

function corsHeaders() {
  return {
    'Access-Control-Allow-Origin':  ALLOWED_ORIGIN,
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
  };
}

function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: {
      'Content-Type':                'application/json',
      'Access-Control-Allow-Origin': ALLOWED_ORIGIN,
    },
  });
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function rt(text) {
  return { rich_text: [{ text: { content: String(text) } }] };
}

function todayISO() {
  return new Date().toISOString().slice(0, 10);
}

// ── GitHub Actions trigger ────────────────────────────────────────────────────

async function triggerGitHubWorkflow(githubPat, workflow) {
  if (!githubPat) return;
  try {
    await fetch(
      `https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/actions/workflows/${workflow}/dispatches`,
      {
        method: 'POST',
        headers: {
          'Authorization': `Bearer ${githubPat}`,
          'Accept':        'application/vnd.github+json',
          'Content-Type':  'application/json',
          'User-Agent':    'geo-memory-worker',
        },
        body: JSON.stringify({ ref: GITHUB_BRANCH }),
      }
    );
  } catch (e) {
    console.error(`GitHub dispatch failed (${workflow}):`, e.message);
  }
}

function triggerGitHubRefresh(githubPat, ctx) {
  // update_places.yml now runs enrich first, then fetch — one trigger does everything
  ctx.waitUntil(triggerGitHubWorkflow(githubPat, 'update_places.yml'));
}

// ── /save handler (Discover → new Place) ─────────────────────────────────────

async function handleSave(data, env, ctx) {
  if (!data.name) {
    return json({ ok: false, error: 'name is required' }, 400);
  }

  const enrichmentStatus = data.enrichment_status || 'Enriched';

  const props = {
    'Name':              { title:  [{ text: { content: data.name } }] },
    'Status':            { select: { name: data.status || 'Want to Visit' } },
    'Enrichment Status': { select: { name: enrichmentStatus } },
    'Source':            { select: { name: data.source || 'Discover' } },
  };

  if (data.notes)                props['Notes Raw']       = rt(data.notes);
  if (data.tags?.length)         props['Tags Raw']         = { multi_select: data.tags.map(t => ({ name: t })) };
  if (data.google_place_id)      props['Google Place ID']  = rt(data.google_place_id);
  if (data.lat  != null)         props['Latitude']         = { number: data.lat };
  if (data.lng  != null)         props['Longitude']        = { number: data.lng };
  if (data.address)              props['Address']          = rt(data.address);
  if (data.city)                 props['City']             = rt(data.city);
  if (data.country)              props['Country']          = rt(data.country);
  if (data.neighborhood)         props['Neighborhood']     = rt(data.neighborhood);
  if (data.category)             props['Category']         = { select: { name: data.category } };
  if (data.google_maps_url)      props['Google Maps URL']  = { url: data.google_maps_url };
  if (data.rating_external != null) props['Rating External'] = { number: data.rating_external };
  if (data.phone)                props['Phone']             = { phone_number: data.phone };
  if (data.website)              props['Website']           = { url: data.website };
  if (data.price_level != null)  props['Price Level']       = { number: data.price_level };
  if (data.hours)                props['Hours']             = rt(data.hours);
  if (data.temporary)            props['Temporary']          = { checkbox: true };
  if (data.expires)              props['Expires']            = { date: { start: data.expires } };

  const notionResp = await fetch('https://api.notion.com/v1/pages', {
    method: 'POST',
    headers: {
      'Authorization':  `Bearer ${env.NOTION_TOKEN}`,
      'Content-Type':   'application/json',
      'Notion-Version': NOTION_VERSION,
    },
    body: JSON.stringify({
      parent:     { database_id: PLACES_DATABASE_ID },
      properties: props,
    }),
  });

  const result = await notionResp.json();

  if (!result.id) {
    console.error('Notion /save error:', JSON.stringify(result));
    return json({ ok: false, error: result.message || 'Notion error' }, 500);
  }

  // Fire-and-forget GitHub refresh
  triggerGitHubRefresh(env.GITHUB_PAT, ctx);

  return json({ ok: true, notion_id: result.id });
}

// ── /check-in handler (existing Place → new Visit record) ────────────────────

async function handleCheckIn(data, env, ctx) {
  if (!data.notion_id) {
    return json({ ok: false, error: 'notion_id of Place is required' }, 400);
  }

  const dateVisited = data.date || todayISO();
  const visitName   = `${data.place_name || 'Visit'} · ${dateVisited}`;

  // Match the existing Visits DB schema
  const props = {
    'Name':         { title: [{ text: { content: visitName } }] },
    'Place':        { relation: [{ id: data.notion_id }] },
    'Date Visited': { date: { start: dateVisited } },
    'Source':       { select: { name: 'App' } },
  };

  if (data.occasion)              props['Occasion']   = { select: { name: data.occasion } };
  if (data.notes)                 props['Notes']      = rt(data.notes);
  if (data.companions)            props['Companions'] = rt(data.companions);
  // Thumbs up/down → Rating select (change Rating property type to Select in Notion)
  if (data.sentiment === 'Good')  props['Rating'] = { select: { name: '👍' } };
  if (data.sentiment === 'Bad')   props['Rating'] = { select: { name: '👎' } };

  const notionResp = await fetch('https://api.notion.com/v1/pages', {
    method: 'POST',
    headers: {
      'Authorization':  `Bearer ${env.NOTION_TOKEN}`,
      'Content-Type':   'application/json',
      'Notion-Version': NOTION_VERSION,
    },
    body: JSON.stringify({
      parent:     { database_id: VISITS_DATABASE_ID },
      properties: props,
    }),
  });

  const result = await notionResp.json();

  if (!result.id) {
    console.error('Notion /check-in error:', JSON.stringify(result));
    return json({ ok: false, error: result.message || 'Notion error' }, 500);
  }

  // Fire-and-forget GitHub refresh
  triggerGitHubRefresh(env.GITHUB_PAT, ctx);

  return json({ ok: true, visit_id: result.id });
}

// ── Main fetch handler ────────────────────────────────────────────────────────

export default {
  async fetch(request, env, ctx) {
    const origin = request.headers.get('Origin') || '';

    if (request.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: corsHeaders() });
    }

    if (origin !== ALLOWED_ORIGIN) {
      return new Response('Forbidden', { status: 403 });
    }

    if (request.method !== 'POST') {
      return new Response('Method Not Allowed', { status: 405 });
    }

    let data;
    try {
      data = await request.json();
    } catch {
      return json({ ok: false, error: 'Invalid JSON' }, 400);
    }

    const url  = new URL(request.url);
    const path = url.pathname;

    if (path === '/save') {
      return handleSave(data, env, ctx);
    } else if (path === '/check-in') {
      return handleCheckIn(data, env, ctx);
    } else {
      return json({ ok: false, error: `Unknown endpoint: ${path}` }, 404);
    }
  }
};
