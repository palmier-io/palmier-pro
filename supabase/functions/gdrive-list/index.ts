import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

interface FileEntry {
  id: string;
  name: string;
  mimeType: string;
  size: number;
}

serve(async (req) => {
  try {
    const authError = await requireUser(req);
    if (authError) return authError;

    const { folderUrl } = await req.json();
    if (!folderUrl) {
      return new Response(JSON.stringify({ error: "folderUrl required" }), { status: 400 });
    }

    const folderId = extractFolderId(folderUrl);
    if (!folderId) {
      return new Response(JSON.stringify({ error: "Could not extract folder ID from URL" }), { status: 400 });
    }

    const saJson = JSON.parse(Deno.env.get("GOOGLE_SERVICE_ACCOUNT_JSON")!);
    const token = await getAccessToken(saJson);

    // List files, paginating if needed
    const allFiles: FileEntry[] = [];
    let pageToken: string | undefined;

    do {
      const listUrl = new URL("https://www.googleapis.com/drive/v3/files");
      listUrl.searchParams.set("q", `'${folderId}' in parents and trashed=false`);
      listUrl.searchParams.set("fields", "files(id,name,mimeType,size),nextPageToken");
      listUrl.searchParams.set("orderBy", "name");
      listUrl.searchParams.set("pageSize", "1000");
      if (pageToken) listUrl.searchParams.set("pageToken", pageToken);

      const res = await fetch(listUrl.toString(), {
        headers: { Authorization: `Bearer ${token}` },
      });
      if (!res.ok) {
        const err = await res.text();
        return new Response(JSON.stringify({ error: `Google API error: ${err}` }), { status: 502 });
      }

      const data = await res.json();
      for (const f of (data.files || [])) {
        allFiles.push({ id: f.id, name: f.name, mimeType: f.mimeType, size: parseInt(f.size || "0") });
      }
      pageToken = data.nextPageToken;
    } while (pageToken);

    // Filter to supported media types
    const supported = allFiles.filter((f) =>
      f.mimeType.startsWith("video/") ||
      f.mimeType.startsWith("image/") ||
      f.mimeType.startsWith("audio/")
    );

    return new Response(JSON.stringify({ files: supported }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    return new Response(JSON.stringify({ error: err.message }), { status: 500 });
  }
});

// Only signed-in users may proxy Drive traffic; the shipped anon key alone is rejected.
async function requireUser(req: Request): Promise<Response | null> {
  const authHeader = req.headers.get("Authorization") ?? "";
  const token = authHeader.replace(/^Bearer\s+/i, "");
  if (!token) {
    return new Response(JSON.stringify({ error: "Sign in required" }), { status: 401 });
  }
  const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/auth/v1/user`, {
    headers: {
      Authorization: `Bearer ${token}`,
      apikey: Deno.env.get("SUPABASE_ANON_KEY")!,
    },
  });
  if (!res.ok) {
    return new Response(JSON.stringify({ error: "Sign in required" }), { status: 401 });
  }
  const user = await res.json();
  if (!user?.id) {
    return new Response(JSON.stringify({ error: "Sign in required" }), { status: 401 });
  }
  return null;
}

function extractFolderId(url: string): string | null {
  const folderMatch = url.match(/\/drive\/folders\/([a-zA-Z0-9_-]+)/);
  if (folderMatch) return folderMatch[1];
  const openMatch = url.match(/[?&]id=([a-zA-Z0-9_-]+)/);
  if (openMatch) return openMatch[1];
  const ucMatch = url.match(/\/uc\?id=([a-zA-Z0-9_-]+)/);
  if (ucMatch) return ucMatch[1];
  const shortMatch = url.match(/drive\.google\.com\/(?:f|file)\/([a-zA-Z0-9_-]+)/);
  if (shortMatch) return shortMatch[1];
  return null;
}

async function getAccessToken(sa: any): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const jwt = await signJWT(
    {
      iss: sa.client_email,
      scope: "https://www.googleapis.com/auth/drive.readonly",
      aud: "https://oauth2.googleapis.com/token",
      exp: now + 3600,
      iat: now,
    },
    sa.private_key,
  );
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });
  const data = await res.json();
  if (!data.access_token) throw new Error(`Token error: ${JSON.stringify(data)}`);
  return data.access_token;
}

async function signJWT(payload: Record<string, unknown>, privateKeyPem: string): Promise<string> {
  const header = { alg: "RS256", typ: "JWT" };

  const b64url = (data: ArrayBuffer): string => {
    const bytes = new Uint8Array(data);
    let binary = "";
    for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
    return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
  };

  const encoder = new TextEncoder();
  const headerB64 = b64url(encoder.encode(JSON.stringify(header)));
  const payloadB64 = b64url(encoder.encode(JSON.stringify(payload)));
  const message = `${headerB64}.${payloadB64}`;

  const pemContent = privateKeyPem
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s+/g, "");
  const derBytes = Uint8Array.from(atob(pemContent), (c) => c.charCodeAt(0));

  const key = await crypto.subtle.importKey(
    "pkcs8",
    derBytes.buffer,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );

  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, encoder.encode(message));

  return `${message}.${b64url(signature)}`;
}
