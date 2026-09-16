export const replayChunks = [];
export const messages = [];
export let resultBody;

export function replayAppend(chunk) {
  replayChunks.push(chunk.slice());
}

export function message(seat, payload) {
  messages.push({ seat, payload: payload.slice() });
}

export function results(body) {
  resultBody = body.slice();
}

export function line() {}
