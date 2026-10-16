"""Jarvis private document helper. stdout is exclusively framed protocol traffic."""
import asyncio
import concurrent.futures
import fcntl
import json
import os
from pathlib import Path
import sqlite3
import stat
import struct
import sys
import uuid

MAX_FRAME = 1_048_576
MAX_SOURCE = 1_048_576
MAX_PAGE = 16_000


class DocumentStore:
    def __init__(self, home):
        import lancedb
        self.home = Path(home)
        self.home.mkdir(mode=0o700, parents=True, exist_ok=True)
        if self.home.is_symlink():
            raise ValueError("invalid_store")
        self.home.chmod(0o700)
        self.lock = open(self.home / "owner.lock", "a+b")
        os.chmod(self.lock.name, 0o600)
        fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.database = sqlite3.connect(self.home / "control.sqlite")
        self.database.execute("CREATE TABLE IF NOT EXISTS store_version(version INTEGER NOT NULL)")
        if not self.database.execute("SELECT version FROM store_version").fetchone():
            self.database.execute("INSERT INTO store_version VALUES (1)")
            self.database.commit()
        os.chmod(self.home / "control.sqlite", 0o600)
        for name in ("lance", "staging"):
            (self.home / name).mkdir(mode=0o700, exist_ok=True)
        self.lance = lancedb.connect(str(self.home / "lance"))
        self.sources = {}
        self.session = None

    def configure(self, payload, session):
        # Phase 1 accepts only explicit host-authorized TXT fixtures; discovery arrives in phase 2.
        root = Path(payload["root"]).resolve(strict=True)
        documents = payload["documents"]
        if not root.is_dir() or len(documents) > 100:
            raise ValueError("invalid_configuration")
        sources = {}
        for item in documents:
            key = str(uuid.UUID(item["document_id"]))
            source = root / item["name"]
            resolved = source.resolve(strict=True)
            if not resolved.is_relative_to(root) or resolved.suffix.lower() not in (".txt", ".md"):
                raise ValueError("invalid_source")
            sources[key] = (source, root)
        self.sources = sources
        self.session = session
        return {"documents": len(sources)}

    def execute(self, operation, payload, session):
        if operation == "configure":
            return self.configure(payload, session)
        if self.session is None or session != self.session:
            raise ValueError("unknown_session")
        if operation == "release":
            self.sources = {}
            self.session = None
            return {}
        if operation == "read":
            key = str(uuid.UUID(payload["document_id"]))
            offset = payload.get("offset", 0)
            if type(offset) is not int or offset < 0:
                raise ValueError("invalid_offset")
            source, root = self.sources[key]
            resolved = source.resolve(strict=True)
            if not resolved.is_relative_to(root):
                raise ValueError("invalid_source")
            descriptor = os.open(resolved, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
            with os.fdopen(descriptor, "rb") as stream:
                before = os.fstat(stream.fileno())
                if not stat.S_ISREG(before.st_mode):
                    raise ValueError("invalid_source")
                raw = stream.read(MAX_SOURCE + 1)
                after = os.fstat(stream.fileno())
            if len(raw) > MAX_SOURCE:
                raise ValueError("source_too_large")
            if (before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_ino, after.st_size, after.st_mtime_ns):
                raise ValueError("source_changed")
            text = raw.decode("utf-8")
            if offset > len(text):
                raise ValueError("invalid_offset")
            return {"text": text[offset:offset + MAX_PAGE], "next_offset": min(len(text), offset + MAX_PAGE), "total_scalars": len(text)}
        if operation == "search":
            query = payload["query"]
            if not isinstance(query, str) or not query.strip() or len(query) > 512:
                raise ValueError("invalid_query")
            rows = []
            for key in self.sources:
                result = self.execute("read", {"document_id": key}, session)
                rows.append({"document_id": key, "text": result["text"]})
            if not rows:
                return {"hits": []}
            table = self.lance.create_table("chunks", rows, mode="overwrite")
            table.create_fts_index("text", replace=True, use_tantivy=False, base_tokenizer="icu", stem=False, remove_stop_words=False, ascii_folding=False)
            hits = table.search(query, query_type="fts").limit(3).to_list()
            return {"hits": [{"document_id": h["document_id"], "text": h["text"][:2000]} for h in hits]}
        raise ValueError("unsupported_operation")

    def close(self):
        self.database.close()
        self.lock.close()


async def serve(home):
    loop = asyncio.get_running_loop()
    executor = concurrent.futures.ThreadPoolExecutor(max_workers=1, thread_name_prefix="documents")
    store = await loop.run_in_executor(executor, DocumentStore, home)
    reader = asyncio.StreamReader(limit=MAX_FRAME + 4)
    protocol = asyncio.StreamReaderProtocol(reader)
    await loop.connect_read_pipe(lambda: protocol, sys.stdin.buffer)
    tasks = {}
    seen = set()
    write_lock = asyncio.Lock()

    async def send(identifier, status, result):
        body = json.dumps({"protocol": 1, "id": identifier, "status": status, "result": result}, ensure_ascii=False).encode()
        if len(body) > MAX_FRAME:
            raise ValueError("oversized")
        async with write_lock:
            sys.stdout.buffer.write(struct.pack(">I", len(body)) + body)
            sys.stdout.buffer.flush()

    async def dispatch(request):
        identifier = request["id"]
        try:
            result = await loop.run_in_executor(executor, store.execute, request["operation"], request["payload"], request.get("session_id"))
            await send(identifier, "ok", result)
        except asyncio.CancelledError:
            await send(identifier, "cancelled", {})
        except (ValueError, KeyError, OSError, UnicodeError):
            await send(identifier, "unavailable", {})
        except Exception:
            # No paths, source text, provider messages or exception payloads leave this process.
            await send(identifier, "unavailable", {})
        finally:
            tasks.pop(identifier, None)

    try:
        while True:
            try:
                header = await reader.readexactly(4)
            except asyncio.IncompleteReadError as error:
                if error.partial:
                    raise ValueError("truncated")
                break
            length = struct.unpack(">I", header)[0]
            if not 0 < length <= MAX_FRAME:
                raise ValueError("oversized")
            request = json.loads((await reader.readexactly(length)).decode("utf-8"))
            identifier = str(uuid.UUID(request["id"]))
            if type(request.get("protocol")) is not int or request["protocol"] != 1 or identifier in seen or not isinstance(request.get("payload"), dict):
                raise ValueError("malformed")
            seen.add(identifier)
            if len(seen) > 100_000:
                raise ValueError("request_limit")
            operation = request["operation"]
            if operation == "hello":
                await send(identifier, "ok", {"protocol": 1, "python": sys.version.split()[0], "isolated": bool(sys.flags.isolated), "pid": os.getpid()})
            elif operation == "shutdown":
                await send(identifier, "ok", {})
                break
            elif operation == "cancel":
                target = tasks.get(request["payload"].get("request_id"))
                if target:
                    target.cancel()
                await send(identifier, "ok", {})
            else:
                if len(tasks) >= 32:
                    await send(identifier, "unavailable", {})
                    continue
                if request.get("session_id") is not None:
                    uuid.UUID(request["session_id"])
                tasks[identifier] = asyncio.create_task(dispatch(request))
    finally:
        for task in list(tasks.values()):
            task.cancel()
        await asyncio.gather(*list(tasks.values()), return_exceptions=True)
        await loop.run_in_executor(executor, store.close)
        executor.shutdown(wait=True, cancel_futures=True)


if __name__ == "__main__":
    os.umask(0o077)
    try:
        asyncio.run(serve(sys.argv[1]))
    except Exception:
        sys.stderr.write("reference helper: protocol or store failure\n")
        sys.exit(2)
