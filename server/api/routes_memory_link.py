"""让别的 AI 连上 TA 的记忆（10-16，brain/memory_link.py）：
App 用的：GET / POST / DELETE /companions/{cid}/memory-link（看地址 / 生成或换一把 / 关掉）；
外面的 AI 用的：POST /mcp/memory/{钥匙}（或 /mcp/memory + Authorization: Bearer），只在 Host 上开。"""
from __future__ import annotations

import os
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from fastapi.responses import JSONResponse

from brain import archive, memory_link as L
from brain.persona import Persona

from .deps import Api, account, api, bearer, own_companion

router = APIRouter()


def _host(a: Api) -> None:
    if not a.cfg.host_mode:
        raise HTTPException(404, "只有 Mele Host 能开")


def _url(request: Request, token: str) -> str:
    base = os.environ.get("NEWAPP_PUBLIC_URL", "").strip().rstrip("/") or str(request.base_url).rstrip("/")
    return f"{base}/mcp/memory/{token}"


@router.get("/companions/{cid}/memory-link")
async def get_link(cid: UUID, request: Request, acc: UUID = Depends(account), a: Api = Depends(api)):
    _host(a)
    await own_companion(a, acc, cid)
    token = await L.get_token(a.deps.pool, a.cfg.box, cid)
    return {"url": _url(request, token) if token else None}


@router.post("/companions/{cid}/memory-link")
async def make_link(cid: UUID, request: Request, acc: UUID = Depends(account), a: Api = Depends(api)):
    _host(a)
    await own_companion(a, acc, cid)
    return {"url": _url(request, await L.new_token(a.deps.pool, a.cfg.box, cid, now=a.deps.now()))}


@router.delete("/companions/{cid}/memory-link")
async def drop_link(cid: UUID, acc: UUID = Depends(account), a: Api = Depends(api)):
    _host(a)
    await own_companion(a, acc, cid)
    await L.revoke(a.deps.pool, cid)
    return {"url": None}


async def _serve(request: Request, a: Api, token: str) -> Response:
    if not a.cfg.host_mode:
        raise HTTPException(404, "Not Found")
    cid = await L.companion_for(a.deps.pool, token)
    if cid is None:
        return JSONResponse({"error": "unknown or revoked link"}, status_code=401)
    msgs = L.parse(await request.body())
    if msgs is None:
        return JSONResponse({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}}, status_code=400)
    name = Persona.from_dict(await archive.get_persona(a.deps.pool, cid), "en").name or "your companion"
    now = a.deps.now()
    batch = msgs if isinstance(msgs, list) else [msgs]
    out = [r for m in batch if isinstance(m, dict)
           and (r := await L.handle(a.deps.pool, a.deps.embedder, cid, m, now=now, name=name)) is not None]
    if not out:
        return Response(status_code=202)          # 全是通知（notifications/initialized 之类）
    return JSONResponse(out if isinstance(msgs, list) else out[0])


@router.post("/mcp/memory/{token}")
async def mcp_link(token: str, request: Request, a: Api = Depends(api)):
    return await _serve(request, a, token)


@router.post("/mcp/memory")
async def mcp_bearer(request: Request, a: Api = Depends(api)):
    return await _serve(request, a, bearer(request))


@router.get("/mcp/memory/{token}")
@router.get("/mcp/memory")
async def mcp_get(a: Api = Depends(api)):
    """streamable HTTP 里 GET 是开推送流；我们不推，回 405（规范里的写法），客户端就只用 POST"""
    return Response(status_code=405, headers={"Allow": "POST"})
