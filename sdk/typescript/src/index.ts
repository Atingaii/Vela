import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process';
import { isAbsolute } from 'node:path';

export type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
export type ObjectValue = { [key: string]: Json };
export type MemoryType = 'decision' | 'constraint' | 'preference' | 'failure' | 'fact' | 'workflow knowledge' | 'observation' | 'hypothesis' | 'checkpoint';
export interface LocalTransport { type: 'local'; executable: string; home: string }
export interface ClientOptions { transport: LocalTransport; project?: string; timeoutMs?: number }
export interface RequestOptions { signal?: AbortSignal; timeoutMs?: number }
export interface CandidateInput { title: string; content: string; type?: MemoryType; project?: string }
export interface MemoryRecord extends ObjectValue { id: string; title: string; content: string; state: string; project: string }
export type SemanticLanguage = 'en' | 'zh-Hans';
export interface ScoringWeights { semantic?: number; recency?: number; importance?: number; recencyHalfLifeDays?: number }
export interface RecallParameters {
  project?: string; budget?: number; retrievalMode?: 'lexical' | 'semantic' | 'hybrid'; language?: SemanticLanguage;
  limit?: number; minSimilarity?: number; scoringWeights?: ScoringWeights;
  branch?: string; worktree?: string; task?: string; sessionId?: string;
}
export type IntegrationRecallParameters = Pick<RecallParameters,'project'|'budget'|'retrievalMode'|'language'|'limit'|'minSimilarity'>;
export interface SemanticModel { id: string; language: SemanticLanguage; revision: number; dimension: number; runtime: string }
export interface SemanticStatus { status: 'ok' | 'unavailable'; model: SemanticModel | null; indexIncomplete: boolean; eligible?: number; indexed?: number; stale?: number; missing?: number; scanned?: number; reason?: string; downloadRequested: false }
export interface SemanticIndexParameters { project?: string; language?: SemanticLanguage; batchSize?: number; cursor?: string }
export interface SemanticIndexResult { status: 'ok' | 'partial' | 'unavailable'; model: SemanticModel | null; processed?: number; indexed?: number; unchanged?: number; skipped?: number; failed?: number; nextCursor?: string | null; hasMore?: boolean; reason?: string; downloadRequested: false }
export interface RecallResult { items: MemoryRecord[]; usedTokens: number; budget: number; truncated: boolean; status?: 'ok' | 'unavailable'; retrievalMode?: 'lexical' | 'semantic' | 'hybrid' | 'unavailable'; model?: SemanticModel | null; indexIncomplete?: boolean; indexCoverage?: SemanticStatus; fallbackReason?: string }
export interface ArchiveExport extends ObjectValue { archive: ObjectValue; count: number; bytes: number; encrypted: boolean }
export interface ArchiveImport extends ObjectValue { imported: number; skipped: number; ids: string[]; skippedIds: string[]; state: string }
export type ErrorCode = 'invalid_input' | 'busy' | 'closed' | 'spawn_failed' | 'protocol_error' | 'output_limit' | 'transport_closed' | 'timeout' | 'cancelled' | 'rpc_error';

export class VelaError extends Error {
  constructor(public readonly code: ErrorCode, public readonly requestId: number | null = null,
    public readonly effectsUnknown = false) {
    super(`Vela request failed: ${code}.`); this.name = 'VelaError';
  }
}
export class VelaBulkError extends Error {
  readonly completed: MemoryRecord[];
  readonly skipped = 0;
  readonly unattempted: number;
  readonly effectsUnknown: boolean;
  constructor(completed: MemoryRecord[], public readonly failedIndex: number, total: number, public readonly cause: VelaError) {
    super('Vela bulk write stopped; inspect completed items and the uncertain request before continuing.');
    this.name = 'VelaBulkError'; this.completed = [...completed];
    this.unattempted = total - failedIndex - 1; this.effectsUnknown = cause.effectsUnknown;
  }
}

const FRAME_LIMIT = 2 * 1024 * 1024;
const STDERR_LIMIT = 64 * 1024;
const timeout = (value: number | undefined, fallback = 15000): number => {
  const result = value ?? fallback;
  if (!Number.isInteger(result) || result < 1 || result > 120000) throw new VelaError('invalid_input');
  return result;
};
const absolute = (value: unknown): string => {
  if (typeof value !== 'string' || !isAbsolute(value) || value.includes('\0')) throw new VelaError('invalid_input');
  return value;
};
const exactKeys = (value: object, allowed: string[]): void => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new VelaError('invalid_input');
  if (Object.keys(value).some(key => !allowed.includes(key))) throw new VelaError('invalid_input');
};
const numeric = (value: unknown, min: number, max: number, integer = false): void => {
  if (value !== undefined && (typeof value !== 'number' || !Number.isFinite(value) || value < min || value > max || (integer && !Number.isInteger(value)))) throw new VelaError('invalid_input');
};
const language = (value: unknown): void => {
  if (value !== undefined && value !== 'en' && value !== 'zh-Hans') throw new VelaError('invalid_input');
};
const candidate = (input: CandidateInput): void => {
  if (!input || typeof input !== 'object') throw new VelaError('invalid_input');
  exactKeys(input, ['title', 'content', 'type', 'project']);
  if (typeof input.title !== 'string' || !input.title.trim() || [...input.title].length > 300 ||
    typeof input.content !== 'string' || !input.content.trim() || Buffer.byteLength(input.content) > 512 * 1024) throw new VelaError('invalid_input');
  if (input.type !== undefined && !['decision','constraint','preference','failure','fact','workflow knowledge','observation','hypothesis','checkpoint'].includes(input.type)) throw new VelaError('invalid_input');
};
interface Pending {
  resolve: (value: Json) => void; reject: (error: VelaError) => void;
  timer: ReturnType<typeof setTimeout>; cleanup: () => void; mutating: boolean;
}

/** An explicit local process connection. It grants no authority beyond the selected helper/store. */
export class VelaClient {
  private readonly child: ChildProcessWithoutNullStreams;
  private readonly defaultTimeout: number;
  private readonly project?: string;
  private readonly pending = new Map<number, Pending>();
  private sequence = 0;
  private buffer = Buffer.alloc(0);
  private stderrBytes = 0;
  private closed = false;
  private spawned = false;
  private readonly exitPromise: Promise<void>;
  private cleanupPromise?: Promise<void>;

  constructor(options: ClientOptions) {
    if (!options || typeof options !== 'object' || !options.transport || typeof options.transport !== 'object') throw new VelaError('invalid_input');
    exactKeys(options, ['transport', 'project', 'timeoutMs']); exactKeys(options.transport, ['type','executable','home']);
    if (options.transport.type !== 'local' || process.platform === 'win32') throw new VelaError('invalid_input');
    const executable = absolute(options.transport.executable), home = absolute(options.transport.home);
    this.project = options.project === undefined ? undefined : absolute(options.project);
    this.defaultTimeout = timeout(options.timeoutMs);
    this.child = spawn(executable, ['rpc', '--no-watch', '--no-schedule', '--home', home], {
      shell: false, detached: true, stdio: ['pipe','pipe','pipe'],
      env: { ...process.env, VELA_DISABLE_DISCOVERY: '1' },
    });
    this.exitPromise = new Promise(resolve => this.child.once('close', () => resolve()));
    this.child.once('spawn', () => { this.spawned = true; });
    this.child.on('error', () => this.stop('spawn_failed'));
    this.child.stdin.on('error', () => this.stop('transport_closed'));
    this.child.stdout.on('data', (chunk: Buffer) => this.receive(chunk));
    this.child.stdout.on('error', () => this.stop('transport_closed'));
    this.child.stderr.on('error', () => this.stop('transport_closed'));
    this.child.stderr.on('data', (chunk: Buffer) => {
      this.stderrBytes += chunk.length;
      // Drain but never retain or expose helper stderr, which may contain user paths/content.
      if (this.stderrBytes > STDERR_LIMIT) this.stop('output_limit');
    });
    this.child.once('close', () => this.stop('transport_closed'));
  }

  private signal(signal: NodeJS.Signals): void {
    if (!this.child.pid) return;
    try { process.kill(-this.child.pid, signal); } catch { /* The owned group already exited. */ }
  }
  private stop(code: ErrorCode, triggeringId: number | null = null): void {
    if (this.closed) return;
    this.closed = true;
    for (const [id, item] of this.pending) {
      clearTimeout(item.timer); item.cleanup();
      item.reject(new VelaError(triggeringId === null || triggeringId === id ? code : 'transport_closed', id, item.mutating && this.spawned));
    }
    this.pending.clear(); this.buffer = Buffer.alloc(0);
    this.child.stdin.destroy(); this.signal('SIGTERM');
    this.cleanupPromise = (async () => {
      let escalation: ReturnType<typeof setTimeout> | undefined;
      await Promise.race([this.exitPromise, new Promise<void>(resolve => { escalation = setTimeout(resolve, 500); })]);
      if (escalation) clearTimeout(escalation);
      // A descendant may outlive a group leader that has already exited.
      this.signal('SIGKILL'); await this.exitPromise;
    })();
  }
  private receive(chunk: Buffer): void {
    if (this.closed) return;
    this.buffer = Buffer.concat([this.buffer, chunk]);
    while (true) {
      const newline = this.buffer.indexOf(10);
      if (newline < 0) { if (this.buffer.length > FRAME_LIMIT) this.stop('output_limit'); return; }
      if (newline > FRAME_LIMIT) { this.stop('output_limit'); return; }
      const line = this.buffer.subarray(0,newline); this.buffer = this.buffer.subarray(newline+1);
      let value: { id?: unknown; result?: Json; error?: unknown; event?: unknown };
      try { value = JSON.parse(new TextDecoder('utf-8', { fatal:true }).decode(line)); }
      catch { this.stop('protocol_error'); return; }
      if (!value || typeof value !== 'object') { this.stop('protocol_error'); return; }
      if (value.event === 'data.changed' && value.id === undefined) continue;
      if (typeof value.id !== 'number' || !this.pending.has(value.id) ||
        (('result' in value) === ('error' in value))) { this.stop('protocol_error'); return; }
      const item = this.pending.get(value.id)!; this.pending.delete(value.id);
      clearTimeout(item.timer); item.cleanup();
      if ('error' in value) item.reject(new VelaError('rpc_error', value.id, item.mutating));
      else item.resolve(value.result!);
    }
  }
  private request<T>(method: string, params: ObjectValue, mutating: boolean, options: RequestOptions = {}): Promise<T> {
    if (this.closed) return Promise.reject(new VelaError('closed'));
    if (this.pending.size >= 32) return Promise.reject(new VelaError('busy'));
    let duration: number; let payload: string;
    const id = ++this.sequence;
    try {
      exactKeys(options, ['timeoutMs','signal']); duration = timeout(options.timeoutMs, this.defaultTimeout);
      payload = JSON.stringify({ id, method, params });
      if (Buffer.byteLength(payload) > FRAME_LIMIT) throw new VelaError('invalid_input');
    } catch { return Promise.reject(new VelaError('invalid_input', id)); }
    if (options.signal?.aborted) return Promise.reject(new VelaError('cancelled', id));
    return new Promise<T>((resolve,reject) => {
      const onAbort = () => this.stop('cancelled', id);
      const timer = setTimeout(() => this.stop('timeout', id),duration);
      this.pending.set(id, { resolve: value => resolve(value as T), reject, timer, mutating,
        cleanup: () => options.signal?.removeEventListener('abort', onAbort) });
      options.signal?.addEventListener('abort', onAbort, { once:true });
      this.child.stdin.write(payload + '\n');
    });
  }
  private selected(project?: string): string { return absolute(project ?? this.project); }
  listProjects(options?: RequestOptions): Promise<ObjectValue[]> { return this.request('projects.list', {}, false, options); }
  registerProject(path: string, options?: RequestOptions): Promise<ObjectValue> { return this.request('projects.add', {path:absolute(path)}, true, options); }
  listMemories(project?: string, options?: RequestOptions): Promise<MemoryRecord[]> { return this.request('memory.list', {project:this.selected(project)}, false, options); }
  recall(query: string, parameters: RecallParameters = {}, options?: RequestOptions): Promise<RecallResult> {
    exactKeys(parameters, ['project','budget','retrievalMode','language','limit','minSimilarity','scoringWeights','branch','worktree','task','sessionId']);
    if (typeof query !== 'string' || !query.trim() || Buffer.byteLength(query) > 16 * 1024) throw new VelaError('invalid_input');
    numeric(parameters.budget,0,4000,true); numeric(parameters.limit,1,100,true); numeric(parameters.minSimilarity,0,1); language(parameters.language);
    if (parameters.retrievalMode !== undefined && !['lexical','semantic','hybrid'].includes(parameters.retrievalMode)) throw new VelaError('invalid_input');
    for (const key of ['branch','worktree','task','sessionId'] as const) if (parameters[key] !== undefined && typeof parameters[key] !== 'string') throw new VelaError('invalid_input');
    if (parameters.scoringWeights !== undefined) {
      const weights = parameters.scoringWeights; exactKeys(weights,['semantic','recency','importance','recencyHalfLifeDays']);
      numeric(weights.semantic,0,10); numeric(weights.recency,0,10); numeric(weights.importance,0,10); numeric(weights.recencyHalfLifeDays,0.01,3650);
      if ((weights.semantic ?? 1) + (weights.recency ?? 0) + (weights.importance ?? 0) <= 0) throw new VelaError('invalid_input');
    }
    return this.request('recall', { ...parameters, scoringWeights: parameters.scoringWeights === undefined ? undefined : {...parameters.scoringWeights}, query, project:this.selected(parameters.project)} as ObjectValue, false, options);
  }
  semanticStatus(parameters: Pick<SemanticIndexParameters,'project' | 'language'> = {}, options?: RequestOptions): Promise<SemanticStatus> {
    exactKeys(parameters,['project','language']); language(parameters.language);
    return this.request('memory.semantic.status', {...parameters,project:this.selected(parameters.project)},false,options);
  }
  semanticIndex(parameters: SemanticIndexParameters = {}, options?: RequestOptions): Promise<SemanticIndexResult> {
    exactKeys(parameters,['project','language','batchSize','cursor']); language(parameters.language); numeric(parameters.batchSize,1,200,true);
    if (parameters.cursor !== undefined && (typeof parameters.cursor !== 'string' || parameters.cursor.length > 4096)) throw new VelaError('invalid_input');
    return this.request('memory.semantic.index',{...parameters,project:this.selected(parameters.project)},true,options);
  }
  saveCandidate(input: CandidateInput, options?: RequestOptions): Promise<MemoryRecord> {
    candidate(input);
    return this.request('memory.save', {title:input.title, content:input.content, type:input.type ?? 'fact', project:this.selected(input.project), scope:'project', state:'candidate'}, true, options);
  }
  async saveCandidates(inputs: CandidateInput[], options?: RequestOptions): Promise<MemoryRecord[]> {
    if (!Array.isArray(inputs) || inputs.length < 1 || inputs.length > 100) throw new VelaError('invalid_input');
    inputs.forEach(input => { candidate(input); this.selected(input.project); });
    const completed: MemoryRecord[] = [];
    for (let index = 0; index < inputs.length; index++) {
      try { completed.push(await this.saveCandidate(inputs[index]!, options)); }
      catch (error) { throw new VelaBulkError(completed,index,inputs.length,error instanceof VelaError ? error : new VelaError('transport_closed',null,true)); }
    }
    return completed;
  }
  exportArchive(project?: string, ids?: string[], options?: RequestOptions): Promise<ArchiveExport> {
    return this.request('memory.archive.export', {project:this.selected(project), ...(ids === undefined ? {} : {ids})}, false, options);
  }
  validateArchive(archive: ObjectValue, options?: RequestOptions): Promise<ObjectValue> { return this.request('memory.archive.validate', {archive}, false, options); }
  archiveFromWalrusRecords(source: ObjectValue, records: ObjectValue[], options?: RequestOptions): Promise<ArchiveExport> {
    return this.request('memory.archive.fromWalrusRecords', {source, records, intendedUse:'candidate-review'}, false, options);
  }
  captureIntegration(namespace:string, sourceID:string, records:ObjectValue[], project?:string, options?:RequestOptions):Promise<ObjectValue>{
    return this.request('memory.integration.capture',{project:this.selected(project),namespace,integration:'openclaw',sourceID,records},true,options);
  }
  recallIntegration(namespace:string,query:string,parameters:IntegrationRecallParameters={},options?:RequestOptions):Promise<RecallResult>{
    return this.request('memory.integration.recall',{...parameters,project:this.selected(parameters.project),namespace,query} as ObjectValue,false,options);
  }
  integrationStats(namespace:string,project?:string,options?:RequestOptions):Promise<ObjectValue>{
    return this.request('memory.integration.stats',{project:this.selected(project),namespace},false,options);
  }
  importArchive(archive: ObjectValue, project?: string, options?: RequestOptions): Promise<ArchiveImport> {
    return this.request('memory.archive.import', {archive, project:this.selected(project)}, true, options);
  }
  /** Terminates the owned helper/group. Pending mutations may already have taken effect. */
  async close(): Promise<void> { this.stop('closed'); await this.cleanupPromise; }
}
