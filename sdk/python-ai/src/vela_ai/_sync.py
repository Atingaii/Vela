"""Synchronous public Responses wrapper with explicit stream ownership."""
from __future__ import annotations

from copy import deepcopy
from dataclasses import dataclass, field
import inspect
import threading
import time
from typing import Any, Iterator
from openai import OpenAI
from openai.types.responses import Response, ResponseStreamEvent
import vela
from ._common import (INTEGRATION, MemoryBinding, MemoryReceipt, VelaResponsesError, append_frame, bounded_text,
                      capture_error, capture_result, check_capture_support, checked_items, checked_options, duration, filter_end,
                      filter_start, frame_items, input_text, receipt, source_id, strip_frames, successful)


@dataclass
class _Call:
    report: MemoryReceipt
    deadline: float
    done: threading.Event = field(default_factory=threading.Event)
    stopped: threading.Event = field(default_factory=threading.Event)
    reason: str = "cancelled"
    timer: threading.Timer | None = None
    helper: vela.VelaClient | None = None
    response: Any = None
    request_client: Any = None
    original: str | None = None
    model_finished: bool = False
    operation_running: bool = True
    completed_event: bool = False
    failed_event: bool = False


class VelaResponses:
    def __init__(self, client: OpenAI, binding: MemoryBinding):
        if not isinstance(client, OpenAI) or not isinstance(binding, MemoryBinding):
            raise VelaResponsesError("invalid_input")
        self._client, self._binding = client, binding.checked()
        self._lock = threading.RLock()
        self._closed = False
        self._turns: set[ResponseTurn] = set()

    def for_turn(self, *, session_id: str, turn_id: str, timeout: float = 120, cancel_event: threading.Event | None = None) -> ResponseTurn:
        with self._lock:
            if self._closed:
                raise VelaResponsesError("closed")
            if len(self._turns) >= 32:
                raise VelaResponsesError("busy")
            if cancel_event is not None and not isinstance(cancel_event, threading.Event):
                raise VelaResponsesError("invalid_input")
            turn = ResponseTurn(self, bounded_text(session_id, 300), bounded_text(turn_id, 300), duration(timeout), cancel_event)
            self._turns.add(turn)
            return turn

    def close(self) -> None:
        with self._lock:
            self._closed = True
            turns = list(self._turns)
        for turn in turns:
            turn.close()

    def __enter__(self) -> VelaResponses:
        return self

    def __exit__(self, *args: Any) -> None:
        self.close()


class ResponseTurn:
    def __init__(self, manager: VelaResponses, session: str, turn: str, timeout: float, event: threading.Event | None):
        self._manager, self._binding = manager, manager._binding
        self._session, self._turn, self._timeout, self._event = session, turn, timeout, event
        self._lock = threading.RLock()
        self._closed = False
        self._active: _Call | None = None
        self._latest = _Call(receipt(self._binding, turn, 0), time.monotonic())

    def receipt(self) -> MemoryReceipt:
        with self._lock:
            return deepcopy(self._latest.report)

    def settled(self, timeout: float | None = None) -> MemoryReceipt:
        current = self._latest
        if timeout is not None:
            duration(timeout)
        if not current.done.wait(timeout):
            raise VelaResponsesError("timeout")
        return deepcopy(current.report)

    def _begin(self) -> _Call:
        with self._lock:
            if self._closed or self._manager._closed:
                raise VelaResponsesError("closed")
            if self._active:
                raise VelaResponsesError("busy")
            call = _Call(receipt(self._binding, self._turn, self._latest.report["model_calls"]), time.monotonic() + self._timeout)
            call.report["attempts"] = self._latest.report["attempts"] + 1
            self._active = self._latest = call
            call.timer = threading.Timer(self._timeout, lambda: self._cancel(call, "timeout"))
            call.timer.daemon = True
            call.timer.start()
            return call

    def _is_cancelled(self, call: _Call) -> bool:
        if self._event is not None and self._event.is_set():
            call.stopped.set()
        if time.monotonic() >= call.deadline:
            call.reason = "timeout"
            call.stopped.set()
        return call.stopped.is_set() or self._closed

    def _guard(self, call: _Call) -> None:
        if self._is_cancelled(call):
            raise VelaResponsesError(call.reason)

    def _remaining(self, call: _Call) -> float:
        self._guard(call)
        return max(0.001, min(self._binding.request_timeout, call.deadline - time.monotonic()))

    def _cancel(self, call: _Call, reason: str = "cancelled") -> None:
        call.reason = reason
        call.stopped.set()
        self._release(call)
        if not call.operation_running:
            self._finish(call, "finished" if call.model_finished else "cancelled")

    def _release(self, call: _Call) -> None:
        with self._lock:
            response, helper = call.response, call.helper
            call.response = call.helper = None
        if response is not None:
            try:
                response.close()
            except Exception:
                pass
        if helper is not None:
            helper.close()

    def _finish(self, call: _Call, state: str) -> None:
        with self._lock:
            if call.done.is_set():
                return
            if call.timer:
                call.timer.cancel()
        self._release(call)
        with self._lock:
            call.request_client = None
            call.report["generation"] = state
            if call.report["capture"]["state"] == "pending":
                call.report["capture"].update(state="skipped", reason="generation_not_complete")
            call.done.set()
            if self._active is call:
                self._active = None

    def _helper(self, call: _Call) -> vela.VelaClient:
        self._guard(call)
        if call.helper is None:
            binding = self._binding
            call.helper = vela.VelaClient(vela.LocalTransport(binding.helper_path, binding.store_home), project=binding.project, timeout=self._remaining(call))
        return call.helper

    def _filter(self, call: _Call, phase: str, value: str, item_id: str | None = None) -> str | None:
        self._guard(call)
        result = filter_start(value)
        if result is not None and self._binding.filter_text is not None:
            try:
                result = self._binding.filter_text(phase, result, {"phase": phase, **({"source_id": item_id} if item_id else {})})
                if inspect.isawaitable(result):
                    if inspect.iscoroutine(result):
                        result.close()
                    raise VelaResponsesError("filter_failed")
            except Exception:
                raise VelaResponsesError("filter_failed") from None
        self._guard(call)
        return filter_end(result)

    def _prepare(self, call: _Call, value: Any, options: dict[str, Any], streaming: bool) -> dict[str, Any]:
        self._guard(call)
        options = checked_options(self._binding, self._manager._client, options, streaming)
        # Public copy owns a frozen endpoint; it shares the application's HTTP
        # transport. Never close this client copy, which would close that transport.
        call.request_client = self._manager._client.with_options(base_url=self._binding.base_url, timeout=self._remaining(call), max_retries=self._manager._client.max_retries)
        checked_options(self._binding, call.request_client, options, streaming)
        call.report["model_recipient"]["configured_endpoint_verified"] = True
        value, original, index = input_text(value)
        call.original = strip_frames(original) if original else None
        if self._binding.auto_capture:
            stats = self._helper(call).integration_stats(self._binding.namespace, timeout=self._remaining(call))
            check_capture_support(stats)
        if original is None:
            call.report["recall"].update(state="skipped", reason="no_user_text")
        else:
            try:
                query = self._filter(call, "query", original)
                if query is None:
                    call.report["recall"].update(state="skipped", reason="query_filtered", filtered_count=1)
                else:
                    result = self._helper(call).recall_integration(self._binding.namespace, query, budget=self._binding.budget, limit=self._binding.limit, timeout=self._remaining(call))
                    items = checked_items(result, self._binding, call.report)
                    selected = [(item["id"], self._filter(call, "injection", item["content"], item["id"])) for item in items]
                    value = append_frame(value, index, frame_items(selected, self._binding, call.report))
            except Exception as error:
                self._guard(call)
                code = error.code if isinstance(error, VelaResponsesError) else "memory_failed"
                if code == "scope_mismatch" or self._binding.failure_policy != "continueWithoutMemory":
                    raise VelaResponsesError(code) from None
                call.report["recall"].update(state="degraded", reason=code, ids=[], used_bytes=0)
        self._release(call)
        self._guard(call)
        requested_timeout = options.pop("timeout", self._binding.request_timeout)
        options.update(input=value, timeout=min(duration(requested_timeout), self._remaining(call)))
        return options

    def _capture(self, call: _Call) -> None:
        if not self._binding.auto_capture or not call.original:
            return
        try:
            text = self._filter(call, "capture", call.original)
            if text is None or len(text) < 30:
                call.report["capture"].update(state="skipped", reason="no_eligible_text")
                return
            result = self._helper(call).capture_integration(self._binding.namespace, source_id(self._binding, self._session, self._turn, call.original),
                [{"id": "current-input", "role": "user", "title": "Responses user input", "content": text}], integration=INTEGRATION, timeout=self._remaining(call))
            capture_result(result, call.report)
        except Exception as error:
            capture_error(error, call.report, call.reason if call.stopped.is_set() else "capture_failed")
        finally:
            self._release(call)

    def create(self, *, input: Any, **options: Any) -> Response:
        call = self._begin()
        try:
            prepared = self._prepare(call, input, options, False)
            self._guard(call)
            call.report["model_calls"] += 1
            with call.request_client.responses.with_streaming_response.create(**prepared) as raw:
                call.response = raw
                self._guard(call)
                response = raw.parse()
                self._guard(call)
                call.response = None
            call.model_finished = successful(response)
            if call.model_finished:
                self._capture(call)
            self._finish(call, "finished" if call.model_finished else "incomplete")
            return response
        except Exception as error:
            self._finish(call, "cancelled" if self._is_cancelled(call) else "failed")
            if isinstance(error, VelaResponsesError):
                raise
            raise VelaResponsesError(call.reason if call.stopped.is_set() else "model_failed") from None
        finally:
            call.operation_running = False

    def stream(self, *, input: Any, **options: Any) -> ResponseMemoryStream:
        call = self._begin()
        try:
            prepared = self._prepare(call, input, options, True)
            self._guard(call)
            call.report["model_calls"] += 1
            response = call.request_client.responses.create(**prepared)
            call.response = response
            self._guard(call)
            return ResponseMemoryStream(self, call, response)
        except Exception as error:
            self._finish(call, "cancelled" if self._is_cancelled(call) else "failed")
            if isinstance(error, VelaResponsesError):
                raise
            raise VelaResponsesError(call.reason if call.stopped.is_set() else "model_failed") from None
        finally:
            call.operation_running = False

    def close(self) -> None:
        with self._lock:
            self._closed = True
            call = self._active
        if call:
            self._cancel(call)
        else:
            if not self._latest.done.is_set():
                self._finish(self._latest, "cancelled")
        with self._manager._lock:
            self._manager._turns.discard(self)

    def __enter__(self) -> ResponseTurn:
        return self

    def __exit__(self, *args: Any) -> None:
        self.close()


class ResponseMemoryStream(Iterator[ResponseStreamEvent]):
    def __init__(self, turn: ResponseTurn, call: _Call, stream: Any):
        self._turn, self._call, self._stream = turn, call, stream
        self._iterator = iter(stream)

    def __iter__(self) -> ResponseMemoryStream:
        return self

    def __next__(self) -> ResponseStreamEvent:
        call, turn = self._call, self._turn
        with turn._lock:
            if call.done.is_set():
                raise StopIteration
            if call.operation_running:
                raise VelaResponsesError("busy")
            call.operation_running = True
        try:
            turn._guard(call)
            event = next(self._iterator)
            turn._guard(call)
            kind = getattr(event, "type", None)
            if kind == "response.completed":
                call.completed_event = successful(getattr(event, "response", None))
            if kind in {"response.failed", "error", "response.incomplete", "response.refusal.delta", "response.refusal.done"}:
                call.failed_event = True
            return event
        except StopIteration:
            call.model_finished = call.completed_event and not call.failed_event
            if call.model_finished:
                turn._capture(call)
            turn._finish(call, "finished" if call.model_finished else "incomplete")
            raise
        except Exception as error:
            turn._finish(call, "cancelled" if turn._is_cancelled(call) else "failed")
            if isinstance(error, VelaResponsesError):
                raise
            raise VelaResponsesError(call.reason if call.stopped.is_set() else "model_failed") from None
        finally:
            call.operation_running = False

    def close(self) -> None:
        if not self._call.done.is_set():
            self._turn._cancel(self._call)

    def __enter__(self) -> ResponseMemoryStream:
        return self

    def __exit__(self, *args: Any) -> None:
        self.close()
