# fork/orca-studio 分支说明

`main` 是上游真相来源,`fork/orca-studio` 是下游分支,设计约束是**始终能 rebase 回 main**——
所有改动尽量收敛在接缝(seam)上,不重构上游结构。

分支在 `main` 之上只加了两条互相独立的线。

## 一、本地后端接缝(local backend seam)

用 `PALMIER_BACKEND=local` 把 Convex + Clerk 换成对本地 `palmier-gateway` 的 HTTP 调用,
实现无账号、无额度、无外网的生成 / 转写 / 模型目录。

- 开关:`Backend/BackendMode.swift`,启动时解析一次;网关地址 `PALMIER_GATEWAY_URL`,默认 `http://localhost:5474`。
- 实现:`Backend/LocalBackend.swift` 复刻各 Convex 接缝的**解码类型**,每个调用点只加一处
  带守卫的提前返回——刻意不做协议抽象,以保证能干净地 rebase 到上游。
- 涉及接缝:账号(`AccountService`)、模型目录(`ModelCatalog`)、生成(`GenerationBackend`)、
  转写(`TranscriptionBackend`)、上传(`BackendStorage`)。
- 响应式的 `convex.subscribe` 由 0.8s 轮询 publisher 替代,终态由调用方取消。
- 附带 `scripts/run-signed.sh`:用稳定签名身份 + 固定 identifier 构建调试二进制,
  让钥匙串的「始终允许」在重复构建后仍然生效(`swift run` 的 ad-hoc 签名每次都变,会反复弹窗)。

```bash
PALMIER_BACKEND=local PALMIER_GATEWAY_URL=http://localhost:5474 \
SIGNING_IDENTITY=C1169D0A26059CDD4209CC52F851C5BBD8076A89 \
scripts/run-signed.sh
```

对接的网关仓库:`~/ghq/github.com/orca-studio/palmier-gateway`(Express + `orca-gateway-core`,
直接拉起本地 `orca-*` MLX skills,端口 5474 API / 5480 状态面板)。

完整的 HTTP 契约、字段级差异、以及已知的 client↔gateway 不一致,见
[docs/design/palmier-gateway-adapter.md](design/palmier-gateway-adapter.md)。

## 二、外部媒体源(external media providers)

从本机的资源服务读取素材,浏览并导入项目。与网关无关,cloud 模式下同样可用。

- 实现:`Sources/PalmierPro/MediaProviders/`——`AssetProvider` 协议 + 静态注册表。
- UI:媒体面板的 Sources 标签页,支持拖拽到时间线。
- Agent 工具:`list_sources`、`list_source_assets`、`import_source_asset`。
- 已注册的源(端口均可用环境变量覆盖):下载素材 `:4617`、自制成片 `:4618`、
  Photos 桥接 `:5374`、剪映素材 `:5174`、CapCut 素材 `:5274`。
- 回环地址的导入由 `AssetProviderRegistry.isRegisteredLoopback` 收口,只放行已注册的 host+port。

设计文档见 [docs/design/external-media-providers.md](design/external-media-providers.md)。

## 工作约定

- 频繁把 `main` 合入本分支,保持分歧尽量小;解冲突时默认采纳 main 的方向,fork 的工作在其上适配。
- fork 侧的适配只留在接缝处,不要为了本地模式改动上游类型或结构。
- 能在 `palmier-gateway` 侧修的问题就别改上游 Swift。
- 不影响主线的缺陷先记录在设计文档里,不当场修。
