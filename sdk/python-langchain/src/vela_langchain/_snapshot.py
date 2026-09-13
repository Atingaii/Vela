"""Optional exact ChatOpenAI adapter using public copy/binding methods only."""
from __future__ import annotations
from copy import deepcopy
from importlib.metadata import version, PackageNotFoundError
import json
from typing import Any
from langchain_core.runnables import Runnable, RunnableBinding
from ._common import MemoryBinding, VelaLangChainError, normalized_url

PROTECTED = {'model','model_name','base_url','api_key','client','async_client','root_client','root_async_client','input','messages','extra_body','stream','timeout','use_responses_api','use_previous_response_id'}


def json_copy(value: Any) -> Any:
    try:
        encoded=json.dumps(value,ensure_ascii=False,allow_nan=False)
        if len(encoded.encode())>2*1024*1024:raise ValueError()
        return json.loads(encoded)
    except Exception:
        raise VelaLangChainError('unsupported_operation') from None


def config_copy(value: Any) -> dict[str, Any] | None:
    if value is None:return None
    if not isinstance(value,dict) or value.get('configurable'):raise VelaLangChainError('unsupported_operation')
    try:
        # Callback objects may contain locks. Their containing list is frozen;
        # callbacks themselves remain explicitly application-owned code.
        return {key:(list(item) if isinstance(item,list) else item) if key=='callbacks' else deepcopy(item) for key,item in value.items()}
    except Exception:raise VelaLangChainError('unsupported_operation') from None


def options_copy(options: dict[str, Any]) -> dict[str, Any]:
    if set(options)&PROTECTED:raise VelaLangChainError('unsupported_operation')
    result=json_copy({k:v for k,v in options.items() if k!='config'})
    if 'config' in options:result['config']=config_copy(options['config'])
    return result


def provider_types() -> tuple[Any, Any, Any]:
    try:
        if version('langchain-core')!='1.6.3' or version('langchain-openai')!='1.6.2' or version('openai')!='3.13.0':raise ValueError()
        from langchain_openai import ChatOpenAI
        from openai import OpenAI, AsyncOpenAI
        return ChatOpenAI,OpenAI,AsyncOpenAI
    except (ImportError,PackageNotFoundError,ValueError):
        raise VelaLangChainError('install_pinned_openai_extra') from None


def unwrap(model: Any) -> tuple[Any, list[tuple[dict[str,Any],dict[str,Any]|None]]]:
    ChatOpenAI,_,_=provider_types();layers=[]
    for _ in range(8):
        if type(model) is ChatOpenAI:return model,layers
        if not isinstance(model,RunnableBinding) or model.config_factories or model.custom_input_type is not None or model.custom_output_type is not None:
            raise VelaLangChainError('unsupported_runnable')
        if set(model.kwargs)&PROTECTED:raise VelaLangChainError('recipient_mismatch')
        layers.append((json_copy(model.kwargs),config_copy(model.config)))
        model=model.bound
    raise VelaLangChainError('unsupported_runnable')


def fixed_defaults(client: Any, headers: dict[str, Any], query: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    """Check public root configuration without extracting private custom mappings."""
    from openai import Omit
    def normalized(values: Any) -> dict[str, str]:
        result={}
        for key,value in values.items():
            if isinstance(value,Omit):continue
            if not isinstance(key,str) or not isinstance(value,str):raise VelaLangChainError('unsupported_provider_defaults')
            result[key.lower()]=value
        return result
    # Public copy with empty custom fields reveals the SDK-generated defaults.
    # A callable credential provider is retained, not invoked or materialized.
    baseline=client.with_options(set_default_headers={},set_default_query={})
    expected=normalized(baseline.default_headers);expected.update(normalized(headers))
    actual=normalized(client.default_headers)
    if 'authorization' not in normalized(headers):
        generated=normalized(client.auth_headers)
        if actual.get('authorization')==generated.get('authorization'):
            actual.pop('authorization',None)
        expected.pop('authorization',None)
    if actual!=expected or dict(client.default_query)!=query:
        raise VelaLangChainError('provider_configuration_mismatch')
    return deepcopy(headers),deepcopy(query)


def snapshot(model: Runnable, binding: MemoryBinding, timeout: float, *, asynchronous_api: bool = False) -> Runnable:
    original,layers=unwrap(model);_,OpenAI,AsyncOpenAI=provider_types()
    sync,asynchronous=original.root_client,original.root_async_client
    for client,resource,kind in [(sync,original.client,OpenAI),(asynchronous,original.async_client,AsyncOpenAI)]:
        if client is None:
            if resource is not None:raise VelaLangChainError('unsupported_provider_client')
        elif type(client) is not kind or resource is not client.chat.completions:
            raise VelaLangChainError('unsupported_provider_client')
    if (asynchronous if asynchronous_api else sync) is None:
        raise VelaLangChainError('unsupported_provider_client')
    if original.model_name!=binding.model or any(normalized_url(str(client.base_url))!=binding.base_url for client in [sync,asynchronous] if client is not None):
        raise VelaLangChainError('recipient_mismatch')
    if original.use_responses_api is True or original.use_previous_response_id or original.n not in {None,1} or original.extra_body or set(original.model_kwargs)&PROTECTED:
        raise VelaLangChainError('unsupported_operation')
    if original.context_management or original.include or original.truncation:
        raise VelaLangChainError('unsupported_operation')
    # Copy only ordinary public settings. Never deepcopy HTTP transports, callbacks,
    # rate limiters or caches; their resource ownership remains with the application.
    updates={name:deepcopy(value) for name in type(original).model_fields for value in [getattr(original,name)] if isinstance(value,(dict,list,set)) and name not in {'callbacks'}}
    headers=json_copy(dict(original.default_headers or {}));query=json_copy(dict(original.default_query or {}))
    def client_copy(client: Any) -> Any:
        if client is None:return None
        frozen_headers,frozen_query=fixed_defaults(client,headers,query)
        result=client.with_options(base_url=binding.base_url,timeout=timeout,max_retries=client.max_retries,set_default_headers=frozen_headers,set_default_query=frozen_query)
        if normalized_url(str(result.base_url))!=binding.base_url:raise VelaLangChainError('recipient_mismatch')
        return result
    frozen_sync,frozen_async=client_copy(sync),client_copy(asynchronous)
    updates.update(default_headers=headers,default_query=query,n=1,model_name=binding.model,openai_api_base=binding.base_url,request_timeout=timeout,use_responses_api=False,use_previous_response_id=False,
        root_client=frozen_sync,root_async_client=frozen_async,client=frozen_sync.chat.completions if frozen_sync is not None else None,async_client=frozen_async.chat.completions if frozen_async is not None else None)
    if isinstance(original.callbacks,list):updates['callbacks']=list(original.callbacks)
    prepared=original.model_copy(update=updates)
    for kwargs,config in reversed(layers):prepared=RunnableBinding(bound=prepared,kwargs=kwargs,config=config or {})
    return prepared
