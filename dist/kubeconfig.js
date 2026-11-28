import { randomBytes } from 'node:crypto';
import { mkdirSync, mkdtempSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
export function defaultPath() {
    return join(mkdtempSync(join(process.env['RUNNER_TEMP'] || tmpdir(), 'drover-kubeconfig.')), 'kubeconfig');
}
// kubectl and helm read a JSON kubeconfig. When Node writes to an existing file, Node keeps the
// mode of the file. Node also follows a symlink at the path. Thus we write a new file and move it
// onto the path.
export function write(path, kubeconfig) {
    const document = {
        apiVersion: 'v1',
        kind: 'Config',
        clusters: [
            {
                name: kubeconfig.cluster,
                cluster: {
                    server: kubeconfig.server,
                    ...(kubeconfig.caCertificate === ''
                        ? {}
                        : { 'certificate-authority-data': Buffer.from(kubeconfig.caCertificate).toString('base64') }),
                    ...(kubeconfig.insecureSkipTlsVerify ? { 'insecure-skip-tls-verify': true } : {}),
                },
            },
        ],
        users: [{ name: kubeconfig.user, user: { token: kubeconfig.token } }],
        contexts: [
            {
                name: kubeconfig.cluster,
                context: {
                    cluster: kubeconfig.cluster,
                    user: kubeconfig.user,
                    ...(kubeconfig.namespace === '' ? {} : { namespace: kubeconfig.namespace }),
                },
            },
        ],
        'current-context': kubeconfig.cluster,
    };
    const directory = dirname(path);
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    const temporary = join(directory, `.kubeconfig.${randomBytes(8).toString('hex')}`);
    try {
        writeFileSync(temporary, `${JSON.stringify(document, null, 2)}\n`, { mode: 0o600, flag: 'wx' });
        renameSync(temporary, path);
    }
    catch (error) {
        rmSync(temporary, { force: true });
        throw error;
    }
}
