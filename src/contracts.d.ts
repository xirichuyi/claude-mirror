/** Shared application data; external SDK payloads remain extensible at the boundary. */
export interface ConnectionConfig { host: string; directory: string; port?: number; name?: string }
export interface Preferences {
  agent?: string;
  selectedModel?: string;
  effort?: string;
  permissionMode?: string;
  executionUser?: string;
  promptCacheTtl?: string;
  fastMode?: boolean;
  additionalDirectories?: string[];
  outputStyle?: string;
}
export interface ChatSession extends ConnectionConfig {
  id: string;
  name: string;
  createdAt: number;
  updatedAt: number;
  messages: ChatMessage[];
  status: string;
  permissions: any[];
  preferences?: Preferences;
  remoteSessionId?: string;
  forkPending?: boolean;
  capabilities?: any;
  [key: string]: any;
}
export interface ChatMessage {
  id: string;
  role: string;
  blocks?: any[];
  createdAt?: number;
  revision?: number;
  [key: string]: any;
}
export interface ActiveRun {
  stopped: boolean;
  stderr: string;
  message: ChatMessage;
  transcript?: import('./transcript.cjs').Transcript;
  query?: any;
  persistent?: boolean;
}
export interface FileTransfer { input?: string; output?: string; data?: string; name?: string; size?: number }
export interface TransferProgress { sessionId: string; name?: string; direction?: string; bytes?: number; total?: number; done?: boolean; error?: string }
export interface RpcOptions { signal?: AbortSignal; timeout?: number }
export interface PendingRequest { resolve: (value: any) => void; reject: (reason: any) => void; timer?: ReturnType<typeof setTimeout>; cleanup?: () => void }
export interface CancellationToken { cancelled?: boolean; cancel?: () => void }
export interface CommandResult { code: number; missing: boolean; stdout: string; stderr: string }
export interface SchemaRule {
  type?: string; title?: string; description?: string; default?: any;
  properties?: Record<string, SchemaRule>; required?: string[];
  items?: SchemaRule; enum?: string[]; enumNames?: string[];
  oneOf?: {const: string; title?: string}[]; anyOf?: {const: string; title?: string}[];
  format?: string; minimum?: number; maximum?: number;
  minLength?: number; maxLength?: number; minItems?: number; maxItems?: number;
}
