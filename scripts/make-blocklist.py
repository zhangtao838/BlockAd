#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
make-blocklist.py — 从开源广告域名列表生成 BlockAd 拦截表

产物：layout/Library/BlockAd/blocklist.txt（打进 .deb，安装到 /Library/BlockAd/）
数据源（均来自成熟开源项目）：
  - VeleSila/yhosts           国内 App 广告 / 统计 / 追踪域名（hosts 格式）
  - OISD small（domains 格式） 全球通用追踪 / 广告 / 挖矿域名轻量版
解析失败时回退到仓库内置的 blocklist.base.txt，保证 CI 永远能出包。
"""
import pathlib
import re
import sys
import urllib.request

# (url, kind)  kind: "hosts" = "0.0.0.0 domain"，"domains" = 每行一个域名（可含 *. 通配）
SOURCES = [
    ("https://raw.githubusercontent.com/VeleSila/yhosts/master/hosts.txt", "hosts"),
    ("https://small.oisd.nl/domainswild", "domains"),
    ("https://raw.githubusercontent.com/AdAway/adaway.github.io/master/hosts.txt", "hosts"),
    # Loon/QuantumultX 社区广告规则（覆盖国内小众 App 广告域名，对齐 Loon 覆盖面）
    ("https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/QuantumultX/Advertising/Advertising.list", "kv_rules"),
]

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "layout" / "Library" / "BlockAd" / "blocklist.txt"
FALLBACK = ROOT / "blocklist.base.txt"

MAX_ENTRIES = 300000          # 内置列表上限（对齐 Loon 级别覆盖，仍为共享只读、零拷贝）

# 从真实设备 DNS 日志里抓到的"漏网广告网络"，保证每次都合并进名单
CUSTOM_DOMAINS = {
    "mosspf.cn", "mosspf.net",              # 魔山广告网络（da/tk/api/adx/mores.*）
    "1rtb.com",                              # 1rtb 广告（SSP 竞价服务器 ssp-svr.1rtb.com）
    "zhangyuyidong.cn",                      # 广告 SDK 主机
    "d2q1y7tir281x6.cloudfront.net",         # 广告素材 CDN（设备实测）
    "d3ttu8op0h9s85.cloudfront.net",         # 广告素材 CDN（设备实测）
    # HTTPDNS 服务器：拦截它们 = 逼广告 SDK 回落系统 DNS，广告域名才能进我们的 hook
    "httpdns.qq.com",                        # 腾讯 HTTPDNS（优量汇 GDT 用）
    "httpdns.volcengineapi.com",             # 字节跳动 HTTPDNS（穿山甲 CSJ 用）
    "httpdns.c.163.com",                     # 网易 HTTPDNS
    "httpdns.aliyuncs.com",                  # 阿里 HTTPDNS
    "httpdns.baidu.com",                     # 百度 HTTPDNS
    "dns.weixin.qq.com",                     # 微信内置 DNS
    "appconf.mail.163.com",                  # Loon 插件实测的 HTTPDNS 配置主机
    "msglb.91160.com",
    "upass.uc.cn",
    "gw-cn.jiaoliuqu.com",
    # 广告素材 CDN（设备日志实测为开屏素材来源）：
    # 注意：这些 CDN 同时服务抖音/快手等内容，请把注入清单里的这类 App 去掉
    "bytescm.com",                           # 字节广告素材 CDN（lf-cdn-tos）
    "douyinpic.com",                         # 广点通广告图素材（p5-ex-gddgtc-sign）
    "kwaiselfcdn.com",                       # 快手广告素材（merge-cover）
    "ksyuncdn.com", "ks-cdn.com",            # 穿山甲素材（金山云）
    "volcgtm.com",                           # 火山引擎素材（zx-vodad-all / sx-img）
    "ugslb.net", "ucloud.com.cn",            # 1rtb 素材（UCloud）
}
DOWNLOAD_TIMEOUT = 25

# 域名只允许这些字符（含保留扩展 '_'）
DOMAIN_CHARS = set("abcdefghijklmnopqrstuvwxyz0123456789.-_*")


def fetch(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": "BlockAd-update/1.0"})
    with urllib.request.urlopen(req, timeout=DOWNLOAD_TIMEOUT) as resp:
        return resp.read().decode("utf-8", "replace")


def wash_domain(raw: str) -> str | None:
    d = raw.strip().lstrip("0.*").rstrip(".")
    d = d.lower()
    if len(d) == 0 or len(d) > 253:
        return None
    if any(ch not in DOMAIN_CHARS for ch in d):
        return None
    # 剥前导 '*.'（通配条目）
    while d.startswith("*"):
        d = d[1:]
    if d.startswith("."):
        d = d[1:]
    if not d or d.startswith(".") or d.endswith("."):
        return None
    if "://" in d or " " in d:
        return None
    return d


def parse_kv_rules(text: str) -> set[str]:
    """解析 QuantumultX/Clash 规则：'HOST-SUFFIX,nodead.com,来源' 提取域名
    兼容 2 段（KEY,val）与 3 段（KEY,val,来源）写法；跳过 IP、关键字类规则。"""
    doms = set()
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or line.startswith("//"):
            continue
        parts = line.split(",")
        if len(parts) < 2:
            continue
        key = parts[0].strip().upper()
        val = parts[1].strip()
        if key not in ("DOMAIN", "DOMAIN-SUFFIX", "HOST", "HOST-SUFFIX"):
            continue
        # 纯 IP 条目跳过（如 HOST,10.10.34.34）
        if not any(ch.isalpha() for ch in val):
            continue
        d = wash_domain(val)
        if d:
            doms.add(d)
    return doms


def parse(kind: str, text: str) -> set[str]:
    doms = set()
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if kind == "hosts":
            parts = line.split()
            if len(parts) < 2:
                continue
            d = wash_domain(parts[-1])          # "0.0.0.0 domain" -> domain
        else:
            d = wash_domain(line)
        if d:
            doms.add(d)
    return doms


def main() -> int:
    all_doms = set(CUSTOM_DOMAINS)          # 先并入设备实测的漏网广告网络
    for url, kind in SOURCES:
        try:
            if kind == "kv_rules":
                doms = parse_kv_rules(fetch(url))
            else:
                doms = parse(kind, fetch(url))
            all_doms |= doms
            print(f"[OK] {kind:8s} {len(doms):>7d} 条  <- {url}")
        except Exception as exc:  # noqa: BLE001
            print(f"[! ] {kind:8s} 拉取/解析失败: {exc!r}\n      <- {url}", file=sys.stderr)

    if not all_doms:
        print("[! ] 所有数据源均失败，回退到内置 blocklist.base.txt", file=sys.stderr)
        all_doms = parse("base", FALLBACK.read_text(encoding="utf-8"))

    domains = sorted(all_doms)
    if len(domains) > MAX_ENTRIES:
        print(f"[i ] 条目 {len(domains)} 超过上限 {MAX_ENTRIES}，已截断")
        domains = domains[:MAX_ENTRIES]

    OUT.parent.mkdir(parents=True, exist_ok=True)
    with OUT.open("w", encoding="utf-8") as fh:
        fh.write("# BlockAd 拦截表（构建时自动生成，勿手改；修改请编辑脚本/数据源后重新构建）\n")
        fh.write(f"# 来源: yhosts + OISD + AdAway, 共 {len(domains)} 条\n")
        for d in domains:
            fh.write(d + "\n")

    # 同时生成 C 源：把列表"反转+小写+排序"后编译进 dylib，
    # App 直接在这份共享只读数据上二分查找 —— 规避沙盒读文件失败，且零拷贝、零额外内存
    C_FILE = ROOT / "blocklist_embedded.c"
    revs = sorted(d[::-1].lower() for d in domains)
    with C_FILE.open("w", encoding="utf-8") as fh:
        fh.write("/* 自动生成，勿手改 —— 内置拦截表（反转+小写+排序，供零拷贝二分查找） */\n")
        fh.write("#include <stddef.h>\n")
        fh.write("const char *const kBaDomains[] = {\n")
        for d in revs:
            esc = d.replace("\\", "\\\\").replace('"', '\\"')
            fh.write(f'    "{esc}",\n')
        fh.write("};\n")
        fh.write(f"const size_t kBaDomainCount = {len(revs)};\n")

    print(f"[OK] 已写入 {OUT}")
    print(f"[OK] 已写入 {C_FILE}（内嵌 {len(domains)} 条）")
    print(f"     共 {len(domains)} 条（去重后）")
    return 0


if __name__ == "__main__":
    sys.exit(main())