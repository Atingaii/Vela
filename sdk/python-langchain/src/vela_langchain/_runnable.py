"""Public Runnable composition. No provider subclasses or method replacement."""
from __future__ import annotations

import asyncio
import threading
from typing import Any, AsyncIterator, Iterator
from langchain_core.messages import AIMessage, AIMessageChunk
from langchain_core.runnables import Runnable, RunnableConfig
from ._common import MemoryBinding, MemoryReceipt, VelaLangChainError
from ._snapshot import unwrap
from ._sync import VelaChatModel as _SyncManager
from ._async import AsyncVelaChatModel as _AsyncManager


class VelaLangChain:
    def __init__(self, model: Runnable, binding: MemoryBinding):
        unwrap(model)
        self._sync = _SyncManager(model, binding)
        self._async = _AsyncManager(model, binding)
        self._closed = False
        self._async_loop: asyncio.AbstractEventLoop | None = None
        self._lock = threading.RLock()
        self._turns: set[MemoryRunnable] = set()

    def for_turn(self, *, session_id: str, turn_id: str, timeout: float = 120,
                 cancel_event: threading.Event | None = None) -> MemoryRunnable:
        with self._lock:
            if self._closed:
                raise VelaLangChainError('closed')
            sync = self._sync.for_turn(session_id=session_id, turn_id=turn_id, timeout=timeout, cancel_event=cancel_event)
            try:
                asynchronous = self._async.for_turn(session_id=session_id, turn_id=turn_id, timeout=timeout)
            except BaseException:
                sync.close()
                raise
            turn = MemoryRunnable(self, sync, asynchronous)
            self._turns.add(turn)
            return turn

    def close(self) -> None:
        with self._lock:
            self._closed = True
            turns = list(self._turns)
        for turn in turns:
            turn.close()

    async def aclose(self) -> None:
        with self._lock:
            self._closed = True
            turns = list(self._turns)
        await asyncio.gather(*(turn.aclose() for turn in turns))

    def __enter__(self) -> VelaLangChain:
        return self

    def __exit__(self, *args: Any) -> None:
        self.close()

    async def __aenter__(self) -> VelaLangChain:
        return self

    async def __aexit__(self, *args: Any) -> None:
        await self.aclose()


class MemoryRunnable(Runnable[Any, AIMessage]):
    """One explicit turn: concurrent calls reject; separate turns can run concurrently."""
    def __init__(self, manager: VelaLangChain, synchronous: Any, asynchronous: Any):
        self._manager, self._sync, self._async = manager, synchronous, asynchronous
        self._lock = threading.RLock()
        self._active = False
        self._latest = self._sync
        self._closed = False
        self._loop: asyncio.AbstractEventLoop | None = None
        self._closing_task: asyncio.Task[Any] | None = None

    def _enter(self, asynchronous: bool) -> None:
        with self._lock:
            if self._closed or self._manager._closed:
                raise VelaLangChainError('closed')
            if self._active:
                raise VelaLangChainError('busy')
            if asynchronous:
                loop = asyncio.get_running_loop()
                with self._manager._lock:
                    prior = self._manager._async_loop
                    if prior is not None and prior is not loop and not prior.is_closed():
                        raise VelaLangChainError('event_loop_mismatch')
                    self._manager._async_loop = loop
            self._active = True
            selected = self._async if asynchronous else self._sync
            for key in ["model_calls", "attempts"]:
                selected._latest.report[key] = self._latest._latest.report[key]
            self._latest = selected
            if asynchronous:
                self._loop = asyncio.get_running_loop()

    def _leave(self) -> None:
        with self._lock:
            self._active = False
            if self._closed:
                with self._manager._lock:
                    self._manager._turns.discard(self)

    def invoke(self, input: Any, config: RunnableConfig | None = None, **kwargs: Any) -> AIMessage:
        self._enter(False)
        try:
            return self._sync.create(input=input, config=config, **kwargs)
        finally:
            self._leave()

    async def ainvoke(self, input: Any, config: RunnableConfig | None = None, **kwargs: Any) -> AIMessage:
        self._enter(True)
        try:
            return await self._async.create(input=input, config=config, **kwargs)
        finally:
            self._leave()

    def stream(self, input: Any, config: RunnableConfig | None = None, **kwargs: Any) -> Iterator[AIMessageChunk]:
        self._enter(False)
        try:
            with self._sync.stream(input=input, config=config, **kwargs) as stream:
                yield from stream
        finally:
            self._leave()

    async def astream(self, input: Any, config: RunnableConfig | None = None, **kwargs: Any) -> AsyncIterator[AIMessageChunk]:
        self._enter(True)
        try:
            async with await self._async.stream(input=input, config=config, **kwargs) as stream:
                async for chunk in stream:
                    yield chunk
        finally:
            self._leave()

    def batch(self, inputs: Any, config: Any = None, **kwargs: Any) -> Any:
        raise VelaLangChainError('distinct_turns_required')

    async def abatch(self, inputs: Any, config: Any = None, **kwargs: Any) -> Any:
        raise VelaLangChainError('distinct_turns_required')

    def batch_as_completed(self, inputs: Any, config: Any = None, **kwargs: Any) -> Any:
        raise VelaLangChainError('distinct_turns_required')

    async def abatch_as_completed(self, inputs: Any, config: Any = None, **kwargs: Any) -> AsyncIterator[Any]:
        raise VelaLangChainError('distinct_turns_required')
        yield  # Retain the public async-iterator shape without dispatching an item.

    def receipt(self) -> MemoryReceipt:
        return self._latest.receipt()

    def settled(self, timeout: float | None = None) -> MemoryReceipt:
        if self._latest is self._async:
            raise VelaLangChainError('use_asettled')
        return self._sync.settled(timeout)

    async def asettled(self, timeout: float | None = None) -> MemoryReceipt:
        if self._latest is self._sync:
            return await asyncio.to_thread(self._sync.settled, timeout)
        return await self._async.settled(timeout)

    def _schedule_async_close(self) -> asyncio.Task[Any]:
        if self._closing_task is None:
            self._closing_task = asyncio.create_task(self._async.close())
        return self._closing_task

    def close(self) -> None:
        """Signal close. For async work, aclose/asettled await final cleanup."""
        with self._lock:
            self._closed = True
            self._sync.close()
            self._async._closed = True
            if self._loop is not None and not self._loop.is_closed():
                self._loop.call_soon_threadsafe(self._schedule_async_close)
            else:
                self._async._manager._turns.discard(self._async)
            # Keep in-flight turns reachable by a subsequent manager.aclose().
            if not self._active:
                with self._manager._lock:
                    self._manager._turns.discard(self)

    async def aclose(self) -> None:
        if self._loop is not None and self._loop is not asyncio.get_running_loop() and not self._loop.is_closed():
            raise VelaLangChainError('event_loop_mismatch')
        self.close()
        await asyncio.shield(self._schedule_async_close())
        if self._sync._active is not None:
            await asyncio.to_thread(self._sync.settled)
        with self._manager._lock:
            self._manager._turns.discard(self)

    def __enter__(self) -> MemoryRunnable:
        return self

    def __exit__(self, *args: Any) -> None:
        self.close()

    async def __aenter__(self) -> MemoryRunnable:
        return self

    async def __aexit__(self, *args: Any) -> None:
        await self.aclose()
