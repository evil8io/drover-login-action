import * as http from 'node:http';
import { request as httpsRequest } from 'node:https';
import { oneLine } from './workflow.js';

export interface Tls {
  // For this request, Node trusts only these certificates.
  ca?: string;
  insecure?: boolean;
}

export interface Request {
  method: 'GET' | 'POST';
  headers: Record<string, string>;
  body?: string;
  tls?: Tls;
}

export interface Response {
  status: number;
  body: string;
}

const TIMEOUT_SECONDS = 60;
const MAX_BODY_BYTES = 1024 * 1024;

// Returns false when Node refuses a proxy variable. We do not pass HTTP_PROXY. The action allows a
// plain HTTP URL of OpenBao only on a loopback address. With HTTP_PROXY, Node sends the tokens of
// such a request to the proxy as plain text.
export function useProxyVariables(): boolean {
  // An older Node 24 does not have this function. Such a Node stops with an error at a named
  // import of the function.
  const configure: ((variables: http.ProxyEnv) => unknown) | undefined = http.setGlobalProxyFromEnv;
  if (configure === undefined) {
    return true;
  }
  const variables: http.ProxyEnv = {};
  for (const name of ['HTTPS_PROXY', 'https_proxy', 'NO_PROXY', 'no_proxy']) {
    const value = process.env[name];
    if (value !== undefined) {
      variables[name] = value;
    }
  }
  try {
    configure(variables);
    return true;
  } catch {
    return false;
  }
}

// Node does not follow a redirect. Thus a server cannot make Node send a token of the request to
// another host.
export function send(url: string, request: Request): Promise<Response> {
  return new Promise((resolve, reject) => {
    const target = new URL(url);
    const options = {
      method: request.method,
      headers: {
        'user-agent': 'drover-login-action',
        ...request.headers,
        ...(request.body === undefined ? {} : { 'content-length': String(Buffer.byteLength(request.body)) }),
      },
      signal: AbortSignal.timeout(TIMEOUT_SECONDS * 1000),
    };
    // Without rejectUnauthorized, Node skips the certificate check when NODE_TLS_REJECT_UNAUTHORIZED
    // is 0 in the job. This also applies to the request to GitHub. With allowPartialTrustChain, Node
    // trusts an intermediate CA or a server certificate in `ca`, as kubectl does.
    const client =
      target.protocol === 'https:'
        ? httpsRequest(target, {
            ...options,
            ca: request.tls?.ca,
            allowPartialTrustChain: request.tls?.ca !== undefined,
            rejectUnauthorized: request.tls?.insecure !== true,
          })
        : http.request(target, options);
    client.on('error', reject);
    // Without this listener, Node closes the connection of a 101 response and does not report an
    // error or a response.
    client.on('upgrade', (_response, socket) => {
      socket.destroy();
      reject(new Error('the server changed the protocol'));
    });
    client.on('response', (response) => {
      const chunks: Buffer[] = [];
      let size = 0;
      response.on('data', (chunk: Buffer) => {
        size += chunk.length;
        if (size > MAX_BODY_BYTES) {
          client.destroy(new Error('the response is larger than 1 MiB'));
          return;
        }
        chunks.push(chunk);
      });
      response.on('error', reject);
      response.on('close', () => {
        if (response.complete) {
          resolve({ status: response.statusCode ?? 0, body: Buffer.concat(chunks).toString('utf8') });
        } else {
          reject(new Error('the connection was closed before the end of the response'));
        }
      });
    });
    client.end(request.body);
  });
}

// Node does not put a part of a request body or a response body in the message of a network error
// or a file error.
export function reason(error: unknown): string {
  if (!(error instanceof Error)) {
    return 'the cause is not known';
  }
  if (error.name === 'AbortError') {
    return `the request took more than ${TIMEOUT_SECONDS} seconds`;
  }
  const code = (error as NodeJS.ErrnoException).code;
  const text = oneLine(error.message);
  if (text !== '' && code !== undefined && !text.includes(code)) {
    return `${text} (${code})`;
  }
  return text || code || error.name;
}
