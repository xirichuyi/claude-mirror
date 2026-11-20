import type { RemoteCC } from '../src/preload.cjs';
import { createSession } from '../src/remote.cjs';
import { preferencePatch } from '../src/capabilities.cjs';
import { SessionInput } from '../src/session-input.cjs';
declare const api: RemoteCC;
const session = createSession({ host: 'example', directory: '~' });
api.configure(session.id, { fastMode: true, selectedModel: 'default' });
api.load(session.id).then(loaded => loaded.messages.map(message => message.id));
// @ts-expect-error Session IDs are strings across the preload boundary.
api.load(42);
// @ts-expect-error Model preferences cannot silently change their representation.
api.configure(session.id, { fastMode: 'yes' });
// @ts-expect-error Reject misspelled preference keys.
api.configure(session.id, { selectedModle: 'default' });
// @ts-expect-error Validated patches retain their field types.
const invalidFlag: string = preferencePatch({ fastMode: true }).fastMode;
const input = new SessionInput();
input.push('hello', session.id);
// @ts-expect-error Queued SDK prompts must be text or content blocks.
input.push(123, session.id);
