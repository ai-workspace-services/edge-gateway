/**
 * 原生 Web Crypto API JWT 验签工具 (0 依赖，0ms 极速执行)
 */

export interface JWTPayload {
  sub?: string;
  user_id?: string;
  tenant_id?: string;
  exp?: number;
  iss?: string;
  [key: string]: any;
}

export interface VerifyResult {
  valid: boolean;
  payload?: JWTPayload;
  error?: string;
}

export async function verifyJWT(token: string, secret: string): Promise<VerifyResult> {
  try {
    const parts = token.split('.');
    if (parts.length !== 3) {
      return { valid: false, error: 'Malformed token' };
    }

    const [headerB64, payloadB64, signatureB64] = parts;
    const encoder = new TextEncoder();
    const data = encoder.encode(`${headerB64}.${payloadB64}`);

    // Base64URL 解码签名
    const signature = Uint8Array.from(
      atob(signatureB64.replace(/-/g, '+').replace(/_/g, '/')),
      (c) => c.charCodeAt(0)
    );

    // 导入 HMAC-SHA256 密钥
    const key = await crypto.subtle.importKey(
      'raw',
      encoder.encode(secret),
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['verify']
    );

    // 验证数字签名
    const isValid = await crypto.subtle.verify('HMAC', key, signature, data);
    if (!isValid) {
      return { valid: false, error: 'Invalid signature' };
    }

    // 解析 Payload 并校验过期时间 (exp)
    const payloadStr = atob(payloadB64.replace(/-/g, '+').replace(/_/g, '/'));
    const payload: JWTPayload = JSON.parse(payloadStr);

    if (payload.exp && Date.now() / 1000 > payload.exp) {
      return { valid: false, error: 'Token expired' };
    }

    return { valid: true, payload };
  } catch (err: any) {
    return { valid: false, error: err.message || 'Verification failed' };
  }
}
