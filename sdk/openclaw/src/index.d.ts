import type {OpenClawPluginDefinition,OpenClawPluginApi} from 'openclaw/plugin-sdk/plugin-entry';
export interface VelaOpenClawConfig {
 version:1; backend:'local'|'walrus'; stateDirectory:string;
 agents:Record<string,{project:string;namespace:string}>;
 helper?:string;home?:string; remote?:{profile:Record<string,unknown>;delegateKeyHex:string;suiPrivateKey?:string;embeddingApiKey?:string};
 autoRecall?:boolean;autoCapture?:boolean;captureAssistant?:boolean;remotePlaintextAcknowledged?:boolean;
 maxRecallResults?:number;maxDistance?:number;maxContextBytes?:number;captureMaxMessages?:number;requestTimeoutMs?:number;
 maxCaptureOperations:number;maxCaptureBytes:number;
}
export declare function registerVelaMemory(api:OpenClawPluginApi):void;
declare const plugin:OpenClawPluginDefinition;
export default plugin;
