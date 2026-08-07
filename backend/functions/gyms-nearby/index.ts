// ============================================================================
// GymStreak — `gyms-nearby` Supabase Edge Function (Deno)
// ----------------------------------------------------------------------------
// Proxies gym/fitness searches to a places provider (Google Places today) so
// the API key NEVER ships in the client bundle. The browser only ever talks to
// this function; the key lives in the function's environment.
//
// Deploy:
//   supabase functions deploy gyms-nearby --no-verify-jwt
//   supabase secrets set GOOGLE_PLACES_API_KEY=xxxxxxxx
// (--no-verify-jwt because onboarding runs BEFORE the user signs in.)
//
// Two modes (JSON POST body):
//   { "mode": "nearby", "lat": 40.72, "lng": -73.99 }   → gyms within ~3 mi
//   { "mode": "search", "query": "equinox", "lat"?, "lng"? } → text search
// (mode is inferred when omitted: a `query` means search, else nearby.)
//
// Response (provider-agnostic — the screen never sees Google's field names):
//   { "gyms": [ { id, name, address, lat, lng, distance_mi } ], "source": "google" }
// Sorted nearest-first when coordinates are known, capped at MAX_RESULTS.
// ============================================================================

const GOOGLE_KEY = Deno.env.get("GOOGLE_PLACES_API_KEY") ?? "";
const RADIUS_METERS = 4828; // ~3 miles
const MAX_RESULTS = 20;

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type",
};

type Gym = {
  id: string;
  name: string;
  address: string;
  lat: number | null;
  lng: number | null;
  distance_mi: number | null;
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "content-type": "application/json" },
  });
}

// Great-circle distance in miles.
function haversineMi(aLat: number, aLng: number, bLat: number, bLng: number): number {
  const R = 3958.8; // earth radius, miles
  const dLat = ((bLat - aLat) * Math.PI) / 180;
  const dLng = ((bLng - aLng) * Math.PI) / 180;
  const s =
    Math.sin(dLat / 2) ** 2 +
    Math.cos((aLat * Math.PI) / 180) *
      Math.cos((bLat * Math.PI) / 180) *
      Math.sin(dLng / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(s), Math.sqrt(1 - s));
}

// ---- provider adapter: Google Places (legacy) -> normalized Gym[] -----------
// Swapping providers later means rewriting only this block.
function normalizeGoogle(results: any[], origin: { lat: number; lng: number } | null): Gym[] {
  return (results ?? []).map((r): Gym => {
    const lat = r?.geometry?.location?.lat ?? null;
    const lng = r?.geometry?.location?.lng ?? null;
    const distance_mi =
      origin && typeof lat === "number" && typeof lng === "number"
        ? Math.round(haversineMi(origin.lat, origin.lng, lat, lng) * 10) / 10
        : null;
    return {
      id: r?.place_id ?? crypto.randomUUID(),
      name: r?.name ?? "Unnamed gym",
      address: r?.formatted_address ?? r?.vicinity ?? "",
      lat,
      lng,
      distance_mi,
    };
  });
}

async function googleNearby(lat: number, lng: number): Promise<Gym[]> {
  const url =
    `https://maps.googleapis.com/maps/api/place/nearbysearch/json` +
    `?location=${lat},${lng}&radius=${RADIUS_METERS}&type=gym&key=${GOOGLE_KEY}`;
  const data = await callGoogle(url);
  return normalizeGoogle(data.results, { lat, lng });
}

async function googleTextSearch(
  query: string,
  origin: { lat: number; lng: number } | null,
): Promise<Gym[]> {
  const bias = origin ? `&location=${origin.lat},${origin.lng}&radius=${RADIUS_METERS}` : "";
  const url =
    `https://maps.googleapis.com/maps/api/place/textsearch/json` +
    `?query=${encodeURIComponent(query + " gym fitness")}${bias}&key=${GOOGLE_KEY}`;
  const data = await callGoogle(url);
  return normalizeGoogle(data.results, origin);
}

async function callGoogle(url: string): Promise<any> {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`provider http ${res.status}`);
  const data = await res.json();
  // Google reports logical errors in a `status` field with HTTP 200.
  if (data.status && data.status !== "OK" && data.status !== "ZERO_RESULTS") {
    throw new Error(`provider ${data.status}: ${data.error_message ?? ""}`.trim());
  }
  return data;
}

// ---- handler ----------------------------------------------------------------
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!GOOGLE_KEY) return json({ error: "server_misconfigured" }, 500);

  let body: any;
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad_json" }, 400);
  }

  const query = typeof body?.query === "string" ? body.query.trim() : "";
  const lat = Number(body?.lat);
  const lng = Number(body?.lng);
  const hasCoords = Number.isFinite(lat) && Number.isFinite(lng);
  const mode = body?.mode ?? (query ? "search" : "nearby");

  try {
    let gyms: Gym[];
    if (mode === "search") {
      if (!query) return json({ error: "missing_query" }, 400);
      gyms = await googleTextSearch(query, hasCoords ? { lat, lng } : null);
    } else {
      if (!hasCoords) return json({ error: "missing_coords" }, 400);
      gyms = await googleNearby(lat, lng);
    }

    // nearest-first when we can, then cap.
    gyms.sort((a, b) => {
      if (a.distance_mi == null) return b.distance_mi == null ? 0 : 1;
      if (b.distance_mi == null) return -1;
      return a.distance_mi - b.distance_mi;
    });

    return json({ gyms: gyms.slice(0, MAX_RESULTS), source: "google" });
  } catch (err) {
    console.error("gyms-nearby error:", err);
    return json({ error: "provider_failed", detail: String(err) }, 502);
  }
});
