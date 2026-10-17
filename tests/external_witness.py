#!/usr/bin/env python3
"""本人限定Quick Tunnelの停止を、Macから独立した実行環境で観測する。

認証情報は受け取らず、GETのログイン転送とCloudflare 1033を区別する。
この観測だけでは認証済み要求の応答・VMの回収・実スリープを証明しない。
"""
import argparse
import datetime
import hashlib
import http.client
import json
import os
import pathlib
import re
import ssl
import time
import urllib.parse
import uuid


def target_host(value):
    if not value.isascii() or any(ord(c) <= 32 or ord(c) == 127 for c in value):
        raise ValueError("検証URLに空白・制御文字は使用できません")
    u = urllib.parse.urlsplit(value)
    host = u.hostname or ""
    if (u.scheme != "https" or u.netloc != host or u.path not in ("", "/")
            or u.query or u.fragment or not re.fullmatch(
                r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.trycloudflare\.com", host)):
        raise ValueError("検証対象は本人限定を確認済みのQuick Tunnel originだけです")
    return host


def classify(host, status, headers, body):
    try:
        location = urllib.parse.urlsplit(headers.get("location", ""))
    except ValueError:
        return "unexpected-response"
    if (status in (302, 303) and location.scheme == "https"
            and location.hostname == "login.trycloudflare.com"
            and location.netloc == location.hostname and location.path == "/authorize"
            and urllib.parse.parse_qs(location.query).get("hostname") == [host]):
        return "login-required"
    error_1033 = (b"1033" in body and b"cloudflare" in body.lower() and b"tunnel" in body.lower())
    error_1033 = error_1033 or re.fullmatch(rb"\s*error code:\s*1033\s*", body) is not None
    if (status == 530 and headers.get("server", "").lower() == "cloudflare"
            and re.fullmatch(r"[a-f0-9]{16,32}-[A-Z0-9]{3}", headers.get("cf-ray", ""))
            and error_1033):
        return "tunnel-unavailable-1033"
    return "unexpected-response"


def utc(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).isoformat()


def observe(host, connection, marker, channel):
    start = time.time()
    result = {"startedAt": start, "startedUTC": utc(start), "channel": channel}
    try:
        previous = connection.sock
        connection.request("GET", marker, headers={"Cache-Control": "no-store", "Accept": "text/html"})
        active = connection.sock
        if getattr(connection, "_witness_socket", None) is not active:
            connection._witness_number = getattr(connection, "_witness_number", 0) + 1
            connection._witness_socket = active
        result.update(reusedTCP=previous is not None and active is previous,
                      connectionNumber=connection._witness_number)
        response = connection.getresponse()
        body = response.read(65537)
        headers = {k.lower(): v for k, v in response.getheaders()}
        result.update(status=response.status, bodySHA256=hashlib.sha256(body).hexdigest(),
                      bodyBytes=len(body), cloudflareRay=headers.get("cf-ray", ""), server=headers.get("server", ""),
                      classification=classify(host, response.status, headers, body)
                      if len(body) <= 65536 else "oversized-response")
    except (OSError, http.client.HTTPException) as error:
        result.update(classification="transport-error", error=type(error).__name__)
        connection.close()
    result["finishedAt"] = time.time()
    result["seconds"] = round(result["finishedAt"] - start, 3)
    return result


def conclusion(rows):
    # DNS・回線の故障を公開停止と誤認しない。各channelの前後を独立確認する。
    details = {}
    for channel in ("new", "persistent"):
        selected = [r for r in rows if r["channel"] == channel]
        baseline = len(selected) >= 3 and all(r["classification"] == "login-required" for r in selected[:3])
        final = len(selected) >= 3 and all(r["classification"] == "tunnel-unavailable-1033" for r in selected[-3:])
        first = next((r["startedAt"] for r in selected if r["classification"] == "tunnel-unavailable-1033"), None)
        resumed = first is not None and any(r["startedAt"] > first and r["classification"] == "login-required" for r in selected)
        first_row = next((r for r in selected if r["classification"] == "tunnel-unavailable-1033"), {})
        same_tcp = bool(first_row.get("reusedTCP")) and any(r["classification"] == "login-required"
            and r.get("connectionNumber") == first_row.get("connectionNumber") for r in selected)
        details[channel] = {"initialPrivateGateObserved": baseline, "final1033Observed": final,
                            "first1033At": first, "gateReturnedAfter1033": resumed,
                            "sameTCPConnectionAcrossStop": same_tcp,
                            "indeterminateSamples": sum(r["classification"] not in
                                ("login-required", "tunnel-unavailable-1033") for r in selected)}
    passed = all(d["initialPrivateGateObserved"] and d["final1033Observed"]
                 and not d["gateReturnedAfter1033"] and d["indeterminateSamples"] == 0 for d in details.values())
    passed = passed and details["persistent"]["sameTCPConnectionAcrossStop"]
    stopped = all(d["final1033Observed"] and not d["gateReturnedAfter1033"]
                  and d["indeterminateSamples"] == 0 for d in details.values())
    return {"externalTransitionObserved": passed, "externalStoppedStateObserved": stopped, "channels": details,
            "authenticatedDeliveryVerified": False, "physicalSleepVerified": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True)
    parser.add_argument("--seconds", type=int, default=240)
    phase = parser.add_mutually_exclusive_group()
    phase.add_argument("--baseline-only", action="store_true")
    phase.add_argument("--stopped-only", action="store_true")
    parser.add_argument("--output", type=pathlib.Path, required=True)
    args = parser.parse_args()
    host = target_host(args.url)
    if not 30 <= args.seconds <= 600:
        parser.error("観測時間は30〜600秒です")
    os.umask(0o077)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    context = ssl.create_default_context()
    persistent = http.client.HTTPSConnection(host, timeout=4, context=context)
    marker = "/qa-stop-witness-" + uuid.uuid4().hex
    started = time.time()
    duration = 6 if args.baseline_only or args.stopped_only else args.seconds
    deadline = time.monotonic() + duration
    report = {"hostname": host, "startedAt": started, "durationSeconds": duration,
              "baselineOnly": args.baseline_only, "stoppedOnly": args.stopped_only,
              "credentialsUsed": False, "observations": []}
    try:
        while time.monotonic() < deadline:
            tick = time.monotonic()
            fresh = http.client.HTTPSConnection(host, timeout=4, context=context)
            try:
                rows = [observe(host, fresh, marker, "new"), observe(host, persistent, marker, "persistent")]
            finally:
                fresh.close()
            report["observations"].extend(rows)
            args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2))
            print(utc(time.time()), " ".join(r["channel"] + ":" + r["classification"] for r in rows), flush=True)
            baseline_ok = all(d["initialPrivateGateObserved"] for d in conclusion(report["observations"])["channels"].values())
            if any(r["classification"] == "unexpected-response" for r in rows) and not baseline_ok:
                break
            time.sleep(max(0, min(2 - (time.monotonic() - tick), deadline - time.monotonic())))
    finally:
        persistent.close()
        report["finishedAt"] = time.time()
        report.update(conclusion(report["observations"]))
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2))
    if args.baseline_only:
        return 0 if all(d["initialPrivateGateObserved"] and d["indeterminateSamples"] == 0 for d in report["channels"].values()) else 1
    if args.stopped_only:
        return 0 if report["externalStoppedStateObserved"] else 1
    return 0 if report["externalTransitionObserved"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
