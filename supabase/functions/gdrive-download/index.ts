import { serve } from "https://deno.land/std@0.168.0/http/server.ts"

serve(async (req) => {
  try {
    const authError = await requireUser(req)
    if (authError) return authError

    const { fileId } = await req.json()
    if (!fileId) {
      return new Response(JSON.stringify({ error: "fileId required" }), { status: 400 })
    }

    const saJson = JSON.parse(Deno.env.get("GOOGLE_SERVICE_ACCOUNT_JSON")!)
    const token = await getAccessToken(saJson)

    const downloadUrl = `https://www.googleapis.com/drive/v3/files/${fileId}?alt=media`
    const resp = await fetch(downloadUrl, {
      headers: { Authorization: `Bearer ${token}` },
    })

    if (!resp.ok) {
      const err = await resp.text()
      return new Response(JSON.stringify({ error: `Drive API error: ${err}` }), {
        status: resp.status,
        headers: { "Content-Type": "application/json" },
      })
    }

    const contentType = resp.headers.get("content-type") || "application/octet-stream"
    const body = await resp.arrayBuffer()

    return new Response(body, {
      headers: {
        "Content-Type": contentType,
        "Content-Length": body.byteLength.toString(),
      },
    })
  } catch (err) {
    return new Response(JSON.stringify({ error: err.message }), { status: 500 })
  }
})

// Only signed-in users may proxy Drive traffic; the shipped anon key alone is rejected.
async function requireUser(req: Request): Promise<Response | null> {
  const authHeader = req.headers.get("Authorization") ?? ""
  const token = authHeader.replace(/^Bearer\s+/i, "")
  if (!token) {
    return new Response(JSON.stringify({ error: "Sign in required" }), { status: 401 })
  }
  const res = await fetch(`${Deno.env.get("SUPABASE_URL")}/auth/v1/user`, {
    headers: {
      Authorization: `Bearer ${token}`,
      apikey: Deno.env.get("SUPABASE_ANON_KEY")!,
    },
  })
  if (!res.ok) {
    return new Response(JSON.stringify({ error: "Sign in required" }), { status: 401 })
  }
  const user = await res.json()
  if (!user?.id) {
    return new Response(JSON.stringify({ error: "Sign in required" }), { status: 401 })
  }
  return null
}

async function getAccessToken(sa: any): Promise<string> {
  const now = Math.floor(Date.now() / 1000)
  const jwt = await signJWT(
    {
      iss: sa.client_email,
      scope: "https://www.googleapis.com/auth/drive.readonly",
      aud: "https://oauth2.googleapis.com/token",
      exp: now + 3600,
      iat: now,
    },
    sa.private_key,
  )
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  })
  const data = await res.json()
  if (!data.access_token) throw new Error(`Token error: ${JSON.stringify(data)}`)
  return data.access_token
}

async function signJWT(payload: Record<string, unknown>, privateKeyPem: string): Promise<string> {
  const header = { alg: "RS256", typ: "JWT" }

  const b64url = (data: ArrayBuffer): string => {
    const bytes = new Uint8Array(data)
    let binary = ""
    for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i])
    return btoa(binary).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_")
  }

  const encoder = new TextEncoder()
  const headerB64 = b64url(encoder.encode(JSON.stringify(header)))
  const payloadB64 = b64url(encoder.encode(JSON.stringify(payload)))
  const message = `${headerB64}.${payloadB64}`

  const pemContent = privateKeyPem
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s+/g, "")
  const derBytes = Uint8Array.from(atob(pemContent), (c) => c.charCodeAt(0))

  const key = await crypto.subtle.importKey(
    "pkcs8",
    derBytes.buffer,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  )

  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, encoder.encode(message))

  return `${message}.${b64url(signature)}`
}
