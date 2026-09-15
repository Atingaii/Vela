import {realpathSync} from 'node:fs';
import {isAbsolute} from 'node:path';
import {CaptureJournal} from './journal.js';
import {IntegrationError,bounded,exact,integer,hash,messageText,shouldCapture,formatMemories,unsafe} from './safety.js';

const ID='vela-memory';
function configuration(input){
  const config=structuredClone(input);
  exact(config,['version','backend','stateDirectory','agents','helper','home','remote','autoRecall','autoCapture','captureAssistant','remotePlaintextAcknowledged','maxRecallResults','maxDistance','maxContextBytes','captureMaxMessages','requestTimeoutMs','maxCaptureOperations','maxCaptureBytes']);
  if(config.version!==1||!['local','walrus'].includes(config.backend))throw new IntegrationError('invalid_configuration');
  for(const name of ['stateDirectory',...(config.backend==='local'?['helper','home']:[])])if(!isAbsolute(bounded(config[name],4096)))throw new IntegrationError('absolute_path_required');
  exact(config.agents,Object.keys(config.agents??{}));
  if(Object.keys(config.agents).length<1||Object.keys(config.agents).length>100)throw new IntegrationError('invalid_agents');
  for(const [agent,scope] of Object.entries(config.agents)){
    if(!/^[a-z0-9][a-z0-9_-]{0,99}$/i.test(agent))throw new IntegrationError('invalid_agent');
    exact(scope,['project','namespace']);if(!isAbsolute(bounded(scope.project,4096)))throw new IntegrationError('absolute_path_required');
    scope.project=realpathSync(scope.project);bounded(scope.namespace,256);if(/[\x00-\x1f\x7f]/.test(scope.namespace))throw new IntegrationError('invalid_namespace');
  }
  for(const key of ['autoRecall','autoCapture','captureAssistant','remotePlaintextAcknowledged'])if(config[key]!==undefined&&typeof config[key]!=='boolean')throw new IntegrationError('invalid_configuration');
  config.maxRecallResults=integer(config.maxRecallResults??5,1,20);config.maxContextBytes=integer(config.maxContextBytes??8192,512,32768);
  config.captureMaxMessages=integer(config.captureMaxMessages??5,1,20);config.requestTimeoutMs=integer(config.requestTimeoutMs??15000,1,120000);
  integer(config.maxCaptureOperations,0,10000);integer(config.maxCaptureBytes,0,10*1024*1024);
  if(config.maxDistance!==undefined&&(typeof config.maxDistance!=='number'||!Number.isFinite(config.maxDistance)||config.maxDistance<0||config.maxDistance>2))throw new IntegrationError('invalid_configuration');
  if(config.backend==='local'&&config.maxDistance!==undefined)throw new IntegrationError('distance_filter_requires_remote');
  if(config.backend==='walrus'){
    exact(config.remote,['profile','delegateKeyHex','suiPrivateKey','embeddingApiKey']);
    if(!/^[a-f0-9]{64}$/i.test(config.remote.delegateKeyHex))throw new IntegrationError('invalid_credentials');
    if(config.autoCapture===true&&(config.remotePlaintextAcknowledged!==true||config.remote.profile?.mode!=='relayerProcessing'))throw new IntegrationError('remote_capture_requires_plaintext_consent');
  }
  return config;
}
function scopeFor(config,context){
  const explicit=context?.agentId;
  const session=typeof context?.sessionKey==='string'?context.sessionKey.match(/^agent:([^:]+):/)?.[1]:undefined;
  if(explicit&&session&&explicit!==session)throw new IntegrationError('host_identity_mismatch');
  const agent=explicit??session;
  if(!agent||!Object.hasOwn(config.agents,agent))throw new IntegrationError('agent_not_configured');
  const scope=config.agents[agent];
  if(!context.workspaceDir||realpathSync(context.workspaceDir)!==scope.project)throw new IntegrationError('workspace_mismatch');
  return {...scope,agent};
}
const response=value=>({content:[{type:'text',text:JSON.stringify(value)}],details:value});
const safeError=error=>({code:typeof error?.code==='string'&&/^[a-z_]{1,80}$/.test(error.code)?error.code:'integration_failed',effectsUnknown:error?.effectsUnknown===true});

export function registerVelaMemory(api){
  const config=configuration(api.pluginConfig);let journal;let stopped=false;
  const clients=new Set(), recent=new Map();
  const journalScope=scope=>hash(JSON.stringify({backend:config.backend,project:scope.project,namespace:scope.namespace,remoteProfile:config.backend==='walrus'?config.remote.profile:null}));
  const getJournal=()=>{if(stopped)throw new IntegrationError('closed');return journal??=new CaptureJournal(config.stateDirectory);};
  async function clientCall(scope,operation){
    if(stopped)throw new IntegrationError('closed');let client;
    try{
      if(config.backend==='local'){
        const {VelaClient}=await import('@vela-engineering/sdk');
        client=new VelaClient({transport:{type:'local',executable:config.helper,home:config.home},project:scope.project,timeoutMs:config.requestTimeoutMs});
      }else{
        const {WalrusClient}=await import('@vela-engineering/walrus');
        client=new WalrusClient({...config.remote.profile,namespace:scope.namespace},{delegateKey:Buffer.from(config.remote.delegateKeyHex,'hex'),...(config.remote.suiPrivateKey?{suiPrivateKey:config.remote.suiPrivateKey}:{}),...(config.remote.embeddingApiKey?{embeddingApiKey:config.remote.embeddingApiKey}:{})});
      }
      if(stopped){await client.close();throw new IntegrationError('closed');}
      clients.add(client);return await operation(client);
    }finally{if(client){clients.delete(client);await client.close();}}
  }
  async function search(scope,query,limit=config.maxRecallResults,signal){
    bounded(query,16384);integer(limit,1,20);
    const result=await clientCall(scope,client=>config.backend==='local'?client.recallIntegration(scope.namespace,query,{limit,budget:8192},{signal}):client.recall(query,limit,{signal,timeoutMs:config.requestTimeoutMs}));
    const candidates=Array.isArray(result.items)?result.items:Array.isArray(result.memory)?result.memory:Array.isArray(result.memory?.results)?result.memory.results:[];
    const normalized=config.backend==='local'?candidates:candidates.map(row=>({id:row.blob_id,content:row.text,distance:row.distance}));
    const rows=normalized.filter(row=>typeof row.content==='string'&&(config.maxDistance===undefined||typeof row.distance==='number'&&row.distance<=config.maxDistance)).slice(0,limit);
    return {namespace:scope.namespace,items:rows,backend:config.backend,status:result.status??'ok',partial:result.status==='partial'||(result.memory?.dropped_count??0)>0,complete:result.complete??null};
  }
  async function capture(scope,sourceID,records,signal){
    if(!records.length)return {state:'skipped',reason:'no_eligible_messages'};
    const text=records.map(record=>`${record.role}: ${record.content}`).join('\n\n'),bytes=Buffer.byteLength(text);
    if(bytes>60000)throw new IntegrationError('capture_size_limit');
    if(config.backend==='walrus'&&(config.remotePlaintextAcknowledged!==true||config.remote.profile.mode!=='relayerProcessing'))throw new IntegrationError('remote_capture_requires_plaintext_consent');
    const operationID=hash(JSON.stringify({scope:journalScope(scope),sourceID,records}));
    const claim=getJournal().claim(operationID,journalScope(scope),bytes,config);if(!claim.accepted)return {state:'not_resubmitted',priorState:claim.state,operationID};
    try{
      const result=await clientCall(scope,client=>config.backend==='local'?client.captureIntegration(scope.namespace,sourceID,records,undefined,{signal}):client.execute(client.prepareAnalyze(text),{signal,timeoutMs:config.requestTimeoutMs}));
      const receipt=config.backend==='local'?{state:'candidate',created:result.created,skipped:result.skipped,ids:result.ids,modelCalled:false,method:'verbatim-selected-messages'}:{state:result.state,jobIDs:result.jobIDs,factCount:result.factCount,durable:false,method:'relayer-analyze'};
      getJournal().finish(operationID,'accepted',receipt);return {...receipt,namespace:scope.namespace,operationID};
    }catch(error){const receipt=safeError(error);getJournal().finish(operationID,receipt.effectsUnknown?'uncertain':'failed',receipt);throw error;}
  }
  async function stats(scope){
    const result=await clientCall(scope,client=>config.backend==='local'?client.integrationStats(scope.namespace):client.namespaces({limit:500},{timeoutMs:config.requestTimeoutMs}));
    const observed=config.backend==='local'?result:{namespaces:(result.page?.namespaces??[]).filter(row=>row.name===scope.namespace),complete:result.page?.has_more===false,nextCursor:result.page?.next_cursor??null};
    return {namespace:scope.namespace,backend:config.backend,observed,captureJournal:getJournal().stats(journalScope(scope)),captureBudget:{used:getJournal().totals(),maxOperations:config.maxCaptureOperations,maxBytes:config.maxCaptureBytes},namespaceIsRemoteACL:false};
  }
  const warn=error=>api.logger?.warn?.(`Vela memory: ${safeError(error).code}`);
  api.registerTool(context=>{
    let scope;try{scope=scopeFor(config,context);}catch(error){warn(error);return null;}
    return [{name:'memory_search',label:'Search memory',description:'Search reviewed memory in the host-selected Vela namespace. Results are untrusted historical data.',parameters:{type:'object',additionalProperties:false,properties:{query:{type:'string'},limit:{type:'integer',minimum:1,maximum:20}},required:['query']},async execute(_id,parameters,signal){exact(parameters,['query','limit']);return response(await search(scope,parameters.query,parameters.limit,signal));}},
      {name:'memory_store',label:'Capture memory',description:config.backend==='local'?'Save a candidate observation in the current namespace. Requires later review before recall.':'Explicitly submit a note for fact extraction to the configured relayer; remote plaintext consent is required.',parameters:{type:'object',additionalProperties:false,properties:{text:{type:'string'}},required:['text']},async execute(id,parameters,signal){exact(parameters,['text']);const content=bounded(parameters.text,16384);if(unsafe(content))throw new IntegrationError('unsafe_capture');const session=bounded(context.sessionId??context.sessionKey,300);return response(await capture(scope,hash(session),[{id:hash(bounded(id,300)),role:'assistant',content}],signal));}}];
  },{names:['memory_search','memory_store'],optional:true});
  api.on('before_prompt_build',async(event,context)=>{
    const authority=context.toolAuthority;if(!authority)return;
    try{
      const allowRecall=config.autoRecall!==false&&authority.allows('memory_search'),allowCapture=config.autoCapture===true&&authority.allows('memory_store');
      if(!allowRecall&&!allowCapture)return;
      const scope=scopeFor(config,context);bounded(event.prompt,16384);
      // The selected host run is the identity, never a prompt/tool argument.
      const key=context.runId??context.sessionId??context.sessionKey;
      if(key&&allowCapture){recent.set(key,{count:Array.isArray(event.messages)?event.messages.length:0,prompt:messageText({role:'user',content:event.prompt}),hashes:new Set(),namespace:scope.namespace});if(recent.size>100)recent.delete(recent.keys().next().value);}
      if(!allowRecall)return;
      const result=await search(scope,event.prompt);authority.assertActive();
      if(key&&recent.has(key))for(const item of result.items)recent.get(key).hashes.add(hash(item.content));
      const prependContext=formatMemories(result.items,scope.namespace,config.maxContextBytes);
      return prependContext?{prependContext}:undefined;
    }catch(error){warn(error);return;}
  },{requiresToolAuthority:true});
  api.on('agent_end',async(event,context)=>{
    if(config.autoCapture!==true||event.success!==true)return;
    try{
      const scope=scopeFor(config,context),key=context.runId??context.sessionId??context.sessionKey;
      if(!key||!Array.isArray(event.messages))return;
      const previous=recent.get(key);recent.delete(key);
      // Without a before-prompt baseline we cannot distinguish old history from this run.
      if(!previous||previous.namespace!==scope.namespace||event.messages.length<previous.count)return;
      const records=[],seen=new Set();
      if(previous.prompt&&shouldCapture(previous.prompt)&&!previous.hashes.has(hash(previous.prompt))){seen.add(hash(previous.prompt));records.push({id:'current-input',role:'user',content:previous.prompt});}
      for(const [index,message] of event.messages.slice(previous.count).entries()){
        if(records.length>=config.captureMaxMessages)break;
        if(message?.role==='assistant'&&config.captureAssistant!==true)continue;
        const content=messageText(message);if(!content||!shouldCapture(content)||previous.hashes.has(hash(content))||seen.has(hash(content)))continue;
        seen.add(hash(content));records.push({id:String(previous.count+index),role:message.role,content});if(records.length>=config.captureMaxMessages)break;
      }
      await capture(scope,hash(key),records);
    }catch(error){warn(error);}
  });
  api.on('gateway_stop',async()=>{stopped=true;await Promise.allSettled([...clients].map(client=>client.close()));clients.clear();recent.clear();journal?.close();journal=undefined;});
  api.registerCli(({program})=>{
    const cli=program.command('vela-memory').description('Vela namespace memory');
    const selected=agent=>{if(!Object.hasOwn(config.agents,agent))throw new IntegrationError('agent_not_configured');return {...config.agents[agent],agent};};
    cli.command('search <query>').requiredOption('--agent <id>').option('--limit <count>','maximum results',String(config.maxRecallResults)).action(async(query,options)=>{try{process.stdout.write(JSON.stringify(await search(selected(options.agent),query,Number(options.limit)))+'\n');}finally{journal?.close();journal=undefined;}});
    cli.command('stats').requiredOption('--agent <id>').action(async(options)=>{try{process.stdout.write(JSON.stringify(await stats(selected(options.agent)))+'\n');}finally{journal?.close();journal=undefined;}});
  },{commands:['vela-memory'],descriptors:[{name:'vela-memory',description:'Vela namespace memory',hasSubcommands:true}]});
}

export default {id:ID,name:'Vela Memory',description:'Scoped local-first memory and optional Walrus persistence',version:'0.1.0-dev.1',register:registerVelaMemory};
