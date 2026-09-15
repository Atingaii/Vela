"""Async Responses composition; cancellation retains per-operation uncertainty."""
from __future__ import annotations

import asyncio
from copy import deepcopy
from dataclasses import dataclass, field
import inspect
import time
from typing import Any, AsyncIterator
from langchain_core.runnables import Runnable
from langchain_core.messages import AIMessage, AIMessageChunk
import vela
from ._common import (INTEGRATION, MemoryBinding, MemoryReceipt, VelaLangChainError, append_frame, bounded_text,
                      capture_error, capture_result, check_capture_support, checked_items, duration, filter_end,
                      filter_start, frame_items, input_text, receipt, source_id, strip_frames, successful, output_flags)
from ._snapshot import options_copy, snapshot


@dataclass
class _Call:
    report: MemoryReceipt
    deadline: float
    done: asyncio.Event = field(default_factory=asyncio.Event)
    stopped: bool = False
    reason: str = "cancelled"
    timer: asyncio.TimerHandle | None = None
    helper: vela.AsyncVelaClient | None = None
    response: Any = None
    request_model: Any = None
    original: str | None = None
    model_finished: bool = False
    task: asyncio.Task[Any] | None = None
    finalization: asyncio.Task[None] | None = None
    cancellation: asyncio.Task[None] | None = None
    completed_event: bool = False
    failed_event: bool = False
    has_text: bool = False


class AsyncVelaChatModel:
    def __init__(self, client: Runnable, binding: MemoryBinding):
        if not isinstance(client, Runnable) or not isinstance(binding, MemoryBinding):
            raise VelaLangChainError("invalid_input")
        self._client, self._binding = client, binding.checked()
        self._closed = False
        self._turns: set[AsyncChatTurn] = set()

    def for_turn(self, *, session_id: str, turn_id: str, timeout: float = 120) -> AsyncChatTurn:
        if self._closed:
            raise VelaLangChainError("closed")
        if len(self._turns) >= 32:
            raise VelaLangChainError("busy")
        turn = AsyncChatTurn(self, bounded_text(session_id, 300), bounded_text(turn_id, 300), duration(timeout))
        self._turns.add(turn)
        return turn

    async def close(self) -> None:
        self._closed = True
        await asyncio.gather(*(turn.close() for turn in list(self._turns)))

    async def __aenter__(self) -> AsyncVelaChatModel:
        return self

    async def __aexit__(self, *args: Any) -> None:
        await self.close()


class AsyncChatTurn:
    def __init__(self, manager: AsyncVelaChatModel, session: str, turn: str, timeout: float):
        self._manager, self._binding = manager, manager._binding
        self._session, self._turn, self._timeout = session, turn, timeout
        self._closed = False
        self._active: _Call | None = None
        self._latest = _Call(receipt(self._binding, turn, 0), time.monotonic())

    def receipt(self) -> MemoryReceipt:
        return deepcopy(self._latest.report)

    async def settled(self, timeout: float | None = None) -> MemoryReceipt:
        call = self._latest
        try:
            await asyncio.wait_for(call.done.wait(), duration(timeout) if timeout is not None else None)
        except asyncio.TimeoutError:
            raise VelaLangChainError("timeout") from None
        return deepcopy(call.report)

    def _begin(self) -> _Call:
        if self._closed or self._manager._closed:
            raise VelaLangChainError("closed")
        if self._active:
            raise VelaLangChainError("busy")
        call = _Call(receipt(self._binding, self._turn, self._latest.report["model_calls"]), time.monotonic() + self._timeout)
        call.report["attempts"] = self._latest.report["attempts"] + 1
        self._active = self._latest = call
        call.task = asyncio.current_task()
        def expired() -> None:
            call.reason, call.stopped = "timeout", True
            if call.task and not call.task.done():
                call.task.cancel()
            else:
                call.cancellation = asyncio.create_task(self._finish(call, "finished" if call.model_finished else "cancelled"))
        call.timer = asyncio.get_running_loop().call_later(self._timeout, expired)
        return call

    def _guard(self, call: _Call) -> None:
        if time.monotonic() >= call.deadline:
            call.reason, call.stopped = "timeout", True
        if call.stopped or self._closed:
            raise VelaLangChainError(call.reason)

    def _remaining(self, call: _Call) -> float:
        self._guard(call)
        return max(0.001, min(self._binding.request_timeout, call.deadline - time.monotonic()))

    async def _release(self, call: _Call) -> None:
        response, helper = call.response, call.helper
        call.response = call.helper = None
        if response is not None:
            try:
                await asyncio.wait_for(response.aclose(), 1)
            except (Exception, asyncio.CancelledError):
                pass
        if helper is not None:
            await helper.close()

    async def _finish(self, call: _Call, state: str) -> None:
        if call.finalization is None:
            async def finish() -> None:
                if call.timer:
                    call.timer.cancel()
                await self._release(call)
                call.request_model = None
                call.report["generation"] = state
                if call.report["capture"]["state"] == "pending":
                    call.report["capture"].update(state="skipped", reason="generation_not_complete")
                call.done.set()
                if self._active is call:
                    self._active = None
            call.finalization = asyncio.create_task(finish())
        await asyncio.shield(call.finalization)

    def _helper(self, call: _Call) -> vela.AsyncVelaClient:
        self._guard(call)
        if call.helper is None:
            binding = self._binding
            call.helper = vela.AsyncVelaClient(vela.LocalTransport(binding.helper_path, binding.store_home), project=binding.project, timeout=self._remaining(call))
        return call.helper

    async def _filter(self, call: _Call, phase: str, value: str, item_id: str | None = None) -> str | None:
        self._guard(call)
        result = filter_start(value)
        if result is not None and self._binding.filter_text is not None:
            try:
                result = self._binding.filter_text(phase, result, {"phase": phase, **({"source_id": item_id} if item_id else {})})
                if inspect.isawaitable(result):
                    result = await result
            except asyncio.CancelledError:
                raise
            except Exception:
                raise VelaLangChainError("filter_failed") from None
        self._guard(call)
        return filter_end(result)

    async def _prepare(self, call: _Call, value: Any, options: dict[str, Any], streaming: bool) -> dict[str, Any]:
        self._guard(call)
        options = options_copy(options)
        call.request_model = snapshot(self._manager._client, self._binding, self._remaining(call), asynchronous_api=True)
        call.report["model_recipient"]["configured_endpoint_verified"] = True
        value, original, index = input_text(value)
        call.original = strip_frames(original) if original else None
        if self._binding.auto_capture:
            try:
                stats = await self._helper(call).integration_stats(self._binding.namespace, timeout=self._remaining(call))
            except Exception:
                self._guard(call)
                raise VelaLangChainError("memory_unavailable") from None
            check_capture_support(stats)
        if original is None:
            call.report["recall"].update(state="skipped", reason="no_user_text")
        else:
            try:
                query = await self._filter(call, "query", original)
                if query is None:
                    call.report["recall"].update(state="skipped", reason="query_filtered", filtered_count=1)
                else:
                    result = await self._helper(call).recall_integration(self._binding.namespace, query, budget=self._binding.budget, limit=self._binding.limit, timeout=self._remaining(call))
                    items = checked_items(result, self._binding, call.report)
                    selected = [(item["id"], await self._filter(call, "injection", item["content"], item["id"])) for item in items]
                    value = append_frame(value, index, frame_items(selected, self._binding, call.report))
            except Exception as error:
                self._guard(call)
                code = error.code if isinstance(error, VelaLangChainError) else "memory_failed"
                if code == "scope_mismatch" or self._binding.failure_policy != "continueWithoutMemory":
                    raise VelaLangChainError(code) from None
                call.report["recall"].update(state="degraded", reason=code, ids=[], used_bytes=0)
        await self._release(call)
        self._guard(call)
        options.update(input=value, timeout=self._remaining(call))
        return options

    async def _capture(self, call: _Call) -> None:
        if not self._binding.auto_capture or not call.original:
            return
        try:
            text = await self._filter(call, "capture", call.original)
            if text is None or len(text) < 30:
                call.report["capture"].update(state="skipped", reason="no_eligible_text")
                return
            result = await self._helper(call).capture_integration(self._binding.namespace, source_id(self._binding, self._session, self._turn, call.original),
                [{"id": "current-input", "role": "user", "title": "LangChain user input", "content": text}], integration=INTEGRATION, timeout=self._remaining(call))
            capture_result(result, call.report)
        except asyncio.CancelledError as error:
            capture_error(error, call.report, call.reason)
            raise
        except Exception as error:
            capture_error(error, call.report, call.reason if call.stopped else "capture_failed")
        finally:
            await asyncio.shield(self._release(call))

    async def create(self, *, input: Any, **options: Any) -> AIMessage:
        call = self._begin()
        try:
            prepared = await self._prepare(call, input, options, False)
            self._guard(call)
            call.report["model_calls"] += 1
            response = await call.request_model.ainvoke(**prepared)
            self._guard(call)
            call.model_finished = successful(response)
            if call.model_finished:
                await self._capture(call)
            await self._finish(call, "finished" if call.model_finished else "incomplete")
            return response
        except asyncio.CancelledError:
            call.stopped = True
            await self._finish(call, "finished" if call.model_finished else "cancelled")
            raise
        except Exception as error:
            await self._finish(call, "cancelled" if call.stopped else "failed")
            if isinstance(error, VelaLangChainError):
                raise
            raise VelaLangChainError(call.reason if call.stopped else "model_failed") from None
        finally:
            call.task = None

    async def stream(self, *, input: Any, **options: Any) -> AsyncChatMemoryStream:
        call = self._begin()
        try:
            prepared = await self._prepare(call, input, options, True)
            self._guard(call)
            call.report["model_calls"] += 1
            response = call.request_model.astream(**prepared)
            call.response = response
            self._guard(call)
            return AsyncChatMemoryStream(self, call, response)
        except asyncio.CancelledError:
            call.stopped = True
            await self._finish(call, "cancelled")
            raise
        except Exception as error:
            await self._finish(call, "cancelled" if call.stopped else "failed")
            if isinstance(error, VelaLangChainError):
                raise
            raise VelaLangChainError(call.reason if call.stopped else "model_failed") from None
        finally:
            call.task = None

    async def close(self) -> None:
        self._closed = True
        call = self._active
        if call:
            call.stopped = True
            operation = call.task
            if operation is not None and operation is not asyncio.current_task() and not operation.done():
                operation.cancel()
                try:
                    await asyncio.shield(operation)
                except (Exception, asyncio.CancelledError):
                    pass
            await self._finish(call, "finished" if call.model_finished else "cancelled")
        elif not self._latest.done.is_set():
            await self._finish(self._latest, "cancelled")
        self._manager._turns.discard(self)

    async def __aenter__(self) -> AsyncChatTurn:
        return self

    async def __aexit__(self, *args: Any) -> None:
        await self.close()


class AsyncChatMemoryStream(AsyncIterator[AIMessageChunk]):
    def __init__(self, turn: AsyncChatTurn, call: _Call, stream: Any):
        self._turn, self._call, self._stream = turn, call, stream
        self._iterator = stream.__aiter__()

    def __aiter__(self) -> AsyncChatMemoryStream:
        return self

    async def __anext__(self) -> AIMessageChunk:
        call, turn = self._call, self._turn
        if call.done.is_set():
            raise StopAsyncIteration
        if call.task is not None:
            raise VelaLangChainError("busy")
        call.task = asyncio.current_task()
        try:
            turn._guard(call)
            event = await self._iterator.__anext__()
            turn._guard(call)
            has_text, completed, failed = output_flags(event)
            call.has_text = call.has_text or has_text
            call.completed_event = call.completed_event or completed
            call.failed_event = call.failed_event or failed
            return event
        except StopAsyncIteration:
            call.model_finished = call.completed_event and call.has_text and not call.failed_event
            try:
                if call.model_finished:
                    await turn._capture(call)
            finally:
                await turn._finish(call, "finished" if call.model_finished else "incomplete")
            raise
        except asyncio.CancelledError:
            call.stopped = True
            await turn._finish(call, "finished" if call.model_finished else "cancelled")
            raise
        except Exception as error:
            await turn._finish(call, "cancelled" if call.stopped else "failed")
            if isinstance(error, VelaLangChainError):
                raise
            raise VelaLangChainError(call.reason if call.stopped else "model_failed") from None
        finally:
            call.task = None

    async def close(self) -> None:
        if not self._call.done.is_set():
            self._call.stopped = True
            task = self._call.task
            if task and task is not asyncio.current_task() and not task.done():
                task.cancel()
                try:
                    await asyncio.shield(task)
                except (Exception, asyncio.CancelledError):
                    pass
            await self._turn._finish(self._call, "finished" if self._call.model_finished else "cancelled")

    async def __aenter__(self) -> AsyncChatMemoryStream:
        return self

    async def __aexit__(self, *args: Any) -> None:
        await self.close()
