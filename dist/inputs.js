import { statSync } from 'node:fs';
import { Failure } from './workflow.js';
const URL_PATTERN = /^(https:\/\/[A-Za-z0-9.-]+|http:\/\/(127\.0\.0\.1|localhost))(:[0-9]+)?$/;
const NAME_PATTERN = /^[a-z0-9]([-a-z0-9]*[a-z0-9])?$/;
const BOOLEAN_PATTERN = /^(true|false)$/;
const PEM_BLOCK = '-----BEGIN CERTIFICATE-----\\n([A-Za-z0-9+/=]+\\n)+-----END CERTIFICATE-----';
const CA_PATTERN = new RegExp(`^(${PEM_BLOCK}(\\n+${PEM_BLOCK})*)?$`);
function input(name) {
    return process.env[`INPUT_${name.toUpperCase()}`] ?? '';
}
function isDirectory(path) {
    try {
        return statSync(path).isDirectory();
    }
    catch {
        return false;
    }
}
function check(name, value, pattern, expected) {
    if (!pattern.test(value)) {
        throw new Failure(`The input ${name} is not valid. The value must be ${expected}.`);
    }
}
export function readInputs() {
    const openbaoUrl = input('openbao-url').replace(/\/$/, '');
    const rancherUrl = input('rancher-url').replace(/\/$/, '');
    const cluster = input('cluster');
    const project = input('project');
    const role = input('role');
    const statement = input('statement');
    const issuer = input('issuer') || 'github';
    const audience = input('audience') || openbaoUrl;
    const ttl = input('ttl');
    const namespace = input('namespace');
    const kubeconfig = input('kubeconfig');
    const exportKubeconfig = input('export-kubeconfig') || 'true';
    const caCertificate = input('ca-certificate')
        .replaceAll('\r', '')
        .replace(/^[ \t\n\v\f]+/, '')
        .replace(/[ \t\n\v\f]+$/, '');
    const insecureSkipTlsVerify = input('insecure-skip-tls-verify') || 'false';
    check('openbao-url', openbaoUrl, URL_PATTERN, 'an https URL with a host and without a path');
    check('rancher-url', rancherUrl, URL_PATTERN, 'an https URL with a host and without a path');
    check('cluster', cluster, NAME_PATTERN, 'a Rancher cluster id, for example c-m-4x2kq7bd');
    check('project', project, NAME_PATTERN, 'a Rancher project id, for example p-abc12');
    check('role', role, /^(project-owner|project-member|read-only)$/, 'project-owner, project-member, or read-only');
    check('statement', statement, /^[a-z0-9]([-a-z0-9]{0,30}[a-z0-9])?$/, 'the name of a statement in the trust annotation of the project, at most 32 characters');
    check('issuer', issuer, NAME_PATTERN, 'the name of a JWT issuer of OpenBao, for example github');
    check('audience', audience, /^[^ \t\n\v\f\r]+$/, 'text without white space');
    check('ttl', ttl, /^([0-9]+[smh]?)?$/, 'a duration, for example 30m, or empty');
    check('namespace', namespace, /^([a-z0-9]([-a-z0-9]*[a-z0-9])?)?$/, 'a namespace name, or empty');
    check('kubeconfig', kubeconfig, /^(\/[^\x00-\x1f\x7f]*)?$/, 'an absolute path, or empty');
    check('export-kubeconfig', exportKubeconfig, BOOLEAN_PATTERN, 'true or false');
    check('ca-certificate', caCertificate, CA_PATTERN, 'one or more PEM certificates, or empty');
    check('insecure-skip-tls-verify', insecureSkipTlsVerify, BOOLEAN_PATTERN, 'true or false');
    if (kubeconfig !== '' && isDirectory(kubeconfig)) {
        throw new Failure('The input kubeconfig is a directory.');
    }
    if (caCertificate !== '' && insecureSkipTlsVerify === 'true') {
        throw new Failure('Set the input ca-certificate or the input insecure-skip-tls-verify. Do not set both, because kubectl does not accept a kubeconfig with both.');
    }
    return {
        openbaoUrl,
        rancherUrl,
        cluster,
        project,
        role,
        statement,
        issuer,
        audience,
        ttl,
        namespace,
        kubeconfig,
        exportKubeconfig: exportKubeconfig === 'true',
        caCertificate,
        insecureSkipTlsVerify: insecureSkipTlsVerify === 'true',
    };
}
