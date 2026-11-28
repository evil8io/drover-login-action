import { appendFileSync } from 'node:fs';

// A Failure is an error with a message that the action wrote for the log of the job.
export class Failure extends Error {}

// With a line break in its text, a server can add a workflow command to the log.
export function oneLine(text: string): string {
  return text.replace(/[\s\x00-\x1f\x7f-\x9f]+/g, ' ').replace(/ $/, '');
}

export function info(message: string): void {
  process.stdout.write(`${message}\n`);
}

export function error(message: string): void {
  const data = message.replaceAll('%', '%25').replaceAll('\r', '%0D').replaceAll('\n', '%0A');
  process.stdout.write(`::error::${data}\n`);
}

const TOKEN_PATTERN = /^[A-Za-z0-9._-]+$/;
const TOKEN_MIN_LENGTH = 16;

// With a line break in a token, a server can add a workflow command to the log or a line to
// GITHUB_OUTPUT. The runner hides each occurrence of a masked value in the log. With a short token,
// the runner thus hides a large part of the log.
export function token(name: string, value: unknown, missing: string): string {
  if (typeof value !== 'string' || value === '') {
    throw new Failure(missing);
  }
  if (!TOKEN_PATTERN.test(value)) {
    throw new Failure(`The ${name} is not one line of the characters A-Z, a-z, 0-9, '.', '_', and '-'.`);
  }
  if (value.length < TOKEN_MIN_LENGTH) {
    throw new Failure(`The ${name} contains fewer than ${TOKEN_MIN_LENGTH} characters.`);
  }
  process.stdout.write(`::add-mask::${value}\n`);
  return value;
}

function append(variable: 'GITHUB_OUTPUT' | 'GITHUB_ENV', name: string, value: string): void {
  const file = process.env[variable];
  if (!file) {
    throw new Failure(`The variable ${variable} is not set.`);
  }
  if (/[\r\n]/.test(value)) {
    throw new Failure(`The value of ${name} contains a line break.`);
  }
  try {
    appendFileSync(file, `${name}=${value}\n`);
  } catch {
    throw new Failure(`The action cannot write to the file of ${variable}.`);
  }
}

export function setOutput(name: string, value: string): void {
  append('GITHUB_OUTPUT', name, value);
}

export function exportVariable(name: string, value: string): void {
  append('GITHUB_ENV', name, value);
}
