#!/usr/bin/env python3
"""
飞书任务接口诊断脚本

用法：
  export FEISHU_APP_ID=cli_xxx
  export FEISHU_APP_SECRET=xxx
  export FEISHU_TASKLIST_GUID=6867bf2c-...   # 可选
  python3 scripts/feishu_task_probe.py

也可以传 user_access_token：
  export FEISHU_USER_ACCESS_TOKEN=u-xxx
  python3 scripts/feishu_task_probe.py
"""

import json
import os
import sys
import urllib.parse
import urllib.request


BASE = "https://open.feishu.cn"


def http(method, path, token=None, body=None, query=None):
    url = BASE + path
    if query:
        url += "?" + urllib.parse.urlencode(query)
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, resp.read().decode("utf-8")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8")


def section(title):
    print()
    print("=" * 70)
    print(title)
    print("=" * 70)


def pretty(label, status, body):
    print(f"[{label}] HTTP {status}")
    try:
        parsed = json.loads(body)
        print(json.dumps(parsed, ensure_ascii=False, indent=2))
    except Exception:
        print(body)


def get_tenant_token(app_id, app_secret):
    section("1) tenant_access_token")
    status, body = http(
        "POST",
        "/open-apis/auth/v3/tenant_access_token/internal",
        body={"app_id": app_id, "app_secret": app_secret},
    )
    pretty("tenant_token", status, body)
    if status != 200:
        return None
    obj = json.loads(body)
    if obj.get("code") != 0:
        return None
    return obj.get("tenant_access_token")


def list_all_tasks(token, label):
    section(f"2) GET /task/v2/tasks  ({label})")
    status, body = http("GET", "/open-apis/task/v2/tasks", token=token, query={"page_size": 50})
    pretty("list_all_tasks", status, body)


def list_tasklists(token, label):
    section(f"3) GET /task/v2/tasklists  ({label})")
    status, body = http("GET", "/open-apis/task/v2/tasklists", token=token, query={"page_size": 50})
    pretty("list_tasklists", status, body)


def get_tasklist_meta(token, guid, label):
    section(f"4) GET /task/v2/tasklists/{guid}  ({label})")
    status, body = http("GET", f"/open-apis/task/v2/tasklists/{guid}", token=token)
    pretty("get_tasklist", status, body)


def list_tasklist_tasks(token, guid, label):
    section(f"5) GET /task/v2/tasklists/{guid}/tasks  ({label})")
    status, body = http(
        "GET",
        f"/open-apis/task/v2/tasklists/{guid}/tasks",
        token=token,
        query={"page_size": 50},
    )
    pretty("list_tasklist_tasks", status, body)


def main():
    app_id = os.environ.get("FEISHU_APP_ID", "").strip()
    app_secret = os.environ.get("FEISHU_APP_SECRET", "").strip()
    user_token = os.environ.get("FEISHU_USER_ACCESS_TOKEN", "").strip()
    tasklist_guid = os.environ.get("FEISHU_TASKLIST_GUID", "").strip()

    if not (app_id and app_secret) and not user_token:
        print("请设置 FEISHU_APP_ID + FEISHU_APP_SECRET，或 FEISHU_USER_ACCESS_TOKEN")
        sys.exit(1)

    tenant_token = None
    if app_id and app_secret:
        tenant_token = get_tenant_token(app_id, app_secret)

    for label, token in [("tenant", tenant_token), ("user", user_token)]:
        if not token:
            continue
        print()
        print("#" * 70)
        print(f"以 {label}_access_token 调用各接口")
        print("#" * 70)
        list_all_tasks(token, label)
        list_tasklists(token, label)
        if tasklist_guid:
            get_tasklist_meta(token, tasklist_guid, label)
            list_tasklist_tasks(token, tasklist_guid, label)


if __name__ == "__main__":
    main()
