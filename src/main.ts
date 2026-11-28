import { reason, send, useProxyVariables, type Request, type Response, type Tls } from './http.js';
import { readInputs } from './inputs.js';
import { defaultPath, write } from './kubeconfig.js';
import { Failure, error, exportVariable, info, oneLine, setOutput, token } from './workflow.js';

type Document = Record<string, unknown>;

function isDocument(value: unknown): value is Document {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

async function request(description: string, url: string, options: Request): Promise<Response> {
  try {
    return await send(url, options);
  } catch (cause) {
    throw new Failure(`${description} failed: ${reason(cause)}.`);
  }
}

// The error message of JSON.parse contains a part of the response. That part can contain a token.
// Thus we do not print the message.
function document(name: string, response: Response): Document {
  let parsed: unknown;
  try {
    parsed = JSON.parse(response.body);
  } catch {
    parsed = undefined;
  }
  if (!isDocument(parsed)) {
    throw new Failure(`The response of the request ${name} is not a JSON object.`);
  }
  return parsed;
}

// OpenBao returns its errors in the list `errors`. GitHub returns an error in `message` or in
// `error`.
function errors(response: Response): string {
  let parsed: unknown;
  try {
    parsed = JSON.parse(response.body);
  } catch {
    return '';
  }
  if (!isDocument(parsed)) {
    return '';
  }
  const list = parsed['errors'] ?? [parsed['message'] || parsed['error']];
  if (!Array.isArray(list)) {
    return '';
  }
  try {
    return oneLine(
      list
        .filter((item) => item !== undefined && item !== null && item !== false)
        .map((item) => (typeof item === 'string' ? item : JSON.stringify(item)))
        .join('; '),
    );
  } catch {
    return '';
  }
}

// Encodes each character outside A-Z, a-z, 0-9, '-', '_', '.', and '~'.
function encode(value: string): string {
  return encodeURIComponent(value).replace(/[!'()*]/g, (character) => `%${character.charCodeAt(0).toString(16).toUpperCase()}`);
}

async function main(): Promise<void> {
  process.umask(0o077);
  const inputs = readInputs();
  const requestUrl = process.env['ACTIONS_ID_TOKEN_REQUEST_URL'] ?? '';
  const requestToken = process.env['ACTIONS_ID_TOKEN_REQUEST_TOKEN'] ?? '';
  if (requestUrl === '' || requestToken === '') {
    throw new Failure('The job cannot request an OIDC token. Give the job the permission id-token: write.');
  }
  if (!useProxyVariables()) {
    info('Node cannot use the proxy variables of the job. The action connects without a proxy.');
  }

  const { openbaoUrl, cluster, project, role } = inputs;
  const loginRole = `${cluster}_${project}_${inputs.statement}`;
  const accountNamespace = `drover-${cluster}-${project}`;
  const server = `${inputs.rancherUrl}/k8s/clusters/${cluster}`;
  // We do not pass `tls` to the request to GitHub. With `ca`, Node does not trust the CA of GitHub.
  // With `insecure`, an attacker on the network path can get the request token of the job.
  const tls: Tls = inputs.caCertificate === '' ? { insecure: inputs.insecureSkipTlsVerify } : { ca: inputs.caCertificate };

  const separator = requestUrl.includes('?') ? '&' : '?';
  const oidc = await request('The OIDC token request to GitHub', `${requestUrl}${separator}audience=${encode(inputs.audience)}`, {
    method: 'GET',
    headers: { authorization: `bearer ${requestToken}`, accept: 'application/json' },
  });
  if (oidc.status !== 200) {
    throw new Failure(`GitHub did not return an OIDC token (HTTP ${oidc.status}): ${errors(oidc)}`);
  }
  const jwt = token('OIDC token', document('oidc', oidc)['value'], 'The OIDC token response does not contain a value.');

  const login = await request(`The login request to ${openbaoUrl}`, `${openbaoUrl}/v1/auth/jwt/${inputs.issuer}/login`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ role: loginRole, jwt }),
    tls,
  });
  if (login.status !== 200) {
    throw new Failure(
      `OpenBao refused the login with the role ${loginRole} at auth/jwt/${inputs.issuer} (HTTP ${login.status}): ${errors(login)}`,
    );
  }
  const auth = document('login', login)['auth'];
  const clientToken = token(
    'OpenBao token',
    isDocument(auth) ? auth['client_token'] : undefined,
    'The login response does not contain a client token.',
  );
  info(`OpenBao accepted the login with the role ${loginRole} at ${openbaoUrl}.`);

  const creds = await request(`The token request to ${openbaoUrl}`, `${openbaoUrl}/v1/kubernetes/${cluster}/creds/${project}-${role}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-vault-token': clientToken },
    body: JSON.stringify({ kubernetes_namespace: accountNamespace, ...(inputs.ttl === '' ? {} : { ttl: inputs.ttl }) }),
    tls,
  });
  if (creds.status !== 200) {
    throw new Failure(`OpenBao did not return a token of ${accountNamespace}/${role} (HTTP ${creds.status}): ${errors(creds)}`);
  }
  const lease = document('creds', creds);
  const data = lease['data'];
  const accountToken = token(
    'ServiceAccount token',
    isDocument(data) ? data['service_account_token'] : undefined,
    'The token response does not contain a ServiceAccount token.',
  );
  const expiresIn = lease['lease_duration'] ?? 0;
  if (typeof expiresIn !== 'number' || !Number.isSafeInteger(expiresIn) || expiresIn < 0) {
    throw new Failure('The lease duration of the token response is not a number of seconds.');
  }
  info(`OpenBao returned a token of ${accountNamespace}/${role} for the cluster ${cluster}. It expires in ${expiresIn} seconds.`);

  let path = inputs.kubeconfig;
  try {
    path ||= defaultPath();
    write(path, {
      cluster,
      server,
      user: `${project}-${role}`,
      token: accountToken,
      namespace: inputs.namespace,
      caCertificate: inputs.caCertificate,
      insecureSkipTlsVerify: inputs.insecureSkipTlsVerify,
    });
  } catch (cause) {
    throw new Failure(`The action cannot write the kubeconfig${path === '' ? '' : ` to ${path}`}: ${reason(cause)}.`);
  }
  info(`The action wrote the kubeconfig to ${path}. The server is ${server}.`);

  setOutput('kubeconfig', path);
  setOutput('server', server);
  setOutput('token', accountToken);
  setOutput('expires-in', String(expiresIn));
  if (inputs.exportKubeconfig) {
    exportVariable('KUBECONFIG', path);
  }
}

let finished = false;

function report(cause: unknown): void {
  finished = true;
  if (cause instanceof Failure) {
    error(cause.message);
  } else {
    const name = cause instanceof Error ? cause.name : typeof cause;
    error(
      `The action stopped because of an unexpected error (${name}). The action does not print the message of such an error, because the message can contain a part of a response.`,
    );
  }
  process.exitCode = 1;
}

process.on('uncaughtException', (cause) => {
  report(cause);
  process.exit(1);
});

// When a request is closed without a response and without an error event, Node prints only a
// warning and exits. We then add the error line of the action.
process.on('exit', () => {
  if (!finished) {
    error('The action stopped before the end of a request.');
    process.exitCode = 1;
  }
});

try {
  await main();
  finished = true;
} catch (cause) {
  report(cause);
}
