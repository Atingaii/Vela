"""Bounded local Vela SDK. A connection is not an owner or namespace ACL."""
from __future__ import annotations

import asyncio
from dataclasses import dataclass
import json
import math
import os
from pathlib import Path
import selectors
import signal
import subprocess
import threading
import time
from typing import Any, Literal, TypedDict

__all__ = ["VelaClient", "AsyncVelaClient", "LocalTransport", "CandidateInput", "SemanticLanguage", "ScoringWeights", "VelaError", "VelaBulkError", "VelaCancelledError"]

SemanticLanguage = Literal["en", "zh-Hans"]


class ScoringWeights(TypedDict, total=False):
    semantic: float
    recency: float
    importance: float
    recency_half_life_days: float


@dataclass(frozen=True)
class LocalTransport:
    executable: str
    home: str
    type: Literal["local"] = "local"


class CandidateInput(TypedDict, total=False):
    title: str
    content: str
    type: str
    project: str


class VelaError(Exception):
    def __init__(self, code: str, request_id: int | None = None, effects_unknown: bool = False):
        super().__init__(f"Vela request failed: {code}.")
        self.code, self.request_id, self.effects_unknown = code, request_id, effects_unknown


class VelaBulkError(Exception):
    def __init__(self, completed: list[dict[str, Any]], failed_index: int, total: int, cause: VelaError):
        super().__init__("Vela bulk write stopped; inspect completed items and the uncertain request before continuing.")
        self.completed, self.failed_index, self.cause = list(completed), failed_index, cause
        self.skipped, self.unattempted = 0, total - failed_index - 1
        self.effects_unknown = cause.effects_unknown


class VelaCancelledError(asyncio.CancelledError):
    def __init__(self, request_id: int | None, effects_unknown: bool):
        super().__init__("Vela caller cancelled; the helper was closed. Core effects may have occurred.")
        self.code, self.request_id, self.effects_unknown = "cancelled", request_id, effects_unknown


_FRAME_LIMIT = 2 * 1024 * 1024
_STDERR_LIMIT = 64 * 1024
_TYPES = {"decision", "constraint", "preference", "failure", "fact", "workflow knowledge", "observation", "hypothesis", "checkpoint"}


class _AsyncCallState:
    """Dispatch receipt owned by one async invocation, never a neighbouring call."""
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.request_id: int | None = None
        self.mutating = self.sent = self.cancelled = False

    def cancel(self) -> tuple[int | None, bool]:
        with self.lock:
            self.cancelled = True
            return (self.request_id if self.sent else None, self.sent and self.mutating)


def _absolute(value: Any) -> str:
    if not isinstance(value, str) or not Path(value).is_absolute() or "\0" in value:
        raise VelaError("invalid_input")
    return value


def _timeout(value: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not 0 < value <= 120:
        raise VelaError("invalid_input")
    return float(value)


def _candidate(value: CandidateInput) -> None:
    if not isinstance(value, dict) or set(value) - {"title", "content", "type", "project"}:
        raise VelaError("invalid_input")
    title, content = value.get("title"), value.get("content")
    if not isinstance(title, str) or not title.strip() or len(title) > 300 or not isinstance(content, str) or not content.strip():
        raise VelaError("invalid_input")
    try:
        if len(content.encode("utf-8")) > 512 * 1024:
            raise VelaError("invalid_input")
    except UnicodeError:
        raise VelaError("invalid_input") from None
    if value.get("type", "fact") not in _TYPES:
        raise VelaError("invalid_input")


def _number(value: Any, minimum: float, maximum: float, *, integer: bool = False) -> None:
    if value is not None and (isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or not minimum <= value <= maximum or (integer and type(value) is not int)):
        raise VelaError("invalid_input")


def _language(value: Any) -> None:
    if value not in ("en", "zh-Hans"):
        raise VelaError("invalid_input")


class VelaClient:
    """Synchronous, serialized requests over one explicitly selected helper.

    No shell, watcher or auto-reconnect. Timeout/close kills the owned process
    group, never retries a request, and does not prove that core work was undone.
    """

    def __init__(self, transport: LocalTransport, *, project: str | None = None, timeout: float = 15):
        if not isinstance(transport, LocalTransport) or transport.type != "local" or os.name != "posix":
            raise VelaError("invalid_input")
        executable, home = _absolute(transport.executable), _absolute(transport.home)
        self._project = None if project is None else _absolute(project)
        self._timeout = _timeout(timeout)
        self._lock = threading.Lock()
        self._call_context = threading.local()
        self._close_lock = threading.Lock()
        self._closed = threading.Event()
        self._buffer, self._stderr_bytes, self._sequence = bytearray(), 0, 0
        self._active_id: int | None = None
        self._active_mutating = False
        try:
            self._process = subprocess.Popen(
                [executable, "rpc", "--no-watch", "--no-schedule", "--home", home],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                bufsize=0, start_new_session=True,
                env={**os.environ, "VELA_DISABLE_DISCOVERY": "1"},
            )
        except (OSError, ValueError):
            raise VelaError("spawn_failed") from None
        self._selector = selectors.DefaultSelector()
        assert self._process.stdin and self._process.stdout and self._process.stderr
        for name, stream in [("stdout", self._process.stdout), ("stderr", self._process.stderr)]:
            os.set_blocking(stream.fileno(), False)
            self._selector.register(stream, selectors.EVENT_READ, name)
        os.set_blocking(self._process.stdin.fileno(), False)

    def _fail(self, code: str, request_id: int, mutating: bool) -> None:
        self.close()
        raise VelaError(code, request_id, mutating)

    def _request(self, method: str, params: dict[str, Any], mutating: bool, timeout: float | None = None) -> Any:
        duration = _timeout(self._timeout if timeout is None else timeout)
        started = time.monotonic()
        if not self._lock.acquire(timeout=duration):
            raise VelaError("busy")
        try:
            if self._closed.is_set():
                raise VelaError("closed")
            self._sequence += 1
            request_id = self._sequence
            try:
                frame = (json.dumps({"id": request_id, "method": method, "params": params}, ensure_ascii=False, allow_nan=False) + "\n").encode("utf-8")
            except (ValueError, TypeError, UnicodeError):
                raise VelaError("invalid_input", request_id) from None
            if len(frame) - 1 > _FRAME_LIMIT:
                raise VelaError("invalid_input", request_id)
            self._active_id, self._active_mutating = request_id, mutating
            call_state: _AsyncCallState | None = getattr(self._call_context, "state", None)
            if call_state:
                with call_state.lock:
                    call_state.request_id, call_state.mutating = request_id, mutating
            assert self._process.stdin
            offset = 0
            while True:
                if self._closed.is_set():
                    raise VelaError("closed", request_id, mutating and offset > 0)
                remaining = duration - (time.monotonic() - started)
                if remaining <= 0:
                    self._fail("timeout", request_id, mutating and offset > 0)
                if offset < len(frame):
                    try:
                        if call_state:
                            # Cancellation cannot snapshot "not sent" and then race this write.
                            with call_state.lock:
                                if call_state.cancelled:
                                    raise VelaError("cancelled", request_id if call_state.sent else None, call_state.sent and mutating)
                                offset += os.write(self._process.stdin.fileno(), frame[offset:])
                                call_state.sent = offset > 0
                        else:
                            offset += os.write(self._process.stdin.fileno(), frame[offset:])
                    except BlockingIOError:
                        pass
                    except (OSError, ValueError):
                        self._fail("transport_closed", request_id, mutating and offset > 0)
                try:
                    ready = self._selector.select(min(remaining, 0.05))
                except (OSError, ValueError):
                    self._fail("transport_closed", request_id, mutating and offset > 0)
                for key, _ in ready:
                    try:
                        data = os.read(key.fd, 65536)
                    except BlockingIOError:
                        continue
                    except OSError:
                        self._fail("transport_closed", request_id, mutating and offset > 0)
                    if not data:
                        if key.data == "stdout":
                            self._fail("transport_closed", request_id, mutating and offset > 0)
                        self._selector.unregister(key.fileobj)
                        continue
                    if key.data == "stderr":
                        self._stderr_bytes += len(data)
                        if self._stderr_bytes > _STDERR_LIMIT:
                            self._fail("output_limit", request_id, mutating and offset > 0)
                        continue
                    self._buffer.extend(data)
                    while b"\n" in self._buffer:
                        line, _, rest = self._buffer.partition(b"\n")
                        self._buffer = bytearray(rest)
                        if len(line) > _FRAME_LIMIT:
                            self._fail("output_limit", request_id, mutating and offset > 0)
                        try:
                            value = json.loads(line.decode("utf-8"))
                        except (ValueError, UnicodeError):
                            self._fail("protocol_error", request_id, mutating and offset > 0)
                        if isinstance(value, dict) and value.get("event") == "data.changed" and "id" not in value:
                            continue
                        if not isinstance(value, dict) or type(value.get("id")) is not int or value["id"] != request_id or (("result" in value) == ("error" in value)):
                            self._fail("protocol_error", request_id, mutating and offset > 0)
                        if "error" in value:
                            raise VelaError("rpc_error", request_id, mutating)
                        return value["result"]
                    if len(self._buffer) > _FRAME_LIMIT:
                        self._fail("output_limit", request_id, mutating and offset > 0)
        finally:
            self._active_id, self._active_mutating = None, False
            self._lock.release()

    def _selected(self, project: str | None) -> str:
        return _absolute(self._project if project is None else project)

    def list_projects(self, *, timeout: float | None = None) -> list[dict[str, Any]]:
        return self._request("projects.list", {}, False, timeout)

    def register_project(self, path: str, *, timeout: float | None = None) -> dict[str, Any]:
        return self._request("projects.add", {"path": _absolute(path)}, True, timeout)

    def list_memories(self, project: str | None = None, *, timeout: float | None = None) -> list[dict[str, Any]]:
        return self._request("memory.list", {"project": self._selected(project)}, False, timeout)

    def recall(self, query: str, *, project: str | None = None, budget: int = 2000,
               retrieval_mode: Literal["lexical", "semantic", "hybrid"] = "lexical", language: SemanticLanguage = "en",
               limit: int | None = None, min_similarity: float | None = None, scoring_weights: ScoringWeights | None = None,
               branch: str | None = None, worktree: str | None = None, task: str | None = None, session_id: str | None = None,
               timeout: float | None = None) -> dict[str, Any]:
        if not isinstance(query, str) or not query.strip() or type(budget) is not int:
            raise VelaError("invalid_input")
        try:
            if len(query.encode("utf-8")) > 16 * 1024:
                raise VelaError("invalid_input")
        except UnicodeError:
            raise VelaError("invalid_input") from None
        _number(budget, 0, 4000, integer=True); _number(limit, 1, 100, integer=True); _number(min_similarity, 0, 1); _language(language)
        if retrieval_mode not in ("lexical", "semantic", "hybrid"):
            raise VelaError("invalid_input")
        params: dict[str, Any] = {"query": query, "project": self._selected(project), "budget": budget, "retrievalMode": retrieval_mode, "language": language}
        for key, value in [("limit", limit), ("minSimilarity", min_similarity), ("branch", branch), ("worktree", worktree), ("task", task), ("sessionId", session_id)]:
            if value is not None:
                if key in {"branch", "worktree", "task", "sessionId"} and not isinstance(value, str):
                    raise VelaError("invalid_input")
                params[key] = value
        if scoring_weights is not None:
            if not isinstance(scoring_weights, dict) or set(scoring_weights) - {"semantic", "recency", "importance", "recency_half_life_days"}:
                raise VelaError("invalid_input")
            if any(value is None for value in scoring_weights.values()):
                raise VelaError("invalid_input")
            for key in ("semantic", "recency", "importance"):
                _number(scoring_weights.get(key), 0, 10)
            _number(scoring_weights.get("recency_half_life_days"), 0.01, 3650)
            if sum(scoring_weights.get(key, default) for key, default in [("semantic", 1), ("recency", 0), ("importance", 0)]) <= 0:
                raise VelaError("invalid_input")
            params["scoringWeights"] = {"recencyHalfLifeDays" if key == "recency_half_life_days" else key: value for key, value in scoring_weights.items()}
        return self._request("recall", params, False, timeout)

    def semantic_status(self, *, project: str | None = None, language: SemanticLanguage = "en", timeout: float | None = None) -> dict[str, Any]:
        _language(language)
        return self._request("memory.semantic.status", {"project": self._selected(project), "language": language}, False, timeout)

    def semantic_index(self, *, project: str | None = None, language: SemanticLanguage = "en", batch_size: int = 32,
                       cursor: str | None = None, timeout: float | None = None) -> dict[str, Any]:
        if type(batch_size) is not int:
            raise VelaError("invalid_input")
        _language(language); _number(batch_size, 1, 200, integer=True)
        params: dict[str, Any] = {"project": self._selected(project), "language": language, "batchSize": batch_size}
        if cursor is not None:
            if not isinstance(cursor, str) or len(cursor) > 4096:
                raise VelaError("invalid_input")
            params["cursor"] = cursor
        return self._request("memory.semantic.index", params, True, timeout)

    def save_candidate(self, memory: CandidateInput, *, timeout: float | None = None) -> dict[str, Any]:
        _candidate(memory)
        return self._request("memory.save", {"title": memory["title"], "content": memory["content"], "type": memory.get("type", "fact"), "project": self._selected(memory.get("project")), "scope": "project", "state": "candidate"}, True, timeout)

    def save_candidates(self, memories: list[CandidateInput], *, timeout: float | None = None) -> list[dict[str, Any]]:
        if not isinstance(memories, list) or not 1 <= len(memories) <= 100:
            raise VelaError("invalid_input")
        for memory in memories:
            _candidate(memory)
            self._selected(memory.get("project"))
        completed: list[dict[str, Any]] = []
        for index, memory in enumerate(memories):
            try:
                completed.append(self.save_candidate(memory, timeout=timeout))
            except VelaError as error:
                raise VelaBulkError(completed, index, len(memories), error) from None
        return completed

    def export_archive(self, project: str | None = None, *, ids: list[str] | None = None, timeout: float | None = None) -> dict[str, Any]:
        params: dict[str, Any] = {"project": self._selected(project)}
        if ids is not None:
            params["ids"] = ids
        return self._request("memory.archive.export", params, False, timeout)

    def validate_archive(self, archive: dict[str, Any], *, timeout: float | None = None) -> dict[str, Any]:
        return self._request("memory.archive.validate", {"archive": archive}, False, timeout)

    def archive_from_walrus_records(self, source: dict[str, Any], records: list[dict[str, Any]], *, timeout: float | None = None) -> dict[str, Any]:
        return self._request("memory.archive.fromWalrusRecords", {"source": source, "records": records, "intendedUse": "candidate-review"}, False, timeout)

    def import_archive(self, archive: dict[str, Any], project: str | None = None, *, timeout: float | None = None) -> dict[str, Any]:
        return self._request("memory.archive.import", {"project": self._selected(project), "archive": archive}, True, timeout)

    def capture_integration(self, namespace: str, source_id: str, records: list[dict[str, Any]], *, project: str | None = None, timeout: float | None = None) -> dict[str, Any]:
        return self._request("memory.integration.capture", {"project": self._selected(project), "namespace": namespace, "integration": "openclaw", "sourceID": source_id, "records": records}, True, timeout)

    def recall_integration(self, namespace: str, query: str, *, project: str | None = None, budget: int = 2000, limit: int = 5, timeout: float | None = None) -> dict[str, Any]:
        return self._request("memory.integration.recall", {"project": self._selected(project), "namespace": namespace, "query": query, "budget": budget, "limit": limit}, False, timeout)

    def integration_stats(self, namespace: str, *, project: str | None = None, timeout: float | None = None) -> dict[str, Any]:
        return self._request("memory.integration.stats", {"project": self._selected(project), "namespace": namespace}, False, timeout)

    def close(self) -> None:
        """Stop the owned helper group. This does not roll back completed core writes."""
        with self._close_lock:
            if self._closed.is_set():
                return
            self._closed.set()
            try:
                os.killpg(self._process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                self._process.wait(timeout=0.5)
            except subprocess.TimeoutExpired:
                pass
            # Descendants may remain after the group leader exits.
            try:
                os.killpg(self._process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            self._process.wait(timeout=2)
            self._selector.close()
            for stream in [self._process.stdin, self._process.stdout, self._process.stderr]:
                if stream:
                    stream.close()

    def __enter__(self) -> VelaClient:
        return self

    def __exit__(self, *args: Any) -> None:
        self.close()


class AsyncVelaClient:
    """Async interface to the same serialized transport; never blocks the event loop.

    Cancellation closes the shared helper and may affect other waiting calls.
    It cannot establish that a started mutation was cancelled inside Vela Core.
    """

    def __init__(self, transport: LocalTransport, *, project: str | None = None, timeout: float = 15):
        self._client = VelaClient(transport, project=project, timeout=timeout)
        self._pending = 0

    async def _run(self, name: str, *args: Any, **kwargs: Any) -> Any:
        if self._pending >= 32:
            raise VelaError("busy")
        self._pending += 1
        state = _AsyncCallState()
        def invoke() -> Any:
            self._client._call_context.state = state
            try:
                return getattr(self._client, name)(*args, **kwargs)
            finally:
                del self._client._call_context.state
        try:
            return await asyncio.to_thread(invoke)
        except asyncio.CancelledError:
            request_id, uncertain = state.cancel()
            await asyncio.shield(asyncio.to_thread(self._client.close))
            raise VelaCancelledError(request_id, uncertain) from None
        finally:
            self._pending -= 1

    async def list_projects(self, **kwargs: Any) -> list[dict[str, Any]]:
        return await self._run("list_projects", **kwargs)

    async def register_project(self, path: str, **kwargs: Any) -> dict[str, Any]:
        return await self._run("register_project", path, **kwargs)

    async def list_memories(self, project: str | None = None, **kwargs: Any) -> list[dict[str, Any]]:
        return await self._run("list_memories", project, **kwargs)

    async def recall(self, query: str, *, project: str | None = None, budget: int = 2000,
                     retrieval_mode: Literal["lexical", "semantic", "hybrid"] = "lexical", language: SemanticLanguage = "en",
                     limit: int | None = None, min_similarity: float | None = None, scoring_weights: ScoringWeights | None = None,
                     branch: str | None = None, worktree: str | None = None, task: str | None = None, session_id: str | None = None,
                     timeout: float | None = None) -> dict[str, Any]:
        return await self._run("recall", query, project=project, budget=budget, retrieval_mode=retrieval_mode, language=language,
                               limit=limit, min_similarity=min_similarity, scoring_weights=scoring_weights,
                               branch=branch, worktree=worktree, task=task, session_id=session_id, timeout=timeout)

    async def semantic_status(self, *, project: str | None = None, language: SemanticLanguage = "en", timeout: float | None = None) -> dict[str, Any]:
        return await self._run("semantic_status", project=project, language=language, timeout=timeout)

    async def semantic_index(self, *, project: str | None = None, language: SemanticLanguage = "en", batch_size: int = 32,
                             cursor: str | None = None, timeout: float | None = None) -> dict[str, Any]:
        return await self._run("semantic_index", project=project, language=language, batch_size=batch_size, cursor=cursor, timeout=timeout)

    async def save_candidate(self, memory: CandidateInput, **kwargs: Any) -> dict[str, Any]:
        return await self._run("save_candidate", memory, **kwargs)

    async def save_candidates(self, memories: list[CandidateInput], **kwargs: Any) -> list[dict[str, Any]]:
        if not isinstance(memories, list) or not 1 <= len(memories) <= 100:
            raise VelaError("invalid_input")
        for memory in memories:
            _candidate(memory)
            self._client._selected(memory.get("project"))
        completed: list[dict[str, Any]] = []
        for index, memory in enumerate(memories):
            try:
                completed.append(await self.save_candidate(memory, **kwargs))
            except (VelaError, VelaCancelledError) as error:
                cause = error if isinstance(error, VelaError) else VelaError("cancelled", error.request_id, error.effects_unknown)
                raise VelaBulkError(completed, index, len(memories), cause) from None
        return completed

    async def export_archive(self, project: str | None = None, **kwargs: Any) -> dict[str, Any]:
        return await self._run("export_archive", project, **kwargs)

    async def validate_archive(self, archive: dict[str, Any], **kwargs: Any) -> dict[str, Any]:
        return await self._run("validate_archive", archive, **kwargs)

    async def archive_from_walrus_records(self, source: dict[str, Any], records: list[dict[str, Any]], **kwargs: Any) -> dict[str, Any]:
        return await self._run("archive_from_walrus_records", source, records, **kwargs)

    async def import_archive(self, archive: dict[str, Any], project: str | None = None, **kwargs: Any) -> dict[str, Any]:
        return await self._run("import_archive", archive, project, **kwargs)

    async def capture_integration(self, namespace: str, source_id: str, records: list[dict[str, Any]], **kwargs: Any) -> dict[str, Any]:
        return await self._run("capture_integration", namespace, source_id, records, **kwargs)

    async def recall_integration(self, namespace: str, query: str, **kwargs: Any) -> dict[str, Any]:
        return await self._run("recall_integration", namespace, query, **kwargs)

    async def integration_stats(self, namespace: str, **kwargs: Any) -> dict[str, Any]:
        return await self._run("integration_stats", namespace, **kwargs)

    async def close(self) -> None:
        await asyncio.to_thread(self._client.close)

    async def __aenter__(self) -> AsyncVelaClient:
        return self

    async def __aexit__(self, *args: Any) -> None:
        await self.close()
