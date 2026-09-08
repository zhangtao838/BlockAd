/*
 * blocklist.h — 广告域名拦截表核心（纯 C，无 UIKit/无注入依赖）
 *
 * 数据结构：域名全部反转（如 "doubleclick.net" -> "ten.kcilcelbuod"）并
 * 按字典序排序，查询时对每个标签边界前缀做二分查找，支持"命中该域名的
 * 任意子域名"语义。用反转串是为了能直接二分查找前缀。
 */
#ifndef BLOCKLIST_H
#define BLOCKLIST_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 从文本文件加载。文件可含以下格式：
 *   - 每行一个域名（小写或混合大小写）
 *   - hosts 格式 "0.0.0.0 domain" / "127.0.0.1 domain"
 *   - 支持 "*.domain" 通配前缀、# 注释、空行
 * 成功返回 1；文件不存在/解析失败返回 0。重复调用幂等（只会加载一次）。
 */
int  bl_load_path(const char *path);

/* 是否已成功加载列表 */
int  bl_loaded(void);

/* host 命中拦截表返回 1（精确域名或任意子域名均算命中）。
 * IP 字面量、无列表、非域名输入一律返回 0。
 */
int  bl_host_blocked(const char *host);

/* 直接使用"反转+小写+排序"的只读数组（内置列表）。
 * 零拷贝、零堆分配：多个进程共享同一份物理内存，单个 App 额外占用≈0。 */
int  bl_use_array(const char *const *sortedRev, size_t count);

/* 从内存文本（每行一个域名 / hosts 格式）解析并热替换当前列表。
 * 供"自动更新规则"使用：后台下载 → 解析 → 原子替换（读路径并发安全）。 */
int  bl_load_text(const char *text);

/* 已加载条数（未加载返回 0，供诊断/设置页展示） */
size_t bl_count(void);

/* 成功加载的列表文件路径（未加载返回 NULL，供诊断用） */
const char *bl_path(void);

/* 释放全部内存（一般仅测试用） */
void bl_cleanup(void);

#ifdef __cplusplus
}
#endif

#endif /* BLOCKLIST_H */