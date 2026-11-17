"""把 Alertmanager webhook 转成飞书机器人文本消息。未配置 FEISHU_WEBHOOK 时只打印。"""
import base64
import hashlib
import hmac
import json
import os
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer


def render(payload, host):
    lines = []
    for a in payload.get("alerts", []):
        labels, ann = a.get("labels", {}), a.get("annotations", {})
        head = "告警" if a.get("status") == "firing" else "恢复"
        sev = labels.get("severity", "")
        lines.append("[%s] %s%s: %s" % (head, labels.get("alertname", ""),
                                       "(%s)" % sev if sev else "", ann.get("summary", "")))
    return "%s\n%s" % (host, "\n".join(lines))


# 机器人开启「签名校验」时需要：以 "时间戳\n密钥" 为 key 对空串做 HMAC-SHA256
def message(text, secret, now):
    msg = {"msg_type": "text", "content": {"text": text}}
    if secret:
        key = ("%d\n%s" % (now, secret)).encode()
        msg["timestamp"] = str(now)
        msg["sign"] = base64.b64encode(hmac.new(key, b"", hashlib.sha256).digest()).decode()
    return msg


def send(msg, webhook):
    req = urllib.request.Request(webhook, json.dumps(msg).encode(), {"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        body = json.load(r)
    # 飞书业务错误也返回 HTTP 200
    if body.get("code", body.get("StatusCode", 0)) != 0:
        raise RuntimeError(body)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):  # 健康检查
        self.send_response(200)
        self.end_headers()

    def do_POST(self):
        try:
            payload = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
            text = render(payload, os.environ.get("HOST_NAME", ""))
            webhook = os.environ.get("FEISHU_WEBHOOK", "")
            if webhook:
                send(message(text, os.environ.get("FEISHU_SECRET", ""), int(time.time())), webhook)
            print(text, flush=True)
            self.send_response(200)
        except Exception as e:  # 返回 5xx 让 Alertmanager 重试
            print("发送失败: %s" % e, flush=True)
            self.send_response(502)
        self.end_headers()

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
